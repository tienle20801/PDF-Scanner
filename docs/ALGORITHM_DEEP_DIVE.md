# Computer Vision Document Enhancement & Scanning Algorithm: Technical Specification & Implementation Reference

This document describes the computer vision pipeline actually implemented in [scripts/batch_scanner.py](../scripts/batch_scanner.py) (Hybrid OpenCV + Vision engine) and [scripts/doc_scanner.swift](../scripts/doc_scanner.swift) (Pure Swift Vision helper), including the **Auto Color** mode (formerly labeled *Magic Color*; `--mode magic_color` remains supported as a CLI alias).

> **Status Legend:** Sections 1–4 reflect the **currently implemented code** in this repository (`scripts/batch_scanner.py` and `scripts/doc_scanner.swift`). Section 5 separates **known limitations** from **proposed future enhancements not yet implemented**.

---

## 1. End-to-End Pipeline Architecture

Mobile captures exhibit perspective skew, non-uniform lighting, cast shadows, desk clutter along borders, curved pages, and optical blur. The Hybrid pipeline transforms raw camera frames $I_{raw} \in \mathbb{R}^{H \times W \times 3}$ (BGR) through the following implemented stages:

```
                              IMPLEMENTED HYBRID PIPELINE
                              
   [ Input: Image (JPG/PNG/WebP/BMP/TIFF/HEIC) or Extracted PDF Page Images ]
                                   │
                                   ▼
 ┌─────────────────────────────────────────────────────────────────────────┐
 │ Stage 1: Document Boundary Detection & Perspective Rectification        │
 │ - Primary (macOS): VNDetectDocumentSegmentationRequest / Rectangles     │
 │ - OpenCV Fallback (`detect_and_crop_with_info`):                        │
 │   • Downscale max dim = 1000 px, HSV score = clip(V - 1.5·S, 0, 255)    │
 │   • Primary: Otsu mask -> Close(15×15), Open(9×9) -> quad [25%..96%]    │
 │   • Fallback: Canny(20,65) + inside-outside paper score gap >= 5.0      │
 │   • Centroid polar corner ordering; solidity >= 0.72; relative min size │
 └─────────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
 ┌─────────────────────────────────────────────────────────────────────────┐
 │ Stage 1.5: Target DPI Downscaling & 128-Point Border Cleaning           │
 │ - `downscale_to_dpi`: shrink-only INTER_AREA resize to A4/Letter @ DPI  │
 │ - `multipoint_border_mask_clean`: 32 pts/edge (128 pts) LAB/HSV mask,   │
 │   local interior paper propagation (`dilate 31×31 ×2 + median 21`),     │
 │   and `_clean_residual_border_bleed` along outer 1.5% margins           │
 └─────────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
 ┌─────────────────────────────────────────────────────────────────────────┐
 │ Stage 2 & 3: White Balance, Background Division & Stroke Compensation   │
 │ - `_estimate_global_wb_gain`: inner low-chroma paper gain [0.70, 1.45]  │
 │ - `_compute_background_ratio`: <=720 px scaled dilate+median + tapering │
 │ - `compensate_strokes_and_lines`: adaptive threshold (p85 - 45) ->      │
 │   fill 1-4px breaks via eroded local ink + `_LINE_BOOST_LUT` (*0.85)    │
 └─────────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
 ┌─────────────────────────────────────────────────────────────────────────┐
 │ Stage 4 & 5: Power-Ramp LUT & Laplacian Sharpening (`auto_color`)       │
 │ - `_MAGIC_LUT`:                                                         │
 │   • i < 215:        int(((i / 215.0) ** 1.55) * 205)                    │
 │   • 215 <= i < 235: int(205 + (i - 215) * 2.5)                          │
 │   • i >= 235:       255                                                 │
 │ - `_SHARPEN_KERNEL`: [[0, -0.25, 0], [-0.25, 2.0, -0.25], [0, -0.25, 0]]│
 └─────────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
 ┌─────────────────────────────────────────────────────────────────────────┐
 │ Stage 6 & 7: Deskew + Gated Surface Flattening & Optional Symmetry      │
 │ - `flatten_document_surface`: median-slope deskew (0.3°..8.0°) ->       │
 │   scale-invariant Ridge 2D poly (clamp 1.8%) -> RMS quality gate (>=15%)│
 │ - `balance_page_symmetry`: off by default (`--symmetry` enables);       │
 │   ignores specks < 10 px² via `connectedComponentsWithStats`            │
 └─────────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
     [ Per-Page Output (`RGB`/`L` JPEG or `1`-bit `bw` PNG) + JSON Manifest + PDF ]
```

