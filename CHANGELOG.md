# Changelog

## v1.2.0 — Performance Optimization, Auto-Workers & Vision Warm-Up (2026-11-19)

### Changes & Measured Results
- **Benchmark Methodology Fix ([scripts/benchmark.py](scripts/benchmark.py)):**
  - Reported both `median` and `min` latencies alongside `LoadAvg` in `bench_single_image`.
  - Isolated `bench_batch` via `/usr/bin/time -l` CLI subprocess execution so reported Peak RSS (`434.5 MiB`) reflects true CLI memory rather than inherited single-page 12MP benchmark buffers (`1022.8 MiB` in earlier `RUSAGE_SELF` runs). Added `--workers` string support (`auto` / `N`) and `--in-process` opt-in.
- **Python Imaging Hot-Path Speedups ([scripts/batch_scanner.py](scripts/batch_scanner.py)):**
  - Replaced full-frame LAB/HSV scans in `multipoint_border_mask_clean`, `flatten_document_surface`, and `balance_page_symmetry` with strided `_estimate_paper_scalars`, strip-only `_compute_strip_bg_mask` / `_extract_strip_edge_offsets`, lazy `paper_bgr` evaluation, and a `900 px` low-res flat/sparse pre-check in `flatten_document_surface`.
  - Replaced `cv2.split`/`np.clip`/`cv2.merge` float32 loops and NumPy boolean masks with `_scale_by_ratio_u8` (`cv2.multiply`), strided WB/p85 estimation, `cv2.threshold`, and `cv2.copyTo`.
  - **PSNR Parity vs Unoptimized Baseline:** `multipoint_clean` **`361.20 dB`** (`exact=True`), `multipoint_dirty` **`361.20 dB`** (`exact=True`), `flatten_curved` **`361.20 dB`** (`exact=True`), `enhance_auto` **`50.73 dB`**, `enhance_gray` **`60.30 dB`**, `symmetry` **`52.72 dB`**.
  - **Measured Latency (`Apple Silicon arm64`, `Darwin 27.2.0`, 5 runs):**
    - `Total 6-stage (A4@200)`: **`621.2 / 558.2 ms` → `264.1 / 215.7 ms`** (`med / min`; `multipoint` `119.6 → 25.0 ms`, `enhance` `167.3 → 53.8 ms`, `flatten` `126.9 → 68.1 ms`, `symmetry` `133.1 → 42.3 ms`).
    - `enhance_image_bgr (full 12MP)`: **`1033.1 / 774.4 ms` → `185.2 / 149.7 ms`**.
    - `10-Page 12MP Batch (workers=1)`: **`7.54 s` → `2.65 s` (`0.27 s/page`)**, Isolated CLI Peak RSS **`434.5 MiB`**.
- **Adaptive Multiprocessing & Vision Warm-Up ([scripts/batch_scanner.py](scripts/batch_scanner.py), [ScannerBridge.swift](macos_app/Sources/ScannerBridge.swift), [PDFToolsService.swift](macos_app/Sources/PDFToolsService.swift), [AppViewModel.swift](macos_app/Sources/AppViewModel.swift)):**
  - Added `resolve_worker_count` and `--workers auto` (`1` worker for `<= 8` pages or `< 1.5 MP` small batches to avoid spawn overhead; up to `4` workers otherwise), passed for `.hybridOpenCV` batches only (`3.70 s` for 10 12MP pages at `--workers auto`, Isolated CLI Peak RSS `424.3 MiB`).
  - Added idempotent non-blocking `PDFToolsService.warmUpVisionOCR()` invoked at `AppViewModel.init()` (skips if `PDF_SCANNER_DISABLE_WARMUP=1`).
- **Verification:** `./tests/run_all.sh` (**23/23 Python tests OK in `33.254s`** + Swift integration/regression suite **PASS**), `swiftc -O -strict-concurrency=complete` (**0 errors, 0 warnings**), and `./macos_app/build_app.sh` (`PDF Scanner.app`, `206M`, `codesign --verify --deep --strict` valid).

## v1.1.1 — Concurrency, Bridge I/O, Unicode NFC & Compression Hardening (2026-11-18)

