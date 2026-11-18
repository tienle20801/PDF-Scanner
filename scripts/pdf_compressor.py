"""Vector-preserving PDF compressor with embedded image downsampling and target-size search."""

from __future__ import annotations

import argparse
import io
import json
import math
import os
import shutil
import sys
import tempfile
import zlib
from pathlib import Path

import cv2
import numpy as np
from PIL import Image
from pypdf import PdfReader, PdfWriter
from pypdf.generic import (
    ContentStream,
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
    """Return (has_font, total_image_pixels) for page classification."""
    has_font = _page_has_fonts(page)
    sum_px = 0
    for _, _, stream in _iter_resource_xobjects(page.get("/Resources"), set()):
        w = int(stream.get("/Width", 0) or 0)
        h = int(stream.get("/Height", 0) or 0)
        sum_px += max(0, w) * max(0, h)
    return has_font, sum_px


def _page_size_inches(page) -> tuple[float, float]:
    box = page.cropbox if page.cropbox is not None else page.mediabox
    w_pt = max(1.0, abs(float(box.right) - float(box.left)))
    h_pt = max(1.0, abs(float(box.top) - float(box.bottom)))
    user_unit = float(page.get("/UserUnit", 1.0) or 1.0)
    if user_unit <= 0:
        user_unit = 1.0
    rotate = int(page.get("/Rotate", 0) or 0) % 360
    if rotate in (90, 270):
        w_pt, h_pt = h_pt, w_pt
    return (w_pt * user_unit) / 72.0, (h_pt * user_unit) / 72.0


def _mul_matrix(m1: tuple[float, ...], m2: tuple[float, ...]) -> tuple[float, float, float, float, float, float]:
    a1, b1, c1, d1, e1, f1 = m1
    a2, b2, c2, d2, e2, f2 = m2
    return (
        a1 * a2 + b1 * c2,
        a1 * b2 + b1 * d2,
        c1 * a2 + d1 * c2,
        c1 * b2 + d1 * d2,
        e1 * a2 + f1 * c2 + e2,
        e1 * b2 + f1 * d2 + f2,
    )


def _collect_xobject_draw_boxes_inches(page) -> dict[tuple[str, ...], tuple[float, float]]:
    """Map XObject key_path -> rendered (width_in, height_in) from page and nested /Form CTMs."""
    user_unit = float(page.get("/UserUnit", 1.0) or 1.0)
    if user_unit <= 0:
        user_unit = 1.0
    boxes: dict[tuple[str, ...], tuple[float, float]] = {}

    def _walk(
        content_obj,
        resources_obj,
        init_ctm: tuple[float, float, float, float, float, float],
        prefix: tuple[str, ...],
        seen_forms: frozenset[int],
    ) -> None:
        if content_obj is None:
            return
        res_dict = _deref(resources_obj)
        xobjs = _deref(res_dict.get("/XObject")) if isinstance(res_dict, dict) else None
        if not isinstance(xobjs, dict):
            return
        try:
            ops = ContentStream(content_obj, page.pdf).operations
        except Exception:
            return

        ctm = init_ctm
        stack: list[tuple[float, float, float, float, float, float]] = []
        for operands, op in ops:
            if op == b"q":
                stack.append(ctm)
            elif op == b"Q":
                if stack:
                    ctm = stack.pop()
            elif op == b"cm" and len(operands) >= 6:
                try:
                    m = tuple(float(v) for v in operands[:6])
                    ctm = _mul_matrix(m, ctm)
                except (TypeError, ValueError):
                    pass
            elif op == b"Do" and operands:
                name = str(operands[0])
                raw_ref = xobjs.get(name)
                if raw_ref is None:
                    continue
                stream = _deref(raw_ref)
                if not hasattr(stream, "get"):
                    continue
                subtype = str(stream.get("/Subtype", ""))
                key_path = prefix + (name,)
                if subtype == "/Image":
                    w_in = math.hypot(ctm[0], ctm[1]) * user_unit / 72.0
                    h_in = math.hypot(ctm[2], ctm[3]) * user_unit / 72.0
                    if w_in > 0.05 and h_in > 0.05:
                        prev = boxes.get(key_path)
                        if prev is None or (w_in * h_in) > (prev[0] * prev[1]):
                            boxes[key_path] = (w_in, h_in)
                elif subtype == "/Form":
                    obj_id = raw_ref.idnum if isinstance(raw_ref, IndirectObject) else id(stream)
                    if obj_id in seen_forms:
                        continue
                    form_mat_raw = _deref(stream.get("/Matrix"))
                    sub_ctm = ctm
                    if isinstance(form_mat_raw, (list, tuple)) and len(form_mat_raw) >= 6:
                        try:
                            fm = tuple(float(v) for v in form_mat_raw[:6])
                            sub_ctm = _mul_matrix(fm, ctm)
                        except (TypeError, ValueError):
                            pass
                    _walk(
                        stream,
                        stream.get("/Resources") or resources_obj,
                        sub_ctm,
                        key_path,
                        seen_forms | {obj_id},
                    )

    _walk(page.get_contents(), page.get("/Resources"), (1.0, 0.0, 0.0, 1.0, 0.0, 0.0), (), frozenset())
    return boxes


def _decode_xobject_pil(page, key_path: tuple[str, ...], stream) -> Image.Image | None:
    """Decode a PDF image XObject into a PIL Image using pypdf's page image decoder first."""
    first_exc: Exception | None = None
    try:
        lookup = key_path[0] if len(key_path) == 1 else key_path
        img_file = page.images[lookup]
        if getattr(img_file, "image", None) is not None:
            return img_file.image.copy()
        if getattr(img_file, "data", None):
            with Image.open(io.BytesIO(img_file.data)) as im:
                im.load()
                return im.copy()
    except Exception as exc:
        first_exc = exc
    try:
        with Image.open(io.BytesIO(stream.get_data())) as im:
            im.load()
            return im.copy()
    except Exception as exc:
        batch_scanner.logger.warning(
            "Failed to decode embedded image %s: %s",
            "/".join(key_path),
            first_exc or exc,
        )
        return None


def _recompress_image_stream_in_place(
    page,
    key_path: tuple[str, ...],
    stream,
    page_w_in: float,
    page_h_in: float,
    draw_box_in: tuple[float, float] | None,
    target_dpi: int,
    jpeg_quality: int,
    enhance_mode: str,
    auto_crop: bool,
) -> bool:
    """Re-encode an embedded /Image XObject in place as JPEG or 1-bit Flate (no orphaned objects)."""
    if stream.get("/ImageMask") is True or stream.get("/SMask") is not None or stream.get("/Mask") is not None:
        return False

    bpc = int(stream.get("/BitsPerComponent", 8) or 8)
    orig_w = int(stream.get("/Width", 0) or 0)
    orig_h = int(stream.get("/Height", 0) or 0)
    if (bpc < 8 and enhance_mode == "original" and not auto_crop) or orig_w * orig_h < 64_000:
        return False

    pil_img = _decode_xobject_pil(page, key_path, stream)
    if pil_img is None:
        return False

    try:
        bgr: np.ndarray | None = None
        if enhance_mode != "original" or auto_crop:
            bgr = batch_scanner._pil_to_bgr(pil_img)
            if auto_crop:
                bgr = batch_scanner.detect_and_crop(bgr)
            if enhance_mode != "original":
                bgr = batch_scanner.enhance_image_bgr(bgr, mode=enhance_mode)
            cur_h, cur_w = bgr.shape[:2]
        else:
            cur_w, cur_h = pil_img.size

        if draw_box_in is not None:
            box_w_in, box_h_in = draw_box_in
        else:
            box_w_in, box_h_in = page_w_in, page_h_in
            if (cur_w > cur_h) != (box_w_in > box_h_in):
                box_w_in, box_h_in = box_h_in, box_w_in

        eff_dpi = max(cur_w / max(box_w_in, 0.5), cur_h / max(box_h_in, 0.5))
        needs_resize = eff_dpi > (target_dpi * 1.04)
        new_w, new_h = cur_w, cur_h
        if needs_resize:
            scale = float(target_dpi) / max(eff_dpi, 1.0)
            new_w = max(32, int(round(cur_w * scale)))
            new_h = max(32, int(round(cur_h * scale)))

        if bgr is not None:
            if needs_resize:
                bgr = cv2.resize(bgr, (new_w, new_h), interpolation=cv2.INTER_AREA)
            canon = batch_scanner.normalize_enhance_mode(enhance_mode)
            work_pil = batch_scanner._bgr_to_pil(bgr, canon)
        elif needs_resize:
            if pil_img.mode == "1":
                work_pil = pil_img.convert("L").resize((new_w, new_h), Image.Resampling.LANCZOS).convert(
                    "1", dither=Image.Dither.NONE
                )
            else:
                work_pil = pil_img.resize((new_w, new_h), Image.Resampling.LANCZOS)
        else:
            work_pil = pil_img

        orig_stream_len = len(getattr(stream, "_data", b"") or b"")
        out_w, out_h = work_pil.size

        if work_pil.mode == "1":
            out_bytes = zlib.compress(work_pil.tobytes(), level=9)
            if (
                orig_stream_len > 0
                and bpc == 1
                and not needs_resize
                and not auto_crop
                and len(out_bytes) >= orig_stream_len
            ):
                return False
            stream_meta = {
                NameObject("/Type"): NameObject("/XObject"),
                NameObject("/Subtype"): NameObject("/Image"),
                NameObject("/Width"): NumberObject(out_w),
                NameObject("/Height"): NumberObject(out_h),
                NameObject("/ColorSpace"): NameObject("/DeviceGray"),
                NameObject("/BitsPerComponent"): NumberObject(1),
                NameObject("/Filter"): NameObject("/FlateDecode"),
                NameObject("/Length"): NumberObject(len(out_bytes)),
            }
        else:
            if work_pil.mode in ("I;16", "I;16B", "I;16L", "I;16N", "I"):
                bgr16 = batch_scanner._pil_to_bgr(work_pil)
                work_pil = Image.fromarray(cv2.cvtColor(bgr16, cv2.COLOR_BGR2GRAY), mode="L")
            elif work_pil.mode not in ("RGB", "L"):
                if "A" in work_pil.mode or work_pil.info.get("transparency") is not None:
                    rgba = work_pil.convert("RGBA")
                    bg = Image.new("RGBA", rgba.size, (255, 255, 255, 255))
                    work_pil = Image.alpha_composite(bg, rgba).convert("RGB")
                else:
                    work_pil = work_pil.convert("RGB")

            buf = io.BytesIO()
            work_pil.save(buf, format="JPEG", quality=jpeg_quality, optimize=True, progressive=False)
            out_bytes = buf.getvalue()
            if (
                orig_stream_len > 0
                and not needs_resize
                and enhance_mode == "original"
                and not auto_crop
                and len(out_bytes) >= orig_stream_len
            ):
                return False

            cs = NameObject("/DeviceGray") if work_pil.mode == "L" else NameObject("/DeviceRGB")
            stream_meta = {
                NameObject("/Type"): NameObject("/XObject"),
                NameObject("/Subtype"): NameObject("/Image"),
                NameObject("/Width"): NumberObject(out_w),
                NameObject("/Height"): NumberObject(out_h),
                NameObject("/ColorSpace"): cs,
                NameObject("/BitsPerComponent"): NumberObject(8),
                NameObject("/Filter"): NameObject("/DCTDecode"),
                NameObject("/Length"): NumberObject(len(out_bytes)),
            }

        # Mutate the cloned stream object directly in-place inside the writer so old streams are overwritten, not orphaned
        stream.__class__ = EncodedStreamObject
        stream.clear()
        stream.update(stream_meta)
        stream._data = out_bytes
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
    if reader.is_encrypted:
        try:
            decrypted = reader.decrypt("")
        except Exception:
            decrypted = 0
        if not decrypted:
            raise ValueError(f"Input PDF is password-protected/encrypted: {source_pdf}")

    writer = PdfWriter()
    vector_pages = 0
    image_pages = 0
    recompressed_images = 0
    seen_xobj_ids: set[int] = set()

    for page in reader.pages:
        has_font, sum_px = _classify_page(page)
        page_w_in, page_h_in = _page_size_inches(page)

        # Preserve pure vector/text pages untouched (no rasterization!)
        if has_font and sum_px < 300_000:
            writer.add_page(page)
            vector_pages += 1
            continue

        draw_boxes = _collect_xobject_draw_boxes_inches(page)
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
                draw_box_in=draw_boxes.get(key_path),
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
        elif page_modified or sum_px > 0:
            image_pages += 1
        else:
            vector_pages += 1

    out_abs = batch_scanner._atomic_write_bytes(dest_pdf, writer.write)
    return {
        "pages": len(reader.pages),
        "vector_pages": vector_pages,
        "image_pages": image_pages,
        "recompressed_images": recompressed_images,
        "after_bytes": os.path.getsize(out_abs),
    }


def _atomic_copy_file(src_path: str | os.PathLike[str], dest_path: str | os.PathLike[str]) -> None:
    def _copy(fp) -> None:
        with open(src_path, "rb") as src_fp:
            shutil.copyfileobj(src_fp, fp)

    batch_scanner._atomic_write_bytes(dest_path, _copy)


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
    if not os.path.isfile(source_pdf):
        raise FileNotFoundError(f"Input PDF not found: {source_pdf}")

    before_bytes = os.path.getsize(source_pdf)
    canon_mode = batch_scanner.normalize_enhance_mode(mode)
    target_bytes = int(target_mb * 1024 * 1024) if target_mb > 0 else 0
    base_dpi = max(72, int(dpi))
    base_q = max(35, min(95, int(jpeg_quality)))
    same_in_out = batch_scanner._canonical_path(source_pdf) == batch_scanner._canonical_path(output_pdf)

    with tempfile.TemporaryDirectory(prefix="pdfcomp_") as td:
        td_path = Path(td)
        staged_source = td_path / "source.pdf"
        shutil.copy2(source_pdf, staged_source)

        init_path = td_path / "init.pdf"
        stats = _compress_once(
            source_pdf=str(staged_source),
            dest_pdf=str(init_path),
            target_dpi=base_dpi,
            jpeg_quality=base_q,
            enhance_mode=canon_mode,
            auto_crop=auto_crop,
        )
        used_dpi = base_dpi
        used_q = base_q
        chosen_path = init_path

        if target_bytes > 0 and stats["after_bytes"] > target_bytes and stats["recompressed_images"] > 0:
            dpi_levels = sorted(
                {d for d in (base_dpi, min(base_dpi, 125), min(base_dpi, 100), min(base_dpi, 85)) if d <= base_dpi},
                reverse=True,
            )
            best_fit: tuple[Path, dict, int, int] | None = None
            smallest_any: tuple[Path, dict, int, int] = (init_path, stats, base_dpi, base_q)
            probe_idx = 0

            def _run_probe(d_try: int, q_try: int) -> tuple[Path, dict]:
                nonlocal probe_idx, smallest_any
                probe_idx += 1
                cand_path = td_path / f"cand_{probe_idx}.pdf"
                cand_stats = _compress_once(
                    source_pdf=str(staged_source),
                    dest_pdf=str(cand_path),
                    target_dpi=d_try,
                    jpeg_quality=q_try,
                    enhance_mode=canon_mode,
                    auto_crop=auto_crop,
                )
                if cand_stats["after_bytes"] < smallest_any[1]["after_bytes"]:
                    smallest_any = (cand_path, cand_stats, d_try, q_try)
                return cand_path, cand_stats

            for d_cand in dpi_levels:
                if canon_mode == "bw":
                    c_path, c_stats = _run_probe(d_cand, base_q)
                    if c_stats["after_bytes"] <= target_bytes:
                        best_fit = (c_path, c_stats, d_cand, base_q)
                        break
                    continue

                q_list = [q for q in (75, 62, 50, 40, 35) if not (d_cand == base_dpi and q >= base_q)]
                if not q_list:
                    continue

                # Check lowest quality at this DPI first so non-monotonic DPI/Q grids never skip valid higher DPIs
                q_min = q_list[-1]
                low_path, low_stats = _run_probe(d_cand, q_min)
                if low_stats["after_bytes"] <= target_bytes:
                    best_fit = (low_path, low_stats, d_cand, q_min)
                    for q_try in q_list[:-1]:
                        hi_path, hi_stats = _run_probe(d_cand, q_try)
                        if hi_stats["after_bytes"] <= target_bytes:
                            best_fit = (hi_path, hi_stats, d_cand, q_try)
                            break
                    break

            chosen = best_fit if best_fit is not None else smallest_any
            if chosen[1]["after_bytes"] < stats["after_bytes"] or (
                best_fit is not None and chosen[1]["after_bytes"] <= target_bytes < stats["after_bytes"]
            ):
                chosen_path, stats, used_dpi, used_q = chosen

        # Guard: if original source PDF is already smaller or equal under non-forced compress, keep original
        kept_original = False
        if canon_mode == "original" and not auto_crop and stats["after_bytes"] >= before_bytes:
            kept_original = True
            stats = {
                **stats,
                "recompressed_images": 0,
                "after_bytes": before_bytes,
            }
            if not same_in_out:
                _atomic_copy_file(staged_source, output_pdf)
        else:
            _atomic_copy_file(chosen_path, output_pdf)

    after_bytes = os.path.getsize(output_pdf)
    target_achieved = True if target_bytes == 0 else (after_bytes <= target_bytes)

    msg_parts = []
    if kept_original:
        msg_parts.append("Giữ nguyên PDF gốc (dung lượng đã tối ưu hơn hoặc bằng bản nén).")
    elif stats["vector_pages"] > 0 and stats["image_pages"] == 0:
        msg_parts.append(f"Giữ nguyên {stats['vector_pages']} trang vector/text.")
    elif stats["vector_pages"] > 0:
        msg_parts.append(
            f"Giữ nguyên {stats['vector_pages']} trang vector/text; nén {stats['recompressed_images']} ảnh trên {stats['image_pages']} trang."
        )
    else:
        msg_parts.append(f"Đã nén {stats['recompressed_images']} ảnh nhúng trên {stats['image_pages']} trang (giữ nguyên khổ trang gốc).")

    if not target_achieved:
        target_str = f"{target_mb:.2f} MiB" if target_mb >= 0.01 else f"{target_mb:.4f} MiB"
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


def _write_json_report(report_path: str | None, payload: dict) -> None:
    if not report_path:
        return
    data = json.dumps(payload, indent=2, ensure_ascii=False).encode("utf-8")
    batch_scanner._atomic_write_bytes(report_path, lambda fp: fp.write(data))


if __name__ == "__main__":
    args = _build_parser().parse_args()
    try:
        res = compress_pdf(
            source_pdf=args.source_pdf,
            output_pdf=args.output_pdf,
            dpi=args.dpi,
            jpeg_quality=args.jpeg_quality,
            target_mb=args.target_mb,
            mode=args.mode,
            auto_crop=args.auto_crop,
        )
    except Exception as exc:
        err_msg = str(exc) or exc.__class__.__name__
        err_payload = {
            "status": "error",
            "error": exc.__class__.__name__,
            "message": err_msg,
            "before_bytes": 0,
            "after_bytes": 0,
            "pages": 0,
            "vector_pages": 0,
            "image_pages": 0,
            "recompressed_images": 0,
            "target_bytes": int(args.target_mb * 1024 * 1024) if args.target_mb > 0 else 0,
            "target_achieved": False,
            "used_dpi": max(72, int(args.dpi)),
            "used_quality": max(35, min(95, int(args.jpeg_quality))),
        }
        try:
            _write_json_report(args.json_report, err_payload)
        except Exception:
            pass
        print(f"[ERROR] {err_msg}", file=sys.stderr, flush=True)
        sys.exit(1)

    _write_json_report(args.json_report, res)
    print(json.dumps(res, ensure_ascii=False), flush=True)