---

## 2. Implemented Mathematical & Algorithmic Details

### 2.1 Stage 1: Document Detection & Perspective Rectification

#### 2.1.1 Primary Engine on macOS (`doc_scanner.swift`)
When `--crop-engine` is `auto` (on macOS) or `vision`, `crop_via_vision` invokes `scripts/doc_scanner.swift` with `--quad-only` and `--manifest`:
1. Runs Apple Vision `VNDetectDocumentSegmentationRequest` (macOS 12+) inside per-page `autoreleasepool` blocks and accepts the top observation if `confidence >= min_confidence` (default `0.45`).
2. Falls back to `VNDetectRectanglesRequest` (`minimumAspectRatio = 0.25`, `maximumAspectRatio = 1.0`, `quadratureTolerance = 45.0`, `minimumSize = 0.2`).
3. Emits the 4 detected corner coordinates (`quad` in top-left pixel coordinates `[tl, tr, br, bl]`) directly in `manifest.json` without an intermediate Vision JPEG encode; Python then warps the original full-resolution image via `perspective_warp(..., preordered=True)`. In standalone `Pure Swift Vision` mode (without `--quad-only`), `doc_scanner.swift` applies `CIPerspectiveCorrection` and CoreImage enhancement directly.

#### 2.1.2 OpenCV Fallback (`detect_and_crop_with_info` / `detect_and_crop`)
When Vision is unavailable or `--crop-engine opencv` is selected (`detect_and_crop` delegates to `detect_and_crop_with_info` and returns structured `method`, `confidence`, `fallback`, and `quad` metadata):
1. Downscales input so $\max(H, W) = 1000\text{ px}$ (`scale = 1000.0 / max(h, w, 1)`).
2. Converts unpadded `small` to HSV and computes a saturation-aware paper brightness score:
   $$\text{score}(x, y) = \operatorname{clip}\left(V(x, y) - 1.5 \cdot S(x, y), \; 0, \; 255\right)$$
3. **Primary Branch (`hsv_otsu`):** Applies `GaussianBlur(..., (9, 9), 0, BORDER_REPLICATE)` and **Otsu binarization** *before* adding the `12 px` zero padding (`mask` close `15×15`, open `9×9`), preventing the artificial padding border from skewing Otsu on bright off-white desks.
4. **Edge Fallback (`canny_edge`):** If `hsv_otsu` finds no valid quad within `[0.25, 0.96]` frame area (e.g., low-contrast white sheet over off-white desk with dark page text), runs `GaussianBlur(5×5)` + `Canny(20, 65)` + `dilate(3×3)` + `close(9×9)` and verifies that the candidate quad has brighter/cleaner interior than surrounding exterior (`p75(score_inside) - median(score_outside) >= 5.0`), rejecting interior table borders on full-bleed pages.
5. Simplifies contours via `approxPolyDP` (or convex hull approximation); falls back to `minAreaRect` only when rectangular solidity `area / box_area >= 0.72` and `area_ratio <= 0.96`.
6. Orders corners via centroid polar angle sorting in `_order_points` ($\operatorname{atan2}(\Delta y, \Delta x)$ clockwise from the vertex closest to top-left ray $-3\pi/4$, eliminating $x+y$ / $y-x$ ties at $45^\circ$) and warps if output dimensions satisfy `max_w >= max(64, int(0.25 * w))` and `max_h >= max(64, int(0.25 * h))`. Otherwise returns `orig` with `method="fallback_original"`.

