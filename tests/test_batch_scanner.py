from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw
from pypdf import PdfReader

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import batch_scanner  # noqa: E402
import pdf_compressor  # noqa: E402
import scan_to_pdf  # noqa: E402


def _make_doc_image(
    width: int,
    height: int,
    accent_bgr: tuple[int, int, int] = (20, 20, 190),
    paper_bgr: tuple[int, int, int] = (242, 240, 236),
    with_border: bool = False,
) -> np.ndarray:
    """Create a synthetic document image with dark text, grid lines, and an accent marker."""
    img = np.full((height, width, 3), paper_bgr, dtype=np.uint8)
    if with_border:
        # Dark desk border around a centered paper rectangle
        desk = np.full((height, width, 3), (45, 52, 65), dtype=np.uint8)
        mx, my = int(width * 0.12), int(height * 0.10)
        desk[my : height - my, mx : width - mx] = paper_bgr
        img = desk
        x0, y0, x1, y1 = mx + 30, my + 30, width - mx - 30, height - my - 30
    else:
        x0, y0, x1, y1 = 40, 40, width - 40, height - 40

    # Horizontal text-like bars and table frame
    cv2.rectangle(img, (x0, y0), (x1, y1), (40, 40, 40), 2)
    for row_y in range(y0 + 50, y1 - 80, 48):
        cv2.line(img, (x0 + 24, row_y), (x1 - 24, row_y), (35, 35, 35), 2)
    # Distinctive colored marker rectangle to verify page identity after batch runs
    cv2.rectangle(img, (x0 + 30, y0 + 20), (x0 + 130, y0 + 70), accent_bgr, -1)
    return img


def _run_cli(args: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(REPO_ROOT / "scripts" / "batch_scanner.py"), *args],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
    )


