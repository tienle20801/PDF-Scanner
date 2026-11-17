from __future__ import annotations

import argparse
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageOps
from pypdf import PdfReader

try:
    import pillow_heif

    pillow_heif.register_heif_opener()
except ImportError:
    pass

SUPPORTED_IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".bmp", ".webp", ".heic", ".heif"}
SUPPORTED_EXTENSIONS = SUPPORTED_IMAGE_EXTENSIONS | {".pdf"}

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
        if os.path.isfile(os.path.join(input_path, entry))
        and os.path.splitext(entry)[1].lower() in SUPPORTED_EXTENSIONS
    ]
    matched.sort(key=_natural_sort_key)
    return [os.path.join(input_path, name) for name in matched]


def _pil_to_bgr(pil_img: Image.Image) -> np.ndarray:
    """Apply EXIF orientation and convert a PIL image to OpenCV BGR."""
    transposed = ImageOps.exif_transpose(pil_img)
    rgb_img = transposed.convert("RGB")
    return cv2.cvtColor(np.array(rgb_img), cv2.COLOR_RGB2BGR)


def load_image_bgr(fpath: str) -> np.ndarray:
    """Load an image via Pillow (handling EXIF orientation and HEIC) into OpenCV BGR."""
    with Image.open(fpath) as pil_img:
        return _pil_to_bgr(pil_img)


def _iter_pdf_pages_bgr(pdf_path: str):
    """Yield (label, bgr_img) for each page in a PDF containing scanned images."""
    reader = PdfReader(pdf_path)
    base_name = os.path.basename(pdf_path)
    for page_idx, page in enumerate(reader.pages, 1):
        rotate = int(page.get("/Rotate", 0) or 0) % 360
        if not page.images:
            print(f"Skipping {base_name} page {page_idx} (no embedded image found).")
            continue
        for img_obj in page.images:
            with Image.open(io.BytesIO(img_obj.data)) as pil_img:
                bgr = _pil_to_bgr(pil_img)
            if rotate == 90:
                bgr = cv2.rotate(bgr, cv2.ROTATE_90_CLOCKWISE)
            elif rotate == 180:
                bgr = cv2.rotate(bgr, cv2.ROTATE_180)
            elif rotate == 270:
                bgr = cv2.rotate(bgr, cv2.ROTATE_90_COUNTERCLOCKWISE)
            yield f"{base_name} [page {page_idx}/{len(reader.pages)}]", bgr


def _order_points(pts: np.ndarray) -> np.ndarray:
    rect = np.zeros((4, 2), dtype="float32")
    coord_sum = pts.sum(axis=1)
    rect[0] = pts[np.argmin(coord_sum)]
    rect[2] = pts[np.argmax(coord_sum)]
    diff = np.diff(pts, axis=1)
    rect[1] = pts[np.argmin(diff)]
    rect[3] = pts[np.argmax(diff)]
    return rect


def perspective_warp(image: np.ndarray, quad: np.ndarray) -> np.ndarray:
    """Warp a 4-point quadrilateral region flat into a rectangular top-down view."""
    rect = _order_points(quad)
    tl, tr, br, bl = rect
    max_width = max(int(np.linalg.norm(br - bl)), int(np.linalg.norm(tr - tl)), 1)
    max_height = max(int(np.linalg.norm(tr - br)), int(np.linalg.norm(tl - bl)), 1)
    dst = np.array(
        [[0, 0], [max_width - 1, 0], [max_width - 1, max_height - 1], [0, max_height - 1]],
        dtype="float32",
    )
    matrix = cv2.getPerspectiveTransform(rect, dst)
    return cv2.warpPerspective(image, matrix, (max_width, max_height))


