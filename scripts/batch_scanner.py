from __future__ import annotations

import argparse
from concurrent.futures import ProcessPoolExecutor, as_completed
import gc
import io
import json
import logging
import multiprocessing
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata
import uuid
import zlib
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageOps
from pypdf import PageObject, PdfReader, PdfWriter
from pypdf.generic import DecodedStreamObject, DictionaryObject, EncodedStreamObject, NameObject, NumberObject

logger = logging.getLogger("pdf_scanner")
if not logger.handlers:
    _handler = logging.StreamHandler(sys.stderr)
    _handler.setFormatter(logging.Formatter("%(message)s"))
    logger.addHandler(_handler)
    logger.setLevel(logging.INFO)
    logger.propagate = False

try:
    import pillow_heif

    pillow_heif.register_heif_opener()
except ImportError:
    pass

SUPPORTED_IMAGE_EXTENSIONS = {
    ".jpg",
    ".jpeg",
    ".png",
    ".bmp",
    ".webp",
    ".tif",
    ".tiff",
    ".heic",
    ".heif",
}
SUPPORTED_EXTENSIONS = SUPPORTED_IMAGE_EXTENSIONS | {".pdf"}

_MODE_ALIASES = {"magic_color": "auto_color"}


def normalize_enhance_mode(mode: str) -> str:
    """Normalize enhancement mode aliases while keeping backward compatibility."""
    return _MODE_ALIASES.get(mode, mode)

_MAGIC_LUT = np.array(
    [
        255
        if i >= 235
        else (
            int(205 + (i - 215) * (50.0 / 20.0))
            if i >= 215
            else int(((i / 215.0) ** 1.55) * 205)
        )
        for i in range(256)
    ],
    dtype=np.uint8,
)
_SHARPEN_KERNEL = np.array(
    [[0.0, -0.25, 0.0], [-0.25, 2.0, -0.25], [0.0, -0.25, 0.0]],
    dtype=np.float32,
)
_LINE_BOOST_LUT = np.clip(np.arange(256, dtype=np.float32) * 0.85, 0, 255).astype(np.uint8)
_KERNEL_2x2 = cv2.getStructuringElement(cv2.MORPH_RECT, (2, 2))
_KERNEL_3x3 = cv2.getStructuringElement(cv2.MORPH_RECT, (3, 3))
_KERNEL_3x5 = cv2.getStructuringElement(cv2.MORPH_RECT, (5, 3))
_KERNEL_2x15 = cv2.getStructuringElement(cv2.MORPH_RECT, (15, 2))
_KERNEL_15x15 = cv2.getStructuringElement(cv2.MORPH_RECT, (15, 15))
_KERNEL_9x9 = cv2.getStructuringElement(cv2.MORPH_RECT, (9, 9))
_KERNEL_1x35 = cv2.getStructuringElement(cv2.MORPH_RECT, (35, 1))
_KERNEL_35x1 = cv2.getStructuringElement(cv2.MORPH_RECT, (1, 35))
_KERNEL_1x7 = cv2.getStructuringElement(cv2.MORPH_RECT, (7, 1))
_KERNEL_7x1 = cv2.getStructuringElement(cv2.MORPH_RECT, (1, 7))
_KERNEL_2x13 = cv2.getStructuringElement(cv2.MORPH_RECT, (13, 2))
_KERNEL_13x2 = cv2.getStructuringElement(cv2.MORPH_RECT, (2, 13))
_KERNEL_31x31 = cv2.getStructuringElement(cv2.MORPH_RECT, (31, 31))


def _canonical_path(path: str | os.PathLike[str]) -> str:
    """Return resolved realpath normalized to Unicode NFC for APFS/Vision parity."""
    return unicodedata.normalize("NFC", os.path.realpath(os.fspath(path)))


def _atomic_write_bytes(dest_path: str | os.PathLike[str], writer_fn) -> str:
    """Write bytes via an unpredictable temp file in the destination dir and atomically replace."""
    out_abs = os.path.abspath(os.fspath(dest_path))
    out_dir = os.path.dirname(out_abs) or "."
    os.makedirs(out_dir, exist_ok=True)
    base = os.path.basename(out_abs)
    tmp_path: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            dir=out_dir,
            prefix=f".{base}.",
            suffix=".tmp",
            delete=False,
        ) as fp:
            tmp_path = fp.name
            writer_fn(fp)
        os.replace(tmp_path, out_abs)
        tmp_path = None
        return out_abs
    except BaseException:
        if tmp_path and os.path.exists(tmp_path):
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
        raise


def _natural_sort_key(filename: str):
    """Sort filenames naturally so page2.jpg comes before page10.jpg."""
    return [int(token) if token.isdigit() else token.lower() for token in re.split(r"(\d+)", filename)]


def find_images(input_path: str) -> list[str]:
    """Return naturally sorted list of supported files from a single file or directory."""
    if os.path.isfile(input_path):
        return [input_path]
    if not os.path.isdir(input_path):
        return []

    matched = [
        entry
        for entry in os.listdir(input_path)
        if not entry.startswith(".")
        and os.path.isfile(os.path.join(input_path, entry))
        and os.path.splitext(entry)[1].lower() in SUPPORTED_EXTENSIONS
    ]
    matched.sort(key=_natural_sort_key)
    return [os.path.join(input_path, name) for name in matched]


def _pil_to_bgr(pil_img: Image.Image) -> np.ndarray:
    """Apply EXIF orientation, scale 16-bit/int gray, flatten transparency over white, and convert to BGR."""
    transposed = ImageOps.exif_transpose(pil_img)
    if transposed.mode in ("I;16", "I;16B", "I;16L", "I;16N"):
        arr16 = np.asarray(transposed).astype(np.uint16)
        arr8 = (arr16 >> 8).astype(np.uint8)
        if isinstance(transposed.info.get("transparency"), int):
            arr8 = np.where(arr16 == transposed.info["transparency"], 255, arr8).astype(np.uint8)
        return cv2.cvtColor(arr8, cv2.COLOR_GRAY2BGR)
    if transposed.mode == "I":
        arr_i = np.asarray(transposed, dtype=np.int64)
        if arr_i.size == 0:
            return np.zeros((0, 0, 3), dtype=np.uint8)
        max_v, min_v = int(arr_i.max()), int(arr_i.min())
        if max_v > 65535 or min_v < 0:
            span = max_v - min_v
            arr8 = (
                np.clip((arr_i - min_v) * (255.0 / span), 0, 255).astype(np.uint8)
                if span > 0
                else np.zeros(arr_i.shape, dtype=np.uint8)
            )
        elif max_v > 255:
            arr8 = (arr_i >> 8).astype(np.uint8)
        else:
            arr8 = arr_i.astype(np.uint8)
        return cv2.cvtColor(arr8, cv2.COLOR_GRAY2BGR)
    if transposed.mode in ("RGBA", "LA", "PA") or (
        transposed.info.get("transparency") is not None
    ):
        rgba = transposed.convert("RGBA")
        white_bg = Image.new("RGBA", rgba.size, (255, 255, 255, 255))
        rgb_img = Image.alpha_composite(white_bg, rgba).convert("RGB")
    else:
        rgb_img = transposed.convert("RGB")
    return cv2.cvtColor(np.array(rgb_img), cv2.COLOR_RGB2BGR)


def load_image_bgr(fpath: str) -> np.ndarray:
    """Load an image via Pillow (handling EXIF orientation and HEIC/TIFF) into OpenCV BGR."""
    with Image.open(fpath) as pil_img:
        return _pil_to_bgr(pil_img)


def _iter_image_pages_bgr(fpath: str):
    """Yield (page_idx_or_none, label, bgr_img) for single-frame images or multi-page TIFFs."""
    base_name = os.path.basename(fpath)
    with Image.open(fpath) as pil_img:
        n_frames = max(1, int(getattr(pil_img, "n_frames", 1) or 1))
        if n_frames == 1:
            yield None, base_name, _pil_to_bgr(pil_img)
            return
        for frame_idx in range(n_frames):
            pil_img.seek(frame_idx)
            yield frame_idx + 1, f"{base_name} [page {frame_idx + 1}/{n_frames}]", _pil_to_bgr(pil_img)


def _iter_pdf_pages_bgr(pdf_path: str):
    """Yield (page_idx, label, bgr_img) for each page in a PDF containing scanned images."""
    reader = PdfReader(pdf_path)
    base_name = os.path.basename(pdf_path)
    for page_idx, page in enumerate(reader.pages, 1):
        rotate = int(page.get("/Rotate", 0) or 0) % 360
        imgs = page.images
        if not imgs:
            res = page.get("/Resources")
            has_fonts = isinstance(res, dict) and bool(res.get("/Font"))
            if has_fonts:
                logger.warning(
                    "Skipping %s page %d: contains vector/text without embedded raster images (pre-rasterize or use macOS app).",
                    base_name,
                    page_idx,
                )
            else:
                logger.info("Skipping %s page %d (no embedded image found).", base_name, page_idx)
            continue
        if len(imgs) > 1:
            logger.warning(
                "%s page %d contains %d embedded images; extracting each as a separate page.",
                base_name,
                page_idx,
                len(imgs),
            )
        for img_obj in imgs:
            with Image.open(io.BytesIO(img_obj.data)) as pil_img:
                bgr = _pil_to_bgr(pil_img)
            if rotate == 90:
                bgr = cv2.rotate(bgr, cv2.ROTATE_90_CLOCKWISE)
            elif rotate == 180:
                bgr = cv2.rotate(bgr, cv2.ROTATE_180)
            elif rotate == 270:
                bgr = cv2.rotate(bgr, cv2.ROTATE_90_COUNTERCLOCKWISE)
            yield page_idx, f"{base_name} [page {page_idx}/{len(reader.pages)}]", bgr


def _load_tiff_frame_bgr(fpath: str, frame_idx: int) -> np.ndarray:
    with Image.open(fpath) as pil_img:
        pil_img.seek(frame_idx)
        return _pil_to_bgr(pil_img)


def _load_pdf_image_bgr(pdf_path: str, page_idx_1based: int, img_idx: int) -> np.ndarray:
    reader = PdfReader(pdf_path)
    page = reader.pages[page_idx_1based - 1]
    rotate = int(page.get("/Rotate", 0) or 0) % 360
    img_obj = page.images[img_idx]
    with Image.open(io.BytesIO(img_obj.data)) as pil_img:
        bgr = _pil_to_bgr(pil_img)
    if rotate == 90:
        bgr = cv2.rotate(bgr, cv2.ROTATE_90_CLOCKWISE)
    elif rotate == 180:
        bgr = cv2.rotate(bgr, cv2.ROTATE_180)
    elif rotate == 270:
        bgr = cv2.rotate(bgr, cv2.ROTATE_90_COUNTERCLOCKWISE)
    return bgr


def _order_points(pts: np.ndarray) -> np.ndarray:
    """Order 4 quadrilateral vertices clockwise starting from top-left [TL, TR, BR, BL]."""
    pts_f = np.asarray(pts, dtype="float32").reshape(4, 2)
    center = pts_f.mean(axis=0)
    angles = np.arctan2(pts_f[:, 1] - center[1], pts_f[:, 0] - center[0])
    cw = pts_f[np.argsort(angles)]
    diag = float(np.linalg.norm(pts_f.max(axis=0) - pts_f.min(axis=0))) + 1e-6
    cw_angles = np.arctan2(cw[:, 1] - center[1], cw[:, 0] - center[0])
    ang_dist = np.abs(np.arctan2(np.sin(cw_angles + 0.75 * np.pi), np.cos(cw_angles + 0.75 * np.pi)))
    min_dist = float(ang_dist.min())
    candidates = np.where(np.abs(ang_dist - min_dist) < 1e-3)[0]
    if len(candidates) > 1:
        start = int(min(candidates, key=lambda i: (float(cw[i, 1]) / diag, float(cw[i, 0]) / diag)))
    else:
        start = int(candidates[0])
    return np.roll(cw, -start, axis=0).astype("float32")


