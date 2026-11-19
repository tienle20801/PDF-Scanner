"""Reproducible Apple Silicon / local benchmark for PDF Scanner pipeline stages and 20-page batch."""

from __future__ import annotations

import argparse
import os
import platform
import re
import resource
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import cv2
import numpy as np

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import batch_scanner  # noqa: E402


def make_synthetic_12mp_page(width: int = 4032, height: int = 3024) -> np.ndarray:
    """Generate a synthetic 12MP document photo on a dark desk with shadow gradient and ruling lines."""
    desk = np.full((height, width, 3), (45, 52, 65), dtype=np.uint8)
    mx, my = int(width * 0.08), int(height * 0.08)
    desk[my : height - my, mx : width - mx] = (232, 234, 236)

    x0, y0, x1, y1 = mx + 60, my + 60, width - mx - 60, height - my - 60
    cv2.rectangle(desk, (x0, y0), (x1, y1), (40, 40, 40), 4)
    for row_y in range(y0 + 120, y1 - 120, 90):
        cv2.line(desk, (x0 + 50, row_y), (x1 - 50, row_y), (35, 35, 35), 3)
    for col_x in range(x0 + 400, x1 - 300, 600):
        cv2.line(desk, (col_x, y0 + 120), (col_x, y1 - 120), (50, 50, 50), 2)
    cv2.circle(desk, (x1 - 240, y1 - 240), 110, (35, 35, 200), 5)

    grad = np.linspace(0.68, 1.0, width, dtype=np.float32)[None, :, None]
    return np.clip(desk.astype(np.float32) * grad, 0, 255).astype(np.uint8)


def _peak_rss_mib(who: int = resource.RUSAGE_SELF) -> float:
    usage = resource.getrusage(who).ru_maxrss
    # macOS reports ru_maxrss in bytes; Linux reports KiB
    divisor = (1024.0 * 1024.0) if sys.platform == "darwin" else 1024.0
    return usage / divisor


def bench_single_image(runs: int = 5) -> None:
    sample = make_synthetic_12mp_page()

    # Warm-up
    _ = batch_scanner.enhance_image_bgr(sample, mode="auto_color")

    t_crop, t_down, t_mp, t_enh_scaled, t_enh_12mp, t_flat, t_sym, t_total = (
        [],
        [],
        [],
        [],
        [],
        [],
        [],
        [],
    )
    for _ in range(runs):
        t0 = time.perf_counter()
        cropped = batch_scanner.detect_and_crop(sample)
        t1 = time.perf_counter()
        down = batch_scanner.downscale_to_dpi(cropped, "a4", 200, 20.0)
        t2 = time.perf_counter()
        mp = batch_scanner.multipoint_border_mask_clean(down, points_per_edge=32)
        t3 = time.perf_counter()
        enh = batch_scanner.enhance_image_bgr(mp, mode="auto_color")
        t4 = time.perf_counter()
        flat = batch_scanner.flatten_document_surface(enh)
        t5 = time.perf_counter()
        _ = batch_scanner.balance_page_symmetry(flat, target_shape=down.shape[:2])
        t6 = time.perf_counter()
        _ = batch_scanner.enhance_image_bgr(sample, mode="auto_color")
        t7 = time.perf_counter()

        t_crop.append((t1 - t0) * 1000.0)
        t_down.append((t2 - t1) * 1000.0)
        t_mp.append((t3 - t2) * 1000.0)
        t_enh_scaled.append((t4 - t3) * 1000.0)
        t_flat.append((t5 - t4) * 1000.0)
        t_sym.append((t6 - t5) * 1000.0)
        t_total.append((t6 - t0) * 1000.0)
        t_enh_12mp.append((t7 - t6) * 1000.0)

    def fmt(xs: list[float]) -> str:
        return f"med={float(np.median(xs)):6.1f} ms, min={float(np.min(xs)):6.1f} ms"

    print(f"\n=== Single 12MP (4032x3024) Stage Timings (runs={runs}) ===")
    print(f"detect_and_crop (OpenCV):      {fmt(t_crop)}")
    print(f"downscale_to_dpi (A4@200):     {fmt(t_down)}")
    print(f"multipoint_border_mask_clean:  {fmt(t_mp)}")
    print(f"enhance_image_bgr (A4@200):    {fmt(t_enh_scaled)}")
    print(f"flatten_document_surface:      {fmt(t_flat)}")
    print(f"balance_page_symmetry:         {fmt(t_sym)}")
    print(f"Total 6-stage (A4@200):        {fmt(t_total)}")
    print(f"enhance_image_bgr (full 12MP): {fmt(t_enh_12mp)}")