### 2.2 Stage 1.5: DPI Downscaling & 128-Point Border Cleaning

- **`downscale_to_dpi`:** For `page_size` in `{"a4", "letter"}`, computes available printable pixels at target `dpi` inside `margin` points (`595.28×841.89 pt` for A4, `612×792 pt` for Letter, orientation-swapped when $w > h$). Downscales using `cv2.INTER_AREA` only when `scale < 0.99`; never upscales. For `page_size == "fit"`, keeps native cropped pixel dimensions.
- **`multipoint_border_mask_clean`:** Estimates paper interior statistics once (`_estimate_paper_stats` over the inner 8%–92% frame in LAB/HSV), identifies non-paper border pixels via LAB chroma deviation (`hypot(a - a_paper, b - b_paper)`), HSV saturation, and darkness thresholds (`_compute_bg_and_paper`). Samples 32 control points per edge (128 total) using 85th-percentile bin offsets smoothed by a 3-tap 1D median + `GaussianBlur((5, 1), 1.2)`. When `outside_mask` is non-empty, propagates clean interior paper intensities at downscaled `<= 500 px` resolution (`dilate` + `medianBlur` with proportionally scaled kernels) and upsamples `INTER_LINEAR`, then cleans residual bleed along the outer 1.5% strips (`_clean_residual_border_bleed` converts only those border strips to LAB/HSV).

### 2.3 Stage 2 & 3: Global White Balance, Resolution-Normalized Background Division & Stroke Repair

Under Land's Retinex / Lambertian model $I(x, y) = R(x, y) \cdot L(x, y)$:

1. **Global Paper White-Balance (`_estimate_global_wb_gain`, `_apply_wb_gain`):**
   Samples the inner 8%–92% crop (downscaled `<= 400 px`), filters pixels in the top luminance quartile (`>= p75` and `>= 70`) whose channel spread $c_{max} - c_{min}$ stays within the lowest-chroma 60% (`+ 8`, capped at `115`), takes `p75` per channel as $P_{BGR}$, and applies bounded per-channel gains via a 3-channel `cv2.LUT`:
   $$g_c = \operatorname{clip}\left(\frac{Y(P_{BGR})}{\max(P_c, 1.0)}, \; 0.70, \; 1.45\right)$$
   Warm/cool paper casts normalize to neutral gray before background division while colored ink/stamp hues stay intact.

2. **Resolution-Normalized Background Estimation & Dark-Block Tapering (`_compute_background_ratio`):**
   Downsamples grayscale $I_{gray}$ to `<= 720 px` (`INTER_AREA`), scales kernels proportionally (`dilate_k = 0.015 * min_ws | 1`, `median_k = 0.042 * min_ws | 1`), computes $I_{bg}$ at working resolution, and tapers the amplification ratio smoothly back toward `1.0` when $I_{bg}$ falls below $0.50 \cdot \text{paper\_luma}$ (reaching `1.0` at $0.20 \cdot \text{paper\_luma}$, capped at `2.2`):
   $$\alpha_{taper} = \operatorname{clip}\left(\frac{I_{bg} - 0.20 L_p}{0.30 L_p}, 0, 1\right), \qquad \alpha(x, y) = 1.0 + \alpha_{taper}\left(\operatorname{clip}\left(\frac{250.0}{I_{bg}}, 0.5, 2.2\right) - 1.0\right)$$
   The smooth ratio field is bilinearly upsampled to full resolution, keeping large dark blocks (e.g., 30×30 mm filled areas) black rather than blowing them white.