class TestPhase1Scanner(unittest.TestCase):
    def test_find_images_skips_hidden_appledouble_and_includes_tiff(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            for name in ["page10.jpg", "page2.tif", "page1.tiff", "._page1.tiff", ".DS_Store", "notes.txt"]:
                (d / name).write_bytes(b"stub")
            found = [Path(p).name for p in batch_scanner.find_images(str(d))]
            self.assertEqual(found, ["page1.tiff", "page2.tif", "page10.jpg"])

    def test_mediabox_consistency_python_and_swift_cli(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            portrait_dir = d / "portrait"
            landscape_dir = d / "landscape"
            portrait_dir.mkdir()
            landscape_dir.mkdir()

            cv2.imwrite(str(portrait_dir / "p1.png"), _make_doc_image(1200, 1600))
            cv2.imwrite(str(landscape_dir / "l1.png"), _make_doc_image(1600, 1200))

            cases = [
                ("a4", portrait_dir, 200, (595.28, 841.89)),
                ("a4", landscape_dir, 200, (841.89, 595.28)),
                ("letter", portrait_dir, 200, (612.0, 792.0)),
                ("letter", landscape_dir, 200, (792.0, 612.0)),
                ("fit", portrait_dir, 150, (1200 * 72.0 / 150.0, 1600 * 72.0 / 150.0)),
            ]

            for page_size, src_dir, dpi, (exp_w, exp_h) in cases:
                py_pdf = d / f"py_{page_size}_{src_dir.name}.pdf"
                proc = _run_cli(
                    [
                        str(src_dir),
                        str(py_pdf),
                        "--no-crop",
                        "--mode",
                        "original",
                        "--page-size",
                        page_size,
                        "--dpi",
                        str(dpi),
                    ]
                )
                self.assertEqual(proc.returncode, 0, proc.stderr + proc.stdout)
                reader = PdfReader(str(py_pdf))
                self.assertEqual(len(reader.pages), 1)
                box = reader.pages[0].mediabox
                self.assertAlmostEqual(float(box.width), exp_w, delta=0.2)
                self.assertAlmostEqual(float(box.height), exp_h, delta=0.2)

                # Verify DCTDecode lossless JPEG embedding
                xobjs = reader.pages[0]["/Resources"]["/XObject"]
                img_obj = next(iter(xobjs.values())).get_object()
                self.assertEqual(str(img_obj["/Filter"]), "/DCTDecode")

                # Verify doc_scanner.swift produces identical MediaBox
                sw_pdf = d / f"sw_{page_size}_{src_dir.name}.pdf"
                sw_proc = subprocess.run(
                    [
                        "swift",
                        str(REPO_ROOT / "scripts" / "doc_scanner.swift"),
                        "--output",
                        str(sw_pdf),
                        "--no-crop",
                        "--mode",
                        "original",
                        "--page-size",
                        page_size,
                        "--dpi",
                        str(dpi),
                        str(src_dir),
                    ],
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(sw_proc.returncode, 0, sw_proc.stderr + sw_proc.stdout)
                sw_reader = PdfReader(str(sw_pdf))
                sw_box = sw_reader.pages[0].mediabox
                self.assertAlmostEqual(float(sw_box.width), exp_w, delta=0.2)
                self.assertAlmostEqual(float(sw_box.height), exp_h, delta=0.2)

    def test_mixed_formats_including_multipage_tiff_and_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            in_dir = d / "in"
            emit_dir = d / "emit"
            in_dir.mkdir()

            # Create JPG, single-page TIFF, 2-page TIFF, WebP, BMP, PNG, plus AppleDouble junk
            Image.fromarray(cv2.cvtColor(_make_doc_image(900, 1200, (0, 0, 220)), cv2.COLOR_BGR2RGB)).save(in_dir / "01.jpg")
            Image.fromarray(cv2.cvtColor(_make_doc_image(900, 1200, (0, 180, 0)), cv2.COLOR_BGR2RGB)).save(in_dir / "02.tif", format="TIFF")
            p_a = Image.fromarray(cv2.cvtColor(_make_doc_image(900, 1200, (220, 0, 0)), cv2.COLOR_BGR2RGB))
            p_b = Image.fromarray(cv2.cvtColor(_make_doc_image(900, 1200, (200, 180, 0)), cv2.COLOR_BGR2RGB))
            p_a.save(in_dir / "03_multi.tiff", format="TIFF", save_all=True, append_images=[p_b])
            Image.fromarray(cv2.cvtColor(_make_doc_image(900, 1200), cv2.COLOR_BGR2RGB)).save(in_dir / "04.webp", format="WEBP")
            Image.fromarray(cv2.cvtColor(_make_doc_image(900, 1200), cv2.COLOR_BGR2RGB)).save(in_dir / "05.bmp", format="BMP")
            Image.fromarray(cv2.cvtColor(_make_doc_image(900, 1200), cv2.COLOR_BGR2RGB)).save(in_dir / "06.png", format="PNG")
            (in_dir / "._01.jpg").write_bytes(b"AppleDouble junk")

            manifest = d / "manifest.json"
            out_pdf = d / "mixed.pdf"
            proc = _run_cli(
                [
                    str(in_dir),
                    str(out_pdf),
                    "--crop-engine",
                    "opencv",
                    "--no-crop",
                    "--mode",
                    "auto_color",
                    "--emit-dir",
                    str(emit_dir),
                    "--manifest",
                    str(manifest),
                ]
            )
            self.assertEqual(proc.returncode, 0, proc.stderr + proc.stdout)
            data = json.loads(manifest.read_text(encoding="utf-8"))
            self.assertEqual(data["pages"], 7)  # 1+1+2+1+1+1
            self.assertEqual(data["pages_error"], 0)
            self.assertEqual(len(data["results"]), 7)
            self.assertTrue(all(r["status"] == "ok" and Path(r["output"]).exists() for r in data["results"]))
            self.assertEqual(len(PdfReader(str(out_pdf)).pages), 7)

    def test_corrupt_image_in_middle_preserves_alignment_and_reports_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            in_dir = d / "batch"
            emit_dir = d / "emit"
            in_dir.mkdir()

            # Distinct solid marker strips so we can verify page 1 stays red and page 3 stays blue
            red_img = _make_doc_image(800, 1000, accent_bgr=(0, 0, 230), paper_bgr=(250, 250, 250))
            blue_img = _make_doc_image(800, 1000, accent_bgr=(230, 0, 0), paper_bgr=(250, 250, 250))
            cv2.imwrite(str(in_dir / "01_red.jpg"), red_img)
            (in_dir / "02_corrupt.jpg").write_bytes(b"not a real jpeg image at all")
            cv2.imwrite(str(in_dir / "03_blue.png"), blue_img)

            for engine in ["opencv", "vision"]:
                sub_emit = emit_dir / engine
                manifest = d / f"manifest_{engine}.json"
                out_pdf = d / f"out_{engine}.pdf"
                proc = _run_cli(
                    [
                        str(in_dir),
                        str(out_pdf),
                        "--crop-engine",
                        engine,
                        "--no-crop",
                        "--mode",
                        "original",
                        "--emit-dir",
                        str(sub_emit),
                        "--manifest",
                        str(manifest),
                    ]
                )
                self.assertEqual(proc.returncode, 0, proc.stderr + proc.stdout)
                m = json.loads(manifest.read_text(encoding="utf-8"))
                self.assertEqual(m["pages"], 2)
                self.assertEqual(m["pages_error"], 1)
                self.assertEqual([r["file"] for r in m["results"]], ["01_red.jpg", "02_corrupt.jpg", "03_blue.png"])
                self.assertEqual([r["status"] for r in m["results"]], ["ok", "error", "ok"])
                self.assertIsNone(m["results"][1]["output"])
                self.assertTrue(len(m["results"][1]["message"]) > 0)

                # Verify output image identity (no shift)
                out1 = cv2.imread(m["results"][0]["output"])
                out3 = cv2.imread(m["results"][2]["output"])
                # Marker region around (90, 75): page 1 must be red (R >> B), page 3 must be blue (B >> R)
                patch1 = out1[65:95, 80:140].mean(axis=(0, 1))  # BGR
                patch3 = out3[65:95, 80:140].mean(axis=(0, 1))
                self.assertGreater(patch1[2], patch1[0] + 100)
                self.assertGreater(patch3[0], patch3[2] + 100)
                self.assertEqual(len(PdfReader(str(out_pdf)).pages), 2)

    def test_all_corrupt_batch_writes_manifest_and_exits_nonzero(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            in_dir = d / "bad"
            in_dir.mkdir()
            (in_dir / "broken.jpg").write_bytes(b"corrupted")
            manifest = d / "manifest.json"
            proc = _run_cli(
                [
                    str(in_dir),
                    "--emit-dir",
                    str(d / "emit"),
                    "--manifest",
                    str(manifest),
                    "--crop-engine",
                    "opencv",
                ]
            )
            self.assertNotEqual(proc.returncode, 0)
            self.assertTrue(manifest.exists())
            m = json.loads(manifest.read_text(encoding="utf-8"))
            self.assertEqual(m["pages"], 0)
            self.assertEqual(m["pages_error"], 1)
            self.assertEqual(m["results"][0]["status"], "error")

    def test_magic_color_alias_matches_auto_color_and_synthetic_baseline(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            in_dir = d / "synth"
            in_dir.mkdir()
            # Synthetic document with dark border + slight shadow gradient
            img = _make_doc_image(1200, 1600, accent_bgr=(25, 25, 210), paper_bgr=(230, 232, 235), with_border=True)
            grad = np.linspace(0.65, 1.0, img.shape[1], dtype=np.float32)[None, :, None]
            shadowed = np.clip(img.astype(np.float32) * grad, 0, 255).astype(np.uint8)
            cv2.imwrite(str(in_dir / "doc.png"), shadowed)

            emit_auto = d / "auto"
            emit_legacy = d / "legacy"
            man_auto = d / "auto.json"
            man_legacy = d / "legacy.json"

            p1 = _run_cli(
                [str(in_dir), "--crop-engine", "opencv", "--mode", "auto_color", "--emit-dir", str(emit_auto), "--manifest", str(man_auto)]
            )
            p2 = _run_cli(
                [str(in_dir), "--crop-engine", "opencv", "--mode", "magic_color", "--emit-dir", str(emit_legacy), "--manifest", str(man_legacy)]
            )
            self.assertEqual(p1.returncode, 0, p1.stderr + p1.stdout)
            self.assertEqual(p2.returncode, 0, p2.stderr + p2.stdout)

            m1 = json.loads(man_auto.read_text(encoding="utf-8"))
            m2 = json.loads(man_legacy.read_text(encoding="utf-8"))
            img1 = cv2.imread(m1["results"][0]["output"])
            img2 = cv2.imread(m2["results"][0]["output"])
            self.assertEqual(img1.shape, img2.shape)
            self.assertTrue(np.array_equal(img1, img2))
            # Blank paper strip between text rows (away from the top-left marker & ruling lines) should be near-white
            h1, w1 = img1.shape[:2]
            paper_patch = img1[int(h1 * 0.45) : int(h1 * 0.55), int(w1 * 0.45) : int(w1 * 0.55)]
            bright_pixels = paper_patch[paper_patch.mean(axis=2) > 200]
            self.assertGreater(float(bright_pixels.mean()), 245.0)

    def test_q11_grayscale_and_bw_channel_formats(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            in_dir = d / "in"
            in_dir.mkdir()
            cv2.imwrite(str(in_dir / "doc.png"), _make_doc_image(1200, 1600))

            # Grayscale -> 1-channel 'L' JPEG & /DeviceGray /DCTDecode
            gray_emit = d / "emit_gray"
            gray_man = d / "man_gray.json"
            gray_pdf = d / "gray.pdf"
            p_gray = _run_cli(
                [
                    str(in_dir),
                    str(gray_pdf),
                    "--no-crop",
                    "--mode",
                    "grayscale",
                    "--emit-dir",
                    str(gray_emit),
                    "--manifest",
                    str(gray_man),
                ]
            )
            self.assertEqual(p_gray.returncode, 0, p_gray.stderr)
            self.assertEqual(p_gray.stdout.strip(), "")  # A3: logs go to stderr, stdout clean
            self.assertIn("[SUCCESS]", p_gray.stderr)
            gm = json.loads(gray_man.read_text(encoding="utf-8"))
            out_gray = Path(gm["results"][0]["output"])
            self.assertEqual(out_gray.suffix, ".jpg")
            with Image.open(out_gray) as im_g:
                self.assertEqual(im_g.mode, "L")
            g_xobj = next(iter(PdfReader(str(gray_pdf)).pages[0]["/Resources"]["/XObject"].values())).get_object()
            self.assertEqual(str(g_xobj["/ColorSpace"]), "/DeviceGray")
            self.assertEqual(str(g_xobj["/Filter"]), "/DCTDecode")
            self.assertEqual(int(g_xobj["/BitsPerComponent"]), 8)

            # B&W -> 1-bit '1' PNG & /DeviceGray /BitsPerComponent 1 /FlateDecode
            bw_emit = d / "emit_bw"
            bw_man = d / "man_bw.json"
            bw_pdf = d / "bw.pdf"
            p_bw = _run_cli(
                [
                    str(in_dir),
                    str(bw_pdf),
                    "--no-crop",
                    "--mode",
                    "bw",
                    "--emit-dir",
                    str(bw_emit),
                    "--manifest",
                    str(bw_man),
                ]
            )
            self.assertEqual(p_bw.returncode, 0, p_bw.stderr)
            bm = json.loads(bw_man.read_text(encoding="utf-8"))
            out_bw = Path(bm["results"][0]["output"])
            self.assertEqual(out_bw.suffix, ".png")
            with Image.open(out_bw) as im_bw:
                self.assertEqual(im_bw.mode, "1")
            bw_xobj = next(iter(PdfReader(str(bw_pdf)).pages[0]["/Resources"]["/XObject"].values())).get_object()
            self.assertEqual(str(bw_xobj["/ColorSpace"]), "/DeviceGray")
            self.assertEqual(str(bw_xobj["/Filter"]), "/FlateDecode")
            self.assertEqual(int(bw_xobj["/BitsPerComponent"]), 1)
            self.assertLess(bw_pdf.stat().st_size, gray_pdf.stat().st_size)

    def test_q7_vision_quad_only_fullres_warp_and_jpeg_quality(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            in_dir = d / "skew"
            in_dir.mkdir()
            # Create skewed page on dark desk with RED marker at top-left and BLUE marker at bottom-right
            canvas = np.full((1200, 900, 3), (38, 42, 48), dtype=np.uint8)
            quad = np.array([[140, 110], [770, 170], [810, 1080], [100, 1010]], dtype=np.int32)
            cv2.fillPoly(canvas, [quad], (244, 244, 242))
            cv2.rectangle(canvas, (190, 190), (310, 310), (0, 0, 230), -1)  # RED top-left
            cv2.rectangle(canvas, (600, 860), (720, 980), (230, 0, 0), -1)  # BLUE bottom-right
            cv2.imwrite(str(in_dir / "skew.png"), canvas)

            emit_q95 = d / "q95"
            emit_q50 = d / "q50"
            man_q95 = d / "q95.json"
            man_q50 = d / "q50.json"

            p95 = _run_cli(
                [
                    str(in_dir),
                    str(d / "q95.pdf"),
                    "--crop-engine",
                    "vision",
                    "--mode",
                    "original",
                    "--multipoint-points",
                    "0",
                    "--jpeg-quality",
                    "95",
                    "--emit-dir",
                    str(emit_q95),
                    "--manifest",
                    str(man_q95),
                ]
            )
            p50 = _run_cli(
                [
                    str(in_dir),
                    str(d / "q50.pdf"),
                    "--crop-engine",
                    "vision",
                    "--mode",
                    "original",
                    "--multipoint-points",
                    "0",
                    "--jpeg-quality",
                    "50",
                    "--emit-dir",
                    str(emit_q50),
                    "--manifest",
                    str(man_q50),
                ]
            )
            self.assertEqual(p95.returncode, 0, p95.stderr)
            self.assertEqual(p50.returncode, 0, p50.stderr)
            m95 = json.loads(man_q95.read_text(encoding="utf-8"))
            self.assertTrue(m95["results"][0]["method"].startswith("vision:"))

            warped = cv2.imread(m95["results"][0]["output"])
            h, w = warped.shape[:2]
            tl_patch = warped[int(h * 0.08) : int(h * 0.16), int(w * 0.08) : int(w * 0.16)].mean(axis=(0, 1))
            br_patch = warped[int(h * 0.80) : int(h * 0.88), int(w * 0.78) : int(w * 0.86)].mean(axis=(0, 1))
            self.assertGreater(tl_patch[2], tl_patch[0] + 100)  # Top-left remains RED
            self.assertGreater(br_patch[0], br_patch[2] + 100)  # Bottom-right remains BLUE
            self.assertLess((d / "q50.pdf").stat().st_size, (d / "q95.pdf").stat().st_size)

    def test_b4_multiprocessing_workers_preserves_order_and_matches_single_worker(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            in_dir = d / "pages"
            in_dir.mkdir()
            colors = [(0, 0, 220), (0, 180, 0), (220, 0, 0), (180, 0, 180)]
            for idx, col in enumerate(colors, 1):
                cv2.imwrite(str(in_dir / f"p{idx}.png"), _make_doc_image(800, 1000, accent_bgr=col))

            man1 = d / "m1.json"
            man2 = d / "m2.json"
            p1 = _run_cli(
                [
                    str(in_dir),
                    str(d / "w1.pdf"),
                    "--crop-engine",
                    "opencv",
                    "--no-crop",
                    "--workers",
                    "1",
                    "--emit-dir",
                    str(d / "e1"),
                    "--manifest",
                    str(man1),
                ]
            )
            p2 = _run_cli(
                [
                    str(in_dir),
                    str(d / "w2.pdf"),
                    "--crop-engine",
                    "opencv",
                    "--no-crop",
                    "--workers",
                    "2",
                    "--emit-dir",
                    str(d / "e2"),
                    "--manifest",
                    str(man2),
                ]
            )
            self.assertEqual(p1.returncode, 0, p1.stderr)
            self.assertEqual(p2.returncode, 0, p2.stderr)
            r1 = json.loads(man1.read_text(encoding="utf-8"))["results"]
            r2 = json.loads(man2.read_text(encoding="utf-8"))["results"]
            self.assertEqual([x["file"] for x in r1], [x["file"] for x in r2])
            for a, b in zip(r1, r2):
                im_a = cv2.imread(a["output"])
                im_b = cv2.imread(b["output"])
                self.assertTrue(np.array_equal(im_a, im_b))

    def test_q1_q2_white_balance_and_dark_block_preservation(self):
        tints = {
            "yellow": (190, 230, 248),
            "blue": (248, 232, 195),
            "pink": (215, 200, 248),
        }
        for name, paper in tints.items():
            img = np.full((800, 600, 3), paper, dtype=np.uint8)
            # ~30x30mm solid black block on 600w page (~90x90 px)
            cv2.rectangle(img, (60, 100), (160, 200), (15, 15, 15), -1)
            # Shaded gray table header with dark text stroke inside
            cv2.rectangle(img, (200, 100), (540, 160), (130, 130, 130), -1)
            cv2.line(img, (220, 130), (500, 130), (20, 20, 20), 4)
            # Red and blue stamps
            cv2.circle(img, (440, 500), 65, (35, 35, 220), -1)
            cv2.circle(img, (220, 500), 65, (215, 85, 30), -1)

            out = batch_scanner.enhance_image_bgr(img, mode="auto_color")
            paper_patch = out[260:380, 60:540]
            paper_mean = paper_patch.mean(axis=(0, 1))
            self.assertGreaterEqual(float(paper_mean.min()), 250.0, f"{name} paper mean={paper_mean}")
            self.assertLessEqual(float(paper_mean.max() - paper_mean.min()), 4.0, f"{name} tint delta={paper_mean}")

            block_mean = float(out[120:180, 80:140].mean())
            self.assertLess(block_mean, 30.0, f"{name} black block washed out: {block_mean}")

            header_bg = float(out[108:116, 220:500].mean())
            header_ink = float(out[129:132, 240:480].mean())
            self.assertGreater(header_bg - header_ink, 60.0, f"{name} header ink contrast too low")

            hsv_in = cv2.cvtColor(img, cv2.COLOR_BGR2HSV)
            hsv_out = cv2.cvtColor(out, cv2.COLOR_BGR2HSV)
            for cx, cy in [(440, 500), (220, 500)]:
                h0 = int(hsv_in[cy, cx, 0])
                h1 = int(hsv_out[cy, cx, 0])
                circ_deg = min(abs(h0 - h1), 180 - abs(h0 - h1)) * 2.0
                self.assertLessEqual(circ_deg, 12.0, f"{name} stamp hue drift {circ_deg} deg ({h0}->{h1})")

    def test_q3_symmetry_default_off_and_dust_filtering(self):
        import inspect

        sig = inspect.signature(batch_scanner.convert_folder_to_hd_pdf)
        self.assertFalse(sig.parameters["balance_symmetry"].default)

        # Page with content shifted heavily toward top/left plus 2x2 corner speck
        img = np.full((1000, 800, 3), (250, 250, 250), dtype=np.uint8)
        cv2.rectangle(img, (60, 80), (420, 620), (30, 30, 30), 3)
        for ry in range(110, 600, 45):
            cv2.line(img, (80, ry), (400, ry), (25, 25, 25), 4)
        img[985:987, 785:787] = (15, 15, 15)  # 2x2 isolated corner dust speck

        centered = batch_scanner.balance_page_symmetry(img)
        gray_c = cv2.cvtColor(centered, cv2.COLOR_BGR2GRAY)
        ys, xs = np.where(gray_c < 200)
        # Main block (360x540) should now sit centered with left margin near ~210 (not shifted by 2x2 corner speck)
        left_margin = int(xs.min())
        right_margin = 800 - int(xs.max())
        self.assertLess(abs(left_margin - right_margin), 20)

        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            in_dir = d / "in"
            emit_def = d / "emit_def"
            emit_sym = d / "emit_sym"
            in_dir.mkdir()
            cv2.imwrite(str(in_dir / "p1.png"), img)
            p_def = _run_cli([str(in_dir), str(d / "def.pdf"), "--no-flatten", "--emit-dir", str(emit_def)])
            p_sym = _run_cli([str(in_dir), str(d / "sym.pdf"), "--no-flatten", "--symmetry", "--emit-dir", str(emit_sym)])
            self.assertEqual(p_def.returncode, 0, p_def.stderr)
            self.assertEqual(p_sym.returncode, 0, p_sym.stderr)
            out_def = cv2.imread(str(next(emit_def.iterdir())))
            # With symmetry off by default, content stays anchored near x=60 (not centered to x~220)
            xs_def = np.where(cv2.cvtColor(out_def, cv2.COLOR_BGR2GRAY) < 200)[1]
            self.assertLess(int(xs_def.min()), 110)

    def test_q4_deskew_and_curl_quality_gate(self):
        # 1. Flat ruled page -> skipped cleanly (pixels preserved)
        flat = np.full((900, 700, 3), (252, 252, 252), dtype=np.uint8)
        for y in range(120, 820, 60):
            cv2.line(flat, (80, y), (620, y), (30, 30, 30), 2)
        self.assertTrue(np.array_equal(flat, batch_scanner.flatten_document_surface(flat)))

        # 2. Sparse top-title page -> skipped cleanly
        sparse = np.full((900, 700, 3), (252, 252, 252), dtype=np.uint8)
        xs = np.arange(80, 620)
        for y0 in [105, 140]:
            for x, y in zip(xs, y0 + np.round(5.0 * np.sin(np.pi * (xs - 80) / 540.0)).astype(int)):
                cv2.circle(sparse, (int(x), int(y)), 1, (25, 25, 25), -1)
        self.assertTrue(np.array_equal(sparse, batch_scanner.flatten_document_surface(sparse)))

        # 3. Curved + 2 deg skewed page -> deskewed and RMS reduced below 1.0 px
        curved = np.full((900, 700, 3), (252, 252, 252), dtype=np.uint8)
        for y0 in range(120, 820, 65):
            ys = y0 + np.round(14.0 * np.sin(np.pi * (xs - 80) / 540.0) + 0.035 * (xs - 350)).astype(int)
            for x, y in zip(xs, ys):
                cv2.circle(curved, (int(x), int(y)), 1, (25, 25, 25), -1)
        rectified = batch_scanner.flatten_document_surface(curved)
        _, _, _, dy_after, *_ = batch_scanner._detect_surface_lines(cv2.cvtColor(rectified, cv2.COLOR_BGR2GRAY))
        rms_after = float(np.sqrt(np.mean(dy_after**2)))
        self.assertLess(rms_after, 1.0)

    def test_q5_broken_stroke_compensation(self):
        for bg_level in (242, 205):
            grid = np.full((600, 800, 3), (bg_level, bg_level, bg_level), dtype=np.uint8)
            cv2.line(grid, (60, 200), (740, 200), (45, 45, 45), 3)
            cv2.line(grid, (300, 60), (300, 540), (45, 45, 45), 3)
            # Punch 3px horizontal and 4px vertical breaks
            grid[198:203, 220:223] = (bg_level, bg_level, bg_level)
            grid[360:364, 298:303] = (bg_level, bg_level, bg_level)

            repaired = batch_scanner.compensate_strokes_and_lines(grid)
            self.assertLess(float(repaired[200, 221].mean()), 75.0, f"bg={bg_level} H gap not bridged")
            self.assertLess(float(repaired[362, 300].mean()), 75.0, f"bg={bg_level} V gap not bridged")

    def test_q6_order_points_45deg_canny_white_on_white_and_small_crop(self):
        # 45-deg rotated portrait corners: previously tied x+y / y-x sums
        rect45 = np.array([[220.0, 60.0], [420.0, 260.0], [280.0, 400.0], [80.0, 200.0]], dtype=np.float32)
        ordered = batch_scanner._order_points(rect45[[2, 0, 3, 1]])
        # Verify strictly convex clockwise non-self-intersecting cycle
        crosses = []
        for i in range(4):
            v1 = ordered[(i + 1) % 4] - ordered[i]
            v2 = ordered[(i + 2) % 4] - ordered[(i + 1) % 4]
            crosses.append(float(v1[0] * v2[1] - v1[1] * v2[0]))
        self.assertTrue(all(c > 0 for c in crosses))

        # White paper (246) with dark text on off-white desk (222) -> Canny fallback detects paper bounds
        wow = np.full((800, 600, 3), (222, 222, 222), dtype=np.uint8)
        cv2.rectangle(wow, (90, 100), (510, 700), (246, 246, 246), -1)
        for ry in range(150, 660, 22):
            cv2.line(wow, (120, ry), (480, ry), (20, 20, 20), 4)
        warped_wow, info_wow = batch_scanner.detect_and_crop_with_info(wow)
        self.assertTrue(info_wow["detected"])
        self.assertEqual(info_wow["method"], "canny_edge")
        self.assertAlmostEqual(warped_wow.shape[0], 600, delta=8)
        self.assertAlmostEqual(warped_wow.shape[1], 420, delta=8)

        # Full-bleed page with inner table border must NOT false-crop onto table rect
        full = _make_doc_image(600, 800, with_border=False)
        _, info_full = batch_scanner.detect_and_crop_with_info(full)
        self.assertFalse(info_full["detected"])
        self.assertEqual(info_full["method"], "fallback_original")

        # Small document (<500px) must crop instead of failing hardcoded 500px threshold
        small_doc = np.full((420, 340, 3), (35, 40, 55), dtype=np.uint8)
        cv2.rectangle(small_doc, (40, 40), (300, 380), (246, 246, 246), -1)
        warped_sm, info_sm = batch_scanner.detect_and_crop_with_info(small_doc)
        self.assertTrue(info_sm["detected"])
        self.assertAlmostEqual(warped_sm.shape[0], 340, delta=6)
        self.assertAlmostEqual(warped_sm.shape[1], 260, delta=6)

    def test_b5_vector_preserving_compression_and_target_budget(self):
        from pypdf import PdfWriter

        sys.path.insert(0, str(REPO_ROOT / "scripts"))
        import pdf_compressor  # noqa: E402

        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            # 1. Create a pure selectable vector/text page via macOS CoreGraphics
            vec_pdf = d / "vector_page.pdf"
            subprocess.run(
                ["swift", "-", str(vec_pdf)],
                input="""
import Foundation
import CoreGraphics
import CoreText
let out = URL(fileURLWithPath: CommandLine.arguments[1])
var box = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
let ctx = CGContext(out as CFURL, mediaBox: &box, nil)!
ctx.beginPDFPage(nil)
let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, "Vector Selectable Text B5 98765" as CFString, [kCTFontAttributeName: font] as CFDictionary)!)
ctx.textPosition = CGPoint(x: 72, y: 740)
CTLineDraw(line, ctx)
ctx.endPDFPage()
ctx.closePDF()
""",
                text=True,
                check=True,
            )

            # 2. Create a 300 DPI receipt-sized (4x6 in -> 288x432 pt) high-res scanned page
            rng = np.random.default_rng(11)
            scan_img = rng.integers(190, 255, (1800, 1200, 3), dtype=np.uint8)
            cv2.putText(scan_img, "RECEIPT B5", (100, 500), cv2.FONT_HERSHEY_SIMPLEX, 3.0, (25, 25, 25), 6)
            scan_jpg = d / "receipt_300dpi.jpg"
            Image.fromarray(scan_img).save(scan_jpg, quality=96)
            scan_pdf = d / "scan_page.pdf"
            batch_scanner.assemble_pdf_from_pages(
                [{"image_path": str(scan_jpg), "format": "jpeg", "width": 1200, "height": 1800, "color_space": "/DeviceRGB"}],
                str(scan_pdf),
                page_size="fit",
                dpi=300,
                margin=0.0,
            )

            mixed = d / "mixed.pdf"
            w = PdfWriter()
            w.append(str(vec_pdf))
            w.append(str(scan_pdf))
            with open(mixed, "wb") as fp:
                w.write(fp)

            out_ok = d / "compressed_ok.pdf"
            rep = pdf_compressor.compress_pdf(
                source_pdf=str(mixed),
                output_pdf=str(out_ok),
                dpi=150,
                jpeg_quality=80,
                target_mb=0.15,
            )
            self.assertEqual(rep["vector_pages"], 1)
            self.assertEqual(rep["image_pages"], 1)
            self.assertTrue(rep["target_achieved"])
            self.assertLessEqual(rep["after_bytes"], int(0.15 * 1024 * 1024))

            r_out = PdfReader(str(out_ok))
            self.assertIn("Vector Selectable Text B5 98765", r_out.pages[0].extract_text())
            self.assertAlmostEqual(float(r_out.pages[0].mediabox.width), 595.28, delta=0.5)
            self.assertAlmostEqual(float(r_out.pages[1].mediabox.width), 288.0, delta=0.5)
            self.assertAlmostEqual(float(r_out.pages[1].mediabox.height), 432.0, delta=0.5)

            # Impossible target on pure vector PDF returns target_achieved=False with message & intact vector text
            out_impossible = d / "impossible.pdf"
            rep2 = pdf_compressor.compress_pdf(
                source_pdf=str(vec_pdf),
                output_pdf=str(out_impossible),
                dpi=150,
                target_mb=0.0001,
            )
            self.assertFalse(rep2["target_achieved"])
            self.assertIn("Không thể nén nhỏ hơn", rep2["message"])
            self.assertIn("Vector Selectable Text B5 98765", PdfReader(str(out_impossible)).pages[0].extract_text())

    def test_a2_persistent_worker_stdio_and_a7_vector_warning(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            p1 = d / "p1.png"
            p2 = d / "p2.png"
            cv2.imwrite(str(p1), _make_doc_image(800, 1000, accent_bgr=(0, 0, 220)))
            cv2.imwrite(str(p2), _make_doc_image(800, 1000, accent_bgr=(220, 0, 0)))

            with subprocess.Popen(
                [sys.executable, str(REPO_ROOT / "scripts" / "batch_scanner.py"), "--worker-stdio"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                cwd=str(REPO_ROOT),
            ) as proc:
                assert proc.stdin and proc.stdout
                jobs = [
                    {"id": "ping", "cmd": "ping"},
                    {"id": "j1", "input": str(p1), "emit_dir": str(d / "e1"), "mode": "auto_color", "auto_crop": False},
                    {"id": "j2", "input": str(p2), "emit_dir": str(d / "e2"), "mode": "bw", "auto_crop": False},
                    {"id": "j_err", "input": str(d / "missing.png"), "emit_dir": str(d / "e3"), "auto_crop": False},
                    {"id": "quit", "cmd": "quit"},
                ]
                for job in jobs:
                    proc.stdin.write(json.dumps(job) + "\n")
                proc.stdin.flush()

                responses = [json.loads(proc.stdout.readline()) for _ in jobs]
                proc.wait(timeout=15)
                self.assertEqual(proc.returncode, 0)
            self.assertEqual(responses[0]["status"], "pong")
            self.assertEqual(responses[1]["status"], "ok")
            self.assertTrue(Path(responses[1]["output"]).exists())
            self.assertEqual(responses[2]["status"], "ok")
            self.assertTrue(responses[2]["output"].endswith(".png"))
            self.assertEqual(responses[3]["status"], "error")
            self.assertEqual(responses[4]["status"], "bye")

            # Q8: doc_scanner.swift grayscale mode outputs true 1-channel 'L' JPEG
            gs_emit = d / "gs_emit"
            sw = subprocess.run(
                [
                    "swift",
                    str(REPO_ROOT / "scripts" / "doc_scanner.swift"),
                    "--mode",
                    "grayscale",
                    "--no-crop",
                    "--emit-dir",
                    str(gs_emit),
                    str(p1),
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(sw.returncode, 0, sw.stderr)
            with Image.open(next(gs_emit.iterdir())) as im:
                self.assertEqual(im.mode, "L")

            # A7: vector-only PDF logs explicit warning instead of failing silently
            vec_pdf = d / "vec_only.pdf"
            from pypdf import PdfWriter as _PW

            pw = _PW()
            pg = pw.add_blank_page(width=200, height=200)
            from pypdf.generic import DictionaryObject as _DO, NameObject as _NO

            pg[_NO("/Resources")] = _DO({_NO("/Font"): _DO({_NO("/F1"): _DO()})})
            with open(vec_pdf, "wb") as fp:
                pw.write(fp)
            res_vec = _run_cli([str(vec_pdf), str(d / "vec_out.pdf"), "--no-crop"])
            self.assertNotEqual(res_vec.returncode, 0)
            self.assertIn("vector/text", res_vec.stderr)

    def test_p1_19_16bit_grayscale_and_pa_rgb_trns_transparency(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            # 16-bit grayscale PNG (I;16): dark ink 5000 on light paper 50000
            arr16 = np.full((120, 120), 50000, dtype=np.uint16)
            arr16[30:90, 30:90] = 5000
            g16_path = d / "gray16.png"
            cv2.imwrite(str(g16_path), arr16)
            bgr16 = batch_scanner.load_image_bgr(str(g16_path))
            self.assertEqual(bgr16.dtype, np.uint8)
            self.assertLess(int(bgr16[60, 60].mean()), 35)
            self.assertGreater(int(bgr16[5, 5].mean()), 175)
            self.assertLess(int(bgr16[5, 5].mean()), 215)

            # I;16B big-endian and 32-bit 'I' mode scaling
            raw_be = np.array([[5000, 50000]], dtype=">u2").tobytes()
            im_be = Image.frombytes("I;16B", (2, 1), raw_be)
            bgr_be = batch_scanner._pil_to_bgr(im_be)
            self.assertEqual(bgr_be[0, 0].tolist(), [19, 19, 19])
            self.assertEqual(bgr_be[0, 1].tolist(), [195, 195, 195])

            im_i = Image.fromarray(np.array([[5000, 50000]], dtype=np.int32), mode="I")
            bgr_i = batch_scanner._pil_to_bgr(im_i)
            self.assertEqual(bgr_i[0, 0].tolist(), [19, 19, 19])
            self.assertEqual(bgr_i[0, 1].tolist(), [195, 195, 195])

            # PA mode transparent corners must flatten onto white (255, 255, 255)
            pa_src = Image.new("RGBA", (80, 80), (0, 0, 0, 0))
            for y in range(25, 55):
                for x in range(25, 55):
                    pa_src.putpixel((x, y), (20, 30, 180, 255))
            pa_img = pa_src.convert("PA")
            bgr_pa = batch_scanner._pil_to_bgr(pa_img)
            self.assertEqual(bgr_pa[5, 5].tolist(), [255, 255, 255])
            self.assertGreater(int(bgr_pa[40, 40][0]), 150)  # Blue pixel in BGR

            # RGB+tRNS PNG transparent corners must flatten onto white (255, 255, 255)
            rgb_trns = Image.new("RGB", (80, 80), (0, 0, 0))
            for y in range(25, 55):
                for x in range(25, 55):
                    rgb_trns.putpixel((x, y), (180, 20, 20))
            trns_path = d / "rgb_trns.png"
            rgb_trns.save(trns_path, format="PNG", transparency=(0, 0, 0))
            bgr_trns = batch_scanner.load_image_bgr(str(trns_path))
            self.assertEqual(bgr_trns[5, 5].tolist(), [255, 255, 255])
            self.assertGreater(int(bgr_trns[40, 40][2]), 150)

            # L+tRNS PNG transparent corners must flatten onto white (255, 255, 255)
            l_trns = Image.new("L", (80, 80), 0)
            for y in range(25, 55):
                for x in range(25, 55):
                    l_trns.putpixel((x, y), 100)
            l_path = d / "l_trns.png"
            l_trns.save(l_path, format="PNG", transparency=0)
            bgr_l = batch_scanner.load_image_bgr(str(l_path))
            self.assertEqual(bgr_l[5, 5].tolist(), [255, 255, 255])
            self.assertEqual(bgr_l[40, 40].tolist(), [100, 100, 100])

    def test_p1_3_unicode_nfc_nfd_vision_manifest_lookup(self):
        import unicodedata
        from unittest import mock

        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            nfc_name = unicodedata.normalize("NFC", 'ngày 2.11 "quote".png')
            nfd_name = unicodedata.normalize("NFD", 'ngày 2.11 "quote".png')
            self.assertNotEqual(nfc_name, nfd_name)

            img = _make_doc_image(900, 1200, with_border=True)
            img_path = d / nfc_name
            cv2.imwrite(str(img_path), img)

            # 1. Helper normalizes both NFC and NFD variants to the same NFC string
            canon_nfc = batch_scanner._canonical_path(str(d / nfc_name))
            canon_nfd = batch_scanner._canonical_path(str(d / nfd_name))
            self.assertEqual(canon_nfc, canon_nfd)
            self.assertEqual(canon_nfc, unicodedata.normalize("NFC", canon_nfc))

            # 2. crop_via_vision normalizes NFD paths in manifest results to NFC keys
            v_manifest = d / "vision_manifest.json"
            v_manifest.write_text(
                json.dumps(
                    {
                        "results": [
                            {
                                "input": os.path.realpath(str(d / nfd_name)),
                                "status": "ok",
                                "detected": True,
                                "method": "document_segmentation",
                                "confidence": 0.97,
                                "width": 900,
                                "height": 1200,
                                "quad": [[108, 120], [792, 120], [792, 1080], [108, 1080]],
                            }
                        ]
                    },
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
            with mock.patch("batch_scanner.subprocess.run") as m_run:
                m_run.return_value = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")
                v_map = batch_scanner.crop_via_vision([canon_nfc], ["echo"], 0.45, False, d)
            self.assertIn(canon_nfc, v_map)
            self.assertEqual(v_map[canon_nfc]["method"], "document_segmentation")

            # 3. Real end-to-end CLI run with --crop-engine vision on Vietnamese NFC file
            out_pdf = d / "vn_vision.pdf"
            out_man = d / "vn_manifest.json"
            proc = _run_cli(
                [
                    str(d),
                    str(out_pdf),
                    "--crop-engine",
                    "vision",
                    "--mode",
                    "original",
                    "--manifest",
                    str(out_man),
                ]
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            m = json.loads(out_man.read_text(encoding="utf-8"))
            self.assertEqual(len(m["results"]), 1)
            self.assertTrue(
                m["results"][0]["method"].startswith("vision:"),
                f"Expected vision crop match, got: {m['results'][0]}",
            )
            self.assertEqual(m["results"][0]["input"], unicodedata.normalize("NFC", m["results"][0]["input"]))

    def test_p1_6_symlink_safe_atomic_writes(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            victim = d / "victim.txt"
            victim.write_text("DO NOT TOUCH", encoding="utf-8")

            in_dir = d / "in"
            in_dir.mkdir()
            cv2.imwrite(str(in_dir / "p1.png"), _make_doc_image(700, 900))

            manifest_path = d / "manifest.json"
            out_pdf = d / "out.pdf"
            (d / "manifest.json.tmp").symlink_to(victim)
            (d / f"out.pdf.tmp.{os.getpid()}").symlink_to(victim)

            proc = _run_cli(
                [
                    str(in_dir),
                    str(out_pdf),
                    "--no-crop",
                    "--crop-engine",
                    "opencv",
                    "--manifest",
                    str(manifest_path),
                ]
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(victim.read_text(encoding="utf-8"), "DO NOT TOUCH")
            self.assertTrue(manifest_path.exists())
            self.assertTrue(out_pdf.exists())

            # Same-PID in-process batch_scanner symlink trap check
            inproc_pdf = d / "out_inproc.pdf"
            inproc_man = d / "man_inproc.json"
            (d / "man_inproc.json.tmp").symlink_to(victim)
            (d / f"out_inproc.pdf.tmp.{os.getpid()}").symlink_to(victim)
            ok = batch_scanner.convert_folder_to_hd_pdf(
                input_path=str(in_dir),
                output_pdf_path=str(inproc_pdf),
                auto_crop=False,
                crop_engine="opencv",
                manifest_path=str(inproc_man),
            )
            self.assertTrue(ok)
            self.assertEqual(victim.read_text(encoding="utf-8"), "DO NOT TOUCH")

            # Compressor symlink trap check
            comp_pdf = d / "comp.pdf"
            (d / f"comp.pdf.tmp.{os.getpid()}").symlink_to(victim)
            rep = pdf_compressor.compress_pdf(str(out_pdf), str(comp_pdf), dpi=150)
            self.assertEqual(victim.read_text(encoding="utf-8"), "DO NOT TOUCH")
            self.assertGreater(rep["after_bytes"], 0)

    def test_p1_20_compressor_autocrop_rotate_inplace_and_search(self):
        import io
        from pypdf import PageObject, PdfWriter
        from pypdf.generic import DecodedStreamObject, DictionaryObject, EncodedStreamObject, NameObject, NumberObject

        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)

            # 20a: auto_crop=True on portrait 2000x3000 containing landscape 1600x1000 document
            canvas = np.full((3000, 2000, 3), (30, 35, 45), dtype=np.uint8)
            canvas[1000:2000, 200:1800] = (242, 242, 242)
            cv2.rectangle(canvas, (260, 1060), (1740, 1940), (35, 35, 35), 4)
            buf_a = io.BytesIO()
            Image.fromarray(cv2.cvtColor(canvas, cv2.COLOR_BGR2RGB)).save(buf_a, format="JPEG", quality=92)
            w_a = PdfWriter()
            pg_a = PageObject.create_blank_page(width=595.28, height=841.89)
            x_a = EncodedStreamObject()
            x_a.update(
                {
                    NameObject("/Type"): NameObject("/XObject"),
                    NameObject("/Subtype"): NameObject("/Image"),
                    NameObject("/Width"): NumberObject(2000),
                    NameObject("/Height"): NumberObject(3000),
                    NameObject("/ColorSpace"): NameObject("/DeviceRGB"),
                    NameObject("/BitsPerComponent"): NumberObject(8),
                    NameObject("/Filter"): NameObject("/DCTDecode"),
                }
            )
            x_a._data = buf_a.getvalue()
            pg_a[NameObject("/Resources")] = DictionaryObject(
                {NameObject("/XObject"): DictionaryObject({NameObject("/Im0"): w_a._add_object(x_a)})}
            )
            cs_a = DecodedStreamObject()
            cs_a.set_data(b"q 595.28 0 0 841.89 0 0 cm /Im0 Do Q")
            pg_a[NameObject("/Contents")] = w_a._add_object(cs_a)
            w_a.add_page(pg_a)
            in_a = d / "autocrop.pdf"
            out_a = d / "autocrop_out.pdf"
            with open(in_a, "wb") as fp:
                w_a.write(fp)
            pdf_compressor.compress_pdf(str(in_a), str(out_a), dpi=150, auto_crop=True)
            out_w_a, out_h_a = PdfReader(str(out_a)).pages[0].images[0].image.size
            self.assertGreater(out_w_a, out_h_a, f"Cropped landscape doc stretched to portrait: {(out_w_a, out_h_a)}")
            self.assertAlmostEqual(out_w_a / float(out_h_a), 1.6, delta=0.08)
            self.assertLessEqual(out_w_a, 1600)
            self.assertLessEqual(out_h_a, 1000)

            # 20b: /Rotate 90 + rotated CTM at exact 150 DPI must NOT over-downscale
            rot_arr = _make_doc_image(1754, 1240)
            buf_b = io.BytesIO()
            Image.fromarray(cv2.cvtColor(rot_arr, cv2.COLOR_BGR2RGB)).save(buf_b, format="JPEG", quality=92)
            w_b = PdfWriter()
            pg_b = PageObject.create_blank_page(width=595.28, height=841.89)
            pg_b[NameObject("/Rotate")] = NumberObject(90)
            x_b = EncodedStreamObject()
            x_b.update(
                {
                    NameObject("/Type"): NameObject("/XObject"),
                    NameObject("/Subtype"): NameObject("/Image"),
                    NameObject("/Width"): NumberObject(1754),
                    NameObject("/Height"): NumberObject(1240),
                    NameObject("/ColorSpace"): NameObject("/DeviceRGB"),
                    NameObject("/BitsPerComponent"): NumberObject(8),
                    NameObject("/Filter"): NameObject("/DCTDecode"),
                }
            )
            x_b._data = buf_b.getvalue()
            pg_b[NameObject("/Resources")] = DictionaryObject(
                {NameObject("/XObject"): DictionaryObject({NameObject("/Im0"): w_b._add_object(x_b)})}
            )
            cs_b = DecodedStreamObject()
            cs_b.set_data(b"q 0 841.89 -595.28 0 595.28 0 cm /Im0 Do Q")
            pg_b[NameObject("/Contents")] = w_b._add_object(cs_b)
            w_b.add_page(pg_b)
            in_b = d / "rot90.pdf"
            out_b = d / "rot90_out.pdf"
            with open(in_b, "wb") as fp:
                w_b.write(fp)
            pdf_compressor.compress_pdf(str(in_b), str(out_b), dpi=150)
            self.assertEqual(PdfReader(str(out_b)).pages[0].images[0].image.size, (1754, 1240))

            # Also test /Rotate 270 without ContentStream CTM (fallback page_size_inches swap)
            w_b2 = PdfWriter()
            pg_b2 = PageObject.create_blank_page(width=595.28, height=841.89)
            pg_b2[NameObject("/Rotate")] = NumberObject(270)
            x_b2 = EncodedStreamObject()
            x_b2.update(dict(x_b))
            x_b2._data = buf_b.getvalue()
            pg_b2[NameObject("/Resources")] = DictionaryObject(
                {NameObject("/XObject"): DictionaryObject({NameObject("/Im0"): w_b2._add_object(x_b2)})}
            )
            w_b2.add_page(pg_b2)
            in_b2 = d / "rot270_noctm.pdf"
            out_b2 = d / "rot270_noctm_out.pdf"
            with open(in_b2, "wb") as fp:
                w_b2.write(fp)
            pdf_compressor.compress_pdf(str(in_b2), str(out_b2), dpi=150)
            self.assertEqual(PdfReader(str(out_b2)).pages[0].images[0].image.size, (1754, 1240))

            # 20c & 20d: Noisy 1800x2400 PDF for in-place equivalence + non-monotonic search + dpi<=base_dpi clamp
            rng = np.random.default_rng(7)
            noisy = rng.integers(80, 240, (2400, 1800, 3), dtype=np.uint8)
            noisy_jpg = d / "noisy.jpg"
            Image.fromarray(noisy).save(noisy_jpg, format="JPEG", quality=96)
            in_c = d / "noisy.pdf"
            batch_scanner.assemble_pdf_from_pages(
                [{"image_path": str(noisy_jpg), "format": "jpeg", "width": 1800, "height": 2400, "color_space": "/DeviceRGB"}],
                str(in_c),
                page_size="a4",
                dpi=300,
                margin=0.0,
            )

            # Check in-place vs separate output equivalence when target search triggers
            out_clean = d / "clean_target.pdf"
            in_place = d / "inplace_target.pdf"
            in_place.write_bytes(in_c.read_bytes())
            r_init = pdf_compressor.compress_pdf(str(in_c), str(d / "init_probe.pdf"), dpi=150, jpeg_quality=80)
            # Pick target slightly below initial Q=80 size to force target-budget search
            target_mb_c = (r_init["after_bytes"] - 2048) / (1024.0 * 1024.0)
            rep_clean = pdf_compressor.compress_pdf(str(in_c), str(out_clean), dpi=150, jpeg_quality=80, target_mb=target_mb_c)
            rep_inplace = pdf_compressor.compress_pdf(str(in_place), str(in_place), dpi=150, jpeg_quality=80, target_mb=target_mb_c)
            self.assertEqual(rep_clean["used_dpi"], rep_inplace["used_dpi"])
            self.assertEqual(rep_clean["used_quality"], rep_inplace["used_quality"])
            self.assertEqual(rep_clean["after_bytes"], rep_inplace["after_bytes"])

            # 20d: Measure (125, 35) vs (100, 75) non-monotonicity and assert (125, 35) is NOT skipped
            r_125_35 = pdf_compressor.compress_pdf(str(in_c), str(d / "p125_35.pdf"), dpi=125, jpeg_quality=35)
            r_100_75 = pdf_compressor.compress_pdf(str(in_c), str(d / "p100_75.pdf"), dpi=100, jpeg_quality=75)
            if r_125_35["after_bytes"] < r_100_75["after_bytes"]:
                budget_bytes = (r_125_35["after_bytes"] + r_100_75["after_bytes"]) // 2
                rep_mono = pdf_compressor.compress_pdf(
                    str(in_c),
                    str(d / "mono_out.pdf"),
                    dpi=125,
                    jpeg_quality=80,
                    target_mb=budget_bytes / (1024.0 * 1024.0),
                )
                self.assertEqual(rep_mono["used_dpi"], 125)
                self.assertTrue(rep_mono["target_achieved"])

            # Clamp candidate DPIs strictly <= base_dpi (base_dpi=72 must never jump to 85)
            rep_72 = pdf_compressor.compress_pdf(
                str(in_c),
                str(d / "clamp72.pdf"),
                dpi=72,
                jpeg_quality=80,
                target_mb=0.001,
            )
            self.assertLessEqual(rep_72["used_dpi"], 72)

    def test_p2_compressor_bw_multiimage_bloat_and_error_json(self):
        import io
        from pypdf import PageObject, PdfWriter
        from pypdf.generic import DecodedStreamObject, DictionaryObject, EncodedStreamObject, NameObject, NumberObject

        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)

            # 1. mode="bw" produces 1-bit /FlateDecode /DeviceGray stream (no JPEG bloat)
            doc_img = _make_doc_image(1200, 1600)
            src_jpg = d / "doc.jpg"
            Image.fromarray(cv2.cvtColor(doc_img, cv2.COLOR_BGR2RGB)).save(src_jpg, quality=92)
            src_pdf = d / "doc.pdf"
            batch_scanner.assemble_pdf_from_pages(
                [{"image_path": str(src_jpg), "format": "jpeg", "width": 1200, "height": 1600, "color_space": "/DeviceRGB"}],
                str(src_pdf),
                page_size="a4",
                dpi=200,
                margin=0.0,
            )
            bw_pdf = d / "doc_bw.pdf"
            gray_pdf = d / "doc_gray.pdf"
            pdf_compressor.compress_pdf(str(src_pdf), str(bw_pdf), dpi=150, mode="bw")
            pdf_compressor.compress_pdf(str(src_pdf), str(gray_pdf), dpi=150, mode="grayscale")
            bw_xobj = next(iter(PdfReader(str(bw_pdf)).pages[0]["/Resources"]["/XObject"].values())).get_object()
            self.assertEqual(int(bw_xobj["/BitsPerComponent"]), 1)
            self.assertEqual(str(bw_xobj["/Filter"]), "/FlateDecode")
            self.assertEqual(str(bw_xobj["/ColorSpace"]), "/DeviceGray")
            self.assertLess(bw_pdf.stat().st_size, gray_pdf.stat().st_size)

            # 2. Font page with multiple 500x500 JPEGs (sum_px = 6 * 250k >= 300k) must recompress all 6
            w_multi = PdfWriter()
            pg_m = PageObject.create_blank_page(width=595.28, height=841.89)
            pg_m[NameObject("/Resources")] = DictionaryObject(
                {
                    NameObject("/Font"): DictionaryObject({NameObject("/F1"): DictionaryObject()}),
                    NameObject("/XObject"): DictionaryObject(),
                }
            )
            for idx in range(6):
                tile = np.random.default_rng(idx).integers(100, 240, (500, 500, 3), dtype=np.uint8)
                tbuf = io.BytesIO()
                Image.fromarray(tile).save(tbuf, format="JPEG", quality=98)
                xo = EncodedStreamObject()
                xo.update(
                    {
                        NameObject("/Type"): NameObject("/XObject"),
                        NameObject("/Subtype"): NameObject("/Image"),
                        NameObject("/Width"): NumberObject(500),
                        NameObject("/Height"): NumberObject(500),
                        NameObject("/ColorSpace"): NameObject("/DeviceRGB"),
                        NameObject("/BitsPerComponent"): NumberObject(8),
                        NameObject("/Filter"): NameObject("/DCTDecode"),
                    }
                )
                xo._data = tbuf.getvalue()
                pg_m["/Resources"]["/XObject"][NameObject(f"/Im{idx}")] = w_multi._add_object(xo)
            w_multi.add_page(pg_m)
            multi_pdf = d / "multi.pdf"
            multi_out = d / "multi_out.pdf"
            with open(multi_pdf, "wb") as fp:
                w_multi.write(fp)
            rep_multi = pdf_compressor.compress_pdf(str(multi_pdf), str(multi_out), dpi=150, jpeg_quality=60)
            self.assertEqual(rep_multi["recompressed_images"], 6)
            self.assertLess(rep_multi["after_bytes"], rep_multi["before_bytes"])

            # 3. Bloat guard under non-forced compress (original, auto_crop=False)
            tiny_arr = np.full((300, 300, 3), 230, dtype=np.uint8)
            tiny_jpg = d / "tiny_q30.jpg"
            Image.fromarray(tiny_arr).save(tiny_jpg, format="JPEG", quality=30)
            tiny_pdf = d / "tiny.pdf"
            batch_scanner.assemble_pdf_from_pages(
                [{"image_path": str(tiny_jpg), "format": "jpeg", "width": 300, "height": 300, "color_space": "/DeviceRGB"}],
                str(tiny_pdf),
                page_size="a4",
                dpi=200,
                margin=0.0,
            )
            tiny_out = d / "tiny_out.pdf"
            rep_bloat = pdf_compressor.compress_pdf(str(tiny_pdf), str(tiny_out), dpi=150, jpeg_quality=95)
            self.assertLessEqual(rep_bloat["after_bytes"], rep_bloat["before_bytes"])

            # 4. Target unmet message uses MiB consistently (no "0.0 MB")
            rep_unmet = pdf_compressor.compress_pdf(str(tiny_pdf), str(d / "unmet.pdf"), dpi=150, target_mb=0.001)
            self.assertFalse(rep_unmet["target_achieved"])
            self.assertIn("MiB", rep_unmet["message"])
            self.assertNotIn("0.0 MB", rep_unmet["message"])

            # 5. Corrupt, encrypted, and missing PDFs write valid --json-report, clean stderr (no Traceback), exit 1
            corrupt_pdf = d / "corrupt.pdf"
            corrupt_pdf.write_bytes(b"not a pdf")
            enc_pdf = d / "encrypted.pdf"
            ew = PdfWriter()
            ew.add_blank_page(200, 200)
            ew.encrypt("secret123")
            with open(enc_pdf, "wb") as fp:
                ew.write(fp)
            missing_pdf = d / "missing.pdf"

            for case_name, src in [("corrupt", corrupt_pdf), ("encrypted", enc_pdf), ("missing", missing_pdf)]:
                jrep = d / f"rep_{case_name}.json"
                proc = subprocess.run(
                    [
                        sys.executable,
                        str(REPO_ROOT / "scripts" / "pdf_compressor.py"),
                        str(src),
                        str(d / f"out_{case_name}.pdf"),
                        "--json-report",
                        str(jrep),
                    ],
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(proc.returncode, 1, proc.stderr)
                self.assertNotIn("Traceback", proc.stderr)
                self.assertTrue(jrep.exists(), f"{case_name} missing json report")
                jdata = json.loads(jrep.read_text(encoding="utf-8"))
                self.assertEqual(jdata.get("status"), "error")
                self.assertTrue(len(jdata.get("message", "")) > 0)

    def test_p2_worker_stdio_edge_cases_downscale_and_scan_to_pdf(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            dir_a = d / "dirA"
            dir_b = d / "dirB"
            dir_a.mkdir()
            dir_b.mkdir()
            shared_emit = d / "shared_emit"

            img_a = dir_a / "scan (2026) v1.png"
            img_b = dir_b / "scan (2026) v1.png"
            cv2.imwrite(str(img_a), _make_doc_image(700, 900, accent_bgr=(0, 0, 230)))
            cv2.imwrite(str(img_b), _make_doc_image(700, 900, accent_bgr=(230, 0, 0)))

            txt_file = d / "notes.txt"
            txt_file.write_text("not an image", encoding="utf-8")
            pdf_file = d / "sample.pdf"
            pdf_file.write_bytes(b"%PDF-1.4\n")

            with subprocess.Popen(
                [sys.executable, str(REPO_ROOT / "scripts" / "batch_scanner.py"), "--worker-stdio"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                cwd=str(d),
            ) as proc:
                assert proc.stdin and proc.stdout
                jobs = [
                    {"id": None, "cmd": "ping"},
                    {"id": "a", "input": str(img_a), "emit_dir": str(shared_emit), "mode": "original", "auto_crop": False},
                    {"id": "b", "input": str(img_b), "emit_dir": str(shared_emit), "mode": "original", "auto_crop": False},
                    {"id": None, "input": str(img_a), "emit_dir": None},
                    {"id": "miss", "input": str(d / "missing.png"), "emit_dir": str(shared_emit), "crop_engine": "vision"},
                    {"id": "pdf", "input": str(pdf_file), "emit_dir": str(shared_emit), "crop_engine": "vision"},
                    {"id": "txt", "input": str(txt_file), "emit_dir": str(shared_emit), "crop_engine": "vision"},
                    {"id": "quit", "cmd": "quit"},
                ]
                for job in jobs:
                    proc.stdin.write(json.dumps(job) + "\n")
                proc.stdin.flush()
                resps = [json.loads(proc.stdout.readline()) for _ in jobs]
                proc.wait(timeout=15)
                self.assertEqual(proc.returncode, 0)

            self.assertEqual(resps[0]["id"], "")
            self.assertEqual(resps[0]["status"], "pong")
            self.assertEqual(resps[1]["status"], "ok")
            self.assertEqual(resps[2]["status"], "ok")
            self.assertNotEqual(resps[1]["output"], resps[2]["output"])
            self.assertTrue(Path(resps[1]["output"]).exists())
            self.assertTrue(Path(resps[2]["output"]).exists())
            self.assertIn("2026", Path(resps[1]["output"]).name)  # Not truncated at " ("
            self.assertEqual(resps[3]["status"], "error")
            self.assertEqual(resps[3]["id"], "")
            self.assertFalse((d / "None").exists())
            for idx in (4, 5, 6):
                self.assertEqual(resps[idx]["status"], "error")
                self.assertNotIn("Vision helper", resps[idx]["message"])

            # Verify crop_via_vision is never invoked for missing, .pdf, or non-image inputs
            import io
            from unittest import mock

            in_lines = "\n".join(
                json.dumps(j)
                for j in [
                    {"id": "m", "input": str(d / "missing.png"), "emit_dir": str(shared_emit), "crop_engine": "vision"},
                    {"id": "p", "input": str(pdf_file), "emit_dir": str(shared_emit), "crop_engine": "vision"},
                    {"id": "t", "input": str(txt_file), "emit_dir": str(shared_emit), "crop_engine": "vision"},
                    {"id": "q", "cmd": "quit"},
                ]
            ) + "\n"
            fake_out = io.StringIO()
            with (
                mock.patch("batch_scanner.crop_via_vision") as m_vis,
                mock.patch("sys.stdin", io.StringIO(in_lines)),
                mock.patch("sys.stdout", fake_out),
            ):
                rc = batch_scanner.run_worker_stdio()
            self.assertEqual(rc, 0)
            m_vis.assert_not_called()

            # downscale_to_dpi clamps >= 72 and falls back unknown page_size -> a4
            tall = np.full((3000, 2200, 3), 240, dtype=np.uint8)
            ds_10 = batch_scanner.downscale_to_dpi(tall, "a4", dpi=10, margin=20.0)
            ds_72 = batch_scanner.downscale_to_dpi(tall, "a4", dpi=72, margin=20.0)
            self.assertEqual(ds_10.shape, ds_72.shape)
            ds_unk = batch_scanner.downscale_to_dpi(tall, "unknown_size", dpi=150, margin=20.0)
            ds_a4 = batch_scanner.downscale_to_dpi(tall, "a4", dpi=150, margin=20.0)
            self.assertEqual(ds_unk.shape, ds_a4.shape)

            # scan_to_pdf.process_image_to_scanned returns consistent '1' mode for bw regardless of auto_crop
            bw_doc = _make_doc_image(800, 1000, with_border=True)
            bw_src = d / "bw_src.png"
            cv2.imwrite(str(bw_src), bw_doc)
            im_nocrop = scan_to_pdf.process_image_to_scanned(str(bw_src), enhance_mode="bw", auto_crop=False)
            im_crop = scan_to_pdf.process_image_to_scanned(str(bw_src), enhance_mode="bw", auto_crop=True)
            self.assertEqual(im_nocrop.mode, "1")
            self.assertEqual(im_crop.mode, "1")

    def test_speed_opt_highres_flatten_symmetry_and_auto_workers(self):
        # 1. High-res (2057x1542) flat page -> fast pre-check skips cleanly (exact pixels preserved)
        flat = np.full((1542, 2057, 3), (252, 252, 252), dtype=np.uint8)
        for y in range(180, 1380, 110):
            cv2.line(flat, (160, y), (1890, y), (30, 30, 30), 2)
        self.assertTrue(np.array_equal(flat, batch_scanner.flatten_document_surface(flat)))

        # 2. High-res (2057x1542) curved + 2 deg skewed table -> pre-check enters full flatten and fixes curl
        curved = np.full((1542, 2057, 3), (252, 252, 252), dtype=np.uint8)
        xs = np.arange(160, 1890)
        for y0 in range(180, 1380, 110):
            ys = y0 + np.round(24.0 * np.sin(np.pi * (xs - 160) / 1730.0) + 0.035 * (xs - 1028)).astype(int)
            pts = np.stack([xs, ys], axis=1).reshape(-1, 1, 2)
            cv2.polylines(curved, [pts], False, (30, 30, 30), 2)
        rectified = batch_scanner.flatten_document_surface(curved)
        _, _, _, dy_after, *_ = batch_scanner._detect_surface_lines(cv2.cvtColor(rectified, cv2.COLOR_BGR2GRAY))
        self.assertLess(float(np.sqrt(np.mean(dy_after**2))), 1.5)

        # 3. High-res (2057x1542) shifted block + 3x3 dust speck -> downscaled balance_page_symmetry centers main content
        asym = np.full((1542, 2057, 3), (250, 250, 250), dtype=np.uint8)
        cv2.rectangle(asym, (140, 120), (1080, 920), (30, 30, 30), 4)
        for ry in range(180, 880, 60):
            cv2.line(asym, (180, ry), (1040, ry), (25, 25, 25), 4)
        asym[1515:1518, 2030:2033] = (15, 15, 15)
        centered = batch_scanner.balance_page_symmetry(asym)
        xs_c = np.where(cv2.cvtColor(centered, cv2.COLOR_BGR2GRAY) < 200)[1]
        self.assertLess(abs(int(xs_c.min()) - (2057 - int(xs_c.max()))), 25)

        # 4. High-res strip-only multipoint_border_mask_clean removes dark outer border without touching interior ink
        dirty = flat.copy()
        dirty[:30, :] = (40, 48, 60)
        dirty[-25:, :] = (40, 48, 60)
        dirty[:, :20] = (40, 48, 60)
        cleaned = batch_scanner.multipoint_border_mask_clean(dirty, points_per_edge=32)
        self.assertGreater(float(cleaned[8, 500].mean()), 180.0)
        self.assertGreater(float(cleaned[1530, 500].mean()), 180.0)
        self.assertGreater(float(cleaned[500, 8].mean()), 180.0)
        self.assertLess(float(cleaned[180, 500].mean()), 80.0)

        # 5. resolve_worker_count matrix & CLI --workers auto end-to-end smoke
        self.assertEqual(batch_scanner.resolve_worker_count(1, 10, sample_pixels=12_000_000), 1)
        self.assertEqual(batch_scanner.resolve_worker_count(4, 6, sample_pixels=12_000_000), 4)
        self.assertEqual(batch_scanner.resolve_worker_count(0, 6, sample_pixels=12_000_000), 1)
        self.assertEqual(batch_scanner.resolve_worker_count(0, 12, sample_pixels=500 * 500), 1)
        resolved_big = batch_scanner.resolve_worker_count(0, 12, sample_pixels=4032 * 3024)
        expected_big = min(4, max(1, (os.cpu_count() or 2) // 2))
        self.assertEqual(resolved_big, expected_big)

        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            in_dir = d / "in"
            in_dir.mkdir()
            doc = _make_doc_image(800, 1000, with_border=True)
            cv2.imwrite(str(in_dir / "p1.jpg"), doc)
            cv2.imwrite(str(in_dir / "p2.jpg"), doc)
            out_pdf = d / "auto_w.pdf"
            p = _run_cli([str(in_dir), str(out_pdf), "--crop-engine", "opencv", "--workers", "auto"])
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(len(PdfReader(str(out_pdf)).pages), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