def bench_batch(
    pages: int = 20, dpi: int = 200, workers: str = "1", in_process: bool = False
) -> None:
    sample = make_synthetic_12mp_page()
    with tempfile.TemporaryDirectory(prefix="pdfscanner_bench_") as tmp:
        tmp_path = Path(tmp)
        in_dir = tmp_path / "in"
        in_dir.mkdir()
        src_jpg = in_dir / "page_001.jpg"
        cv2.imwrite(str(src_jpg), sample, [cv2.IMWRITE_JPEG_QUALITY, 92])
        del sample
        raw_bytes = src_jpg.read_bytes()
        for i in range(2, pages + 1):
            (in_dir / f"page_{i:03d}.jpg").write_bytes(raw_bytes)

        out_pdf = tmp_path / "out.pdf"
        t0 = time.perf_counter()
        if in_process:
            workers_val: int | str = int(workers) if workers.lstrip("+-").isdigit() else workers
            ok = batch_scanner.convert_folder_to_hd_pdf(
                input_path=str(in_dir),
                output_pdf_path=str(out_pdf),
                mode="auto_color",
                auto_crop=True,
                dpi=dpi,
                crop_engine="opencv",
                page_size="a4",
                workers=workers_val,
            )
            elapsed = time.perf_counter() - t0
            rss_label = "Process Peak RSS"
            rss_mib = _peak_rss_mib(resource.RUSAGE_SELF)
        else:
            cmd = [
                sys.executable,
                str(SCRIPT_DIR / "batch_scanner.py"),
                str(in_dir),
                str(out_pdf),
                "--mode",
                "auto_color",
                "--dpi",
                str(dpi),
                "--crop-engine",
                "opencv",
                "--page-size",
                "a4",
                "--workers",
                str(workers),
            ]
            use_time_l = sys.platform == "darwin" and os.path.exists("/usr/bin/time")
            full_cmd = ["/usr/bin/time", "-l", *cmd] if use_time_l else cmd
            proc = subprocess.run(full_cmd, capture_output=True, text=True)
            elapsed = time.perf_counter() - t0
            ok = proc.returncode == 0
            if not ok and proc.stderr:
                print(proc.stderr, file=sys.stderr)
            rss_label = "Isolated CLI Peak RSS"
            m = re.search(r"(\d+)\s+maximum resident set size", proc.stderr or "")
            if m:
                rss_mib = int(m.group(1)) / (1024.0 * 1024.0)
            else:
                rss_mib = _peak_rss_mib(resource.RUSAGE_CHILDREN)

        size_mib = out_pdf.stat().st_size / (1024.0 * 1024.0) if out_pdf.exists() else 0.0
        print(f"\n=== {pages}-Page 12MP Batch (OpenCV, A4 @ {dpi} DPI, workers={workers}) ===")
        print(f"Success: {ok}, Elapsed: {elapsed:.2f} s ({elapsed / pages:.2f} s/page)")
        print(f"Output PDF size: {size_mib:.2f} MiB, {rss_label}: {rss_mib:.1f} MiB")


def main() -> None:
    parser = argparse.ArgumentParser(description="Benchmark PDF Scanner pipeline on synthetic 12MP documents.")
    parser.add_argument("--pages", type=int, default=20, help="Number of 12MP pages for batch benchmark (default: 20)")
    parser.add_argument("--runs", type=int, default=5, help="Single-page iterations for median timing (default: 5)")
    parser.add_argument("--dpi", type=int, default=200, help="Target PDF DPI (default: 200)")
    parser.add_argument("--workers", default="1", help="Worker processes ('auto', 0, or N; default: 1)")
    parser.add_argument("--batch-only", action="store_true", help="Skip single-page warm-up before batch benchmark")
    parser.add_argument("--in-process", action="store_true", help="Run batch in-process instead of isolated CLI subprocess")
    args = parser.parse_args()

    l1, l5, l15 = os.getloadavg()
    print(
        f"Environment: {platform.system()} {platform.release()} ({platform.machine()}), "
        f"Python {platform.python_version()}, OpenCV {cv2.__version__}, NumPy {np.__version__}, "
        f"LoadAvg: {l1:.2f} {l5:.2f} {l15:.2f}"
    )
    if not args.batch_only:
        bench_single_image(runs=args.runs)
    bench_batch(pages=args.pages, dpi=args.dpi, workers=args.workers, in_process=args.in_process)


if __name__ == "__main__":
    main()