### Changes & Measured Results
- **Luồng 1 (`8d04c3b` + Sprint 3 UI Polish — Swift / SwiftUI / Vision / Bridge):**
  - **Concurrency & Crash Fixes (`P0-1`, `P1-7..P1-12`):** Replaced `queue.indices` iteration in `AppViewModel.executeBatchScan` with UUID snapshots and `queueEpoch`/`taskEpoch` guards while blocking destructive queue edits during `isBusy`; tracked all 5 PDF tools (`Pair / Split / MergeQueue / MergeExternal / Rotate`) in `activeWorkTask` via `runTrackedPDFToolTask`; fixed `addURLs`, `clearQueue`, `resetCurrentTaskToNewBatch`, and `rotateItem` race conditions; distinguished intentional `SIGTERM` cancellation (`CancellationError`) from failures in `ScannerBridge.runProcessStreaming`; added folder batch overwrite confirmation (`confirmDirectoryBatchWrite`) for Pair `.separateFiles` / Split `.allPages` while eliminating double overwrite prompts with `NSSavePanel`.
  - **Bridge Deadlock & Pipe I/O (`P0-2`, `P1-11`, `P1-13..P1-15`, `P1-18`):** Fixed `PersistentPythonWorker.runJob` `NSLock` deadlock via `defer` unlock before `terminate()`, checked cancellation before launching jobs inside `serialQueue`, synchronized `persistentWorker` creation/teardown under `workerLock`, buffered incomplete trailing multi-byte UTF-8 chunks across reads in `LinePipeAccumulator`, drained `runPreflightCheck` stdout/stderr concurrently via `DispatchGroup` before `waitUntilExit()`, searched `python3.*` dynamically, isolated `previewCacheDirectory` per PID, and rejected `processedCacheKey == nil` previews.
  - **Core PDF, Unicode NFC, Security & Vision (`P1-3..P1-5`, `P1-16`, `P1-17`):** Rejected locked PDFs (`PDFToolError.lockedPDF`), composited transparent RGBA PNGs over white in `stageItemToImageFile` and `doc_scanner.swift`, prevented `formatPairFileName` path traversal (`/` & `..`, containment check) and Vietnamese `\p{L}` `x`-prefix corruption, resolved symlinks consistently (`resolvingSymlinksInPath()` + target mtime), added `pageSize`/`margin` to `imageProcessingSignature`, normalized canonical paths to Unicode NFC (`precomposedStringWithCanonicalMapping`), and wrote compiled PDFs atomically via temp file replacement.
  - **Sprint 3 UI Polish:** Removed unused `ToggleSingleComparisonView`, `showProcessedInToggle`, and `.toggleSingle`/`.sideBySide` enum cases; added Finder **Open With** / Dock drop handling (`application(_:open:)` + `ExternalOpenURLRouter` + `.handlesExternalEvents(matching: [])`); fixed Console auto-scroll past the 500-line cap; respected edited `ScanTaskPanel` `outputPDFPath`; and cleared stale `rotateSourceURL` when dropping multiple items onto `Merge/Rotate`.
- **Luồng 2 (`027bf11` — Python Engine, `pdf_compressor.py` & `scan_to_pdf.py`):**
  - **Unicode NFC & Atomic File I/O (`P1-3`, `P1-6`):** Added `_canonical_path` (`unicodedata.normalize("NFC", os.path.realpath(...))`) across task discovery, `crop_via_vision`, `--worker-stdio`, and manifest matching; replaced predictable `.tmp` filenames with `NamedTemporaryFile` + `os.replace` (`_atomic_write_bytes`).
  - **16-Bit & Alpha Decoding (`P1-19`, P2):** Scaled 16-bit grayscale PNGs (`I;16`/`I`) cleanly (`>> 8`) instead of clamping `>= 256` to `255`, and composited `"PA"` and `*+tRNS` transparency images onto white `(255, 255, 255)`.
  - **Vector-Preserving Compression (`P1-20a..d`, P2):** Computed post-crop dimensions after `detect_and_crop`, incorporated `/Rotate` + `CTM` + `/UserUnit` into `eff_dpi`, staged immutable source copies when `source_pdf == output_pdf`, clamped candidate DPIs `<= base_dpi` with non-monotonic candidate evaluation, preserved 1-bit `/FlateDecode` `/DeviceGray` streams for `mode="bw"`, summed multi-image pixel footprints on font pages, added a bloat guard, and emitted structured `--json-report` errors cleanly.
  - **`--worker-stdio` & CLI Edge Cases:** Prevented `index=0` filename collisions in shared `emit_dir`, guarded `null` inputs, rejected missing/`.pdf` inputs prior to Vision cropping, clamped `downscale_to_dpi >= 72`, and unified `scan_to_pdf.py` `bw` output to 1-bit `"1"`.