def detect_and_crop(img: np.ndarray) -> np.ndarray:
    """Detect document bounds via saturation-aware paper segmentation and warp flat."""
    orig = img.copy()
    h, w = img.shape[:2]

    scale = 1000.0 / max(h, w, 1)
    small = cv2.resize(img, (max(1, int(w * scale)), max(1, int(h * scale))))
    sh, sw = small.shape[:2]

    # Pad with black border so paper touching image edges forms a closed contour
    pad = 12
    padded = cv2.copyMakeBorder(small, pad, pad, pad, pad, cv2.BORDER_CONSTANT, value=(0, 0, 0))
    hsv = cv2.cvtColor(padded, cv2.COLOR_BGR2HSV)
    _, s_ch, v_ch = cv2.split(hsv)

    # Paper has high brightness and low saturation; suppress colored backgrounds
    score = np.clip(v_ch.astype(np.float32) - 1.5 * s_ch.astype(np.float32), 0, 255).astype(np.uint8)
    score = cv2.GaussianBlur(score, (9, 9), 0)
    _, mask = cv2.threshold(score, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    mask[:pad, :] = 0
    mask[-pad:, :] = 0
    mask[:, :pad] = 0
    mask[:, -pad:] = 0

    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_RECT, (15, 15)))
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_RECT, (9, 9)))

    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    contours = sorted(contours, key=cv2.contourArea, reverse=True)

    paper_rect = None
    if contours and cv2.contourArea(contours[0]) > (sw * sh * 0.35):
        contour = contours[0]
        peri = cv2.arcLength(contour, True)
        approx = cv2.approxPolyDP(contour, 0.02 * peri, True)
        if len(approx) == 4 and cv2.isContourConvex(approx):
            pts_small = approx.reshape(4, 2).astype(np.float32) - pad
        else:
            pts_small = cv2.boxPoints(cv2.minAreaRect(contour)).astype(np.float32) - pad

        pts_small[:, 0] = np.clip(pts_small[:, 0], 0, sw - 1)
        pts_small[:, 1] = np.clip(pts_small[:, 1], 0, sh - 1)
        paper_rect = pts_small / scale

    if paper_rect is not None:
        tl, tr, br, bl = _order_points(paper_rect)
        max_w = max(int(np.linalg.norm(br - bl)), int(np.linalg.norm(tr - tl)))
        max_h = max(int(np.linalg.norm(tr - br)), int(np.linalg.norm(tl - bl)))
        if max_w > 500 and max_h > 500:
            return perspective_warp(orig, paper_rect)

    return orig


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