3. **Stroke & Ruling Line Compensation (`compensate_strokes_and_lines`):**
   Computes an adaptive ink threshold `ink_thresh = clip(p85(norm_gray) - 45, 140, 220)` and resolution-scaled morphological kernels (`open_len ~ 35 * min_dim / 1650`, `close_len ~ 7..11`). Detected `1–4 px` horizontal/vertical gaps `(close > 0) & (line_mask == 0)` are filled directly from locally eroded neighbor stroke intensity (`cv2.erode` with `(close_len, 3)` / `(3, close_len)`), and masked grid strokes are uniformly boosted via `_LINE_BOOST_LUT` (`* 0.85`).

### 2.4 Stage 4 & 5: Power-Ramp LUT (`_MAGIC_LUT`) & Spatial Sharpening

1. **8-Bit Tone Transfer Table (`_MAGIC_LUT`):**
   Applied via `cv2.LUT(compensated, _MAGIC_LUT)`:
   $$T(i) = \begin{cases} \left\lfloor \left(\frac{i}{215.0}\right)^{1.55} \cdot 205 \right\rfloor, & 0 \le i < 215 \\ \left\lfloor 205 + (i - 215) \cdot 2.5 \right\rfloor, & 215 \le i < 235 \\ 255, & 235 \le i \le 255 \end{cases}$$
   The sub-linear power exponent `1.55` suppresses mid/dark ink relative to `205`, the steep `2.5` ramp lifts near-white paper `[215, 234]` into `[205, 252]`, and values `>= 235` clip to `255`.

2. **Laplacian Unsharp Convolution (`_SHARPEN_KERNEL`):**
   Applied via `cv2.filter2D(lut_applied, -1, _SHARPEN_KERNEL)` with fixed gain $\lambda = 0.25$:
   $$K_{sharp} = \begin{bmatrix} 0 & -0.25 & 0 \\ -0.25 & 2.0 & -0.25 \\ 0 & -0.25 & 0 \end{bmatrix}, \qquad \sum_{i,j} K_{sharp}(i,j) = 1.0$$

### 2.5 Other Implemented Enhancement Modes (`enhance_image_bgr`)