- **Verification & Measured Data (Post-Sprint-3 Build):**
  - **`./tests/run_all.sh`:** **22/22 Python `unittest` cases OK (`39.577s`)** + **`[PASS] All Swift Phase 1 unit & integration tests passed.`** (including all P0/P1/P2 regressions across Python and Swift).
  - **`-strict-concurrency=complete` release compile:** **0 errors, 0 warnings** (`macos_app/Sources/**/*.swift`, `3.1M` `PDFScanner` binary).
  - **`scripts/benchmark.py --pages 10 --runs 3` (`arm64`, `Darwin 27.2.0`):** Single 12MP 6-stage median (`A4@200`) **`533.6 ms`** (full-res `enhance_image_bgr` **`576.0 ms`**); 10-page batch **`5.50 s`** (`0.55 s/page`), **`1.39 MiB`**, Peak RSS **`1022.8 MiB`**.
  - **Standalone Packaging:** `PDF Scanner.app` (`v1.1.1`, `206M`, `codesign --verify --deep --strict` PASS) and `PDF-Scanner.dmg` (`99M` / `103,316,092 B`, `hdiutil verify` VALID).

## v1.1.0 (Phase 4) — Standalone Packaging, Vector-Preserving Compression, OCR & Orientation Engine (2026-11-17)

### Changes & Measured Results
- **B5 (Vector-Preserving PDF Compression & Target-Size Binary Search):**
  - Added [scripts/pdf_compressor.py](scripts/pdf_compressor.py) and updated `ScannerBridge.compressPDF`, `AppViewModel`, and `CompressTaskPanel`: preserves selectable vector/text pages and original page `MediaBox` dimensions untouched; re-encodes embedded raster `/Image` XObjects in place inside `PdfWriter` (preventing orphaned stream bloat) with `LANCZOS` DPI downsampling and a binary-search preset ladder when `--target-mb` is set; defaults compression mode to `Original` (`auto_crop=False`).
  - **Measured verification on mixed CoreGraphics vector + `300 DPI` receipt (`288×432 pt`) scan PDF:** Compressed from `1,733,186 B` → **`95,927 B`** (`-94.5%`, meeting `<= 0.15 MiB` budget on pass 1), preserved selectable vector text verbatim (`"Vector Selectable Text B5 98765"`), preserved both `595.28×841.89` and `288×432` `MediaBox` sizes, and reported clear `target_achieved=False` notice on impossible `0.0001 MiB` vector budget.
- **A1 (Standalone Bundling, Precompiled Vision Helper & Startup Preflight):**
  - Updated [macos_app/build_app.sh](macos_app/build_app.sh) to precompile [scripts/doc_scanner.swift](scripts/doc_scanner.swift) (`swiftc -O`) to `Contents/Resources/bin/doc_scanner` and bundle a relocatable `python_runtime` + `.venv` site-packages (`206 MiB` total `PDF Scanner.app`, passing `codesign --verify --deep --strict`).
  - Updated [ScannerBridge.swift](macos_app/Sources/ScannerBridge.swift) (`discoverPython`, `discoverPrecompiledDocScanner`, `runPreflightCheck`) and [ContentView.swift](macos_app/Sources/ContentView.swift) with an actionable startup preflight warning banner (`Pure Swift Vision` fallback button if Python dependencies are absent) and verified relocated execution under `/tmp` with minimal `PATH=/usr/bin:/bin`.
- **A2 (Persistent Python Preview Worker `--worker-stdio`):**
  - Added `--worker-stdio` JSON-lines loop in [scripts/batch_scanner.py](scripts/batch_scanner.py) (`run_worker_stdio`) and `PersistentPythonWorker` in [ScannerBridge.swift](macos_app/Sources/ScannerBridge.swift) so consecutive single-page previews reuse a warm OpenCV/NumPy/Pillow interpreter without respawn overhead.