def _extract_edge_offsets(
    bg_mask: np.ndarray, strip_depth: int, side: str, points_per_edge: int
) -> np.ndarray:
    """Extract inward background depth along one edge ('top', 'bottom', 'left', 'right')."""
    h, w = bg_mask.shape
    if side in ("top", "bottom"):
        strip = bg_mask[:strip_depth, :] if side == "top" else bg_mask[h - strip_depth :, :]
        if side == "bottom":
            strip = strip[::-1, :]
        axis_len = w
    else:
        strip = bg_mask[:, :strip_depth] if side == "left" else bg_mask[:, w - strip_depth :]
        if side == "right":
            strip = strip[:, ::-1]
        strip = strip.T.copy()  # transpose so outer edge is row 0
        # Prevent top/bottom border bleed from smearing into left/right edge curves near page corners
        tb_ignore = min(strip.shape[1] // 8, max(6, int(0.02 * h)))
        strip[:, :tb_ignore] = 0
        strip[:, -tb_ignore:] = 0
        axis_len = h

    closed = cv2.morphologyEx(strip, cv2.MORPH_CLOSE, np.ones((3, 5), np.uint8))
    opened = cv2.morphologyEx(closed, cv2.MORPH_OPEN, np.ones((2, 15), np.uint8))

    _, labels = cv2.connectedComponents(opened)
    border_labels = set(np.unique(labels[0, :])) - {0}
    if not border_labels:
        return np.zeros(axis_len, dtype=np.float32)

    connected = np.isin(labels, list(border_labels))
    offsets = np.zeros(axis_len, dtype=np.float32)
    ys, xs = np.where(connected)
    if ys.size > 0:
        np.maximum.at(offsets, xs, ys + 1)
    return _smooth_edge_curve(offsets, points_per_edge, strip_depth)


def _estimate_paper_stats(
    image: np.ndarray,
) -> tuple[np.ndarray, np.ndarray, float, float, float, np.ndarray]:
    """Return (lab, hsv, l_paper, a_paper, b_paper, paper_bgr) from inner 8%..92% frame."""
    h, w = image.shape[:2]
    lab = cv2.cvtColor(image, cv2.COLOR_BGR2LAB)
    hsv = cv2.cvtColor(image, cv2.COLOR_BGR2HSV)

    y0, y1 = int(0.08 * h), int(0.92 * h)
    x0, x1 = int(0.08 * w), int(0.92 * w)
    inner_lab = lab[y0:y1, x0:x1]
    l_paper = float(np.percentile(inner_lab[:, :, 0], 80))
    a_paper = float(np.median(inner_lab[:, :, 1]))
    b_paper = float(np.median(inner_lab[:, :, 2]))

    inner_bgr = image[y0:y1, x0:x1]
    paper_px = inner_bgr[inner_lab[:, :, 0] >= l_paper - 10]
    paper_bgr = (
        np.median(paper_px, axis=0).astype(np.uint8)
        if paper_px.size > 0
        else np.array([245, 245, 245], dtype=np.uint8)
    )
    return lab, hsv, l_paper, a_paper, b_paper, paper_bgr


def _compute_bg_and_paper(
    image: np.ndarray,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """Return (is_bg_mask, chroma_diff, saturation, paper_bgr)."""
    lab, hsv, l_paper, a_paper, b_paper, paper_bgr = _estimate_paper_stats(image)

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
    return is_bg, chroma_diff, S, paper_bgr


def _clean_residual_border_bleed(image: np.ndarray) -> np.ndarray:
    """Clean thin residual background bleed touching the outer 1.5% border."""
    h, w = image.shape[:2]
    _, chroma_diff, S, paper_bgr = _compute_bg_and_paper(image)
    bleed = ((chroma_diff > 8.5) | (S > 30)).astype(np.uint8) * 255

    out = image.copy()
    v_depth = max(4, int(0.015 * h))
    h_depth = max(4, int(0.015 * w))

    strips = [
        ((0, v_depth, 0, w), (2, 13), "row0"),
        ((h - v_depth, h, 0, w), (2, 13), "row_end"),
        ((0, h, 0, h_depth), (13, 2), "col0"),
        ((0, h, w - h_depth, w), (13, 2), "col_end"),
    ]
    for (r0, r1, c0, c1), ksize, edge_pos in strips:
        patch = bleed[r0:r1, c0:c1]
        opened = cv2.morphologyEx(patch, cv2.MORPH_OPEN, np.ones(ksize, np.uint8))
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
            out[r0:r1, c0:c1][mask] = paper_bgr
    return out


def multipoint_border_mask_clean(image: np.ndarray, points_per_edge: int = 32) -> np.ndarray:
    """Mask out curved background outside a 128-point border polygon using local paper fill."""
    if points_per_edge <= 0:
        return image
    h, w = image.shape[:2]
    if h < 120 or w < 120:
        return image

    is_bg, _, _, _ = _compute_bg_and_paper(image)
    lab, _, l_paper, _, _, _ = _estimate_paper_stats(image)
    dark_tb_raw = (lab[:, :, 0].astype(np.float32) < min(148.0, l_paper - 58.0)).astype(np.uint8) * 255
    dark_tb = cv2.morphologyEx(dark_tb_raw, cv2.MORPH_OPEN, np.ones((2, 15), np.uint8))
    is_bg_tb = cv2.bitwise_or(is_bg, dark_tb)

    tb_depth = max(8, int(0.055 * h))
    lr_depth = max(8, int(0.045 * w))

    y_top = _extract_edge_offsets(is_bg_tb, tb_depth, "top", points_per_edge)
    y_bottom = (h - 1.0) - _extract_edge_offsets(is_bg_tb, tb_depth, "bottom", points_per_edge)
    x_left = _extract_edge_offsets(is_bg, lr_depth, "left", points_per_edge)
    x_right = (w - 1.0) - _extract_edge_offsets(is_bg, lr_depth, "right", points_per_edge)

    out = image.copy()
    ys = np.arange(h, dtype=np.float32)[:, None]
    xs = np.arange(w, dtype=np.float32)[None, :]
    outside_mask = (
        (ys < y_top[None, :])
        | (ys > y_bottom[None, :])
        | (xs < x_left[:, None])
        | (xs > x_right[:, None])
    )
    # Propagate adjacent interior paper intensity into outside_mask so dilation in enhance avoids dark edge halos
    seed = image.copy()
    seed[outside_mask | (is_bg_tb > 0)] = 0
    local_bg = cv2.medianBlur(cv2.dilate(seed, np.ones((31, 31), np.uint8), iterations=2), 21)
    out[outside_mask] = local_bg[outside_mask]
    return _clean_residual_border_bleed(out)


def _extract_ruling_samples(
    line_map: np.ndarray, horizontal: bool, min_span: int
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Extract (xs, ys, deltas) deviation samples along horizontal or vertical ruling lines."""
    work = line_map if horizontal else line_map.T
    num_labels, labels, stats, _ = cv2.connectedComponentsWithStats(work)
    xs_list, ys_list, d_list = [], [], []

    for lbl in range(1, num_labels):
        bx, by, bw, bh, _ = stats[lbl]
        if bw < min_span or bw / max(bh, 1) < 8.0:
            continue
        comp = labels[by : by + bh, bx : bx + bw] == lbl
        col_counts = comp.sum(axis=0)
        valid_cols = np.where(col_counts > 0)[0]
        if valid_cols.size < max(10, min_span // 2):
            continue
        row_idx = np.arange(by, by + bh, dtype=np.float32)[:, None]
        y_centroids = (comp[:, valid_cols] * row_idx).sum(axis=0) / col_counts[valid_cols]
        y_bar = float(np.median(y_centroids))
        x_coords = (bx + valid_cols).astype(np.float32)

        if horizontal:
            xs_list.append(x_coords)
            ys_list.append(np.full_like(x_coords, y_bar))
        else:
            xs_list.append(np.full_like(x_coords, y_bar))
            ys_list.append(x_coords)
        d_list.append(y_centroids - y_bar)

    if not xs_list:
        empty = np.empty(0, dtype=np.float32)
        return empty, empty, empty
    return np.concatenate(xs_list), np.concatenate(ys_list), np.concatenate(d_list)


def _poly_features(xh: np.ndarray, yh: np.ndarray, degree3_x: bool) -> np.ndarray:
    cols = [np.ones_like(xh), xh, yh, xh * xh, xh * yh, yh * yh]
    if degree3_x:
        cols.extend([xh * xh * xh, xh * xh * yh, xh * yh * yh])
    return np.stack(cols, axis=1)


def _fit_ridge_surface(
    xs: np.ndarray, ys: np.ndarray, deltas: np.ndarray, w: int, h: int, degree3_x: bool, lam: float = 50.0
) -> np.ndarray:
    """Fit regularized 2D polynomial displacement surface with 2-pass MAD outlier rejection."""
    if xs.size < 30:
        return np.zeros((h, w), dtype=np.float32)

    if xs.size > 12000:
        idx = np.linspace(0, xs.size - 1, 12000, dtype=int)
        xs, ys, deltas = xs[idx], ys[idx], deltas[idx]

    xh = xs / float(w) - 0.5
    yh = ys / float(h) - 0.5
    Phi = _poly_features(xh, yh, degree3_x)
    reg = lam * np.eye(Phi.shape[1], dtype=np.float64)

    coef = np.zeros(Phi.shape[1], dtype=np.float64)
    mask = np.ones(xs.size, dtype=bool)
    for _ in range(3):
        P = Phi[mask].astype(np.float64)
        d = deltas[mask].astype(np.float64)
        if P.shape[0] < 20:
            break
        coef = np.linalg.solve(P.T @ P + reg, P.T @ d)
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
    max_shift = 0.03 * min(h, w)
    return np.clip(surface, -max_shift, max_shift).astype(np.float32)


def flatten_document_surface(image: np.ndarray) -> np.ndarray:
    """Flatten 3D page curl & local warp using extracted ruling/text lines + Ridge 2D polynomial fit."""
    h, w = image.shape[:2]
    if h < 120 or w < 120:
        return image

    _, _, _, _, _, paper_bgr = _estimate_paper_stats(image)
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    inv = cv2.adaptiveThreshold(gray, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY_INV, 31, 10)

    py, px = max(4, int(0.02 * h)), max(4, int(0.02 * w))
    inv[:py, :] = 0
    inv[h - py :, :] = 0
    inv[:, :px] = 0
    inv[:, w - px :] = 0

    h_map = cv2.morphologyEx(inv, cv2.MORPH_OPEN, np.ones((1, max(45, w // 22)), np.uint8))
    xs_h, ys_h, dy_h = _extract_ruling_samples(h_map, horizontal=True, min_span=max(40, int(0.08 * w)))
    if xs_h.size < max(200, w // 4):
        closed_txt = cv2.morphologyEx(inv, cv2.MORPH_CLOSE, np.ones((2, max(25, w // 40)), np.uint8))
        text_lines = cv2.morphologyEx(closed_txt, cv2.MORPH_OPEN, np.ones((2, max(50, w // 18)), np.uint8))
        xs_h, ys_h, dy_h = _extract_ruling_samples(text_lines, horizontal=True, min_span=max(40, int(0.08 * w)))

    v_map = cv2.morphologyEx(inv, cv2.MORPH_OPEN, np.ones((max(40, h // 18), 1), np.uint8))
    xs_v, ys_v, dx_v = _extract_ruling_samples(v_map, horizontal=False, min_span=max(40, int(0.08 * h)))

    if xs_h.size < 30 and xs_v.size < 30:
        return image

    delta_y = _fit_ridge_surface(xs_h, ys_h, dy_h, w, h, degree3_x=True, lam=50.0)
    delta_x = _fit_ridge_surface(xs_v, ys_v, dx_v, w, h, degree3_x=False, lam=50.0)
    delta_y = delta_y - float(np.median(delta_y))
    delta_x = delta_x - float(np.median(delta_x))

    pad = int(0.065 * min(h, w)) + 8
    padded = cv2.copyMakeBorder(
        image, pad, pad, pad, pad, cv2.BORDER_CONSTANT, value=paper_bgr.tolist()
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
        borderValue=paper_bgr.tolist(),
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

    lab, _, l_paper, _, _, paper_bgr = _estimate_paper_stats(image)
    content_raw = (lab[:, :, 0].astype(np.float32) < (l_paper - 28.0)).astype(np.uint8) * 255
    content_clean = cv2.morphologyEx(content_raw, cv2.MORPH_OPEN, np.ones((2, 2), np.uint8))
    ys, xs = np.where(content_clean > 0)
    if ys.size < 50:
        return _center_crop_to_shape(image, th, tw)

    x_min = max(0, int(np.min(xs)) - 6)
    x_max = min(w, int(np.max(xs)) + 7)
    y_min = max(0, int(np.min(ys)) - 6)
    y_max = min(h, int(np.max(ys)) + 7)
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
    w_pt, h_pt = (595.28, 841.89) if page_size == "a4" else (612.0, 792.0)
    h, w = image.shape[:2]
    if w > h:
        w_pt, h_pt = h_pt, w_pt
    avail_w_px = max(100.0, (w_pt - 2.0 * margin) * dpi / 72.0)
    avail_h_px = max(100.0, (h_pt - 2.0 * margin) * dpi / 72.0)
    scale = min(1.0, avail_w_px / max(w, 1), avail_h_px / max(h, 1))
    if scale >= 0.99:
        return image
    return cv2.resize(image, (max(1, int(w * scale)), max(1, int(h * scale))), interpolation=cv2.INTER_AREA)


def compensate_strokes_and_lines(normalized: np.ndarray) -> np.ndarray:
    """Repair small 1-4px breaks in table borders and boost thin line contrast after resampling."""
    norm_gray = cv2.cvtColor(normalized, cv2.COLOR_BGR2GRAY)
    line_mask = (norm_gray < 195).astype(np.uint8) * 255
    h_lines = cv2.morphologyEx(
        cv2.morphologyEx(line_mask, cv2.MORPH_OPEN, np.ones((1, 35), np.uint8)),
        cv2.MORPH_CLOSE,
        np.ones((1, 7), np.uint8),
    )
    v_lines = cv2.morphologyEx(
        cv2.morphologyEx(line_mask, cv2.MORPH_OPEN, np.ones((35, 1), np.uint8)),
        cv2.MORPH_CLOSE,
        np.ones((7, 1), np.uint8),
    )
    grid_mask = (h_lines > 0) | (v_lines > 0)
    out = normalized.copy()
    out[grid_mask] = np.clip(out[grid_mask].astype(np.float32) * 0.82, 0, 255).astype(np.uint8)
    return out


def _compute_background_ratio(gray: np.ndarray) -> np.ndarray:
    """Estimate uneven illumination via morphological dilation + median blur."""
    dilated = cv2.dilate(gray, np.ones((15, 15), np.uint8))
    bg = cv2.medianBlur(dilated, 41)
    bg_32 = np.maximum(bg.astype(np.float32), 1.0)
    return 250.0 / bg_32


def enhance_image_bgr(img: np.ndarray, mode: str = "magic_color") -> np.ndarray:
    """Enhance a BGR OpenCV image in-place pipeline and return a BGR ndarray."""
    if mode == "original":
        return img

    if mode == "clean":
        lab = cv2.cvtColor(img, cv2.COLOR_BGR2LAB)
        l_ch, a_ch, b_ch = cv2.split(lab)
        bg = cv2.GaussianBlur(l_ch, (0, 0), sigmaX=max(15, min(img.shape[:2]) // 30))
        norm_l = cv2.divide(l_ch, bg, scale=255)
        cleaned = cv2.cvtColor(cv2.merge((norm_l, a_ch, b_ch)), cv2.COLOR_LAB2BGR)
        return cv2.convertScaleAbs(cleaned, alpha=1.1, beta=5)

    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)

    if mode == "magic_color":
        ratio = _compute_background_ratio(gray)
        b, g, r = cv2.split(img.astype(np.float32))
        normalized = cv2.merge(
            [np.clip(b * ratio, 0, 255), np.clip(g * ratio, 0, 255), np.clip(r * ratio, 0, 255)]
        ).astype(np.uint8)
        compensated = compensate_strokes_and_lines(normalized)
        lut_applied = cv2.LUT(compensated, _MAGIC_LUT)
        return cv2.filter2D(lut_applied, -1, _SHARPEN_KERNEL)

    if mode == "bw":
        bg = cv2.GaussianBlur(gray, (0, 0), sigmaX=max(15, min(img.shape[:2]) // 30))
        norm = cv2.divide(gray, bg, scale=255)
        bw = cv2.adaptiveThreshold(
            norm, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY, 25, 11
        )
        return cv2.cvtColor(bw, cv2.COLOR_GRAY2BGR)

    if mode == "grayscale":
        ratio = _compute_background_ratio(gray)
        norm_gray = np.clip(gray.astype(np.float32) * ratio, 0, 255).astype(np.uint8)
        clean_gray = cv2.LUT(norm_gray, _MAGIC_LUT)
        return cv2.cvtColor(clean_gray, cv2.COLOR_GRAY2BGR)

    raise ValueError(f"Unsupported enhance mode: {mode}")


def enhance_image(img: np.ndarray, mode: str = "magic_color") -> Image.Image:
    """Enhance a BGR OpenCV image using the selected document scanner mode and return a PIL Image."""
    enhanced_bgr = enhance_image_bgr(img, mode=mode)
    if mode in ("bw", "grayscale"):
        return Image.fromarray(cv2.cvtColor(enhanced_bgr, cv2.COLOR_BGR2GRAY)).convert("L")
    return Image.fromarray(cv2.cvtColor(enhanced_bgr, cv2.COLOR_BGR2RGB))


def enhance_magic_color(img: np.ndarray) -> Image.Image:
    """Backward-compatible wrapper for Magic Color enhancement."""
    return enhance_image(img, mode="magic_color")


def crop_via_vision(
    inputs: list[str],
    swift_script: Path,
    min_confidence: float,
    no_crop: bool,
    tmp_dir: Path,
) -> list[tuple[Path, dict]]:
    """Run macOS Vision document segmentation via Swift helper and return cropped image paths + metadata."""
    crop_dir = tmp_dir / "vision_crops"
    raw_pdf = tmp_dir / "vision_raw.pdf"
    cmd = [
        "swift",
        str(swift_script),
        "--output",
        str(raw_pdf),
        "--mode",
        "original",
        "--page-size",
        "fit",
        "--min-confidence",
        str(min_confidence),
        "--save-debug",
        str(crop_dir),
    ]
    if no_crop:
        cmd.append("--no-crop")
    cmd.extend(inputs)

    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"Vision crop failed: {proc.stderr.strip()}")
    if proc.stderr.strip():
        print(proc.stderr.strip(), file=sys.stderr)

    meta = json.loads(proc.stdout)
    crop_files = sorted(crop_dir.glob("*_scanned.jpg"), key=lambda p: _natural_sort_key(p.name))
    return list(zip(crop_files, meta.get("results", [])))


def convert_folder_to_hd_pdf(
    input_path: str,
    output_pdf_path: str,
    mode: str = "magic_color",
    auto_crop: bool = True,
    dpi: int = 200,
    crop_engine: str = "auto",
    multipoint_points: int = 32,
    page_size: str = "a4",
    margin: float = 20.0,
    flatten_surface: bool = True,
    balance_symmetry: bool = True,
    save_debug: str | None = None,
    min_confidence: float = 0.45,
) -> bool:
    """Scan a folder/image/PDF and export a geometrically flattened, shadow-free HD PDF."""
    if not os.path.exists(input_path):
        print(f"Input path does not exist: {input_path}")
        return False

    files = find_images(input_path)
    if not files:
        print(f"No images found in {input_path}")
        return False

    swift_script = Path(__file__).resolve().parent / "doc_scanner.swift"
    has_vision = sys.platform == "darwin" and shutil.which("swift") is not None and swift_script.exists()
    use_vision = auto_crop and (
        crop_engine == "vision" or (crop_engine == "auto" and has_vision)
    )
    if auto_crop and crop_engine == "vision" and not has_vision:
        print("[ERROR] --crop-engine vision requires macOS with swift and doc_scanner.swift.", file=sys.stderr)
        return False

    debug_dir = Path(save_debug).expanduser() if save_debug else None
    if debug_dir:
        debug_dir.mkdir(parents=True, exist_ok=True)

    print(
        f"Processing {len(files)} file(s) from: {input_path} "
        f"[mode={mode}, crop_engine={'vision' if use_vision else 'opencv'}, "
        f"multipoint={multipoint_points}, flatten={flatten_surface}, symmetry={balance_symmetry}, dpi={dpi}]"
    )

    pages: list[Image.Image] = []
    with tempfile.TemporaryDirectory(prefix="camscanner_") as tmp:
        tmp_dir = Path(tmp)
        raw_items: list[tuple[str, str | np.ndarray]] = []
        seq = 0
        for fpath in files:
            fname = os.path.basename(fpath)
            _, ext = os.path.splitext(fname)
            if ext.lower() == ".pdf":
                try:
                    for label, bgr in _iter_pdf_pages_bgr(fpath):
                        seq += 1
                        if use_vision:
                            tmp_img = tmp_dir / f"pdf_{seq:04d}.jpg"
                            cv2.imwrite(str(tmp_img), bgr, [cv2.IMWRITE_JPEG_QUALITY, 95])
                            raw_items.append((label, str(tmp_img)))
                        else:
                            raw_items.append((label, bgr))
                except Exception as exc:
                    print(f"Skipping {fname} (failed to read PDF): {exc}")
            else:
                seq += 1
                if use_vision:
                    raw_items.append((fname, fpath))
                else:
                    try:
                        raw_items.append((fname, load_image_bgr(fpath)))
                    except Exception as exc:
                        print(f"Skipping {fname} (failed to load): {exc}")

        if not raw_items:
            print("No valid pages were processed.")
            return False

        if use_vision:
            vision_inputs = [str(item[1]) for item in raw_items]
            cropped = crop_via_vision(vision_inputs, swift_script, min_confidence, False, tmp_dir)
            work_items = []
            for (label, _), (crop_path, meta) in zip(raw_items, cropped):
                bgr = load_image_bgr(str(crop_path))
                conf = meta.get("confidence")
                suffix = f" ({meta.get('method', 'vision')}, conf={conf:.2f})" if conf is not None else ""
                work_items.append((f"{label}{suffix}", bgr))
        else:
            work_items = [
                (label, detect_and_crop(img) if auto_crop else img)
                for label, img in raw_items
            ]

        for page_idx, (label, img) in enumerate(work_items, start=1):
            print(f"[Page {page_idx}/{len(work_items)}] Enhancing {label}...")
            img = downscale_to_dpi(img, page_size, dpi, margin)
            if auto_crop and multipoint_points > 0:
                orig_hw = img.shape[:2]
                img = multipoint_border_mask_clean(img, points_per_edge=multipoint_points)
                img = enhance_image_bgr(img, mode=mode)
                if flatten_surface:
                    img = flatten_document_surface(img)
                if balance_symmetry:
                    img = balance_page_symmetry(img, target_shape=orig_hw)
            else:
                img = enhance_image_bgr(img, mode=mode)

            rgb = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
            pil_page = Image.fromarray(rgb)
            if debug_dir:
                stem = re.sub(r"[^A-Za-z0-9._-]+", "_", label.split(" (")[0]).strip("_") or f"page_{page_idx}"
                pil_page.save(debug_dir / f"{page_idx:02d}_{stem}_{mode}.jpg", format="JPEG", quality=86, optimize=True)
            pages.append(pil_page)

    if not pages:
        print("No valid pages were processed.")
        return False

    out_dir = os.path.dirname(os.path.abspath(output_pdf_path))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    first, rest = pages[0], pages[1:]
    first.save(
        output_pdf_path,
        save_all=True,
        append_images=rest,
        quality=86,
        optimize=True,
        dpi=(dpi, dpi),
    )
    size_bytes = os.path.getsize(output_pdf_path)
    print(f"\n[SUCCESS] Saved HD Scanned PDF: {output_pdf_path}")
    print(f"Total pages: {len(pages)}, Size: {size_bytes:,} bytes ({size_bytes / (1024 * 1024):.2f} MiB)")
    return True


def _build_arg_parser() -> argparse.ArgumentParser:
    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    default_input = os.path.join(base_dir, "input")
    default_output = os.path.join(base_dir, "output", "Scanned_Document_HD.pdf")

    parser = argparse.ArgumentParser(
        description="Local HD Document Scanner (zero watermark, Vision/OpenCV crop, 128-pt clean, surface flatten, Magic Color / Clean / B&W / Grayscale)."
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
        help=f"Output PDF file path (default: {default_output})",
    )
    parser.add_argument(
        "--output",
        dest="output_flag",
        default=None,
        help="Output PDF file path (overrides positional output_pdf)",
    )
    parser.add_argument(
        "--mode",
        choices=["magic_color", "clean", "bw", "grayscale", "original"],
        default="magic_color",
        help="Enhancement filter mode (default: magic_color)",
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
        help="Target page sizing box before DPI downscaling (default: a4)",
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
        help="Page margin in points for downscaling calculation (default: 20.0)",
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
    parser.add_argument(
        "--no-symmetry",
        action="store_true",
        help="Disable symmetric margin centering",
    )
    parser.add_argument(
        "--save-debug",
        default=None,
        help="Directory to save per-page processed JPEGs for visual inspection",
    )
    return parser


if __name__ == "__main__":
    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    default_output = os.path.join(base_dir, "output", "Scanned_Document_HD.pdf")
    args = _build_arg_parser().parse_args()
    out_path = args.output_flag or args.output_pdf or default_output
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
        balance_symmetry=not args.no_symmetry,
        save_debug=args.save_debug,
        min_confidence=args.min_confidence,
    )
    sys.exit(0 if success else 1)