def perspective_warp(image: np.ndarray, quad: np.ndarray, preordered: bool = False) -> np.ndarray:
    """Warp a 4-point quadrilateral region flat into a rectangular top-down view."""
    rect = quad.astype("float32") if preordered else _order_points(quad)
    tl, tr, br, bl = rect
    max_width = max(int(np.linalg.norm(br - bl)), int(np.linalg.norm(tr - tl)), 1)
    max_height = max(int(np.linalg.norm(tr - br)), int(np.linalg.norm(tl - bl)), 1)
    dst = np.array(
        [[0, 0], [max_width - 1, 0], [max_width - 1, max_height - 1], [0, max_height - 1]],
        dtype="float32",
    )
    matrix = cv2.getPerspectiveTransform(rect, dst)
    return cv2.warpPerspective(image, matrix, (max_width, max_height))


def _extract_quad_from_contours(
    contours: list[np.ndarray],
    sw: int,
    sh: int,
    pad: int,
    scale: float,
    min_area_ratio: float = 0.25,
    max_area_ratio: float = 0.96,
    min_solidity: float = 0.72,
) -> tuple[np.ndarray, float] | None:
    """Extract a validated 4-point quad and confidence from area-sorted contours."""
    frame_area = float(max(1, sw * sh))
    for contour in contours[:3]:
        area = float(cv2.contourArea(contour))
        area_ratio = area / frame_area
        if area_ratio < min_area_ratio:
            break

        peri = cv2.arcLength(contour, True)
        approx = cv2.approxPolyDP(contour, 0.02 * peri, True)
        is_poly4 = len(approx) == 4 and cv2.isContourConvex(approx)
        if not is_poly4:
            hull = cv2.convexHull(contour)
            hull_peri = cv2.arcLength(hull, True)
            hull_approx = cv2.approxPolyDP(hull, 0.025 * hull_peri, True)
            if len(hull_approx) == 4 and cv2.isContourConvex(hull_approx):
                hull_area = max(float(cv2.contourArea(hull)), 1.0)
                if area / hull_area >= min_solidity:
                    approx = hull_approx
                    is_poly4 = True

        if is_poly4:
            if area_ratio > max_area_ratio:
                continue
            pts_small = approx.reshape(4, 2).astype(np.float32) - pad
            conf = min(0.95, 0.58 + 0.35 * area_ratio)
        else:
            rect = cv2.minAreaRect(contour)
            box_area = float(rect[1][0] * rect[1][1])
            solidity = area / max(box_area, 1.0)
            if solidity < min_solidity or area_ratio > max_area_ratio:
                continue
            pts_small = cv2.boxPoints(rect).astype(np.float32) - pad
            conf = min(0.85, 0.45 + 0.35 * solidity)

        pts_small[:, 0] = np.clip(pts_small[:, 0], 0, sw - 1)
        pts_small[:, 1] = np.clip(pts_small[:, 1], 0, sh - 1)
        return pts_small / scale, conf
    return None


def _detect_quad_hsv_otsu(
    score_inner: np.ndarray, sw: int, sh: int, pad: int, scale: float
) -> tuple[np.ndarray, float] | None:
    """Primary detector: Otsu threshold on brightness-minus-saturation paper score."""
    blurred = cv2.GaussianBlur(score_inner, (9, 9), 0, borderType=cv2.BORDER_REPLICATE)
    _, mask_inner = cv2.threshold(blurred, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    mask = cv2.copyMakeBorder(mask_inner, pad, pad, pad, pad, cv2.BORDER_CONSTANT, value=0)
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, _KERNEL_15x15)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, _KERNEL_9x9)
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    contours = sorted(contours, key=cv2.contourArea, reverse=True)
    return _extract_quad_from_contours(contours, sw, sh, pad, scale)


