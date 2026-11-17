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
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import batch_scanner  # noqa: E402


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


if __name__ == "__main__":
    unittest.main(verbosity=2)