- **Q9 & Q10 (Optional Invisible OCR Layer & Single-Pass Corner-Vector Reading Orientation):**
  - Replaced `tiffRepresentation` and global `orientationLock` serialization in [PDFToolsService.swift](macos_app/Sources/PDFToolsService.swift) with direct downscaled `CGImage` loading (`<= 1600 px`), single-pass `.accurate` Vision OCR (`vi-VT` + `en-US`) voting over unrotated `topRight - topLeft` observation corner vectors (`conf^2 × alnumCount`, pixel-scaled `cross(u, v)` orthogonality check, `>= 55%` dominance & `> 1.15×` upright margin gates), centralized constants in [AppConstants.swift](macos_app/Sources/AppConstants.swift), and `OCRTextLine` cache reuse when `deg == 0`.
  - **Measured reading-orientation accuracy:** `100%` consistency across `220` rotated checks (`55` real scan pages × `0°/90°/180°/270°` including `matsau.pdf`, `matsau_HD.pdf`, `matsau_BW.pdf`, `ngày 1.11.pdf`, `ngày 2.11.pdf`), `64/64` logbook pages (`0` false flips), and synthetic single-line/skewed Vietnamese & English `4`-rotation suites.
  - Added `ScanSettings.enableOCR` (`false` default for speed) rendering searchable/selectable CoreText `kCGTextInvisible` text layers in `compileProcessedImagesToPDF`, verified via `PDFDocument.page(at: 0).string` extraction in Swift integration tests.
- **Q8 (Pure Swift Vision Mode Parity & Honest UI):**
  - Added native CoreImage/DeviceGray `grayscale` mode in [scripts/doc_scanner.swift](scripts/doc_scanner.swift) (verified `PIL.Image.mode == "L"`), updated `EnhanceMode.pureSwiftEffectiveTitle`, and hid Hybrid-only controls (`Crop Engine`, `128-pt`, `Flatten`, `Symmetry`) when `Pure Swift Vision` is active.
- **P2 Cleanup (`A4`, `A6`, `A7`, `A8`, `R2–R4`):**
  - Split `ContentView.swift` (`3169` lines) into [AppConstants.swift](macos_app/Sources/AppConstants.swift), [AppViewModel.swift](macos_app/Sources/AppViewModel.swift), [Views/TaskRailView.swift](macos_app/Sources/Views/TaskRailView.swift), [Views/PageStripView.swift](macos_app/Sources/Views/PageStripView.swift), [Views/CenterCanvasView.swift](macos_app/Sources/Views/CenterCanvasView.swift), [Views/ScanTaskPanel.swift](macos_app/Sources/Views/ScanTaskPanel.swift), [Views/PDFToolsTaskPanels.swift](macos_app/Sources/Views/PDFToolsTaskPanels.swift), [Views/PDFDialogHelpers.swift](macos_app/Sources/Views/PDFDialogHelpers.swift), and slim [ContentView.swift](macos_app/Sources/ContentView.swift).
  - Wrapped async subprocess execution and batch tasks in `withTaskCancellationHandler` (`A6`), added explicit vector-page skip warnings in `_iter_pdf_pages_bgr` (`A7`), updated [README.md](README.md) (`R2–R4` requirements, troubleshooting, known limits, dependency licenses) and [docs/ALGORITHM_DEEP_DIVE.md](docs/ALGORITHM_DEEP_DIVE.md).

## Phase 3 — Image Quality, Crop Fallback & Quality Gates (2026-11-17)

### Changes & Measured Results
- **Q1 (Paper White-Balance Normalization):**
  - Added `_estimate_global_wb_gain` and `_apply_wb_gain` (single 3-channel uint8 LUT clamped `[0.70, 1.45]`, filtering inner 8%–92% top-luma pixels by lowest 60% chroma spread `+ 8` so colored stamps do not skew white balance) inside `enhance_image_bgr` (`auto_color` and `clean`).
  - **Measured before/after on synthetic tinted pages (`800×600`, yellow `(190,230,248)`, blue `(248,232,195)`, pink `(215,200,248)`):** Paper neutral mean **`(255, 255, 255)`** (`max channel delta = 0.00`), red/blue stamp hue drift **`<= 10°`** (`2°` red, `4°–10°` blue on OpenCV `[0..180)` circle).
