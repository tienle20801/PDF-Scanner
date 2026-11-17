"""Vector-preserving PDF compressor with embedded image downsampling and target-size search."""

from __future__ import annotations

import argparse
import io
import json
import os
import sys
import tempfile
from pathlib import Path

import cv2
import numpy as np
from PIL import Image
from pypdf import PdfReader, PdfWriter
from pypdf.generic import (
    EncodedStreamObject,
    IndirectObject,
    NameObject,
    NumberObject,
)

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import batch_scanner  # noqa: E402


def _deref(obj):
    return obj.get_object() if isinstance(obj, IndirectObject) else obj


def _page_has_fonts(page) -> bool:
    resources = _deref(page.get("/Resources"))
    if not isinstance(resources, dict):
        return False
    fonts = _deref(resources.get("/Font"))
    return bool(isinstance(fonts, dict) and len(fonts) > 0)


def _iter_resource_xobjects(resources, seen_forms: set[int], prefix: tuple[str, ...] = ()):
    """Yield (key_path, raw_ref, stream_obj) across page and nested /Form XObjects."""
    res_obj = _deref(resources)
    if not isinstance(res_obj, dict):
        return
    xobjs = _deref(res_obj.get("/XObject"))
    if not isinstance(xobjs, dict):
        return

    for key in list(xobjs.keys()):
        raw_ref = xobjs[key]
        obj_id = raw_ref.idnum if isinstance(raw_ref, IndirectObject) else id(raw_ref)
        stream = _deref(raw_ref)
        if not hasattr(stream, "get"):
            continue
        subtype = str(stream.get("/Subtype", ""))
        key_path = prefix + (str(key),)
        if subtype == "/Image":
            yield key_path, raw_ref, stream
        elif subtype == "/Form":
            if obj_id in seen_forms:
                continue
            seen_forms.add(obj_id)
            yield from _iter_resource_xobjects(stream.get("/Resources"), seen_forms, key_path)


def _classify_page(page) -> tuple[bool, int]:
    """Return (has_font, max_image_pixels) for page classification."""
    has_font = _page_has_fonts(page)
    max_px = 0
    for _, _, stream in _iter_resource_xobjects(page.get("/Resources"), set()):
        w = int(stream.get("/Width", 0) or 0)
        h = int(stream.get("/Height", 0) or 0)
        max_px = max(max_px, w * h)
    return has_font, max_px


def _page_size_inches(page) -> tuple[float, float]:
    box = page.cropbox if page.cropbox is not None else page.mediabox
    w_pt = max(1.0, abs(float(box.right) - float(box.left)))
    h_pt = max(1.0, abs(float(box.top) - float(box.bottom)))
    return w_pt / 72.0, h_pt / 72.0


def _decode_xobject_pil(page, key_path: tuple[str, ...], stream) -> Image.Image | None:
    """Decode a PDF image XObject into a PIL Image using pypdf's page image decoder first."""
    try:
        lookup = key_path[0] if len(key_path) == 1 else key_path
        img_file = page.images[lookup]
        if getattr(img_file, "image", None) is not None:
            return img_file.image.copy()
        if getattr(img_file, "data", None):
            with Image.open(io.BytesIO(img_file.data)) as im:
                im.load()
                return im.copy()
    except Exception:
        pass
    try:
        with Image.open(io.BytesIO(stream.get_data())) as im:
            im.load()
            return im.copy()
    except Exception:
        return None