def _detect_quad_canny(
    small: np.ndarray, score_inner: np.ndarray, sw: int, sh: int, pad: int, scale: float
) -> tuple[np.ndarray, float] | None:
    """Edge-based fallback for low-contrast white-on-white sheets verified by interior paper score."""
    gray_s = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY)
    rep = cv2.copyMakeBorder(gray_s, pad, pad, pad, pad, cv2.BORDER_REPLICATE)
    blur = cv2.GaussianBlur(rep, (5, 5), 0)
    edges = cv2.Canny(blur, 20, 65)[pad:-pad, pad:-pad]
    edges_pad = cv2.copyMakeBorder(edges, pad, pad, pad, pad, cv2.BORDER_CONSTANT, value=0)
    edges_closed = cv2.dilate(edges_pad, _KERNEL_3x3)
    edges_closed = cv2.morphologyEx(edges_closed, cv2.MORPH_CLOSE, _KERNEL_9x9)

    contours, _ = cv2.findContours(edges_closed, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    contours = sorted(contours, key=cv2.contourArea, reverse=True)
    cand = _extract_quad_from_contours(contours, sw, sh, pad, scale, min_area_ratio=0.25)
    if cand is None:
        return None

    paper_rect, conf = cand
    pts_small = np.round(_order_points(paper_rect) * scale).astype(np.int32)
    quad_mask = np.zeros((sh, sw), dtype=np.uint8)
    cv2.fillConvexPoly(quad_mask, pts_small, 255)
    inside_vals = score_inner[quad_mask == 255]
    outside_vals = score_inner[quad_mask == 0]
    if inside_vals.size < 50 or outside_vals.size < 50:
        return None
    # Distinguish a real white sheet over desk from a printed table frame on full-bleed white paper
    score_gap = float(np.percentile(inside_vals, 75)) - float(np.median(outside_vals))
    if score_gap < 5.0:
        return None
    return paper_rect, min(conf, 0.85)


def detect_and_crop_with_info(img: np.ndarray) -> tuple[np.ndarray, dict]:
    """Detect document bounds with HSV+Otsu and Canny fallback, returning cropped image and metadata."""
    orig = img.copy()
    h, w = img.shape[:2]
    scale = 1000.0 / max(h, w, 1)
    sw, sh = max(1, int(w * scale)), max(1, int(h * scale))
    small = cv2.resize(img, (sw, sh))

    pad = 12
    hsv = cv2.cvtColor(small, cv2.COLOR_BGR2HSV)
    _, s_ch, v_ch = cv2.split(hsv)
    score_inner = np.clip(v_ch.astype(np.float32) - 1.5 * s_ch.astype(np.float32), 0, 255).astype(np.uint8)

    method = "hsv_otsu"
    cand = _detect_quad_hsv_otsu(score_inner, sw, sh, pad, scale)
    if cand is None:
        method = "canny_edge"
        cand = _detect_quad_canny(small, score_inner, sw, sh, pad, scale)

    min_warp_w = max(64, int(0.25 * w))
    min_warp_h = max(64, int(0.25 * h))
    if cand is not None:
        paper_rect, conf = cand
        ordered = _order_points(paper_rect)
        tl, tr, br, bl = ordered
        max_w = max(int(np.linalg.norm(br - bl)), int(np.linalg.norm(tr - tl)))
        max_h = max(int(np.linalg.norm(tr - br)), int(np.linalg.norm(tl - bl)))
        if max_w >= min_warp_w and max_h >= min_warp_h:
            warped = perspective_warp(orig, ordered, preordered=True)
            return warped, {
                "detected": True,
                "method": method,
                "confidence": round(float(conf), 3),
                "fallback": False,
                "quad": ordered.tolist(),
            }

    return orig, {
        "detected": False,
        "method": "fallback_original",
        "confidence": 0.0,
        "fallback": True,
        "quad": None,
    }


def detect_and_crop(img: np.ndarray) -> np.ndarray:
    """Detect document bounds via HSV+Otsu and Canny fallback, returning cropped BGR image."""
    cropped, _ = detect_and_crop_with_info(img)
    return cropped


def _smooth_edge_curve(raw_offsets: np.ndarray, points_per_edge: int, max_val: int) -> np.ndarray:
    """Sample control points, apply 1D median & Gaussian smoothing, and interpolate edge curve."""
    n = len(raw_offsets)
    if n < 8 or points_per_edge < 4:
        return raw_offsets.astype(np.float32)

    nodes_x = np.linspace(0, n - 1, points_per_edge)
    bin_edges = np.linspace(0, n, points_per_edge + 1, dtype=int)
    ctrl = np.array(
        [np.median(raw_offsets[bin_edges[i] : max(bin_edges[i] + 1, bin_edges[i + 1])]) for i in range(points_per_edge)],
        dtype=np.float32,
    )
    for i in range(points_per_edge):
        seg = raw_offsets[bin_edges[i] : max(bin_edges[i] + 1, bin_edges[i + 1])]
        if np.any(seg > 0):
            ctrl[i] = float(np.percentile(seg, 85))

    padded = np.pad(ctrl, 1, mode="edge")
    ctrl = np.median(np.stack([padded[:-2], padded[1:-1], padded[2:]], axis=0), axis=0).astype(np.float32)

    ctrl_smooth = cv2.GaussianBlur(ctrl.reshape(1, -1), (5, 1), sigmaX=1.2).ravel()
    curve = np.interp(np.arange(n, dtype=np.float32), nodes_x, ctrl_smooth).astype(np.float32)
    curve[curve > 1.0] += 2.0
    return np.clip(curve, 0.0, float(max_val))


def _estimate_paper_scalars(image: np.ndarray) -> tuple[float, float, float, np.ndarray]:
    """Estimate (l_paper, a_paper, b_paper, paper_bgr) from a strided inner 8%..92% subsample."""
    h, w = image.shape[:2]
    step = max(1, max(h, w) // 500)
    small = image[::step, ::step]
    sh, sw = small.shape[:2]
    y0 = int(0.08 * sh)
    y1 = max(y0 + 1, int(0.92 * sh))
    x0 = int(0.08 * sw)
    x1 = max(x0 + 1, int(0.92 * sw))

    inner_bgr = small[y0:y1, x0:x1]
    inner_lab = cv2.cvtColor(inner_bgr, cv2.COLOR_BGR2LAB)
    l_paper = float(np.percentile(inner_lab[:, :, 0], 80))
    a_paper = float(np.median(inner_lab[:, :, 1]))
    b_paper = float(np.median(inner_lab[:, :, 2]))

    paper_px = inner_bgr[inner_lab[:, :, 0] >= l_paper - 10]
    paper_bgr = (
        np.median(paper_px, axis=0).astype(np.uint8)
        if paper_px.size > 0
        else np.array([245, 245, 245], dtype=np.uint8)
    )
    return l_paper, a_paper, b_paper, paper_bgr


def _compute_strip_bg_mask(
    strip_bgr: np.ndarray,
    l_paper: float,
    a_paper: float,
    b_paper: float,
    include_dark_tb: bool = False,
) -> np.ndarray:
    """Detect non-paper border background pixels on an edge strip or downscaled seed."""
    lab = cv2.cvtColor(strip_bgr, cv2.COLOR_BGR2LAB)
    hsv = cv2.cvtColor(strip_bgr, cv2.COLOR_BGR2HSV)
    L = lab[:, :, 0].astype(np.float32)
    a = lab[:, :, 1].astype(np.float32)
    b = lab[:, :, 2].astype(np.float32)
    S = hsv[:, :, 1]
    chroma_diff = np.hypot(a - a_paper, b - b_paper)
    dark_diff = l_paper - L

    is_bg = (
        (chroma_diff > 9.0)
        | ((S > 32) & (chroma_diff > 6.5))
        | ((dark_diff > 22.0) & (chroma_diff > 5.5))
        | ((L < 90) & (chroma_diff > 5.5))
    ).astype(np.uint8) * 255
    if include_dark_tb:
        dark_tb_raw = (L < min(148.0, l_paper - 58.0)).astype(np.uint8) * 255
        dark_tb = cv2.morphologyEx(dark_tb_raw, cv2.MORPH_OPEN, _KERNEL_2x15)
        is_bg = cv2.bitwise_or(is_bg, dark_tb)
    return is_bg


def _extract_strip_edge_offsets(
    strip_mask: np.ndarray,
    side: str,
    points_per_edge: int,
    full_h: int,
) -> np.ndarray:
    """Extract inward background depth along one oriented edge strip ('top', 'bottom', 'left', 'right')."""
    if side == "top":
        strip = strip_mask
    elif side == "bottom":
        strip = strip_mask[::-1, :]
    elif side == "left":
        strip = strip_mask.T.copy()
        tb_ignore = min(strip.shape[1] // 8, max(6, int(0.02 * full_h)))
        if tb_ignore > 0:
            strip[:, :tb_ignore] = 0
            strip[:, -tb_ignore:] = 0
    else:
        strip = strip_mask[:, ::-1].T.copy()
        tb_ignore = min(strip.shape[1] // 8, max(6, int(0.02 * full_h)))
        if tb_ignore > 0:
            strip[:, :tb_ignore] = 0
            strip[:, -tb_ignore:] = 0

    axis_len = strip.shape[1]
    closed = cv2.morphologyEx(strip, cv2.MORPH_CLOSE, _KERNEL_3x5)
    opened = cv2.morphologyEx(closed, cv2.MORPH_OPEN, _KERNEL_2x15)

    _, labels = cv2.connectedComponents(opened)
    border_labels = set(np.unique(labels[0, :])) - {0}
    if not border_labels:
        return np.zeros(axis_len, dtype=np.float32)

    connected = np.isin(labels, list(border_labels))
    offsets = np.zeros(axis_len, dtype=np.float32)
    ys, xs = np.where(connected)
    if ys.size > 0:
        np.maximum.at(offsets, xs, ys + 1)
    return _smooth_edge_curve(offsets, points_per_edge, strip.shape[0])


def _clean_residual_border_bleed(
    image: np.ndarray,
    a_paper: float | None = None,
    b_paper: float | None = None,
    paper_bgr: np.ndarray | None = None,
) -> np.ndarray:
    """Clean thin residual background bleed touching the outer 1.5% border."""
    h, w = image.shape[:2]
    if a_paper is None or b_paper is None or paper_bgr is None:
        _, a_paper, b_paper, paper_bgr = _estimate_paper_scalars(image)

    out = image.copy()
    v_depth = max(4, int(0.015 * h))
    h_depth = max(4, int(0.015 * w))

    strips = [
        ((0, v_depth, 0, w), _KERNEL_2x13, "row0"),
        ((h - v_depth, h, 0, w), _KERNEL_2x13, "row_end"),
        ((0, h, 0, h_depth), _KERNEL_13x2, "col0"),
        ((0, h, w - h_depth, w), _KERNEL_13x2, "col_end"),
    ]
    for (r0, r1, c0, c1), kernel, edge_pos in strips:
        strip_bgr = out[r0:r1, c0:c1]
        strip_lab = cv2.cvtColor(strip_bgr, cv2.COLOR_BGR2LAB)
        strip_hsv = cv2.cvtColor(strip_bgr, cv2.COLOR_BGR2HSV)
        chroma_diff = np.hypot(
            strip_lab[:, :, 1].astype(np.float32) - a_paper,
            strip_lab[:, :, 2].astype(np.float32) - b_paper,
        )
        bleed_patch = ((chroma_diff > 8.5) | (strip_hsv[:, :, 1] > 30)).astype(np.uint8) * 255
        opened = cv2.morphologyEx(bleed_patch, cv2.MORPH_OPEN, kernel)
        _, labels = cv2.connectedComponents(opened)
        if edge_pos == "row0":
            edge_labels = set(np.unique(labels[0, :])) - {0}
        elif edge_pos == "row_end":
            edge_labels = set(np.unique(labels[-1, :])) - {0}
        elif edge_pos == "col0":
            edge_labels = set(np.unique(labels[:, 0])) - {0}
        else:
            edge_labels = set(np.unique(labels[:, -1])) - {0}
        if edge_labels:
            mask = np.isin(labels, list(edge_labels))
            strip_bgr[mask] = paper_bgr
    return out


def multipoint_border_mask_clean(image: np.ndarray, points_per_edge: int = 32) -> np.ndarray:
    """Mask out curved background outside a 128-point border polygon using local paper fill."""
    if points_per_edge <= 0:
        return image
    h, w = image.shape[:2]
    if h < 120 or w < 120:
        return image

    l_paper, a_paper, b_paper, paper_bgr = _estimate_paper_scalars(image)
    tb_depth = max(8, int(0.055 * h))
    lr_depth = max(8, int(0.045 * w))

    top_bg = _compute_strip_bg_mask(image[:tb_depth, :], l_paper, a_paper, b_paper, include_dark_tb=True)
    bot_bg = _compute_strip_bg_mask(image[h - tb_depth :, :], l_paper, a_paper, b_paper, include_dark_tb=True)
    left_bg = _compute_strip_bg_mask(image[:, :lr_depth], l_paper, a_paper, b_paper, include_dark_tb=False)
    right_bg = _compute_strip_bg_mask(image[:, w - lr_depth :], l_paper, a_paper, b_paper, include_dark_tb=False)

    y_top = _extract_strip_edge_offsets(top_bg, "top", points_per_edge, h)
    y_bottom = (h - 1.0) - _extract_strip_edge_offsets(bot_bg, "bottom", points_per_edge, h)
    x_left = _extract_strip_edge_offsets(left_bg, "left", points_per_edge, h)
    x_right = (w - 1.0) - _extract_strip_edge_offsets(right_bg, "right", points_per_edge, h)

    has_outside = bool(
        np.any(y_top > 0) or np.any(y_bottom < h - 1.0) or np.any(x_left > 0) or np.any(x_right < w - 1.0)
    )
    if not has_outside:
        return _clean_residual_border_bleed(image, a_paper=a_paper, b_paper=b_paper, paper_bgr=paper_bgr)

    out = image.copy()
    ys = np.arange(h, dtype=np.float32)[:, None]
    xs = np.arange(w, dtype=np.float32)[None, :]
    outside_mask = (
        (ys < y_top[None, :])
        | (ys > y_bottom[None, :])
        | (xs < x_left[:, None])
        | (xs > x_right[:, None])
    )
    # Propagate adjacent interior paper intensity into outside_mask at low resolution for speed
    if np.any(outside_mask):
        scale = min(1.0, 500.0 / max(h, w))
        if scale < 0.99:
            sw = max(1, int(round(w * scale)))
            sh = max(1, int(round(h * scale)))
            small_seed = cv2.resize(image, (sw, sh), interpolation=cv2.INTER_AREA)
            small_bg = _compute_strip_bg_mask(small_seed, l_paper, a_paper, b_paper, include_dark_tb=True) > 0
            small_out = cv2.resize(outside_mask.astype(np.uint8), (sw, sh), interpolation=cv2.INTER_NEAREST) > 0
            small_seed[small_out | small_bg] = 0
            k_dil = max(5, int(round(31 * scale)) | 1)
            k_med = max(3, int(round(21 * scale)) | 1)
            dil_kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (k_dil, k_dil))
            small_fill = cv2.medianBlur(cv2.dilate(small_seed, dil_kernel, iterations=2), k_med)
            local_bg = cv2.resize(small_fill, (w, h), interpolation=cv2.INTER_LINEAR)
        else:
            full_bg = _compute_strip_bg_mask(image, l_paper, a_paper, b_paper, include_dark_tb=True) > 0
            seed = image.copy()
            seed[outside_mask | full_bg] = 0
            local_bg = cv2.medianBlur(cv2.dilate(seed, _KERNEL_31x31, iterations=2), 21)
        out[outside_mask] = local_bg[outside_mask]

    return _clean_residual_border_bleed(out, a_paper=a_paper, b_paper=b_paper, paper_bgr=paper_bgr)


def _extract_ruling_lines(
    line_map: np.ndarray,
    horizontal: bool,
    min_span: int,
    max_thickness: float | None = None,
    min_fill_ratio: float = 0.65,
) -> list[tuple[np.ndarray, np.ndarray, float]]:
    """Extract per-line (primary_coords, orthogonal_centroids, median_pos) tuples from line map."""
    work = line_map if horizontal else line_map.T
    num_labels, labels, stats, _ = cv2.connectedComponentsWithStats(work)
    lines: list[tuple[np.ndarray, np.ndarray, float]] = []

    for lbl in range(1, num_labels):
        bx, by, bw, bh, _ = stats[lbl]
        if bw < min_span:
            continue
        if max_thickness is None and bw / max(bh, 1) < 8.0:
            continue
        comp = labels[by : by + bh, bx : bx + bw] == lbl
        col_counts = comp.sum(axis=0)
        valid_cols = np.where(col_counts > 0)[0]
        if valid_cols.size < max(15, int(min_fill_ratio * bw)):
            continue
        if max_thickness is not None and float(np.median(col_counts[valid_cols])) > max_thickness:
            continue
        row_idx = np.arange(by, by + bh, dtype=np.float32)[:, None]
        y_centroids = (comp[:, valid_cols] * row_idx).sum(axis=0) / col_counts[valid_cols]
        if y_centroids.size > 4 and float(np.median(np.abs(np.diff(y_centroids)))) > 3.0:
            continue
        y_bar = float(np.median(y_centroids))
        x_coords = (bx + valid_cols).astype(np.float32)
        lines.append((x_coords, y_centroids.astype(np.float32), y_bar))
    return lines


def _concat_ruling_lines(
    lines: list[tuple[np.ndarray, np.ndarray, float]], horizontal: bool
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    if not lines:
        empty = np.empty(0, dtype=np.float32)
        return empty, empty, empty
    xs_list, ys_list, d_list = [], [], []
    for x_coords, y_centroids, y_bar in lines:
        if horizontal:
            xs_list.append(x_coords)
            ys_list.append(np.full_like(x_coords, y_bar))
        else:
            xs_list.append(np.full_like(x_coords, y_bar))
            ys_list.append(x_coords)
        d_list.append(y_centroids - y_bar)
    return np.concatenate(xs_list), np.concatenate(ys_list), np.concatenate(d_list)


def _extract_ruling_samples(
    line_map: np.ndarray, horizontal: bool, min_span: int
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Extract (xs, ys, deltas) deviation samples along horizontal or vertical ruling lines."""
    return _concat_ruling_lines(_extract_ruling_lines(line_map, horizontal, min_span), horizontal)


def _poly_features(xh: np.ndarray, yh: np.ndarray, degree3_x: bool) -> np.ndarray:
    cols = [np.ones_like(xh), xh, yh, xh * xh, xh * yh, yh * yh]
    if degree3_x:
        cols.extend([xh * xh * xh, xh * xh * yh, xh * yh * yh])
    return np.stack(cols, axis=1)


def _fit_ridge_surface(
    xs: np.ndarray,
    ys: np.ndarray,
    deltas: np.ndarray,
    w: int,
    h: int,
    degree3_x: bool,
    lam: float = 0.015,
    max_shift_ratio: float = 0.018,
) -> np.ndarray:
    """Fit scale-invariant regularized 2D polynomial surface with 3-pass MAD rejection."""
    if xs.size < 30:
        return np.zeros((h, w), dtype=np.float32)

    if xs.size > 12000:
        idx = np.linspace(0, xs.size - 1, 12000, dtype=int)
        xs, ys, deltas = xs[idx], ys[idx], deltas[idx]

    xh = xs / float(w) - 0.5
    yh = ys / float(h) - 0.5
    Phi = _poly_features(xh, yh, degree3_x)

    coef = np.zeros(Phi.shape[1], dtype=np.float64)
    mask = np.ones(xs.size, dtype=bool)
    for _ in range(3):
        P = Phi[mask].astype(np.float64)
        d = deltas[mask].astype(np.float64)
        if P.shape[0] < 20:
            break
        gram = P.T @ P
        pen = np.maximum(np.diag(gram), 1.0) * float(lam)
        pen[0] = 1e-6
        coef = np.linalg.solve(gram + np.diag(pen), P.T @ d)
        res = np.abs(deltas.astype(np.float64) - Phi.astype(np.float64) @ coef)
        mad = float(np.median(res))
        thresh = 2.5 * max(1.4826 * mad, 1.0)
        new_mask = res <= thresh
        if new_mask.sum() >= 20:
            mask = new_mask

    gx = (np.arange(w, dtype=np.float32) / float(w) - 0.5)[None, :]
    gy = (np.arange(h, dtype=np.float32) / float(h) - 0.5)[:, None]
    surface = coef[0] + coef[1] * gx + coef[2] * gy + coef[3] * (gx * gx) + coef[4] * (gx * gy) + coef[5] * (gy * gy)
    if degree3_x:
        surface = surface + coef[6] * (gx * gx * gx) + coef[7] * (gx * gx * gy) + coef[8] * (gx * gy * gy)
    max_shift = max_shift_ratio * min(h, w)
    return np.clip(surface, -max_shift, max_shift).astype(np.float32)


def _detect_surface_lines(gray: np.ndarray):
    """Extract curved/tilted horizontal & vertical ruling/text lines without flat-kernel truncation."""
    h, w = gray.shape[:2]
    inv = cv2.adaptiveThreshold(gray, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY_INV, 31, 10)
    py, px = max(4, int(0.02 * h)), max(4, int(0.02 * w))
    inv[:py, :] = 0
    inv[h - py :, :] = 0
    inv[:, :px] = 0
    inv[:, w - px :] = 0

    v_strict = cv2.morphologyEx(inv, cv2.MORPH_OPEN, np.ones((max(35, h // 18), 1), np.uint8))
    h_seed = cv2.subtract(inv, cv2.dilate(v_strict, _KERNEL_3x3))
    h_closed = cv2.morphologyEx(h_seed, cv2.MORPH_CLOSE, np.ones((3, max(16, w // 42)), np.uint8))
    min_h_span = max(40, int(0.08 * w))
    h_lines = _extract_ruling_lines(
        h_closed, horizontal=True, min_span=min_h_span, max_thickness=max(14.0, 0.022 * h)
    )
    xs_h, ys_h, dy_h = _concat_ruling_lines(h_lines, horizontal=True)

    h_strict = cv2.morphologyEx(inv, cv2.MORPH_OPEN, np.ones((1, max(35, w // 18)), np.uint8))
    v_seed = cv2.subtract(inv, cv2.dilate(h_strict, _KERNEL_3x3))
    v_closed = cv2.morphologyEx(v_seed, cv2.MORPH_CLOSE, np.ones((max(16, h // 42), 3), np.uint8))
    v_lines = _extract_ruling_lines(
        v_closed, horizontal=False, min_span=max(40, int(0.08 * h)), max_thickness=max(14.0, 0.022 * w)
    )
    xs_v, ys_v, dx_v = _concat_ruling_lines(v_lines, horizontal=False)
    return h_lines, xs_h, ys_h, dy_h, v_lines, xs_v, ys_v, dx_v


def _estimate_skew_angle_deg(h_lines: list[tuple[np.ndarray, np.ndarray, float]], w: int) -> float:
    """Estimate consistent global skew angle in degrees from median slope of horizontal lines."""
    min_skew_span = max(50, int(0.12 * w))
    angles = []
    for x_coords, y_centroids, _ in h_lines:
        if x_coords.size < 20 or float(x_coords.max() - x_coords.min()) < min_skew_span:
            continue
        xc = x_coords - float(x_coords.mean())
        yc = y_centroids - float(y_centroids.mean())
        denom = float(np.dot(xc, xc))
        if denom < 1e-3:
            continue
        slope = float(np.dot(xc, yc)) / denom
        deg = float(np.degrees(np.arctan(slope)))
        if abs(deg) <= 10.0:
            angles.append(deg)

    if len(angles) < 2:
        return 0.0
    ang_arr = np.array(angles, dtype=np.float32)
    med = float(np.median(ang_arr))
    mad = float(np.median(np.abs(ang_arr - med)))
    if mad > 1.2:
        return 0.0
    return med


def flatten_document_surface(
    image: np.ndarray, max_shift_ratio: float = 0.018
) -> np.ndarray:
    """Deskew global tilt and flatten 3D page curl only when line-straightness RMS improves."""
    h, w = image.shape[:2]
    if h < 120 or w < 120:
        return image

    paper_bgr_cache: list[int] | None = None

    def _paper_bgr_list() -> list[int]:
        nonlocal paper_bgr_cache
        if paper_bgr_cache is None:
            paper_bgr_cache = _estimate_paper_scalars(image)[3].tolist()
        return paper_bgr_cache

    work_img = image
    gray = cv2.cvtColor(work_img, cv2.COLOR_BGR2GRAY)

    # Fast pre-check at <=900px so already-flat pages skip full-resolution morphology
    if max(h, w) > 1000:
        scale = 900.0 / max(h, w)
        sw = max(120, int(round(w * scale)))
        sh = max(120, int(round(h * scale)))
        gray_sm = cv2.resize(gray, (sw, sh), interpolation=cv2.INTER_AREA)
        h_l_sm, xs_h_sm, ys_h_sm, dy_h_sm, _, xs_v_sm, _, dx_v_sm = _detect_surface_lines(gray_sm)
        skew_pre = _estimate_skew_angle_deg(h_l_sm, sw)
        if abs(skew_pre) < 0.25 or abs(skew_pre) > 8.5:
            if xs_h_sm.size < 20 and xs_v_sm.size < 20:
                logger.info("Flatten skipped (insufficient line samples)")
                return work_img
            if xs_h_sm.size >= 20:
                if (len(h_l_sm) < 2 or float(ys_h_sm.max() - ys_h_sm.min()) < 0.14 * sh) and xs_v_sm.size < 20:
                    logger.info("Flatten skipped (sparse vertical coverage)")
                    return work_img
                rms_est = float(np.sqrt(np.mean(dy_h_sm**2))) * (h / float(sh))
            else:
                rms_est = float(np.sqrt(np.mean(dx_v_sm**2))) * (w / float(sw))
            if rms_est < 1.1:
                logger.info("Flatten skipped (already flat: rms_before=%.2f px)", rms_est)
                return work_img

    h_lines, xs_h, ys_h, dy_h, v_lines, xs_v, ys_v, dx_v = _detect_surface_lines(gray)

    skew_deg = _estimate_skew_angle_deg(h_lines, w)
    if 0.3 <= abs(skew_deg) <= 8.0:
        rot_m = cv2.getRotationMatrix2D((w / 2.0, h / 2.0), skew_deg, 1.0)
        work_img = cv2.warpAffine(
            work_img,
            rot_m,
            (w, h),
            flags=cv2.INTER_CUBIC,
            borderMode=cv2.BORDER_CONSTANT,
            borderValue=_paper_bgr_list(),
        )
        logger.info("Deskewed page by %.2f deg", skew_deg)
        gray = cv2.cvtColor(work_img, cv2.COLOR_BGR2GRAY)
        h_lines, xs_h, ys_h, dy_h, v_lines, xs_v, ys_v, dx_v = _detect_surface_lines(gray)

    if xs_h.size < 30 and xs_v.size < 30:
        logger.info("Flatten skipped (insufficient line samples)")
        return work_img

    if xs_h.size >= 30:
        y_span = float(ys_h.max() - ys_h.min())
        if (len(h_lines) < 2 or y_span < 0.15 * h) and xs_v.size < 30:
            logger.info("Flatten skipped (sparse vertical coverage)")
            return work_img
        rms_before = float(np.sqrt(np.mean(dy_h**2)))
    else:
        rms_before = float(np.sqrt(np.mean(dx_v**2)))

    if rms_before < 1.2:
        logger.info("Flatten skipped (already flat: rms_before=%.2f px)", rms_before)
        return work_img

    delta_y = _fit_ridge_surface(
        xs_h, ys_h, dy_h, w, h, degree3_x=True, lam=0.015, max_shift_ratio=max_shift_ratio
    )
    delta_x = _fit_ridge_surface(
        xs_v, ys_v, dx_v, w, h, degree3_x=False, lam=0.015, max_shift_ratio=max_shift_ratio
    )
    delta_y = delta_y - float(np.median(delta_y))
    delta_x = delta_x - float(np.median(delta_x))

    if xs_h.size >= 30:
        after_devs = []
        for x_i, y_i, _ in h_lines:
            xi = np.clip(np.round(x_i).astype(int), 0, w - 1)
            yi = np.clip(np.round(y_i).astype(int), 0, h - 1)
            y_after = y_i - delta_y[yi, xi]
            after_devs.append(y_after - float(np.median(y_after)))
        rms_after = float(np.sqrt(np.mean(np.concatenate(after_devs) ** 2)))
    else:
        after_devs = []
        for y_i, x_i, _ in v_lines:
            xi = np.clip(np.round(x_i).astype(int), 0, w - 1)
            yi = np.clip(np.round(y_i).astype(int), 0, h - 1)
            x_after = x_i - delta_x[yi, xi]
            after_devs.append(x_after - float(np.median(x_after)))
        rms_after = float(np.sqrt(np.mean(np.concatenate(after_devs) ** 2)))

    if rms_after >= 0.85 * rms_before or (rms_before - rms_after) < 0.35:
        logger.info("Flatten skipped (quality gate: rms %.2f -> %.2f px)", rms_before, rms_after)
        return work_img

    logger.info("Flatten applied (rms %.2f -> %.2f px)", rms_before, rms_after)
    pad = int(0.065 * min(h, w)) + 8
    fill_val = _paper_bgr_list()
    padded = cv2.copyMakeBorder(
        work_img, pad, pad, pad, pad, cv2.BORDER_CONSTANT, value=fill_val
    )
    dx_pad = cv2.copyMakeBorder(delta_x, pad, pad, pad, pad, cv2.BORDER_REPLICATE)
    dy_pad = cv2.copyMakeBorder(delta_y, pad, pad, pad, pad, cv2.BORDER_REPLICATE)
    grid_x = np.arange(w + 2 * pad, dtype=np.float32)[None, :] + dx_pad
    grid_y = np.arange(h + 2 * pad, dtype=np.float32)[:, None] + dy_pad
    return cv2.remap(
        padded,
        grid_x.astype(np.float32),
        grid_y.astype(np.float32),
        interpolation=cv2.INTER_CUBIC,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=fill_val,
    )


def _center_crop_to_shape(image: np.ndarray, th: int, tw: int) -> np.ndarray:
    h, w = image.shape[:2]
    if (h, w) == (th, tw):
        return image
    y0 = max(0, (h - th) // 2)
    x0 = max(0, (w - tw) // 2)
    return image[y0 : y0 + th, x0 : x0 + tw]


def balance_page_symmetry(
    image: np.ndarray, target_shape: tuple[int, int] | None = None
) -> np.ndarray:
    """Center printed content symmetrically inside paper canvas with equal 4-side margins."""
    h, w = image.shape[:2]
    th, tw = target_shape if target_shape is not None else (h, w)
    if th < 120 or tw < 120:
        return _center_crop_to_shape(image, th, tw)

    l_paper, _, _, paper_bgr = _estimate_paper_scalars(image)
    lab_L = cv2.cvtColor(image, cv2.COLOR_BGR2LAB)[:, :, 0]
    thresh_val = int(np.ceil(l_paper - 28.0)) - 1
    if thresh_val < 0:
        return _center_crop_to_shape(image, th, tw)
    _, content_raw = cv2.threshold(lab_L, min(255, thresh_val), 255, cv2.THRESH_BINARY_INV)
    content_clean = cv2.morphologyEx(content_raw, cv2.MORPH_OPEN, _KERNEL_2x2)
    num_lbl, _, stats, _ = cv2.connectedComponentsWithStats(content_clean, connectivity=8)
    if num_lbl <= 1:
        return _center_crop_to_shape(image, th, tw)

    areas = stats[1:, cv2.CC_STAT_AREA]
    kept = stats[1:][areas >= 10]
    if kept.shape[0] == 0 or int(kept[:, cv2.CC_STAT_AREA].sum()) < 50:
        return _center_crop_to_shape(image, th, tw)

    x_min = max(0, int(kept[:, cv2.CC_STAT_LEFT].min()) - 6)
    y_min = max(0, int(kept[:, cv2.CC_STAT_TOP].min()) - 6)
    x_max = min(w, int((kept[:, cv2.CC_STAT_LEFT] + kept[:, cv2.CC_STAT_WIDTH]).max()) + 7)
    y_max = min(h, int((kept[:, cv2.CC_STAT_TOP] + kept[:, cv2.CC_STAT_HEIGHT]).max()) + 7)
    cw, ch = x_max - x_min, y_max - y_min
    if cw < int(0.3 * tw) or ch < int(0.3 * th):
        return _center_crop_to_shape(image, th, tw)

    crop = image[y_min:y_max, x_min:x_max]
    pad_x = max(8, int(0.022 * tw))
    pad_y = max(8, int(0.025 * th))
    avail_w = max(20, tw - 2 * pad_x)
    avail_h = max(20, th - 2 * pad_y)
    scale = min(1.0, avail_w / float(cw), avail_h / float(ch))

    if scale < 0.999:
        new_w = max(1, int(round(cw * scale)))
        new_h = max(1, int(round(ch * scale)))
        crop = cv2.resize(crop, (new_w, new_h), interpolation=cv2.INTER_AREA)
    else:
        new_w, new_h = cw, ch

    canvas = np.full((th, tw, 3), paper_bgr, dtype=np.uint8)
    off_x = (tw - new_w) // 2
    off_y = (th - new_h) // 2
    canvas[off_y : off_y + new_h, off_x : off_x + new_w] = crop
    return canvas


def downscale_to_dpi(image: np.ndarray, page_size: str, dpi: int, margin: float) -> np.ndarray:
    """Downscale image to fit within target page size and DPI without upscaling."""
    if page_size == "fit":
        return image
    effective_dpi = float(max(72, int(dpi)))
    w_pt, h_pt = (612.0, 792.0) if page_size == "letter" else (595.28, 841.89)
    h, w = image.shape[:2]
    if w > h:
        w_pt, h_pt = h_pt, w_pt
    avail_w_px = max(100.0, (w_pt - 2.0 * margin) * effective_dpi / 72.0)
    avail_h_px = max(100.0, (h_pt - 2.0 * margin) * effective_dpi / 72.0)
    scale = min(1.0, avail_w_px / max(w, 1), avail_h_px / max(h, 1))
    if scale >= 0.99:
        return image
    return cv2.resize(image, (max(1, int(w * scale)), max(1, int(h * scale))), interpolation=cv2.INTER_AREA)


def compensate_strokes_and_lines(normalized: np.ndarray) -> np.ndarray:
    """Repair 1-4px breaks in ruling borders using local ink intensity and adaptive thresholds."""
    h, w = normalized.shape[:2]
    norm_gray = cv2.cvtColor(normalized, cv2.COLOR_BGR2GRAY)
    step = max(1, max(h, w) // 500)
    p85 = float(np.percentile(norm_gray[::step, ::step], 85))
    ink_thresh = int(np.clip(p85 - 45.0, 140.0, 220.0))
    _, line_mask = cv2.threshold(norm_gray, ink_thresh - 1, 255, cv2.THRESH_BINARY_INV)

    min_dim = min(h, w)
    open_len = max(15, int(round(35.0 * min_dim / 1650.0)) | 1)
    close_len = max(7, min(11, int(round(7.0 * min_dim / 1650.0)) | 1))
    k_h_open = _KERNEL_1x35 if open_len == 35 else cv2.getStructuringElement(cv2.MORPH_RECT, (open_len, 1))
    k_v_open = _KERNEL_35x1 if open_len == 35 else cv2.getStructuringElement(cv2.MORPH_RECT, (1, open_len))
    k_h_close = _KERNEL_1x7 if close_len == 7 else cv2.getStructuringElement(cv2.MORPH_RECT, (close_len, 1))
    k_v_close = _KERNEL_7x1 if close_len == 7 else cv2.getStructuringElement(cv2.MORPH_RECT, (1, close_len))

    h_open = cv2.morphologyEx(line_mask, cv2.MORPH_OPEN, k_h_open)
    h_close = cv2.morphologyEx(h_open, cv2.MORPH_CLOSE, k_h_close)
    v_open = cv2.morphologyEx(line_mask, cv2.MORPH_OPEN, k_v_open)
    v_close = cv2.morphologyEx(v_open, cv2.MORPH_CLOSE, k_v_close)

    out = normalized.copy()
    not_line = cv2.bitwise_not(line_mask)
    h_gap = cv2.bitwise_and(h_close, not_line)
    if cv2.countNonZero(h_gap):
        h_ink = cv2.erode(normalized, cv2.getStructuringElement(cv2.MORPH_RECT, (close_len, 3)))
        cv2.copyTo(h_ink, h_gap, out)

    v_gap = cv2.bitwise_and(v_close, not_line)
    if cv2.countNonZero(v_gap):
        v_ink = cv2.erode(normalized, cv2.getStructuringElement(cv2.MORPH_RECT, (3, close_len)))
        cv2.copyTo(v_ink, v_gap, out)

    grid_mask = cv2.bitwise_or(cv2.bitwise_or(h_open, v_open), cv2.bitwise_or(h_gap, v_gap))
    if cv2.countNonZero(grid_mask):
        boosted = cv2.LUT(out, _LINE_BOOST_LUT)
        cv2.copyTo(boosted, grid_mask, out)
    return out


def _estimate_global_wb_gain(img: np.ndarray) -> np.ndarray:
    """Estimate per-channel white-balance gains from inner bright low-chroma paper pixels."""
    h, w = img.shape[:2]
    y0, y1 = int(h * 0.08), int(h * 0.92)
    x0, x1 = int(w * 0.08), int(w * 0.92)
    roi = img[y0:y1, x0:x1] if (y1 - y0 >= 24 and x1 - x0 >= 24) else img
    rh, rw = roi.shape[:2]
    step = max(1, max(rh, rw) // 400)
    if step > 1:
        roi = roi[::step, ::step]

    flat = roi.reshape(-1, 3).astype(np.float32)
    luma = 0.114 * flat[:, 0] + 0.587 * flat[:, 1] + 0.299 * flat[:, 2]
    luma_thresh = max(70.0, float(np.percentile(luma, 75)))
    bright = flat[luma >= luma_thresh]
    if bright.shape[0] < 16:
        return np.ones(3, dtype=np.float32)

    sat_diff = bright.max(axis=1) - bright.min(axis=1)
    sat_cap = min(115.0, float(np.percentile(sat_diff, 60)) + 8.0)
    paper_px = bright[sat_diff <= sat_cap]
    if paper_px.shape[0] < 16:
        paper_px = bright

    paper_bgr = np.percentile(paper_px, 75, axis=0)
    if float(paper_bgr.min()) < 70.0:
        return np.ones(3, dtype=np.float32)

    target_luma = float(0.114 * paper_bgr[0] + 0.587 * paper_bgr[1] + 0.299 * paper_bgr[2])
    return np.clip(target_luma / np.maximum(paper_bgr, 1.0), 0.70, 1.45).astype(np.float32)


def _apply_wb_gain(img: np.ndarray, gain: np.ndarray) -> np.ndarray:
    """Apply 3-channel white-balance gains via a single uint8 3-channel LUT."""
    if np.allclose(gain, 1.0, atol=0.01):
        return img
    idx = np.arange(256, dtype=np.float32)
    lut = np.stack(
        [np.clip(np.round(idx * gain[c]), 0, 255).astype(np.uint8) for c in range(3)],
        axis=1,
    ).reshape(1, 256, 3)
    return cv2.LUT(img, lut)


def _compute_background_ratio(gray: np.ndarray, paper_luma: float | None = None) -> np.ndarray:
    """Estimate uneven illumination at <=720px with scaled kernels and dark-block tapering."""
    h, w = gray.shape[:2]
    max_dim = max(h, w, 1)
    work_max = 720
    if max_dim > work_max:
        scale = float(work_max) / max_dim
        ws = (max(32, int(round(w * scale))), max(32, int(round(h * scale))))
        work_gray = cv2.resize(gray, ws, interpolation=cv2.INTER_AREA)
    else:
        work_gray = gray

    min_ws = min(work_gray.shape[:2])
    dilate_k = max(5, int(round(0.015 * min_ws)) | 1)
    median_k = max(11, int(round(0.042 * min_ws)) | 1)

    dilated = cv2.dilate(work_gray, cv2.getStructuringElement(cv2.MORPH_RECT, (dilate_k, dilate_k)))
    bg_small = cv2.medianBlur(dilated, median_k)
    bg_32_small = np.maximum(bg_small.astype(np.float32), 1.0)
    if paper_luma is None:
        paper_luma = max(80.0, float(np.percentile(bg_32_small, 85)))

    low_t = 0.50 * paper_luma
    zero_t = 0.20 * paper_luma
    alpha = np.clip((bg_32_small - zero_t) / max(low_t - zero_t, 1.0), 0.0, 1.0)
    raw_ratio = np.clip(250.0 / bg_32_small, 0.5, 2.2)
    ratio_small = (1.0 + alpha * (raw_ratio - 1.0)).astype(np.float32)

    if ratio_small.shape != (h, w):
        return cv2.resize(ratio_small, (w, h), interpolation=cv2.INTER_LINEAR)
    return ratio_small


def _scale_by_ratio_u8(img: np.ndarray, ratio: np.ndarray) -> np.ndarray:
    """Multiply uint8 image (1-ch gray or 3-ch BGR) by float32 ratio field safely."""
    scale_arr = cv2.merge((ratio, ratio, ratio)) if img.ndim == 3 else ratio
    try:
        return cv2.multiply(img, scale_arr, dtype=cv2.CV_8U)
    except cv2.error:
        return cv2.multiply(img.astype(np.float32), scale_arr, dtype=cv2.CV_8U)


def enhance_image_bgr(img: np.ndarray, mode: str = "auto_color") -> np.ndarray:
    """Enhance a BGR OpenCV image in-place pipeline and return a BGR ndarray."""
    mode = normalize_enhance_mode(mode)
    if mode == "original":
        return img

    if mode == "clean":
        wb_img = _apply_wb_gain(img, _estimate_global_wb_gain(img))
        lab = cv2.cvtColor(wb_img, cv2.COLOR_BGR2LAB)
        l_ch, a_ch, b_ch = cv2.split(lab)
        bg = cv2.GaussianBlur(l_ch, (0, 0), sigmaX=max(15, min(wb_img.shape[:2]) // 30))
        norm_l = cv2.divide(l_ch, bg, scale=255)
        cleaned = cv2.cvtColor(cv2.merge((norm_l, a_ch, b_ch)), cv2.COLOR_LAB2BGR)
        return cv2.convertScaleAbs(cleaned, alpha=1.1, beta=5)

    if mode == "auto_color":
        wb_img = _apply_wb_gain(img, _estimate_global_wb_gain(img))
        gray = cv2.cvtColor(wb_img, cv2.COLOR_BGR2GRAY)
        ratio = _compute_background_ratio(gray)
        normalized = _scale_by_ratio_u8(wb_img, ratio)
        compensated = compensate_strokes_and_lines(normalized)
        lut_applied = cv2.LUT(compensated, _MAGIC_LUT)
        return cv2.filter2D(lut_applied, -1, _SHARPEN_KERNEL)

    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)

    if mode == "bw":
        bg = cv2.GaussianBlur(gray, (0, 0), sigmaX=max(15, min(img.shape[:2]) // 30))
        norm = cv2.divide(gray, bg, scale=255)
        bw = cv2.adaptiveThreshold(
            norm, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY, 25, 11
        )
        return cv2.cvtColor(bw, cv2.COLOR_GRAY2BGR)

    if mode == "grayscale":
        ratio = _compute_background_ratio(gray)
        norm_gray = _scale_by_ratio_u8(gray, ratio)
        clean_gray = cv2.LUT(norm_gray, _MAGIC_LUT)
        return cv2.cvtColor(clean_gray, cv2.COLOR_GRAY2BGR)

    raise ValueError(f"Unsupported enhance mode: {mode}")


def _bgr_to_pil(enhanced_bgr: np.ndarray, canon_mode: str) -> Image.Image:
    """Convert processed BGR array into 1-bit ('1'), grayscale ('L'), or RGB PIL Image."""
    if canon_mode == "bw":
        gray = cv2.cvtColor(enhanced_bgr, cv2.COLOR_BGR2GRAY)
        binary = ((gray > 128).astype(np.uint8) * 255)
        return Image.fromarray(binary, mode="L").convert("1", dither=Image.Dither.NONE)
    if canon_mode == "grayscale":
        return Image.fromarray(cv2.cvtColor(enhanced_bgr, cv2.COLOR_BGR2GRAY), mode="L")
    return Image.fromarray(cv2.cvtColor(enhanced_bgr, cv2.COLOR_BGR2RGB))


def enhance_image(img: np.ndarray, mode: str = "auto_color") -> Image.Image:
    """Enhance a BGR OpenCV image using the selected document scanner mode and return a PIL Image."""
    canon_mode = normalize_enhance_mode(mode)
    enhanced_bgr = enhance_image_bgr(img, mode=canon_mode)
    return _bgr_to_pil(enhanced_bgr, canon_mode)


def enhance_magic_color(img: np.ndarray) -> Image.Image:
    """Backward-compatible wrapper for Auto Color (formerly Magic Color) enhancement."""
    return enhance_image(img, mode="auto_color")


def compute_pdf_page_geometry(
    img_w: int, img_h: int, page_size: str, dpi: int, margin: float
) -> tuple[float, float, float, float, float, float]:
    """Compute (page_w, page_h, draw_x, draw_y, draw_w, draw_h) in PDF points matching Swift PDFToolsService."""
    effective_dpi = float(max(72, int(dpi)))
    is_landscape = img_w > img_h
    if page_size == "a4":
        page_w, page_h = (841.89, 595.28) if is_landscape else (595.28, 841.89)
    elif page_size == "letter":
        page_w, page_h = (792.0, 612.0) if is_landscape else (612.0, 792.0)
    elif page_size == "fit":
        page_w = max(72.0, img_w * 72.0 / effective_dpi)
        page_h = max(72.0, img_h * 72.0 / effective_dpi)
    else:
        raise ValueError(f"Unsupported page_size: {page_size}")

    effective_margin = 0.0 if page_size == "fit" else float(margin)
    avail_w = max(10.0, page_w - 2.0 * effective_margin)
    avail_h = max(10.0, page_h - 2.0 * effective_margin)
    draw_scale = min(avail_w / max(img_w, 1), avail_h / max(img_h, 1))
    draw_w = img_w * draw_scale
    draw_h = img_h * draw_scale
    draw_x = (page_w - draw_w) / 2.0
    draw_y = (page_h - draw_h) / 2.0
    return page_w, page_h, draw_x, draw_y, draw_w, draw_h


def assemble_pdf_from_pages(
    page_specs: list[dict],
    output_pdf_path: str,
    page_size: str,
    dpi: int,
    margin: float,
) -> None:
    """Assemble JPEG (8-bit RGB/L via /DCTDecode) or 1-bit PNG (/FlateDecode) pages into an exact-MediaBox PDF."""
    writer = PdfWriter()
    for spec in page_specs:
        img_w = int(spec["width"])
        img_h = int(spec["height"])
        page_fmt = spec.get("format", "jpeg")
        color_space = spec.get("color_space", "/DeviceRGB")
        img_path = Path(spec["image_path"])

        page_w, page_h, draw_x, draw_y, draw_w, draw_h = compute_pdf_page_geometry(
            img_w, img_h, page_size=page_size, dpi=dpi, margin=margin
        )
        page = PageObject.create_blank_page(width=page_w, height=page_h)

        xobj = EncodedStreamObject()
        if page_fmt == "png_1bit":
            with Image.open(img_path) as pil_bw:
                bw_1 = pil_bw.convert("1")
                raw_packed = bw_1.tobytes()
            xobj.update(
                {
                    NameObject("/Type"): NameObject("/XObject"),
                    NameObject("/Subtype"): NameObject("/Image"),
                    NameObject("/Width"): NumberObject(img_w),
                    NameObject("/Height"): NumberObject(img_h),
                    NameObject("/ColorSpace"): NameObject("/DeviceGray"),
                    NameObject("/BitsPerComponent"): NumberObject(1),
                    NameObject("/Filter"): NameObject("/FlateDecode"),
                }
            )
            xobj._data = zlib.compress(raw_packed, level=9)
        else:
            xobj.update(
                {
                    NameObject("/Type"): NameObject("/XObject"),
                    NameObject("/Subtype"): NameObject("/Image"),
                    NameObject("/Width"): NumberObject(img_w),
                    NameObject("/Height"): NumberObject(img_h),
                    NameObject("/ColorSpace"): NameObject(color_space),
                    NameObject("/BitsPerComponent"): NumberObject(8),
                    NameObject("/Filter"): NameObject("/DCTDecode"),
                }
            )
            xobj._data = img_path.read_bytes()

        img_ref = writer._add_object(xobj)
        page[NameObject("/Resources")] = DictionaryObject(
            {NameObject("/XObject"): DictionaryObject({NameObject("/Im0"): img_ref})}
        )

        content_ops = (
            f"q 1 1 1 rg 0 0 {page_w:.4f} {page_h:.4f} re f Q\n"
            f"q {draw_w:.4f} 0 0 {draw_h:.4f} {draw_x:.4f} {draw_y:.4f} cm /Im0 Do Q\n"
        ).encode("ascii")
        content = DecodedStreamObject()
        content.set_data(content_ops)
        page[NameObject("/Contents")] = writer._add_object(content)
        writer.add_page(page)

    _atomic_write_bytes(output_pdf_path, writer.write)


def assemble_pdf_from_jpegs(
    page_specs: list[dict],
    output_pdf_path: str,
    page_size: str,
    dpi: int,
    margin: float,
) -> None:
    """Backward-compatible wrapper for assemble_pdf_from_pages."""
    normalized = [
        {**spec, "image_path": spec.get("image_path") or spec["jpeg_path"]}
        for spec in page_specs
    ]
    assemble_pdf_from_pages(normalized, output_pdf_path, page_size=page_size, dpi=dpi, margin=margin)


def resolve_vision_helper(script_dir: Path | None = None) -> tuple[list[str], Path | None]:
    """Return command prefix (precompiled binary first, else swift + script) and helper path."""
    sdir = script_dir or Path(__file__).resolve().parent
    for bin_cand in (sdir / "doc_scanner", sdir.parent / "bin" / "doc_scanner"):
        if bin_cand.is_file() and os.access(bin_cand, os.X_OK):
            return [str(bin_cand)], bin_cand
    swift_script = sdir / "doc_scanner.swift"
    if sys.platform == "darwin" and shutil.which("swift") is not None and swift_script.exists():
        return ["swift", str(swift_script)], swift_script
    return [], None


def crop_via_vision(
    inputs: list[str],
    vision_cmd: list[str] | Path,
    min_confidence: float,
    no_crop: bool,
    tmp_dir: Path,
) -> dict[str, dict]:
    """Run macOS Vision quad detection (--quad-only) via binary or swift helper and return manifest map."""
    manifest_file = tmp_dir / "vision_manifest.json"
    prefix = [str(vision_cmd)] if isinstance(vision_cmd, Path) and not str(vision_cmd).endswith(".swift") else (
        ["swift", str(vision_cmd)] if isinstance(vision_cmd, Path) else list(vision_cmd)
    )
    cmd = [
        *prefix,
        "--quad-only",
        "--min-confidence",
        str(min_confidence),
        "--manifest",
        str(manifest_file),
    ]
    if no_crop:
        cmd.append("--no-crop")
    cmd.extend(inputs)

    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.stderr.strip():
        logger.info("%s", proc.stderr.strip())

    if manifest_file.exists():
        meta = json.loads(manifest_file.read_text(encoding="utf-8"))
        return {
            _canonical_path(entry["input"]): entry
            for entry in meta.get("results", [])
            if entry.get("input")
        }

    if proc.returncode != 0:
        raise RuntimeError(f"Vision crop failed: {proc.stderr.strip()}")

    meta = json.loads(proc.stdout)
    return {
        _canonical_path(entry["input"]): entry
        for entry in meta.get("results", [])
        if entry.get("input")
    }


def _write_manifest(manifest_path: Path | None, payload: dict) -> None:
    if manifest_path is None:
        return
    data = json.dumps(payload, indent=2, ensure_ascii=False).encode("utf-8")
    _atomic_write_bytes(manifest_path, lambda fp: fp.write(data))


def _make_task_entry(
    index: int,
    canon_fpath: str,
    fname: str,
    label: str,
    kind: str,
    load_path: str | None = None,
    frame_index: int = 0,
    page_index: int | None = None,
    error: str | None = None,
    vision_input: str | None = None,
) -> dict:
    return {
        "index": index,
        "input": canon_fpath,
        "file": fname,
        "page_index": page_index,
        "label": label,
        "kind": kind,
        "load_path": load_path,
        "frame_index": frame_index,
        "error": error,
        "vision_input": vision_input,
        "vision_meta": None,
    }


def _discover_page_tasks(files: list[str], use_vision: bool, tmp_dir: Path) -> list[dict]:
    """Build lightweight streaming page tasks without keeping decoded BGR arrays in RAM."""
    tasks: list[dict] = []
    seq = 0

    for fpath in files:
        fname = os.path.basename(fpath)
        canon_fpath = _canonical_path(fpath)
        ext_lower = os.path.splitext(fname)[1].lower()

        if ext_lower == ".pdf":
            try:
                yielded_any = False
                for page_idx, label, bgr in _iter_pdf_pages_bgr(fpath):
                    yielded_any = True
                    seq += 1
                    tmp_img = tmp_dir / f"pdf_{seq:04d}.png"
                    cv2.imwrite(str(tmp_img), bgr)
                    del bgr
                    canon_tmp = _canonical_path(tmp_img)
                    tasks.append(
                        _make_task_entry(
                            len(tasks),
                            canon_fpath,
                            fname,
                            label,
                            kind="image",
                            load_path=canon_tmp,
                            page_index=page_idx,
                            vision_input=canon_tmp if use_vision else None,
                        )
                    )
                if not yielded_any:
                    tasks.append(
                        _make_task_entry(
                            len(tasks),
                            canon_fpath,
                            fname,
                            fname,
                            kind="error",
                            error="PDF has no embedded images to extract",
                        )
                    )
            except Exception as exc:
                logger.warning("Skipping %s (failed to read PDF): %s", fname, exc)
                tasks.append(
                    _make_task_entry(
                        len(tasks),
                        canon_fpath,
                        fname,
                        fname,
                        kind="error",
                        error=f"Failed to read PDF: {exc}",
                    )
                )
            continue

        if ext_lower in (".tif", ".tiff"):
            try:
                with Image.open(fpath) as tiff_probe:
                    n_frames = max(1, int(getattr(tiff_probe, "n_frames", 1) or 1))
                if n_frames > 1:
                    if use_vision:
                        for page_idx, label, bgr in _iter_image_pages_bgr(fpath):
                            seq += 1
                            tmp_img = tmp_dir / f"tiff_{seq:04d}.png"
                            cv2.imwrite(str(tmp_img), bgr)
                            del bgr
                            canon_tmp = _canonical_path(tmp_img)
                            tasks.append(
                                _make_task_entry(
                                    len(tasks),
                                    canon_fpath,
                                    fname,
                                    label,
                                    kind="image",
                                    load_path=canon_tmp,
                                    page_index=page_idx,
                                    vision_input=canon_tmp,
                                )
                            )
                    else:
                        for frame_idx in range(n_frames):
                            seq += 1
                            label = f"{fname} [page {frame_idx + 1}/{n_frames}]"
                            tasks.append(
                                _make_task_entry(
                                    len(tasks),
                                    canon_fpath,
                                    fname,
                                    label,
                                    kind="tiff_frame",
                                    load_path=canon_fpath,
                                    frame_index=frame_idx,
                                    page_index=frame_idx + 1,
                                )
                            )
                    continue
            except Exception as exc:
                logger.warning("Skipping %s (failed to load): %s", fname, exc)
                tasks.append(
                    _make_task_entry(
                        len(tasks),
                        canon_fpath,
                        fname,
                        fname,
                        kind="error",
                        error=f"Failed to load image: {exc}",
                    )
                )
                continue

        seq += 1
        tasks.append(
            _make_task_entry(
                len(tasks),
                canon_fpath,
                fname,
                fname,
                kind="image",
                load_path=canon_fpath,
                vision_input=canon_fpath if use_vision else None,
            )
        )

    return tasks


def _init_worker() -> None:
    """Limit per-worker OpenCV thread pool to avoid CPU oversubscription across processes."""
    cv2.setNumThreads(1)


def _process_single_page_task(task: dict, config: dict) -> dict:
    """Load, crop, enhance, and write one page to disk; return lightweight metadata only."""
    idx = task["index"]
    label = task["label"]
    if task["error"] is not None:
        return {
            "manifest": {
                "index": idx,
                "input": task["input"],
                "file": task["file"],
                "page_index": task["page_index"],
                "status": "error",
                "output": None,
                "message": task["error"],
                "method": "none",
                "confidence": 0.0,
                "width": 0,
                "height": 0,
            },
            "page_spec": None,
        }

    crop_method = "none"
    crop_conf = 0.0
    img: np.ndarray | None = None
    load_error: str | None = None

    try:
        if task["kind"] == "tiff_frame":
            raw_bgr = _load_tiff_frame_bgr(task["load_path"], task["frame_index"])
        else:
            raw_bgr = load_image_bgr(task["load_path"])
    except Exception as exc:
        load_error = f"Failed to load image: {exc}"
        raw_bgr = None

    if raw_bgr is not None:
        auto_crop = config["auto_crop"]
        use_vision = config["use_vision"]
        if auto_crop and use_vision:
            v_meta = task.get("vision_meta")
            if v_meta and v_meta.get("status") == "ok":
                crop_conf = float(v_meta.get("confidence") or 0.0)
                if v_meta.get("detected") and v_meta.get("quad"):
                    quad = np.array(v_meta["quad"], dtype=np.float32)
                    vw = float(v_meta.get("width") or raw_bgr.shape[1])
                    vh = float(v_meta.get("height") or raw_bgr.shape[0])
                    if vw > 0 and vh > 0 and (
                        int(round(vw)) != raw_bgr.shape[1] or int(round(vh)) != raw_bgr.shape[0]
                    ):
                        quad[:, 0] *= raw_bgr.shape[1] / vw
                        quad[:, 1] *= raw_bgr.shape[0] / vh
                    img = perspective_warp(raw_bgr, quad, preordered=True)
                    crop_method = f"vision:{v_meta.get('method', 'vision')}"
                else:
                    img = raw_bgr
                    crop_method = "vision:none"
            else:
                img, crop_info = detect_and_crop_with_info(raw_bgr)
                crop_method = f"opencv_fallback:{crop_info['method']}"
                crop_conf = float(crop_info["confidence"])
        elif auto_crop:
            img, crop_info = detect_and_crop_with_info(raw_bgr)
            crop_method = f"opencv:{crop_info['method']}"
            crop_conf = float(crop_info["confidence"])
        else:
            img = raw_bgr
            crop_method = "none"
        del raw_bgr

    if img is None or load_error is not None:
        err_msg = load_error or "Unknown image load error"
        logger.warning("Skipping %s (%s)", label, err_msg)
        return {
            "manifest": {
                "index": idx,
                "input": task["input"],
                "file": task["file"],
                "page_index": task["page_index"],
                "status": "error",
                "output": None,
                "message": err_msg,
                "method": crop_method,
                "confidence": crop_conf,
                "width": 0,
                "height": 0,
            },
            "page_spec": None,
        }

    total_items = config["total_items"]
    canon_mode = config["canon_mode"]
    page_size = config["page_size"]
    dpi = config["dpi"]
    margin = config["margin"]
    multipoint_points = config["multipoint_points"]
    flatten_surface = config["flatten_surface"]
    balance_symmetry = config["balance_symmetry"]
    jpeg_quality = config["jpeg_quality"]
    auto_crop = config["auto_crop"]

    suffix = f" ({crop_method}, conf={crop_conf:.2f})" if crop_conf > 0 else ""
    logger.info("[Page %d/%d] Enhancing %s%s...", idx + 1, total_items, label, suffix)

    img = downscale_to_dpi(img, page_size, dpi, margin)
    if auto_crop and multipoint_points > 0:
        orig_hw = img.shape[:2]
        img = multipoint_border_mask_clean(img, points_per_edge=multipoint_points)
        img = enhance_image_bgr(img, mode=canon_mode)
        if flatten_surface:
            img = flatten_document_surface(img)
        if balance_symmetry:
            img = balance_page_symmetry(img, target_shape=orig_hw)
    else:
        img = enhance_image_bgr(img, mode=canon_mode)

    pil_page = _bgr_to_pil(img, canon_mode)
    del img

    stem = re.sub(r"[^A-Za-z0-9._-]+", "_", label).strip("_") or f"page_{idx + 1}"
    is_bw_1bit = pil_page.mode == "1"
    ext = "png" if is_bw_1bit else "jpg"
    emit_dir_path = Path(config["emit_dir"]) if config["emit_dir"] else None
    tmp_dir_path = Path(config["tmp_dir"])
    debug_dir = Path(config["debug_dir"]) if config["debug_dir"] else None

    emit_tag = config.get("emit_tag")
    file_prefix = f"{idx + 1:04d}_{emit_tag}_" if emit_tag else f"{idx + 1:04d}_"
    out_path = (emit_dir_path or tmp_dir_path) / f"{file_prefix}{stem}_{canon_mode}.{ext}"
    if is_bw_1bit:
        pil_page.save(out_path, format="PNG", optimize=True)
        page_fmt = "png_1bit"
        color_space = "/DeviceGray"
    else:
        pil_page.save(
            out_path,
            format="JPEG",
            quality=jpeg_quality,
            optimize=True,
            progressive=False,
        )
        page_fmt = "jpeg"
        color_space = "/DeviceGray" if pil_page.mode == "L" else "/DeviceRGB"

    width, height = pil_page.width, pil_page.height
    pil_page.close()
    del pil_page

    debug_out_path = None
    if debug_dir is not None:
        debug_file = debug_dir / f"{idx + 1:02d}_{stem}_{canon_mode}.{ext}"
        shutil.copy2(out_path, debug_file)
        debug_out_path = _canonical_path(debug_file)

    emitted_out = _canonical_path(out_path) if emit_dir_path is not None else debug_out_path
    return {
        "manifest": {
            "index": idx,
            "input": task["input"],
            "file": task["file"],
            "page_index": task["page_index"],
            "status": "ok",
            "output": emitted_out,
            "message": "",
            "method": crop_method,
            "confidence": crop_conf,
            "width": width,
            "height": height,
        },
        "page_spec": {
            "image_path": str(out_path),
            "format": page_fmt,
            "width": width,
            "height": height,
            "color_space": color_space,
        },
    }


def _parse_workers_arg(value: str) -> int:
    """Parse --workers value ('auto', 0, or positive integer >= 1) into int (0 means auto)."""
    token = str(value).strip().lower()
    if token == "auto":
        return 0
    try:
        parsed = int(token)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"Invalid --workers value: {value!r} (use 'auto' or >= 0)") from exc
    if parsed < 0:
        raise argparse.ArgumentTypeError(f"Invalid --workers value: {value!r} (must be >= 0 or 'auto')")
    return parsed


def resolve_worker_count(requested_workers: int, task_count: int, sample_pixels: int = 0) -> int:
    """Resolve effective worker count; auto (<= 0) avoids multiprocessing spawn overhead on small/low-res batches."""
    if task_count <= 1:
        return 1
    if requested_workers > 0:
        return max(1, min(requested_workers, task_count))
    if task_count <= 8:
        return 1
    if 0 < sample_pixels < 1_500_000 and task_count < 16:
        return 1
    return min(4, max(1, (os.cpu_count() or 2) // 2), task_count)


def convert_folder_to_hd_pdf(
    input_path: str,
    output_pdf_path: str | None = None,
    mode: str = "auto_color",
    auto_crop: bool = True,
    dpi: int = 200,
    crop_engine: str = "auto",
    multipoint_points: int = 32,
    page_size: str = "a4",
    margin: float = 20.0,
    flatten_surface: bool = True,
    balance_symmetry: bool = False,
    save_debug: str | None = None,
    emit_dir: str | None = None,
    manifest_path: str | None = None,
    min_confidence: float = 0.45,
    jpeg_quality: int = 86,
    workers: int | str = 1,
) -> bool:
    """Scan a folder/image/PDF in streaming mode and export processed pages/manifest and/or an HD PDF."""
    canon_mode = normalize_enhance_mode(mode)
    jpeg_quality = max(1, min(100, int(jpeg_quality)))
    if isinstance(workers, str) and workers.strip().lower() == "auto":
        requested_workers = 0
    else:
        requested_workers = max(0, int(workers))
    manifest_file = Path(manifest_path).expanduser() if manifest_path else None

    if not os.path.exists(input_path):
        logger.error("Input path does not exist: %s", input_path)
        _write_manifest(
            manifest_file,
            {
                "engine": "hybrid_opencv",
                "output": output_pdf_path,
                "pages": 0,
                "pages_error": 0,
                "results": [],
            },
        )
        return False

    files = find_images(input_path)
    if not files:
        logger.error("No images found in %s", input_path)
        _write_manifest(
            manifest_file,
            {
                "engine": "hybrid_opencv",
                "output": output_pdf_path,
                "pages": 0,
                "pages_error": 0,
                "results": [],
            },
        )
        return False

    vision_cmd, _ = resolve_vision_helper()
    has_vision = sys.platform == "darwin" and bool(vision_cmd)
    use_vision = auto_crop and (
        crop_engine == "vision" or (crop_engine == "auto" and has_vision)
    )
    if auto_crop and crop_engine == "vision" and not has_vision:
        logger.error("[ERROR] --crop-engine vision requires macOS with doc_scanner binary or swift + doc_scanner.swift.")
        return False

    emit_dir_path = Path(emit_dir).expanduser() if emit_dir else None
    if emit_dir_path:
        emit_dir_path.mkdir(parents=True, exist_ok=True)

    debug_dir = Path(save_debug).expanduser() if save_debug else None
    if debug_dir:
        debug_dir.mkdir(parents=True, exist_ok=True)

    logger.info(
        "Processing %d file(s) from: %s [mode=%s, crop_engine=%s, multipoint=%d, flatten=%s, symmetry=%s, dpi=%d, q=%d, workers=%s]",
        len(files),
        input_path,
        canon_mode,
        "vision" if use_vision else "opencv",
        multipoint_points,
        flatten_surface,
        balance_symmetry,
        dpi,
        jpeg_quality,
        "auto" if requested_workers <= 0 else requested_workers,
    )

    with tempfile.TemporaryDirectory(prefix="pdfscanner_") as tmp:
        tmp_dir = Path(tmp)
        tasks = _discover_page_tasks(files, use_vision=use_vision, tmp_dir=tmp_dir)

        sample_pixels = 0
        if requested_workers <= 0:
            for t in tasks:
                lp = t.get("load_path")
                if t.get("error") is None and lp:
                    try:
                        with Image.open(lp) as im_hdr:
                            sw_px, sh_px = im_hdr.size
                        sample_pixels = int(sw_px) * int(sh_px)
                        break
                    except Exception:
                        pass
        effective_workers = resolve_worker_count(requested_workers, len(tasks), sample_pixels=sample_pixels)
        if requested_workers <= 0:
            logger.info("Auto-selected %d worker(s) for %d page(s)", effective_workers, len(tasks))

        if use_vision:
            vision_inputs = [t["vision_input"] for t in tasks if t["error"] is None and t["vision_input"]]
            if vision_inputs:
                vision_results = crop_via_vision(vision_inputs, vision_cmd, min_confidence, False, tmp_dir)
                for t in tasks:
                    vi = t.get("vision_input")
                    if vi:
                        t["vision_meta"] = vision_results.get(_canonical_path(vi))

        config = {
            "total_items": len(tasks),
            "canon_mode": canon_mode,
            "auto_crop": auto_crop,
            "use_vision": use_vision,
            "page_size": page_size,
            "dpi": dpi,
            "margin": margin,
            "multipoint_points": multipoint_points,
            "flatten_surface": flatten_surface,
            "balance_symmetry": balance_symmetry,
            "jpeg_quality": jpeg_quality,
            "emit_dir": str(emit_dir_path) if emit_dir_path else None,
            "tmp_dir": str(tmp_dir),
            "debug_dir": str(debug_dir) if debug_dir else None,
        }

        ordered_results: list[dict | None] = [None] * len(tasks)
        if effective_workers > 1 and len(tasks) > 1:
            mp_ctx = multiprocessing.get_context("spawn")
            with ProcessPoolExecutor(
                max_workers=min(effective_workers, len(tasks)),
                mp_context=mp_ctx,
                initializer=_init_worker,
            ) as executor:
                future_to_idx = {
                    executor.submit(_process_single_page_task, task, config): task["index"]
                    for task in tasks
                }
                for fut in as_completed(future_to_idx):
                    idx = future_to_idx[fut]
                    ordered_results[idx] = fut.result()
        else:
            for step_i, task in enumerate(tasks, 1):
                ordered_results[task["index"]] = _process_single_page_task(task, config)
                if step_i % 20 == 0:
                    gc.collect()

        manifest_results: list[dict] = []
        page_specs: list[dict] = []
        pages_ok = 0
        pages_error = 0

        for res in ordered_results:
            assert res is not None
            manifest_results.append(res["manifest"])
            if res["manifest"]["status"] == "ok" and res["page_spec"] is not None:
                pages_ok += 1
                page_specs.append(res["page_spec"])
            else:
                pages_error += 1

        if pages_ok == 0:
            _write_manifest(
                manifest_file,
                {
                    "engine": "hybrid_opencv",
                    "output": None,
                    "pages": 0,
                    "pages_error": pages_error,
                    "results": manifest_results,
                },
            )
            logger.error("No valid pages were processed.")
            return False

        if output_pdf_path:
            assemble_pdf_from_pages(
                page_specs=page_specs,
                output_pdf_path=output_pdf_path,
                page_size=page_size,
                dpi=dpi,
                margin=margin,
            )
            size_bytes = os.path.getsize(output_pdf_path)
            logger.info("\n[SUCCESS] Saved HD Scanned PDF: %s", output_pdf_path)
            logger.info(
                "Total pages: %d, Errors: %d, Size: %s bytes (%.2f MiB)",
                pages_ok,
                pages_error,
                f"{size_bytes:,}",
                size_bytes / (1024 * 1024),
            )
        else:
            logger.info("\n[SUCCESS] Emitted %d page(s) (Errors: %d)", pages_ok, pages_error)

        _write_manifest(
            manifest_file,
            {
                "engine": "hybrid_opencv",
                "output": os.path.abspath(output_pdf_path) if output_pdf_path else None,
                "pages": pages_ok,
                "pages_error": pages_error,
                "results": manifest_results,
            },
        )
        return True


def _build_arg_parser() -> argparse.ArgumentParser:
    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    default_input = os.path.join(base_dir, "input")
    default_output = os.path.join(base_dir, "output", "Scanned_Document_HD.pdf")

    parser = argparse.ArgumentParser(
        description="Local HD Document Scanner (zero watermark, Vision/OpenCV crop, 128-pt clean, surface flatten, Auto Color / Clean / B&W / Grayscale)."
    )
    parser.add_argument(
        "input_path",
        nargs="?",
        default=default_input,
        help=f"Input folder, image, or PDF path (default: {default_input})",
    )
    parser.add_argument(
        "output_pdf",
        nargs="?",
        default=None,
        help=f"Output PDF file path (default: {default_output} unless --emit-dir is used)",
    )
    parser.add_argument(
        "--output",
        dest="output_flag",
        default=None,
        help="Output PDF file path (overrides positional output_pdf)",
    )
    parser.add_argument(
        "--mode",
        choices=["auto_color", "magic_color", "clean", "bw", "grayscale", "original"],
        default="auto_color",
        help="Enhancement filter mode (default: auto_color; magic_color accepted as alias)",
    )
    parser.add_argument(
        "--crop-engine",
        choices=["auto", "vision", "opencv"],
        default="auto",
        help="Document boundary detection engine (default: auto)",
    )
    parser.add_argument(
        "--multipoint-points",
        type=int,
        default=32,
        help="Control points per edge for 128-pt border cleaning (0 to disable, default: 32)",
    )
    parser.add_argument(
        "--page-size",
        choices=["a4", "letter", "fit"],
        default="a4",
        help="Target page sizing box and PDF MediaBox (default: a4)",
    )
    parser.add_argument(
        "--dpi",
        type=int,
        default=200,
        help="Target PDF DPI (default: 200)",
    )
    parser.add_argument(
        "--margin",
        type=float,
        default=20.0,
        help="Page margin in points for a4/letter layout (default: 20.0)",
    )
    parser.add_argument(
        "--jpeg-quality",
        type=int,
        default=86,
        help="JPEG output quality 1..100 for color/grayscale pages (default: 86)",
    )
    parser.add_argument(
        "--workers",
        type=_parse_workers_arg,
        default=1,
        help="Number of worker processes for page enhancement ('auto', 0, or N; default: 1)",
    )
    parser.add_argument(
        "--min-confidence",
        type=float,
        default=0.45,
        help="Minimum boundary detection confidence for Vision engine (0.0..1.0, default: 0.45)",
    )
    parser.add_argument(
        "--no-crop",
        action="store_true",
        help="Disable automatic document border detection, 128-pt clean, flatten, and symmetry centering",
    )
    parser.add_argument(
        "--no-flatten",
        action="store_true",
        help="Disable 2D Ridge surface flattening",
    )
    sym_group = parser.add_mutually_exclusive_group()
    sym_group.add_argument(
        "--symmetry",
        action="store_true",
        dest="balance_symmetry",
        default=False,
        help="Enable symmetric 4-side margin centering (disabled by default to preserve layout)",
    )
    sym_group.add_argument(
        "--no-symmetry",
        action="store_false",
        dest="balance_symmetry",
        help="Disable symmetric margin centering (default)",
    )
    parser.add_argument(
        "--emit-dir",
        default=None,
        help="Directory to emit per-page processed images (skips PDF assembly if --output is omitted)",
    )
    parser.add_argument(
        "--manifest",
        default=None,
        help="Path to write JSON manifest of per-page outputs and errors",
    )
    parser.add_argument(
        "--save-debug",
        default=None,
        help="Directory to save per-page processed images for visual inspection",
    )
    parser.add_argument(
        "--worker-stdio",
        action="store_true",
        help="Run as a persistent JSON-lines stdio worker for low-latency previews",
    )
    return parser


def run_worker_stdio() -> int:
    """Process single-page preview requests delivered as JSON lines over stdin/stdout."""
    _init_worker()
    vision_cmd, _ = resolve_vision_helper()
    has_vision = sys.platform == "darwin" and bool(vision_cmd)
    valid_modes = {"auto_color", "clean", "bw", "grayscale", "original"}
    job_seq = 0

    def _reply(obj: dict) -> None:
        sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
        sys.stdout.flush()

    def _reply_error(rid: str, msg: str) -> None:
        _reply(
            {
                "id": rid,
                "status": "error",
                "output": None,
                "message": msg,
                "method": "none",
                "confidence": 0.0,
                "width": 0,
                "height": 0,
            }
        )

    while True:
        raw_line = sys.stdin.readline()
        if not raw_line:
            break
        line = raw_line.strip()
        if not line:
            continue

        req_id = ""
        try:
            req = json.loads(line)
            if not isinstance(req, dict):
                _reply_error("", "Invalid JSON object request")
                continue
            raw_id = req.get("id")
            req_id = "" if raw_id is None else str(raw_id)
            cmd = req.get("cmd")
            if cmd == "ping":
                _reply({"status": "pong", "id": req_id})
                continue
            if cmd == "quit":
                _reply({"status": "bye", "id": req_id})
                break

            raw_input = req.get("input")
            if not isinstance(raw_input, str) or not raw_input.strip():
                _reply_error(req_id, "Missing or null input path")
                continue

            raw_emit_dir = req.get("emit_dir")
            if not isinstance(raw_emit_dir, str) or not raw_emit_dir.strip():
                _reply_error(req_id, "Missing or null emit_dir")
                continue

            canon_mode = normalize_enhance_mode(str(req.get("mode", "auto_color")))
            if canon_mode not in valid_modes:
                _reply_error(req_id, f"Unsupported enhance mode: {canon_mode}")
                continue

            canon_input = _canonical_path(raw_input)
            if not os.path.isfile(canon_input):
                _reply_error(req_id, f"Input file not found: {raw_input}")
                continue
            if (
                os.path.splitext(raw_input)[1].lower() == ".pdf"
                or os.path.splitext(canon_input)[1].lower() == ".pdf"
            ):
                _reply_error(req_id, "PDF inputs are not supported in single-page --worker-stdio mode")
                continue
            try:
                with Image.open(canon_input) as probe_im:
                    _ = probe_im.format
            except Exception as exc:
                _reply_error(req_id, f"Failed to load image: {exc}")
                continue

            emit_dir_path = Path(raw_emit_dir).expanduser()
            emit_dir_path.mkdir(parents=True, exist_ok=True)

            auto_crop = bool(req.get("auto_crop", True))
            crop_engine = str(req.get("crop_engine", "auto")).lower()
            use_vision = auto_crop and (
                crop_engine == "vision" or (crop_engine == "auto" and has_vision)
            )
            min_conf = float(req.get("min_confidence", 0.45))
            job_seq += 1

            with tempfile.TemporaryDirectory(prefix="pdfscanner_w_") as td:
                tmp_dir = Path(td)
                fname = unicodedata.normalize("NFC", os.path.basename(raw_input)) or os.path.basename(canon_input)
                task = _make_task_entry(
                    index=0,
                    canon_fpath=canon_input,
                    fname=fname,
                    label=fname,
                    kind="image",
                    load_path=canon_input,
                    vision_input=canon_input if use_vision else None,
                )
                if use_vision:
                    try:
                        v_map = crop_via_vision([canon_input], vision_cmd, min_conf, False, tmp_dir)
                        task["vision_meta"] = v_map.get(canon_input)
                    except Exception as exc:
                        logger.warning("Vision helper fallback to OpenCV in worker: %s", exc)

                config = {
                    "total_items": 1,
                    "canon_mode": canon_mode,
                    "auto_crop": auto_crop,
                    "use_vision": use_vision,
                    "page_size": str(req.get("page_size", "a4")),
                    "dpi": int(req.get("dpi", 200)),
                    "margin": float(req.get("margin", 20.0)),
                    "multipoint_points": int(req.get("multipoint_points", 32)),
                    "flatten_surface": bool(req.get("flatten_surface", True)),
                    "balance_symmetry": bool(req.get("balance_symmetry", False)),
                    "jpeg_quality": max(1, min(100, int(req.get("jpeg_quality", 86)))),
                    "emit_dir": str(emit_dir_path),
                    "emit_tag": f"w{job_seq:04d}_{uuid.uuid4().hex[:6]}",
                    "tmp_dir": str(tmp_dir),
                    "debug_dir": None,
                }
                res = _process_single_page_task(task, config)
                manifest = res["manifest"]
                manifest["id"] = req_id
                _reply(manifest)
        except Exception as exc:
            _reply_error(req_id, str(exc))
        finally:
            gc.collect()

    return 0


if __name__ == "__main__":
    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    default_output = os.path.join(base_dir, "output", "Scanned_Document_HD.pdf")
    args = _build_arg_parser().parse_args()
    if args.worker_stdio:
        sys.exit(run_worker_stdio())
    out_path = args.output_flag or args.output_pdf
    if not out_path and not args.emit_dir:
        out_path = default_output
    success = convert_folder_to_hd_pdf(
        input_path=args.input_path,
        output_pdf_path=out_path,
        mode=args.mode,
        auto_crop=not args.no_crop,
        dpi=args.dpi,
        crop_engine=args.crop_engine,
        multipoint_points=args.multipoint_points,
        page_size=args.page_size,
        margin=args.margin,
        flatten_surface=not args.no_flatten,
        balance_symmetry=args.balance_symmetry,
        save_debug=args.save_debug,
        emit_dir=args.emit_dir,
        manifest_path=args.manifest,
        min_confidence=args.min_confidence,
        jpeg_quality=args.jpeg_quality,
        workers=args.workers,
    )
    sys.exit(0 if success else 1)