- **Q2 (Downsampled Background Field & Dark-Block Tapering):**
  - Updated `_compute_background_ratio` to downsample `gray` to `<= 720 px`, scale `dilate` (`0.015 * min_ws`) and `medianBlur` (`0.042 * min_ws`) kernels proportionally, and taper `ratio` toward `1.0` smoothly below `0.50 * paper_luma` (max `2.2`).
  - **Measured preservation:** `~30×30 mm` (`100×100 px`) black block `(15, 15, 15)` stayed dark (`mean = 2.0–2.3`) instead of blowing out white, and shaded table header (`130`) kept ink contrast (`header_bg - header_ink > 60`).
- **Q3 (`balanceSymmetry` Default Off & Speck Filtering):**
  - Changed default `balance_symmetry` / `balanceSymmetry` to `False` across [macos_app/Sources/Models.swift](macos_app/Sources/Models.swift), [macos_app/Sources/ScannerBridge.swift](macos_app/Sources/ScannerBridge.swift), [macos_app/Sources/ContentView.swift](macos_app/Sources/ContentView.swift), [scan_to_pdf.py](scan_to_pdf.py), and [scripts/batch_scanner.py](scripts/batch_scanner.py) (`--symmetry` opt-in, `--no-symmetry` preserved).
  - Updated `balance_page_symmetry` to ignore isolated dust specks (`area < 10 px²` via `connectedComponentsWithStats`) before computing the content bounding box.
- **Q4 (Explicit Deskew, Quality Gate & Curl Extraction Fix):**
  - Replaced destructive `(1, 45)` flat opening in `_detect_surface_lines` with orthogonal-border subtraction + gentle `(3, max(16, w // 42))` closing + stroke-thickness filtering (`_extract_ruling_lines`), switched `_fit_ridge_surface` from fixed `lam=50.0` (which severely underfit quadratic/cubic curl at typical sample sizes) to scale-invariant relative Ridge regularization (`0.015 * diag(P^T P)`), lowered clamp `max_shift_ratio` from `0.03` to `0.018`, added median-slope global deskew (`0.3°..8.0°`), sparse vertical coverage check (`>= 15%` page height), and `rms_after < 0.85 * rms_before` quality gate.
  - **Measured metrics:** Flat & top-title sparse pages skipped cleanly (`0 px` distortion); curved + `2.0°` skewed table (`14 px` curl) deskewed by `2.01°` and flattened from `rms = 4.46 px -> 0.40 px` (`-91%`).
- **Q5 (Stroke & Broken Line Repair):**
  - Replaced hardcoded `< 195` and `* 0.82` scaling in `compensate_strokes_and_lines` with adaptive `ink_thresh = clip(p85 - 45, 140, 220)`, resolution-scaled kernels, real neighboring ink gap fill via `cv2.erode` on `(close > 0) & (line_mask == 0)`, and `_LINE_BOOST_LUT` (`* 0.85`).
  - **Measured gap intensity:** `3–4 px` breaks in dark ruling borders improved from `205` (before) to **`38.0`** (after `_LINE_BOOST_LUT`, matching surrounding stroke darkness on both `242` and `205` paper levels).
- **Q6 (Upgrade `detect_and_crop` & Centroid Polar Ordering):**
  - Rewrote `_order_points` using centroid `atan2` clockwise sorting starting closest to top-left ray (fixing `x+y` / `y-x` ties on $45^\circ$-rotated sheets).
  - Added `detect_and_crop_with_info` returning structured `method`, `confidence`, `fallback`, `quad` (wired into per-page manifest & logs), Otsu thresholding before zero-padding, `Canny(20, 65)` white-on-white fallback with `inside - outside >= 5.0` paper score verification, relative min warp bounds (`max(64, 0.25 * w/h)` instead of hardcoded `500 px`), and `minAreaRect` solidity `>= 0.72` guard.
- **Measured End-to-End Speed & Memory (`Apple M1`, 12MP `4032×3024`, `A4 @ 200 DPI`):**
  - Single 12MP 6-stage median latency: **`336.4 ms`** (down from `420.5 ms` in Phase 2).
  - `20 pages`, `workers=1` (`benchmark.py`): **`6.13 s`** (`0.31 s/page`); standalone CLI (`/usr/bin/time -l`): **`6.49 s`**, peak RSS **`433.6 MiB`**.
  - `20 pages`, `workers=4` (`benchmark.py`): **`4.48 s`** (`0.22 s/page`).