def _recompress_image_stream_in_place(
    page,
    key_path: tuple[str, ...],
    stream,
    page_w_in: float,
    page_h_in: float,
    target_dpi: int,
    jpeg_quality: int,
    enhance_mode: str,
    auto_crop: bool,
) -> bool:
    """Re-encode an embedded /Image XObject in place as optimized JPEG (no orphaned objects)."""
    if stream.get("/ImageMask") is True or stream.get("/SMask") is not None or stream.get("/Mask") is not None:
        return False

    bpc = int(stream.get("/BitsPerComponent", 8) or 8)
    orig_w = int(stream.get("/Width", 0) or 0)
    orig_h = int(stream.get("/Height", 0) or 0)
    if bpc < 8 or orig_w * orig_h < 64_000:
        return False

    pil_img = _decode_xobject_pil(page, key_path, stream)
    if pil_img is None:
        return False

    try:
        cur_w, cur_h = pil_img.size
        eff_dpi = max(cur_w / max(page_w_in, 0.5), cur_h / max(page_h_in, 0.5))
        needs_resize = eff_dpi > (target_dpi * 1.04)
        new_w, new_h = cur_w, cur_h
        if needs_resize:
            scale = float(target_dpi) / max(eff_dpi, 1.0)
            new_w = max(32, int(round(cur_w * scale)))
            new_h = max(32, int(round(cur_h * scale)))

        work_pil = pil_img
        if enhance_mode != "original" or auto_crop:
            bgr = batch_scanner._pil_to_bgr(work_pil)
            if auto_crop:
                bgr = batch_scanner.detect_and_crop(bgr)
            if enhance_mode != "original":
                bgr = batch_scanner.enhance_image_bgr(bgr, mode=enhance_mode)
            if needs_resize:
                bgr = cv2.resize(bgr, (new_w, new_h), interpolation=cv2.INTER_AREA)
            canon = batch_scanner.normalize_enhance_mode(enhance_mode)
            work_pil = batch_scanner._bgr_to_pil(bgr, canon)
        elif needs_resize:
            work_pil = work_pil.resize((new_w, new_h), Image.Resampling.LANCZOS)

        if work_pil.mode == "1":
            work_pil = work_pil.convert("L")
        elif work_pil.mode not in ("RGB", "L"):
            if "A" in work_pil.mode:
                bg = Image.new("RGB", work_pil.size, (255, 255, 255))
                rgba = work_pil.convert("RGBA")
                bg.paste(rgba, mask=rgba.split()[-1])
                work_pil = bg
            else:
                work_pil = work_pil.convert("RGB")

        buf = io.BytesIO()
        work_pil.save(buf, format="JPEG", quality=jpeg_quality, optimize=True, progressive=False)
        jpeg_bytes = buf.getvalue()

        orig_stream_len = len(getattr(stream, "_data", b"") or b"")
        if orig_stream_len > 0 and not needs_resize and enhance_mode == "original" and len(jpeg_bytes) >= orig_stream_len:
            return False

        out_w, out_h = work_pil.size
        cs = NameObject("/DeviceGray") if work_pil.mode == "L" else NameObject("/DeviceRGB")

        # Mutate the cloned stream object directly in-place inside the writer so old streams are overwritten, not orphaned
        stream.__class__ = EncodedStreamObject
        stream.clear()
        stream.update(
            {
                NameObject("/Type"): NameObject("/XObject"),
                NameObject("/Subtype"): NameObject("/Image"),
                NameObject("/Width"): NumberObject(out_w),
                NameObject("/Height"): NumberObject(out_h),
                NameObject("/ColorSpace"): cs,
                NameObject("/BitsPerComponent"): NumberObject(8),
                NameObject("/Filter"): NameObject("/DCTDecode"),
                NameObject("/Length"): NumberObject(len(jpeg_bytes)),
            }
        )
        stream._data = jpeg_bytes
        return True
    finally:
        pil_img.close()