- **`clean`:** Applies `_apply_wb_gain` before LAB `L` Gaussian division ($\sigma_x = \max(15, \min(H, W) // 30)$), `cv2.divide(l_ch, bg, scale=255)`, then `convertScaleAbs(alpha=1.1, beta=5)`.
- **`bw`:** Gaussian background division on grayscale followed by `cv2.adaptiveThreshold(..., ADAPTIVE_THRESH_GAUSSIAN_C, THRESH_BINARY, blockSize=25, C=11)`. Saved via `_bgr_to_pil` as a 1-bit `"1"` PNG and embedded in Python CLI PDFs as 1-bit `/DeviceGray` `/FlateDecode`.
- **`grayscale`:** `_compute_background_ratio(gray)` + `_MAGIC_LUT`, saved via `_bgr_to_pil` as 1-channel `"L"` JPEG and embedded as 8-bit `/DeviceGray` `/DCTDecode`.
- **`original`:** Identity pass (returns cropped/flattened image untouched).

### 2.6 Stage 6 & 7: Deskew, Quality-Gated 2D Surface Flattening & Symmetry Centering

- **`flatten_document_surface`:**
  1. Removes orthogonal strict borders first before gentle closing (`(3, max(16, w // 42))`) so curved and tilted lines remain intact without horizontal slicing (`_detect_surface_lines`).
  2. Estimates global skew from median linear slopes of long lines; if consistent (`MAD <= 1.2°`) and `0.3° <= |skew| <= 8.0°`, deskews via `cv2.warpAffine(..., INTER_CUBIC)` filled with `paper_bgr` and re-extracts line coordinates.
  3. Fits a scale-invariant Ridge 2D polynomial (`lam = 0.015` relative diagonal penalty, 3-pass MAD outlier rejection, displacement clamped to `max_shift_ratio = 0.018 * min(h, w)`).
  4. Enforces **sparse & straightness quality gates** before `cv2.remap`: skips when horizontal lines cover `< 15%` page height without vertical support, when `rms_before < 1.2 px`, or when predicted `rms_after >= 0.85 * rms_before` (or improvement `< 0.35 px`).
- **`balance_page_symmetry`:** Disabled by default (`balance_symmetry=False`, UI `balanceSymmetry = false`) to preserve original layout. When explicitly enabled (`--symmetry`), filters tiny specks (`area >= 10 px²` via `connectedComponentsWithStats`), crops the content bounding box, and centers onto a `paper_bgr` canvas.

---

## 3. Implemented Parameters Reference (`scripts/batch_scanner.py`)

| Function / Constant | Parameter | Current Value in Code | Notes |
|---|---|---|---|
| `detect_and_crop_with_info` | Downscale bound / min warp | `1000 px`, `max(64, 0.25 * w/h)` | Dual `hsv_otsu` + `canny_edge` fallback |
| `detect_and_crop_with_info` | Score & Canny thresholds | `V - 1.5·S`, `Canny(20, 65)` | Canny verified by `score_gap >= 5.0` |
| `detect_and_crop_with_info` | Area & solidity guards | `0.25..0.96` area, `solidity >= 0.72` | Returns `orig` on fallback |
| `multipoint_border_mask_clean` | Control points | `32` per edge (`128` total) | Downscaled `local_bg` (`<= 500 px`) + 1.5% border bleed clean |
| `_estimate_global_wb_gain` | Inner ROI & gain clamp | `8%..92%`, `[0.70, 1.45]` | Filters low-chroma bright pixels (`<= p60 + 8`) |
| `_compute_background_ratio` | Work bound / kernels / cap | `<= 720 px`, `0.015`/`0.042 * min_ws`, `max 2.2` | Tapers below `0.50 * paper_luma` to `1.0` |
| `compensate_strokes_and_lines` | Threshold / kernel / boost | `clip(p85 - 45, 140, 220)`, scaled, `_LINE_BOOST_LUT` (`0.85`) | Fills `1–4 px` breaks from `cv2.erode` ink |
| `_MAGIC_LUT` | Power & ramp | `i < 215` exp `1.55` to `205`; `215..234` slope `2.5`; `>= 235` -> `255` | 256-byte LUT |
| `_SHARPEN_KERNEL` | `λ` | `0.25` | `[[0,-.25,0],[-.25,2,-.25],[0,-.25,0]]` |
| `_fit_ridge_surface` / `flatten` | Rel. Ridge `λ` / clamp / gates | `0.015 * diag`, `0.018 * min(h, w)`, `15%` RMS | Deskews `0.3°..8.0°` before polynomial fit |
| `balance_page_symmetry` | Default / speck filter | `False` default, `area >= 10 px²` | CLI `--symmetry` / `--no-symmetry` |
| JPEG & PDF export | JPEG quality / DPI / workers | `quality=86` (`88` in Swift CLI), `dpi=200`, `workers=1` | `RGB`/`L` via `/DCTDecode`; `bw` 1-bit via `/FlateDecode` |

---

## 4. Measured Benchmarks (Apple Silicon)

All timings below are reproducibly measured using [scripts/benchmark.py](../scripts/benchmark.py) on synthetic 12MP (`4032×3024` RGB) document captures:

- **Machine & OS:** Apple M1 (`arm64`, 8 cores, 8 GB RAM), `macOS 27.2` (`Darwin 27.2.0`)
- **Runtime:** Python `3.10.22`, OpenCV `5.0.0`, NumPy `2.2.6`

### 4.1 Per-Stage Latency (12MP Single Page, Median of 5 Runs)

| Pipeline Stage | Working Resolution | Median Latency (ms) |
|---|---|---:|
| `detect_and_crop` (OpenCV) | `4032×3024` (det. at `1000 px`) | `11.2 ms` |
| `downscale_to_dpi` (`A4 @ 200 DPI`) | `4032×3024` → `~2200×1650` | `15.7 ms` |
| `multipoint_border_mask_clean` (`32` pts/edge) | Scaled `A4 @ 200 DPI` | `67.2 ms` |
| `enhance_image_bgr` (`auto_color`) | Scaled `A4 @ 200 DPI` | `79.7 ms` |
| `flatten_document_surface` (quality-gated) | Scaled `A4 @ 200 DPI` | `85.7 ms` |
| `balance_page_symmetry` | Scaled `A4 @ 200 DPI` | `76.8 ms` |
| **Total 6-Stage Pipeline (`A4 @ 200 DPI`)** | **12MP → A4@200** | **`336.4 ms`** |
| *Reference: `enhance_image_bgr` on unscaled 12MP* | *`4032×3024` (e.g. `--page-size fit`)* | *`377.4 ms`* |

### 4.2 End-to-End Streaming & Parallel Batch Runs (`A4 @ 200 DPI`, OpenCV)

| Batch Workload | Elapsed | Output PDF | Peak RSS |
|---|---:|---:|---:|
| **20-Page 12MP (`--workers 1`, `benchmark.py`)** | `6.13 s` (`0.31 s/page`) | `2.78 MiB` | — |
| **20-Page 12MP Standalone CLI (`workers=1`, `/usr/bin/time -l`)** | `6.49 s` (`0.32 s/page`) | `2.78 MiB` | `433.6 MiB` |
| **20-Page 12MP (`--workers 4`, `benchmark.py`)** | `4.48 s` (`0.22 s/page`) | `2.78 MiB` | — |

---

## 5. Architecture & Remaining Research Directions

### 5.1 Production Architecture Implemented in Phase 4
- **Vector-Preserving PDF Compression ([scripts/pdf_compressor.py](../scripts/pdf_compressor.py), `B5`):** Classifies pages via `/Font` and `/Image` pixel footprint (`< 300k px`); preserves pure text/vector pages and page `MediaBox` dimensions untouched; mutates compressed `/Image` XObjects in place inside `PdfWriter` (avoiding orphaned duplicate streams) and runs binary-search over `(dpi, jpeg_quality)` down to readable floors (`85 DPI, Q=35`) for target size budgets.
- **Self-Contained Packaging & Preflight (`A1`, `A2`):** `macos_app/build_app.sh` precompiles `scripts/doc_scanner.swift` into `Contents/Resources/bin/doc_scanner` (`swiftc -O`) and bundles relocatable `python_runtime` + `.venv` packages cleanly under strict ad-hoc `codesign`; `ScannerBridge` runs startup dependency preflight and maintains a persistent `--worker-stdio` Python process for low-latency live previews.
- **Optional Vision OCR (`Q9`) & Single-Pass Corner-Vector Reading Orientation (`Q10`):** `PDFToolsService.detectReadingOrientationDegrees` builds downscaled `<= 1600 px` `CGImage` inputs directly (removing `tiffRepresentation` and global `NSLock` serialization), runs a single `.accurate` Vision OCR pass with supported `vi-VT` + `en-US` languages, and aggregates `conf^2 × alnumCount`-weighted quadrant votes from each observation's corner vector (`topRight - topLeft`, pixel-scaled with a positive `cross(u, v)` orthogonality check and dominance + margin gates over `0°`), eliminating `.fast` Vietnamese blind spots and `.accurate` internal auto-rotation ambiguity. Already-upright pages (`deg == 0`) populate the `OCRTextLine` cache reused during `compileProcessedImagesToPDF` (invisible CoreText text mode `.invisible`) when OCR is toggled on.
- **Honest Pure Swift Engine (`Q8`):** Adds native CoreImage/DeviceGray `.grayscale` mode to `doc_scanner.swift` and surfaces actual CoreImage mode labels in UI while hiding Hybrid-only pipeline controls.

### 5.2 Research Directions *(Not Scheduled)*
- Lightweight semantic segmentation for zero-contrast borderless surfaces, Thin-Plate Spline (TPS) spine mesh unwarping, Navier-Stokes specular glare inpainting, and severe two-sided bleed-through compensation below `_MAGIC_LUT` threshold `215`.