## Phase 2 — Reliability, Streaming Memory & Performance (2026-11-17)

### Changes & Measured Results
- **B4 (Streaming Pipeline & `--workers N`):**
  - Replaced upfront full-resolution BGR buffering (`_stage_input_files`) in [scripts/batch_scanner.py](scripts/batch_scanner.py) with lightweight task descriptors (`_discover_page_tasks`) and per-page disk-backed processing (`_process_single_page_task`), freeing arrays after each page.
  - Added `--workers N` (`ProcessPoolExecutor` with `spawn` context and `cv2.setNumThreads(1)` per worker; each worker reads/writes files independently).
  - Wrapped per-image Vision loop in `autoreleasepool` in [scripts/doc_scanner.swift](scripts/doc_scanner.swift).
  - **Measured Peak RSS & Speed (`Apple M1`, 12MP `4032×3024`, `A4 @ 200 DPI`, OpenCV):**
    - `20 pages`, `workers=1`: **`9.93 s`** (`0.50 s/page`), isolated peak RSS **`714.8 MiB`** (down from `31.15 s` / `1163.2 MiB`).
    - `20 pages`, `workers=4`: **`6.11 s`** (`0.31 s/page`), parent peak RSS **`428.2 MiB`**.
    - `100 pages`, `workers=1`: **`52.54 s`** (`0.53 s/page`), output `14.10 MiB`, isolated peak RSS **`723.2 MiB`** (flat $O(1)$ memory, `< 1.5 GB`).
- **Q7 (Single Final JPEG Encode & `--jpeg-quality`):**
  - Added `--quad-only` to [scripts/doc_scanner.swift](scripts/doc_scanner.swift) so `crop_via_vision` returns 4 corner coordinates in `manifest.json` and [scripts/batch_scanner.py](scripts/batch_scanner.py) warps directly from the original full-resolution image via `perspective_warp(..., preordered=True)`, removing the intermediate Vision JPEG encode/decode roundtrip (`44.61 dB` single-pass vs `44.00 dB` 2-pass reference PSNR on synthetic skewed text page).
  - Updated `stageItemToImageFile` in [macos_app/Sources/PDFToolsService.swift](macos_app/Sources/PDFToolsService.swift) to stage PDF pages as lossless `.png` instead of `0.94` JPEG.
  - Added `--jpeg-quality <1..100>` across [scripts/batch_scanner.py](scripts/batch_scanner.py) (default `86`), [scripts/doc_scanner.swift](scripts/doc_scanner.swift) (default `88`), `ScanSettings.jpegQuality` in [macos_app/Sources/Models.swift](macos_app/Sources/Models.swift), [macos_app/Sources/ScannerBridge.swift](macos_app/Sources/ScannerBridge.swift), and [macos_app/Sources/ContentView.swift](macos_app/Sources/ContentView.swift).
- **R5 (Eliminate Redundant LAB/HSV Conversions & Allocations):**
  - Preallocated module-level structuring element kernels (`_KERNEL_*`) in [scripts/batch_scanner.py](scripts/batch_scanner.py).
  - Reused `_estimate_paper_stats` inside `multipoint_border_mask_clean`, skipped HSV conversion when `need_hsv=False` (`flatten_document_surface`, `balance_page_symmetry`), restricted `_clean_residual_border_bleed` LAB/HSV conversion to the outer `1.5%` border strips, and computed `local_bg` at downscaled `<= 500 px` resolution only when `outside_mask` is non-empty.
  - **Measured single 12MP (`A4 @ 200 DPI`) median stage timings:** `multipoint_border_mask_clean` **`402.5 ms → 66.5 ms`**, total 6-stage **`979.5 ms → 420.5 ms`** (`2.3×` speedup).