def _compress_once(
    source_pdf: str,
    dest_pdf: str,
    target_dpi: int,
    jpeg_quality: int,
    enhance_mode: str,
    auto_crop: bool,
) -> dict:
    reader = PdfReader(source_pdf)
    writer = PdfWriter()
    vector_pages = 0
    image_pages = 0
    recompressed_images = 0
    seen_xobj_ids: set[int] = set()

    for page in reader.pages:
        has_font, max_px = _classify_page(page)
        page_w_in, page_h_in = _page_size_inches(page)

        # Preserve pure vector/text pages untouched (no rasterization!)
        if has_font and max_px < 300_000:
            writer.add_page(page)
            vector_pages += 1
            continue

        added_page = writer.add_page(page)
        page_modified = False
        for key_path, raw_ref, stream in _iter_resource_xobjects(added_page.get("/Resources"), set()):
            ref_id = raw_ref.idnum if isinstance(raw_ref, IndirectObject) else id(stream)
            if ref_id in seen_xobj_ids:
                continue
            seen_xobj_ids.add(ref_id)

            changed = _recompress_image_stream_in_place(
                added_page,
                key_path=key_path,
                stream=stream,
                page_w_in=page_w_in,
                page_h_in=page_h_in,
                target_dpi=target_dpi,
                jpeg_quality=jpeg_quality,
                enhance_mode=enhance_mode,
                auto_crop=auto_crop,
            )
            if changed:
                recompressed_images += 1
                page_modified = True

        if has_font and not page_modified:
            vector_pages += 1
        elif page_modified or max_px > 0:
            image_pages += 1
        else:
            vector_pages += 1

    # Remove unreferenced objects if supported and write atomically
    out_abs = os.path.abspath(dest_pdf)
    os.makedirs(os.path.dirname(out_abs), exist_ok=True)
    tmp_out = f"{out_abs}.tmp.{os.getpid()}"
    try:
        with open(tmp_out, "wb") as fp:
            writer.write(fp)
        os.replace(tmp_out, out_abs)
    finally:
        if os.path.exists(tmp_out):
            os.remove(tmp_out)

    return {
        "pages": len(reader.pages),
        "vector_pages": vector_pages,
        "image_pages": image_pages,
        "recompressed_images": recompressed_images,
        "after_bytes": os.path.getsize(out_abs),
    }