- **Q11 (Single-Channel `grayscale` & 1-bit `bw` Outputs):**
  - Updated `_bgr_to_pil` / `enhance_image` in [scripts/batch_scanner.py](scripts/batch_scanner.py) so `grayscale` saves as 1-channel `"L"` JPEG (`/DeviceGray` `/DCTDecode`) and `bw` saves as 1-bit `"1"` PNG embedded as `/DeviceGray` `/BitsPerComponent 1` `/FlateDecode` in `assemble_pdf_from_pages`.
  - Updated [macos_app/Sources/ScannerBridge.swift](macos_app/Sources/ScannerBridge.swift) to preserve `.png` / `.jpg` extensions in `previewCacheDirectory`.
- **A3 (Channel Separation):**
  - Routed progress and diagnostic logs in [scripts/batch_scanner.py](scripts/batch_scanner.py) through Python `logging` on `stderr`, keeping `stdout` clean and `--manifest` / `--emit-dir` as the structured data channel.
- **A5 (Keyed Preview Cache, Layout Separation, Slider Commit & Cache Cleanup):**
  - Added `ScanSettings.imageProcessingSignature` and `InputPageItem.processedCacheKey` ([macos_app/Sources/Models.swift](macos_app/Sources/Models.swift)), `PDFToolsService.previewCacheKey` ([macos_app/Sources/PDFToolsService.swift](macos_app/Sources/PDFToolsService.swift)), `previewCacheByKey` & `syncPreviewsToCurrentSettings` ([macos_app/Sources/ContentView.swift](macos_app/Sources/ContentView.swift)), and `ScannerBridge.cleanupTemporaryCaches()` on launch (`AppViewModel.init`) and termination (`AppDelegate.applicationWillTerminate` in [macos_app/Sources/PDFScannerApp.swift](macos_app/Sources/PDFScannerApp.swift)).
  - Excluded pure PDF layout controls (`A4` ↔ `Letter`, `margin` slider) from image cache invalidation and switched `minConfidence`, `multipointPoints`, `dpi`, and `jpegQuality` sliders to `onEditingChanged` commit.
- **Verification:**
  - `./tests/run_all.sh`: **9/9 Python `unittest` cases OK** (`12.969s`) + **Swift Phase 1+2 tests PASS**.
  - `./macos_app/build_app.sh`: `PDF Scanner.app` (`2.7M`) built and signed cleanly.

## Phase 1 — Foundation Fixes, Manifest & PDF MediaBox Unification (2026-11-17)

### Summary of Decisions Applied
- **Scope:** Phase 1 implemented first (`B1`, `B2`, `B3`, `B6`, `B7`, `A9`, `R1`, `R6`, `requirements.txt`), pausing for review before Phases 2–4.
- **Recorded Decisions for Later Phases:**
  - `A1` (Phase 4): Bundle standalone Python + venv into app `Resources`, pre-compile `doc_scanner.swift` binary via `swiftc -O`, and add startup preflight check.
  - `B5` (Phase 4): Smart PDF compression preserving vector/text pages and original page size, re-encoding embedded images only with target-size loop (`Auto Color` / A4 off by default).
  - `Q3` (Phase 3): Set `balanceSymmetry` default to `false`.
  - `Q9` (Phase 4): Add optional Apple Vision OCR invisible text layer, **off by default** to prioritize speed.
  - `R1` (Applied in Phase 1): Renamed `CamScannerApp.swift` → `PDFScannerApp.swift` and UI/default mode `"Magic Color"` → `"Auto Color"` (keeping `--mode magic_color` as a backward-compatible CLI alias).

### Changes & Measured Results
- **B1 (TIFF & Image Format Support) & R6 (Hidden AppleDouble Filtering):**
  - `macos_app/Sources/PDFToolsService.swift`: Restricted fast-copy in `stageItemToImageFile` to unrotated `jpg`/`jpeg`/`png`; all other formats (`tif`, `tiff`, `bmp`, `webp`, `heic`, `heif`) and rotated images are decoded via CoreImage/`CGImageSource`, composited over white, and staged as lossless `.png`.
  - `scripts/batch_scanner.py`: Added `.tif`/`.tiff` to `SUPPORTED_IMAGE_EXTENSIONS`, multi-page TIFF frame iteration (`_iter_image_pages_bgr`), alpha compositing over white in `_pil_to_bgr`, and leading-dot exclusion in `find_images`.
- **B2 (JSON Manifest & `--emit-dir` / `--manifest` Channel):**
  - Added `--emit-dir` and `--manifest` to both `scripts/batch_scanner.py` and `scripts/doc_scanner.swift` (`--output` optional when `--emit-dir` is supplied).
  - Replaced positional `zip()` in `crop_via_vision` (`batch_scanner.py`) and filename-sorted `--save-debug` matching in `ScannerBridge.swift` with canonical-path manifest lookups (`InputPageItem.id`).
  - Added `InputPageItem.scanError` in `Models.swift` and red `Lỗi` status indicators + error tooltips in `ContentView.swift` (`CompactPageStripView` and `InteractiveSplitComparisonView`).
- **B3 (Single PDF Assembly & Exact `MediaBox`):**
  - App exports (`ScannerBridge.runBatchScan`) now always emit per-page images and compile the final PDF exclusively via `PDFToolsService.compileProcessedImagesToPDF` so cached and uncached runs produce identical `MediaBox` (`A4`, `Letter`, `Fit`).
  - Standalone Python CLI (`scripts/batch_scanner.py`) now uses `compute_pdf_page_geometry` + `assemble_pdf_from_jpegs` (`pypdf` `/DCTDecode` lossless JPEG embedding) matching Swift and `doc_scanner.swift` `MediaBox` and margins.
- **R1, B6, B7, `requirements.txt` & Reproducible Benchmark:**
  - Updated `requirements.txt` to include `pillow-heif>=0.16.0`.
  - Renamed `CamScannerApp.swift` → `PDFScannerApp.swift`; renamed `"Magic Color"` → `"Auto Color"` across Swift UI, SVGs, `README.md`, `scan_to_pdf.py`, and `docs/ALGORITHM_DEEP_DIVE.md` (with `magic_color` kept as CLI alias and `enhance_magic_color` kept for compatibility).
  - Updated `README.md` (`B6`) to remove unverified `"Lossless 300 DPI"`, `"~3.2s"`, and `"1000+ pages"` claims, separated offline local execution from optional cloud MCP, and documented TIFF and current Python/Xcode CLT requirements.
  - Rewrote `docs/ALGORITHM_DEEP_DIVE.md` (`B7`) to match the real code in `scripts/batch_scanner.py` (HSV+Otsu, `dilate 15×15` + `median 41`, `250.0 / bg`, `compensate_strokes_and_lines`, `_MAGIC_LUT` power `1.55`, `_SHARPEN_KERNEL` `λ=0.25`, Ridge flattening, scalar tint preservation limitation) and separated unimplemented proposals into Section 5.2.
  - Added `scripts/benchmark.py` and measured on Apple M1 (`macOS 27.2 arm64`, `8 GB RAM`, Python `3.10.22`, OpenCV `5.0.0`):
    - Single 12MP (`4032×3024`, A4 @ 200 DPI, OpenCV) 6-stage median: **`979.5 ms`** (`detect_and_crop` `17.0 ms`, `downscale` `20.5 ms`, `multipoint` `402.5 ms`, `enhance` `161.8 ms`, `flatten` `217.6 ms`, `symmetry` `160.1 ms`); unscaled 12MP `enhance_image_bgr`: **`715.1 ms`**.
    - 20-page 12MP batch (`A4 @ 200 DPI`, OpenCV): **`31.15 s`** (`1.56 s/page`), output `2.82 MiB`, peak RSS **`1163.2 MiB`**.
- **A9 (Automated Tests):**
  - Added `tests/test_batch_scanner.py` (6 Python `unittest` cases covering `find_images`, `MediaBox` + `/DCTDecode` across Python & `doc_scanner.swift`, mixed JPG/TIF/multi-page TIFF/WebP/BMP/PNG, corrupt-in-middle alignment with both OpenCV & Vision, all-corrupt manifest exit behavior, and `magic_color`/`auto_color` equivalence).
  - Added `tests/test_swift_bridge_and_tools.swift` (Swift unit tests for `parsePageRanges`, `formatPairFileName`, `naturalCompare`, `uniqueURLIfExists`, B1 staging for JPG/TIF/WebP/HEIC/PNG, B3 uncached vs cached `MediaBox` parity across A4/Letter/Fit, and B2 corrupt-in-middle `ScannerBridge` tests for both Hybrid and Pure Swift Vision).
  - Added `tests/run_all.sh`.