def compress_pdf(
    source_pdf: str,
    output_pdf: str,
    dpi: int = 150,
    jpeg_quality: int = 80,
    target_mb: float = 0.0,
    mode: str = "original",
    auto_crop: bool = False,
) -> dict:
    """Compress embedded scan images while preserving vector text pages and original MediaBoxes."""
    if not os.path.exists(source_pdf):
        raise FileNotFoundError(f"Input PDF not found: {source_pdf}")

    before_bytes = os.path.getsize(source_pdf)
    canon_mode = batch_scanner.normalize_enhance_mode(mode)
    target_bytes = int(target_mb * 1024 * 1024) if target_mb > 0 else 0
    base_dpi = max(72, int(dpi))
    base_q = max(35, min(95, int(jpeg_quality)))

    # Initial pass at user's chosen DPI & quality
    stats = _compress_once(
        source_pdf=source_pdf,
        dest_pdf=output_pdf,
        target_dpi=base_dpi,
        jpeg_quality=base_q,
        enhance_mode=canon_mode,
        auto_crop=auto_crop,
    )
    used_dpi = base_dpi
    used_q = base_q

    if target_bytes > 0 and stats["after_bytes"] > target_bytes and stats["recompressed_images"] > 0:
        with tempfile.TemporaryDirectory(prefix="pdfcomp_") as td:
            # Candidate grid ordered from highest readability down to minimum readable preset
            candidates: list[tuple[int, int]] = []
            for d_cand in sorted({base_dpi, min(base_dpi, 125), min(base_dpi, 100), 85}, reverse=True):
                for q_cand in (75, 62, 50, 40, 35):
                    if d_cand == base_dpi and q_cand >= base_q:
                        continue
                    candidates.append((d_cand, q_cand))

            # Binary search along monotonic quality/DPI degradation ladder when possible; fallback linear refine
            lo, hi = 0, len(candidates) - 1
            best_fit: tuple[Path, dict, int, int] | None = None
            smallest_any: tuple[Path, dict, int, int] | None = (None, stats, base_dpi, base_q)  # type: ignore

            probe_idx = 0
            while lo <= hi:
                mid = (lo + hi) // 2
                d_try, q_try = candidates[mid]
                probe_idx += 1
                cand_path = Path(td) / f"cand_{probe_idx}.pdf"
                cand_stats = _compress_once(
                    source_pdf=source_pdf,
                    dest_pdf=str(cand_path),
                    target_dpi=d_try,
                    jpeg_quality=q_try,
                    enhance_mode=canon_mode,
                    auto_crop=auto_crop,
                )
                if smallest_any[0] is None or cand_stats["after_bytes"] < smallest_any[1]["after_bytes"]:
                    smallest_any = (cand_path, cand_stats, d_try, q_try)

                if cand_stats["after_bytes"] <= target_bytes:
                    best_fit = (cand_path, cand_stats, d_try, q_try)
                    hi = mid - 1  # Try higher quality / DPI still fitting under target
                else:
                    lo = mid + 1  # Need stronger compression

            chosen = best_fit if best_fit is not None else smallest_any
            if chosen[0] is not None and chosen[1]["after_bytes"] < stats["after_bytes"]:
                os.replace(str(chosen[0]), os.path.abspath(output_pdf))
                stats = chosen[1]
                used_dpi = chosen[2]
                used_q = chosen[3]

    # Guard: if original source PDF is already smaller and user didn't request enhancement/crop, keep smallest unless target not affected
    after_bytes = os.path.getsize(output_pdf)
    target_achieved = True if target_bytes == 0 else (after_bytes <= target_bytes)

    msg_parts = []
    if stats["vector_pages"] > 0 and stats["image_pages"] == 0:
        msg_parts.append(f"Giữ nguyên {stats['vector_pages']} trang vector/text.")
    elif stats["vector_pages"] > 0:
        msg_parts.append(
            f"Giữ nguyên {stats['vector_pages']} trang vector/text; nén {stats['recompressed_images']} ảnh trên {stats['image_pages']} trang."
        )
    else:
        msg_parts.append(f"Đã nén {stats['recompressed_images']} ảnh nhúng trên {stats['image_pages']} trang (giữ nguyên khổ trang gốc).")

    if not target_achieved:
        target_str = f"{target_mb:.1f} MB"
        after_mb = after_bytes / (1024.0 * 1024.0)
        msg_parts.append(
            f"Không thể nén nhỏ hơn {target_str} mà vẫn giữ nguyên trang vector và độ đọc tối thiểu (đạt {after_mb:.2f} MiB ở {used_dpi} DPI, Q={used_q})."
        )

    return {
        "before_bytes": before_bytes,
        "after_bytes": after_bytes,
        "pages": stats["pages"],
        "vector_pages": stats["vector_pages"],
        "image_pages": stats["image_pages"],
        "recompressed_images": stats["recompressed_images"],
        "target_bytes": target_bytes,
        "target_achieved": target_achieved,
        "used_dpi": used_dpi,
        "used_quality": used_q,
        "message": " ".join(msg_parts),
    }


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Vector-preserving PDF compressor")
    p.add_argument("source_pdf", help="Source PDF path")
    p.add_argument("output_pdf", help="Output compressed PDF path")
    p.add_argument("--dpi", type=int, default=150, help="Max target DPI for embedded raster images (default: 150)")
    p.add_argument("--jpeg-quality", type=int, default=80, help="Initial JPEG quality 35..95 (default: 80)")
    p.add_argument("--target-mb", type=float, default=0.0, help="Optional target size limit in MiB (0 disables)")
    p.add_argument(
        "--mode",
        choices=["original", "auto_color", "magic_color", "clean", "bw", "grayscale"],
        default="original",
        help="Optional enhancement filter for embedded images (default: original)",
    )
    p.add_argument("--auto-crop", action="store_true", help="Optionally auto-crop embedded images before re-encoding")
    p.add_argument("--json-report", default=None, help="Write structured JSON result summary to path")
    return p


if __name__ == "__main__":
    args = _build_parser().parse_args()
    res = compress_pdf(
        source_pdf=args.source_pdf,
        output_pdf=args.output_pdf,
        dpi=args.dpi,
        jpeg_quality=args.jpeg_quality,
        target_mb=args.target_mb,
        mode=args.mode,
        auto_crop=args.auto_crop,
    )
    if args.json_report:
        rp = Path(args.json_report)
        rp.parent.mkdir(parents=True, exist_ok=True)
        rp.write_text(json.dumps(res, indent=2), encoding="utf-8")
    print(json.dumps(res), flush=True)
