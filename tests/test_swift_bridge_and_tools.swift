import AppKit
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

func assertTrue(_ cond: Bool, _ msg: String) {
    if !cond {
        fputs("[FAIL] \(msg)\n", stderr)
        exit(1)
    }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String) {
    if a != b {
        fputs("[FAIL] \(msg): expected \(b), got \(a)\n", stderr)
        exit(1)
    }
}

func assertApprox(_ a: Double, _ b: Double, tol: Double = 0.25, _ msg: String) {
    if abs(a - b) > tol {
        fputs("[FAIL] \(msg): expected \(b) ± \(tol), got \(a)\n", stderr)
        exit(1)
    }
}

func makeSyntheticImage(width: Int, height: Int, rgb: (CGFloat, CGFloat, CGFloat)) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(CGColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1.0))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // Draw dark lines and distinctive color block
    ctx.setFillColor(CGColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1.0))
    ctx.fill(CGRect(x: 40, y: height - 180, width: 220, height: 120))
    ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0))
    for y in stride(from: 80, to: height - 220, by: 60) {
        ctx.fill(CGRect(x: 60, y: y, width: width - 120, height: 4))
    }
    return ctx.makeImage()!
}

func saveImage(_ cg: CGImage, to url: URL, utType: UTType) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, utType.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, nil)
    let ok = CGImageDestinationFinalize(dest)
    assertTrue(ok, "Failed to save \(url.lastPathComponent)")
}

func saveWebPViaPython(_ cg: CGImage, to url: URL, tempDir: URL, pythonPath: String) {
    let tmpPng = tempDir.appendingPathComponent("tmp_webp_src.png")
    saveImage(cg, to: tmpPng, utType: .png)
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: pythonPath)
    proc.arguments = ["-c", "from PIL import Image; import sys; Image.open(sys.argv[1]).save(sys.argv[2], format='WEBP')", tmpPng.path, url.path]
    try! proc.run()
    proc.waitUntilExit()
    assertEqual(proc.terminationStatus, 0, "Failed to save WebP via Python Pillow")
    try? FileManager.default.removeItem(at: tmpPng)
}

func dominantChannel(ofImageAt url: URL) -> (r: Double, g: Double, b: Double) {
    let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    let w = cg.width
    let h = cg.height
    let cs = CGColorSpaceCreateDeviceRGB()
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(
        data: &buf,
        width: w,
        height: h,
        bitsPerComponent: 8,
        bytesPerRow: w * 4,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

    // Sample top-left marker region (y in 40..180 from top, x in 40..220)
    var sr = 0.0, sg = 0.0, sb = 0.0, count = 0.0
    for y in 60..<min(h, 150) {
        for x in 50..<min(w, 200) {
            let off = (y * w + x) * 4
            sr += Double(buf[off])
            sg += Double(buf[off + 1])
            sb += Double(buf[off + 2])
            count += 1.0
        }
    }
    return (sr / count, sg / count, sb / count)
}

@main
struct SwiftPhase1Tests {
    static func main() async {
        do {
            try await runAll()
            print("[PASS] All Swift Phase 1 unit & integration tests passed.")
            exit(0)
        } catch {
            fputs("[FAIL] Uncaught error: \(error)\n", stderr)
            exit(1)
        }
    }

    static func runAll() async throws {
        // 1. Unit tests: parsePageRanges, formatPairFileName, naturalCompare, uniqueURLIfExists
        assertEqual(try PDFToolsService.parsePageRanges("1-3, 5", totalPages: 6), [0, 1, 2, 4], "parsePageRanges 1-3, 5")
        assertEqual(try PDFToolsService.parsePageRanges("", totalPages: 3), [0, 1, 2], "parsePageRanges empty -> all")
        var threw = false
        do { _ = try PDFToolsService.parsePageRanges("3-1", totalPages: 5) } catch { threw = true }
        assertTrue(threw, "parsePageRanges invalid range should throw")

        assertEqual(PDFToolsService.formatPairFileName(pattern: "TaiLieu_xx", startIndex: 1, offset: 0), "TaiLieu_01.pdf", "formatPairFileName TaiLieu_xx")
        assertEqual(PDFToolsService.formatPairFileName(pattern: "Ngay_xx.11", startIndex: 5, offset: 2), "Ngay_07.11.pdf", "formatPairFileName Ngay_xx.11")
        assertEqual(PDFToolsService.formatPairFileName(pattern: "Doc.pdf", startIndex: 1, offset: 9), "Doc_10.pdf", "formatPairFileName Doc.pdf")

        let u2 = URL(fileURLWithPath: "/tmp/page2.jpg")
        let u10 = URL(fileURLWithPath: "/tmp/page10.jpg")
        assertTrue(PDFToolsService.naturalCompare(u2, u10), "naturalCompare page2 < page10")

        let fm = FileManager.default
        let tmpRoot = fm.temporaryDirectory.appendingPathComponent("pdfscanner_swift_test_\(UUID().uuidString)")
        try fm.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpRoot) }

        let existing = tmpRoot.appendingPathComponent("sample.pdf")
        try Data("x".utf8).write(to: existing)
        let unique = PDFToolsService.uniqueURLIfExists(existing)
        assertEqual(unique.lastPathComponent, "sample_1.pdf", "uniqueURLIfExists _1")

        // 2. B1 Staging test: mixed jpg, tif, webp, heic, png -> only jpg/png fast-copied, others converted to png
        let srcDir = tmpRoot.appendingPathComponent("mixed")
        let stageDir = tmpRoot.appendingPathComponent("stage")
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)

        let aURL = srcDir.appendingPathComponent("a.jpg")
        let bURL = srcDir.appendingPathComponent("b.tif")
        let cURL = srcDir.appendingPathComponent("c.webp")
        let dURL = srcDir.appendingPathComponent("d.heic")
        let eURL = srcDir.appendingPathComponent("e.png")

        let repoRoot = URL(fileURLWithPath: fm.currentDirectoryPath)
        setenv("PDF_SCANNER_ROOT", repoRoot.path, 1)
        let bridge = try ScannerBridge()

        saveImage(makeSyntheticImage(width: 800, height: 1100, rgb: (0.9, 0.05, 0.05)), to: aURL, utType: .jpeg)
        saveImage(makeSyntheticImage(width: 800, height: 1100, rgb: (0.05, 0.8, 0.05)), to: bURL, utType: .tiff)
        saveWebPViaPython(makeSyntheticImage(width: 800, height: 1100, rgb: (0.1, 0.4, 0.85)), to: cURL, tempDir: tmpRoot, pythonPath: bridge.pythonURL.path)
        saveImage(makeSyntheticImage(width: 800, height: 1100, rgb: (0.8, 0.5, 0.1)), to: dURL, utType: .heic)
        saveImage(makeSyntheticImage(width: 800, height: 1100, rgb: (0.05, 0.1, 0.9)), to: eURL, utType: .png)

        let items = PDFToolsService.loadInputItems(from: [srcDir])
        assertEqual(items.count, 5, "loadInputItems should load all 5 mixed formats")

        for (i, item) in items.enumerated() {
            let staged = try PDFToolsService.stageItemToImageFile(item: item, index: i, stagingDir: stageDir)
            let ext = staged.pathExtension.lowercased()
            assertTrue(["jpg", "jpeg", "png"].contains(ext), "staged format must be jpg/png, got \(ext) for \(item.displayName)")
        }

        // 3. B3 Single PDF Assembler & Cache consistency (uncached vs cached produce identical MediaBox)

        var settings = ScanSettings()
        settings.engine = .hybridOpenCV
        settings.mode = .autoColor
        settings.autoCrop = false
        settings.pageSize = .a4
        settings.dpi = 200
        settings.margin = 20.0

        let uncachedPDF = tmpRoot.appendingPathComponent("uncached_a4.pdf")
        let resUncached = try await bridge.runBatchScan(items: items, settings: settings, outputPDF: uncachedPDF) { _ in }
        assertEqual(resUncached.resolvedURLs.count, 5, "all 5 mixed pages should resolve")
        assertEqual(resUncached.errors.count, 0, "no errors expected on valid mixed formats")

        var cachedItems = items
        for idx in cachedItems.indices {
            cachedItems[idx].processedPreviewURL = resUncached.resolvedURLs[cachedItems[idx].id]
            cachedItems[idx].processedCacheKey = PDFToolsService.previewCacheKey(for: cachedItems[idx], settings: settings)
        }
        let cachedPDF = tmpRoot.appendingPathComponent("cached_a4.pdf")
        let resCached = try await bridge.runBatchScan(items: cachedItems, settings: settings, outputPDF: cachedPDF) { _ in }
        assertEqual(resCached.resolvedURLs.count, 5, "cached batch count == 5")

        let doc1 = PDFDocument(url: uncachedPDF)!
        let doc2 = PDFDocument(url: cachedPDF)!
        assertEqual(doc1.pageCount, 5, "uncached PDF pageCount")
        assertEqual(doc2.pageCount, 5, "cached PDF pageCount")
        for p in 0..<5 {
            let b1 = doc1.page(at: p)!.bounds(for: .mediaBox)
            let b2 = doc2.page(at: p)!.bounds(for: .mediaBox)
            assertApprox(Double(b1.width), 595.28, "uncached A4 width")
            assertApprox(Double(b1.height), 841.89, "uncached A4 height")
            assertApprox(Double(b1.width), Double(b2.width), "cached vs uncached width match")
            assertApprox(Double(b1.height), Double(b2.height), "cached vs uncached height match")
        }

        // Also test Letter and Fit
        settings.pageSize = .letter
        let letterPDF = tmpRoot.appendingPathComponent("letter.pdf")
        _ = try await bridge.runBatchScan(items: cachedItems, settings: settings, outputPDF: letterPDF) { _ in }
        let letterBox = PDFDocument(url: letterPDF)!.page(at: 0)!.bounds(for: .mediaBox)
        assertApprox(Double(letterBox.width), 612.0, "Letter width")
        assertApprox(Double(letterBox.height), 792.0, "Letter height")

        settings.pageSize = .fit
        settings.dpi = 150
        let fitPDF = tmpRoot.appendingPathComponent("fit.pdf")
        _ = try await bridge.runBatchScan(items: cachedItems, settings: settings, outputPDF: fitPDF) { _ in }
        let fitBox = PDFDocument(url: fitPDF)!.page(at: 0)!.bounds(for: .mediaBox)
        assertApprox(Double(fitBox.width), 800.0 * 72.0 / 150.0, "Fit width")
        assertApprox(Double(fitBox.height), 1100.0 * 72.0 / 150.0, "Fit height")

        // 4. B2 Corrupt image in middle of batch via ScannerBridge (both Hybrid and Pure Swift Vision)
        let corruptDir = tmpRoot.appendingPathComponent("corrupt_batch")
        try fm.createDirectory(at: corruptDir, withIntermediateDirectories: true)
        let redURL = corruptDir.appendingPathComponent("01_red.jpg")
        let badTifURL = corruptDir.appendingPathComponent("02_bad.tif")
        let badJpgURL = corruptDir.appendingPathComponent("03_bad.jpg")
        let blueURL = corruptDir.appendingPathComponent("04_blue.png")

        saveImage(makeSyntheticImage(width: 800, height: 1000, rgb: (0.95, 0.05, 0.05)), to: redURL, utType: .jpeg)
        try Data("not a valid tiff".utf8).write(to: badTifURL)
        try Data("not a valid jpg".utf8).write(to: badJpgURL)
        saveImage(makeSyntheticImage(width: 800, height: 1000, rgb: (0.05, 0.05, 0.95)), to: blueURL, utType: .png)

        let corruptItems = PDFToolsService.loadInputItems(from: [corruptDir])
        assertEqual(corruptItems.count, 4, "loadInputItems includes corrupt items by extension")

        for eng in [PipelineEngine.hybridOpenCV, PipelineEngine.pureSwiftVision] {
            var engSettings = ScanSettings()
            engSettings.engine = eng
            engSettings.mode = .original
            engSettings.autoCrop = false
            engSettings.pageSize = .a4

            let outURL = tmpRoot.appendingPathComponent("corrupt_\(eng.rawValue).pdf")
            let batchRes = try await bridge.runBatchScan(items: corruptItems, settings: engSettings, outputPDF: outURL) { _ in }
            assertEqual(batchRes.resolvedURLs.count, 2, "only 2 valid items resolved for \(eng.rawValue)")
            assertEqual(batchRes.errors.count, 2, "2 corrupt items errored for \(eng.rawValue)")
            assertTrue(batchRes.errors[corruptItems[1].id] != nil, "02_bad.tif has error")
            assertTrue(batchRes.errors[corruptItems[2].id] != nil, "03_bad.jpg has error")

            let p1 = dominantChannel(ofImageAt: batchRes.resolvedURLs[corruptItems[0].id]!)
            let p4 = dominantChannel(ofImageAt: batchRes.resolvedURLs[corruptItems[3].id]!)
            assertTrue(p1.r > p1.b + 80, "01_red kept red identity for \(eng.rawValue)")
            assertTrue(p4.b > p4.r + 80, "04_blue kept blue identity for \(eng.rawValue)")
            assertEqual(PDFDocument(url: outURL)?.pageCount ?? 0, 2, "output PDF has 2 valid pages")
        }

        // 5. A5 Cache Key Separation (layout changes do NOT invalidate enhance key; pixel changes DO)
        var sA4 = ScanSettings()
        sA4.pageSize = .a4
        sA4.margin = 20.0
        var sLetter = sA4
        sLetter.pageSize = .letter
        sLetter.margin = 48.0
        var sFit = sA4
        sFit.pageSize = .fit
        var sBW = sA4
        sBW.mode = .bw
        var sQ60 = sA4
        sQ60.jpegQuality = 60

        let sampleItem = corruptItems[0]
        let kA4 = PDFToolsService.previewCacheKey(for: sampleItem, settings: sA4)
        let kLetter = PDFToolsService.previewCacheKey(for: sampleItem, settings: sLetter)
        let kFit = PDFToolsService.previewCacheKey(for: sampleItem, settings: sFit)
        let kBW = PDFToolsService.previewCacheKey(for: sampleItem, settings: sBW)
        let kQ60 = PDFToolsService.previewCacheKey(for: sampleItem, settings: sQ60)
        var sA4OCR = sA4
        sA4OCR.enableOCR = true
        let kA4OCR = PDFToolsService.previewCacheKey(for: sampleItem, settings: sA4OCR)
        var sA4Margin = sA4
        sA4Margin.margin = 48.0
        let kA4Margin = PDFToolsService.previewCacheKey(for: sampleItem, settings: sA4Margin)

        assertEqual(kA4, kA4OCR, "Toggling enableOCR must keep same preview cache key")
        assertTrue(kA4 != kLetter, "Changing pageSize (A4 -> Letter) must change preview cache key")
        assertTrue(kA4 != kA4Margin, "Changing margin must change preview cache key")
        assertTrue(kA4 != kFit, "Switching to Fit must change cache key")
        assertTrue(kA4 != kBW, "Changing mode must change cache key")
        assertTrue(kA4 != kQ60, "Changing jpegQuality must change cache key")

        var rotatedItem = sampleItem
        rotatedItem.rotationDegrees = 90
        assertTrue(kA4 != PDFToolsService.previewCacheKey(for: rotatedItem, settings: sA4), "Rotation must change cache key")

        // 6. Q7 & Q11: PDF staging emits lossless PNG, and BW mode emits 1-bit PNG compiled into PDF
        let bwOutPDF = tmpRoot.appendingPathComponent("bw_out.pdf")
        let bwRes = try await bridge.runBatchScan(items: [sampleItem], settings: sBW, outputPDF: bwOutPDF) { _ in }
        let bwPreview = bwRes.resolvedURLs[sampleItem.id]!
        assertEqual(bwPreview.pathExtension.lowercased(), "png", "BW mode should emit PNG preview")
        assertEqual(PDFDocument(url: bwOutPDF)?.pageCount ?? 0, 1, "BW PDF compiles cleanly")

        assertEqual(sA4.balanceSymmetry, false, "Q3: balanceSymmetry must default to false")
        var sSym = sA4
        sSym.balanceSymmetry = true
        assertTrue(
            PDFToolsService.previewCacheKey(for: sampleItem, settings: sA4)
                != PDFToolsService.previewCacheKey(for: sampleItem, settings: sSym),
            "Toggling balanceSymmetry must change preview cache key"
        )

        let pdfStageItem = InputPageItem(sourceURL: bwOutPDF, pageIndexInPDF: 0, displayName: "p1")
        let pdfStaged = try PDFToolsService.stageItemToImageFile(item: pdfStageItem, index: 0, stagingDir: stageDir)
        assertEqual(pdfStaged.pathExtension.lowercased(), "png", "PDF page staging must emit lossless PNG")

        // 7. A1 Preflight check & A2 Persistent Python worker single-page preview
        let preflight = bridge.runPreflightCheck()
        assertTrue(preflight.isHealthy, "A1 preflight check must succeed in repo environment: \(preflight.summary)")
        assertTrue(!preflight.opencvVersion.isEmpty, "Preflight must report OpenCV version")

        var prevSettings = ScanSettings()
        prevSettings.engine = .hybridOpenCV
        prevSettings.mode = .autoColor
        prevSettings.autoCrop = false
        let prev1 = try await bridge.previewSinglePage(item: corruptItems[0], settings: prevSettings) { _ in }
        let prev2 = try await bridge.previewSinglePage(item: corruptItems[3], settings: prevSettings) { _ in }
        assertTrue(fm.fileExists(atPath: prev1.path), "A2 persistent worker preview 1 exists")
        assertTrue(fm.fileExists(atPath: prev2.path), "A2 persistent worker preview 2 exists")

        // 8. Q9 Optional Invisible Vision OCR Text Layer + Q10 Shared OCR Cache
        assertEqual(ScanSettings().enableOCR, false, "Q9: enableOCR must default to false")
        let ocrImgURL = tmpRoot.appendingPathComponent("ocr_sample.png")
        try makeOCRTestImage(text: "PDFSCANNER PHASE4 OCR TEST 2026", to: ocrImgURL)
        let ocrItem = InputPageItem(sourceURL: ocrImgURL, displayName: "ocr_sample.png")
        let detectedOrient = await PDFToolsService.detectReadingOrientationDegreesAsync(for: ocrItem, cacheAccurateOCR: true)
        assertEqual(detectedOrient, 0, "Upright synthetic OCR image detects 0 deg orientation")
        let sharedCacheKey = PDFToolsService.ocrCacheKey(for: ocrImgURL, pageIndex: nil, rotationDegrees: 0)
        let cachedLines = PDFToolsService.cachedOCRTextLines(forKey: sharedCacheKey)
        assertTrue((cachedLines?.isEmpty == false), "Q10+Q9: detectReadingOrientation with cacheAccurateOCR=true populates OCR cache")

        var ocrSettings = ScanSettings()
        ocrSettings.autoCrop = false
        ocrSettings.enableOCR = true
        let ocrPDF = tmpRoot.appendingPathComponent("ocr_out.pdf")
        try PDFToolsService.compileProcessedImagesToPDF(
            imageURLs: [ocrImgURL],
            destinationURL: ocrPDF,
            settings: ocrSettings,
            sourceItems: [ocrItem]
        )
        let extractedText = PDFDocument(url: ocrPDF)?.page(at: 0)?.string ?? ""
        assertTrue(extractedText.contains("PDFSCANNER") || extractedText.contains("2026"), "Q9 exported PDF must embed searchable OCR text (got: '\(extractedText)')")

        // 9. B5 Vector-preserving PDF compression via ScannerBridge
        let vecPDF = tmpRoot.appendingPathComponent("b5_vec.pdf")
        try makeVectorTextPDF(text: "Vector Bridge Preservation 54321", to: vecPDF)
        let vecCompOut = tmpRoot.appendingPathComponent("b5_comp.pdf")
        let compRes = try await bridge.compressPDF(sourcePDF: vecPDF, outputPDF: vecCompOut, dpi: 150, jpegQuality: 80, targetMB: 0.0) { _ in }
        assertEqual(compRes.vectorPagesPreserved, 1, "B5 must classify and preserve vector page")
        let compText = PDFDocument(url: vecCompOut)?.page(at: 0)?.string ?? ""
        assertTrue(compText.contains("Vector Bridge Preservation 54321"), "B5 vector text remains selectable after compression")

        // 10. Q10 Reading Orientation Regression (0/90/180/270, Vietnamese, single-line, skew, cache invariant)
        let orientSuites: [(String, [String], CGFloat)] = [
            ("vn_multi", ["CỘNG HÒA XÃ HỘI CHỦ NGHĨA VIỆT NAM", "Biểu mẫu kiểm tra vệ sinh cửa hàng", "Ngày kiểm tra: 17/11/2026"], 0.0),
            ("vn_single", ["HỢP ĐỒNG LAO ĐỘNG"], 0.0),
            ("en_single", ["INVOICE SUMMARY 2026"], 0.0),
            ("skew_text", ["Báo cáo doanh thu tháng 11", "Tổng thu: 125.000.000 VND"], 0.14),
        ]
        for (name, lines, skew) in orientSuites {
            let baseCG = try makeOCRTextCGImage(lines: lines, skewRadians: skew)
            let preds = try [0, 90, 180, 270].map { rotCW -> Int in
                let rotatedCG = try rotateCGImageCW(baseCG, degrees: rotCW)
                return PDFToolsService.detectReadingOrientationDegrees(from: rotatedCG)
            }
            assertEqual(preds, [0, 270, 180, 90], "Q10 \(name) 4-rotation invariance failed (got \(preds))")
        }

        // Verify rotated file InputPageItem returns 270 CW fix, does not cache unrotated boxes, and reads 0 after applying fix
        let cg90 = try rotateCGImageCW(makeOCRTextCGImage(lines: ["CỘNG HÒA XÃ HỘI CHỦ NGHĨA VIỆT NAM", "Biên bản bàn giao hồ sơ"]), degrees: 90)
        let img90URL = tmpRoot.appendingPathComponent("orient_90.png")
        saveImage(cg90, to: img90URL, utType: .png)
        let item90 = InputPageItem(sourceURL: img90URL, displayName: "orient_90.png")
        let fix90 = await PDFToolsService.detectReadingOrientationDegreesAsync(for: item90, cacheAccurateOCR: true)
        assertEqual(fix90, 270, "Q10 90-CW image must request 270 CW correction")
        let uncachedRotatedKey = PDFToolsService.ocrCacheKey(for: img90URL, pageIndex: nil, rotationDegrees: 270)
        assertTrue(PDFToolsService.cachedOCRTextLines(forKey: uncachedRotatedKey) == nil, "Q10 must not cache pre-rotation OCR boxes under rotated key")
        let itemFixed = InputPageItem(sourceURL: img90URL, displayName: "orient_90.png", rotationDegrees: 270)
        assertEqual(PDFToolsService.detectReadingOrientationDegrees(for: itemFixed), 0, "Q10 corrected item must verify as 0 deg upright")

        // Real multi-page scan regression check when repo fixture exists locally
        let matsauURL = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("input/matsau.pdf")
        if fm.fileExists(atPath: matsauURL.path) {
            let expectedPages: [(Int, Int)] = [(0, 0), (1, 270), (2, 90), (3, 270), (4, 90), (10, 270), (16, 270)]
            for (pIdx, expDeg) in expectedPages {
                let it = InputPageItem(sourceURL: matsauURL, pageIndexInPDF: pIdx, displayName: "matsau_p\(pIdx + 1)")
                let got = PDFToolsService.detectReadingOrientationDegrees(for: it, cacheAccurateOCR: false)
                assertEqual(got, expDeg, "Q10 matsau.pdf page \(pIdx + 1) orientation mismatch")
                if got != 0 {
                    let fixed = InputPageItem(sourceURL: matsauURL, pageIndexInPDF: pIdx, displayName: "matsau_p\(pIdx + 1)", rotationDegrees: got)
                    assertEqual(PDFToolsService.detectReadingOrientationDegrees(for: fixed), 0, "Q10 matsau.pdf page \(pIdx + 1) must be 0 after +\(got) deg")
                }
            }
        }

        // 11. Sprint 1/2 P0 & P1 & P2 Regression Tests
        try await runSprint1RegressionTests(tmpRoot: tmpRoot, repoRoot: repoRoot, bridge: bridge)
    }

    static func runSprint1RegressionTests(tmpRoot: URL, repoRoot: URL, bridge: ScannerBridge) async throws {
        let fm = FileManager.default

        // 11a. [P1-4 + P2] formatPairFileName path traversal, Unicode \p{L} boundary, startIndex >= 1, containment
        assertEqual(PDFToolsService.formatPairFileName(pattern: "../../escaped_xx", startIndex: 1, offset: 0), "escaped_01.pdf", "P1-4 strip ../ traversal")
        assertEqual(PDFToolsService.formatPairFileName(pattern: "../..", startIndex: 1, offset: 0), "page_01.pdf", "P1-4 bare .. fallback")
        assertEqual(PDFToolsService.formatPairFileName(pattern: "a\\b\\c_xx", startIndex: -5, offset: 0), "c_01.pdf", "P1-4 backslash + negative startIndex clamp")
        assertEqual(PDFToolsService.formatPairFileName(pattern: "xác_nhận", startIndex: 1, offset: 0), "xác_nhận_01.pdf", "P2 Unicode letter boundary keeps xác_nhận intact")
        assertEqual(PDFToolsService.formatPairFileName(pattern: "xa\u{0301}c_nha\u{0323}\u{0302}n_xx", startIndex: 2, offset: 0), "xác_nhận_02.pdf", "P2 NFD Vietnamese pattern preserves word and matches xx")

        let pairParent = tmpRoot.appendingPathComponent("pair_containment")
        let pairDest = pairParent.appendingPathComponent("nested")
        try fm.createDirectory(at: pairDest, withIntermediateDirectories: true)
        let frontImg = pairParent.appendingPathComponent("front.png")
        let backImg = pairParent.appendingPathComponent("back.png")
        saveImage(makeSyntheticImage(width: 400, height: 600, rgb: (0.2, 0.2, 0.8)), to: frontImg, utType: .png)
        saveImage(makeSyntheticImage(width: 400, height: 600, rgb: (0.8, 0.2, 0.2)), to: backImg, utType: .png)
        let frontItem = InputPageItem(sourceURL: frontImg, displayName: "front.png")
        let pairOuts = try PDFToolsService.pairFrontAndBack(
            frontPDFURL: nil,
            queueItems: [frontItem],
            backSourceURL: backImg,
            outputMode: .separateFiles,
            destinationURL: pairDest,
            filePrefix: "../../escaped_xx",
            startIndex: 1
        )
        assertEqual(pairOuts.count, 1, "P1-4 pair should create 1 file")
        assertTrue(!fm.fileExists(atPath: pairParent.appendingPathComponent("escaped_01.pdf").path), "P1-4 must NOT escape pairDest")
        assertTrue(fm.fileExists(atPath: pairDest.appendingPathComponent("escaped_01.pdf").path), "P1-4 must write inside pairDest")

        // 11b. [P1-5 + P2] Symlink traversal in expandURLsWithFolderMeta, stageItemToImageFile, and resolved mtime in cache keys
        let realTargetDir = tmpRoot.appendingPathComponent("real_sym_target")
        let symFolder = tmpRoot.appendingPathComponent("sym_folder")
        try fm.createDirectory(at: realTargetDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: symFolder, withIntermediateDirectories: true)
        let realTargetImg = realTargetDir.appendingPathComponent("target_photo.png")
        saveImage(makeSyntheticImage(width: 400, height: 500, rgb: (0.1, 0.7, 0.2)), to: realTargetImg, utType: .png)
        let relativeSym = symFolder.appendingPathComponent("linked_photo.png")
        try fm.createSymbolicLink(atPath: relativeSym.path, withDestinationPath: "../real_sym_target/target_photo.png")

        let expandedMeta = PDFToolsService.expandURLsWithFolderMeta([symFolder])
        assertEqual(expandedMeta.count, 1, "P1-5 expandURLsWithFolderMeta must include symlinked file inside folder")
        assertEqual(expandedMeta.first?.folderName, "sym_folder", "P1-5 preserve folderName")

        let symStageDir = tmpRoot.appendingPathComponent("sym_stage")
        try fm.createDirectory(at: symStageDir, withIntermediateDirectories: true)
        let symItem = InputPageItem(sourceURL: relativeSym, displayName: "linked_photo.png")
        let symStaged = try PDFToolsService.stageItemToImageFile(item: symItem, index: 0, stagingDir: symStageDir)
        assertTrue(fm.isReadableFile(atPath: symStaged.path), "P1-5 staged file from relative symlink must be readable")
        let stagedAttrs = try fm.attributesOfItem(atPath: symStaged.path)
        assertTrue((stagedAttrs[.type] as? FileAttributeType) == .typeRegular, "P1-5 staged file must be regular file, not symlink")

        let keyBeforeMtime = PDFToolsService.previewCacheKey(for: symItem, settings: ScanSettings())
        let ocrKeyBeforeMtime = PDFToolsService.ocrCacheKey(for: relativeSym)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: realTargetImg.path)
        let keyAfterMtime = PDFToolsService.previewCacheKey(for: symItem, settings: ScanSettings())
        let ocrKeyAfterMtime = PDFToolsService.ocrCacheKey(for: relativeSym)
        assertTrue(keyBeforeMtime != keyAfterMtime, "P2 previewCacheKey must reflect resolved target mtime")
        assertTrue(ocrKeyBeforeMtime != ocrKeyAfterMtime, "P2 ocrCacheKey must reflect resolved target mtime")

        // 11c. [P1-16] Locked (password-protected) PDF must be rejected across loadInputItems & PDFToolsService
        let unlockedSrcPDF = tmpRoot.appendingPathComponent("for_lock.pdf")
        try makeVectorTextPDF(text: "Secret Content", to: unlockedSrcPDF)
        let lockedPDF = tmpRoot.appendingPathComponent("locked.pdf")
        let lockDoc = PDFDocument(url: unlockedSrcPDF)!
        assertTrue(
            lockDoc.write(to: lockedPDF, withOptions: [
                PDFDocumentWriteOption.userPasswordOption: "userpass123",
                PDFDocumentWriteOption.ownerPasswordOption: "ownerpass123"
            ]),
            "Create user-password locked PDF"
        )
        assertEqual(PDFToolsService.loadInputItems(from: [lockedPDF]).count, 0, "P1-16 loadInputItems must return 0 items for locked PDF")

        func assertThrows(_ label: String, _ block: () throws -> Void) {
            var didThrow = false
            do { try block() } catch { didThrow = true }
            assertTrue(didThrow, label)
        }
        assertThrows("P1-16 splitPDF rejects locked PDF") {
            _ = try PDFToolsService.splitPDF(sourceURL: lockedPDF, mode: .customRange, rangeSpec: "1", destinationURL: tmpRoot.appendingPathComponent("locked_split.pdf"))
        }
        assertThrows("P1-16 pairFrontAndBack rejects locked front PDF") {
            _ = try PDFToolsService.pairFrontAndBack(frontPDFURL: lockedPDF, queueItems: [], backSourceURL: backImg, outputMode: .singleCombined, destinationURL: tmpRoot.appendingPathComponent("locked_pair.pdf"), filePrefix: "p", startIndex: 1)
        }
        assertThrows("P1-16 pairFrontAndBack rejects locked back PDF") {
            _ = try PDFToolsService.pairFrontAndBack(frontPDFURL: unlockedSrcPDF, queueItems: [], backSourceURL: lockedPDF, outputMode: .singleCombined, destinationURL: tmpRoot.appendingPathComponent("locked_pair2.pdf"), filePrefix: "p", startIndex: 1)
        }
        assertThrows("P1-16 mergePDFFiles rejects locked PDF") {
            _ = try PDFToolsService.mergePDFFiles(urls: [lockedPDF], destinationURL: tmpRoot.appendingPathComponent("locked_merge.pdf"))
        }
        assertThrows("P1-16 rotatePDFFile rejects locked PDF") {
            _ = try PDFToolsService.rotatePDFFile(sourceURL: lockedPDF, destinationURL: tmpRoot.appendingPathComponent("locked_rot.pdf"), clockwiseDegrees: 90, autoPortrait: false, rangeSpec: "1")
        }

        // 11d. [P1-17] Transparent RGBA PNG must composite over white in stageItemToImageFile & PureSwiftVision (--no-crop)
        let alphaPNG = tmpRoot.appendingPathComponent("transparent_border.png")
        let alphaW = 400, alphaH = 400
        let alphaCtx = CGContext(
            data: nil, width: alphaW, height: alphaH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        alphaCtx.clear(CGRect(x: 0, y: 0, width: alphaW, height: alphaH))
        alphaCtx.setFillColor(CGColor(red: 0.15, green: 0.25, blue: 0.85, alpha: 1.0))
        alphaCtx.fill(CGRect(x: 120, y: 120, width: 160, height: 160))
        saveImage(alphaCtx.makeImage()!, to: alphaPNG, utType: .png)

        let alphaItem = InputPageItem(sourceURL: alphaPNG, displayName: "transparent_border.png")
        let alphaStaged = try PDFToolsService.stageItemToImageFile(item: alphaItem, index: 0, stagingDir: symStageDir)
        let stagedCorner = samplePixelRGB(atX: 5, y: 5, inImageAt: alphaStaged)
        assertTrue(stagedCorner.r >= 245 && stagedCorner.g >= 245 && stagedCorner.b >= 245, "P1-17 staged transparent PNG corner must be white, got \(stagedCorner)")

        var visionNoCrop = ScanSettings()
        visionNoCrop.engine = .pureSwiftVision
        visionNoCrop.mode = .original
        visionNoCrop.autoCrop = false
        let alphaPreview = try await bridge.previewSinglePage(item: alphaItem, settings: visionNoCrop) { _ in }
        let previewCorner = samplePixelRGB(atX: 5, y: 5, inImageAt: alphaPreview)
        assertTrue(previewCorner.r >= 245 && previewCorner.g >= 245 && previewCorner.b >= 245, "P1-17 PureSwiftVision transparent PNG corner must be white, got \(previewCorner)")

        // 11e. [P1-3 + P2] Compile and invoke doc_scanner.swift directly: NFC canonicalization on NFD input & sanitized --save-debug stem
        let docScannerBin = tmpRoot.appendingPathComponent("doc_scanner_bin")
        let compileProc = Process()
        compileProc.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        compileProc.arguments = [
            "-O", "-framework", "Foundation", "-framework", "CoreImage",
            "-framework", "CoreGraphics", "-framework", "ImageIO", "-framework", "Vision",
            repoRoot.appendingPathComponent("scripts/doc_scanner.swift").path,
            "-o", docScannerBin.path
        ]
        try compileProc.run()
        compileProc.waitUntilExit()
        assertEqual(compileProc.terminationStatus, 0, "Compile doc_scanner.swift")

        let nfdName = "nga\u{0300}y (test) #1.png"
        let nfcName = nfdName.precomposedStringWithCanonicalMapping
        let nfdFile = tmpRoot.appendingPathComponent(nfdName)
        let nfcFile = tmpRoot.appendingPathComponent(nfcName)
        saveImage(makeSyntheticImage(width: 500, height: 700, rgb: (0.1, 0.2, 0.7)), to: nfdFile, utType: .png)
        let nfcManifest = tmpRoot.appendingPathComponent("nfc_manifest.json")
        let debugDir = tmpRoot.appendingPathComponent("debug_out")
        let docOut = tmpRoot.appendingPathComponent("doc_nfc.pdf")
        let runDoc = Process()
        runDoc.executableURL = docScannerBin
        runDoc.arguments = [
            "--output", docOut.path,
            "--no-crop",
            "--manifest", nfcManifest.path,
            "--save-debug", debugDir.path,
            nfdFile.path
        ]
        try runDoc.run()
        runDoc.waitUntilExit()
        assertEqual(runDoc.terminationStatus, 0, "doc_scanner run on NFD filename")
        let mData = try Data(contentsOf: nfcManifest)
        let mDecoded = try JSONDecoder().decode(PipelineManifest.self, from: mData)
        let expectedCanonNFC = nfcFile.standardizedFileURL.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping
        assertEqual(mDecoded.results.first?.input, expectedCanonNFC, "P1-3 doc_scanner manifest input must be NFC canonical path")
        let debugEntries = (try? fm.contentsOfDirectory(atPath: debugDir.path)) ?? []
        assertTrue(debugEntries.count == 1 && !debugEntries[0].contains(" ") && !debugEntries[0].contains("#"), "P2 --save-debug stem must be sanitized (got \(debugEntries))")
        assertEqual(PDFToolsService.ocrCacheKey(for: nfdFile), PDFToolsService.ocrCacheKey(for: nfcFile), "P1-3 ocrCacheKey identical for NFD and NFC")
        assertEqual(PDFToolsService.previewCacheKey(for: InputPageItem(sourceURL: nfdFile, displayName: "n"), settings: ScanSettings()),
                    PDFToolsService.previewCacheKey(for: InputPageItem(sourceURL: nfcFile, displayName: "n"), settings: ScanSettings()),
                    "P1-3 previewCacheKey identical for NFD and NFC")

        // 11f. [P2] compileProcessedImagesToPDF atomic write: mid-batch failure leaves no partial PDF or corrupt sentinel
        let atomicOut = tmpRoot.appendingPathComponent("atomic_sentinel.pdf")
        let sentinelBytes = Data("SENTINEL_INTACT".utf8)
        try sentinelBytes.write(to: atomicOut)
        let missingImg = tmpRoot.appendingPathComponent("does_not_exist.jpg")
        assertThrows("P2 compileProcessedImagesToPDF throws on missing image") {
            try PDFToolsService.compileProcessedImagesToPDF(imageURLs: [frontImg, missingImg], destinationURL: atomicOut, settings: ScanSettings())
        }
        assertEqual(try Data(contentsOf: atomicOut), sentinelBytes, "P2 failed compileProcessedImagesToPDF must not corrupt existing destination")

        // 11g. [P1-18] processedPreviewURL with processedCacheKey == nil MUST be treated as cache MISS
        let cleanItem = InputPageItem(sourceURL: frontImg, displayName: "front.png")
        var cleanSettings = ScanSettings()
        cleanSettings.engine = .pureSwiftVision
        cleanSettings.mode = .clean
        cleanSettings.autoCrop = false
        let cleanPrev = try await bridge.previewSinglePage(item: cleanItem, settings: cleanSettings) { _ in }
        var staleItem = cleanItem
        staleItem.processedPreviewURL = cleanPrev
        staleItem.processedCacheKey = nil
        var bwSettings = cleanSettings
        bwSettings.mode = .bw
        let bwOut = tmpRoot.appendingPathComponent("p18_bw.pdf")
        let p18Res = try await bridge.runBatchScan(items: [staleItem], settings: bwSettings, outputPDF: bwOut) { _ in }
        let resolvedP18 = p18Res.resolvedURLs[staleItem.id]!
        assertTrue(resolvedP18.path != cleanPrev.path, "P1-18 nil processedCacheKey must NOT reuse stale preview")

        // 11h. Mock-root ScannerBridge tests: P0-2 deadlock, P1-15 pre-cancel, P1-13 UTF-8 pipe, P1-14 preflight >256KB, P1-7 SIGTERM cancel, P2 python3.* glob
        defer { setenv("PDF_SCANNER_ROOT", repoRoot.path, 1) }

        // P0-2: Invalid executable python3.10 fails proc.run() -> must throw rapidly without NSLock deadlock
        let badRoot = tmpRoot.appendingPathComponent("mock_bad_worker")
        try fm.createDirectory(at: badRoot.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try fm.createDirectory(at: badRoot.appendingPathComponent("python_runtime/bin"), withIntermediateDirectories: true)
        try Data("# dummy\n".utf8).write(to: badRoot.appendingPathComponent("scripts/batch_scanner.py"))
        try Data("# dummy\n".utf8).write(to: badRoot.appendingPathComponent("scripts/pdf_compressor.py"))
        try Data("print(\"hi\")\n".utf8).write(to: badRoot.appendingPathComponent("scripts/doc_scanner.swift"))
        let badPy = badRoot.appendingPathComponent("python_runtime/bin/python3.10")
        try Data().write(to: badPy) // 0-byte executable causes ENOEXEC on proc.run()
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: badPy.path)

        setenv("PDF_SCANNER_ROOT", badRoot.path, 1)
        let badBridge = try ScannerBridge()
        var badSettings = ScanSettings()
        badSettings.engine = .hybridOpenCV
        var p02Threw = false
        let tStartP02 = Date()
        do {
            _ = try await badBridge.previewSinglePage(item: frontItem, settings: badSettings) { _ in }
        } catch {
            p02Threw = true
        }
        assertTrue(p02Threw, "P0-2 bad worker launch must throw instead of succeeding")
        assertTrue(Date().timeIntervalSince(tStartP02) < 5.0, "P0-2 bad worker launch must not deadlock")

        // P1-15: Pre-cancelled Task calling previewSinglePage must throw CancellationError without running worker
        let preCancelTask = Task<Void, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await badBridge.previewSinglePage(item: frontItem, settings: badSettings) { _ in }
        }
        var p15Cancelled = false
        do {
            try await preCancelTask.value
        } catch is CancellationError {
            p15Cancelled = true
        } catch {
            p15Cancelled = false
        }
        assertTrue(p15Cancelled, "P1-15 pre-cancelled Task must throw CancellationError")

        // P2 discoverPython python3.11 + P1-14 >280KB stderr preflight + P1-13 split UTF-8 chunks + P1-7 SIGTERM cancel
        let mockRoot = tmpRoot.appendingPathComponent("mock_good_worker")
        try fm.createDirectory(at: mockRoot.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try fm.createDirectory(at: mockRoot.appendingPathComponent("python_runtime/bin"), withIntermediateDirectories: true)
        try Data("# dummy\n".utf8).write(to: mockRoot.appendingPathComponent("scripts/batch_scanner.py"))
        try Data("# dummy\n".utf8).write(to: mockRoot.appendingPathComponent("scripts/pdf_compressor.py"))
        try Data("print(\"hi\")\n".utf8).write(to: mockRoot.appendingPathComponent("scripts/doc_scanner.swift"))

        let realPy = bridge.pythonURL.path
        let mockPy11 = mockRoot.appendingPathComponent("python_runtime/bin/python3.11")
        let mockImpl = mockRoot.appendingPathComponent("mock_impl.py")
        let mockImplScript = """
        import os, sys, time, json, shutil
        args = sys.argv[1:]
        if "-c" in args:
            # P1-14: emit 280 KiB to stderr before printing version to stdout
            sys.stderr.write("W" * 286720 + "\\n")
            sys.stderr.flush()
            sys.stdout.write("3.11.9|4.10.0\\n")
            sys.stdout.flush()
            sys.exit(0)
        if any("sleep_cancel" in a for a in args):
            time.sleep(10)
            sys.exit(0)
        if any("utf8_stress" in a for a in args):
            line = "CỘNG HÒA XÃ HỘI CHỦ NGHĨA VIỆT NAM - dòng ".encode("utf-8")
            for i in range(4000):
                payload = line + f"{i:04d}\\n".encode("utf-8")
                # Split mid-UTF-8 byte sequence across two writes
                os.write(1, payload[:5])
                os.write(1, payload[5:])
            p_idx = next(i for i, a in enumerate(args) if a.endswith("pdf_compressor.py"))
            src_pdf = args[p_idx + 1]
            dst_pdf = args[p_idx + 2]
            shutil.copy2(src_pdf, dst_pdf)
            rep_idx = args.index("--json-report") + 1
            with open(args[rep_idx], "w", encoding="utf-8") as f:
                json.dump({
                    "before_bytes": 100,
                    "after_bytes": 50,
                    "pages": 1,
                    "vector_pages": 1,
                    "image_pages": 0,
                    "recompressed_images": 0,
                    "target_bytes": 0,
                    "target_achieved": True,
                    "used_dpi": 150,
                    "used_quality": 80,
                    "message": "ok"
                }, f)
            sys.exit(0)
        sys.exit(0)
        """
        try Data(mockImplScript.utf8).write(to: mockImpl)
        let mockWrapper = """
        #!/bin/sh
        unset PYTHONHOME PYTHONPATH
        exec "\(realPy)" "\(mockImpl.path)" "$@"
        """
        try Data(mockWrapper.utf8).write(to: mockPy11)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockPy11.path)

        setenv("PDF_SCANNER_ROOT", mockRoot.path, 1)
        let mockBridge = try ScannerBridge()
        assertEqual(mockBridge.pythonURL.lastPathComponent, "python3.11", "P2 discoverPython must detect python3.11 dynamically")

        let tPreflight = Date()
        let pf = mockBridge.runPreflightCheck()
        assertTrue(pf.isHealthy, "P1-14 preflight with 280 KiB stderr must succeed cleanly (got: \(pf.summary))")
        assertTrue(Date().timeIntervalSince(tPreflight) < 5.0, "P1-14 preflight must not deadlock on >256KB stderr")

        final class LineCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var lines: [String] = []
            func append(_ line: String) {
                lock.lock()
                lines.append(line)
                lock.unlock()
            }
            func snapshot() -> [String] {
                lock.lock()
                defer { lock.unlock() }
                return lines
            }
        }
        let collector = LineCollector()
        let utf8InPDF = tmpRoot.appendingPathComponent("utf8_stress_in.pdf")
        let utf8OutPDF = tmpRoot.appendingPathComponent("utf8_stress_out.pdf")
        try makeVectorTextPDF(text: "UTF8 Stress", to: utf8InPDF)
        _ = try await mockBridge.compressPDF(sourcePDF: utf8InPDF, outputPDF: utf8OutPDF) { line in
            if line.hasPrefix("CỘNG HÒA") {
                collector.append(line)
            }
        }
        let receivedLines = collector.snapshot()
        assertEqual(receivedLines.count, 4000, "P1-13 LinePipeAccumulator must deliver all 4000 split UTF-8 lines")
        assertTrue(!receivedLines.contains(where: { $0.contains("\u{FFFD}") }), "P1-13 must not produce UTF-8 replacement characters")

        // P1-7: Intentional cancellation during compressPDF throws CancellationError (not processFailed(15))
        let sleepInPDF = tmpRoot.appendingPathComponent("sleep_cancel_in.pdf")
        let sleepOutPDF = tmpRoot.appendingPathComponent("sleep_cancel_out.pdf")
        try makeVectorTextPDF(text: "Cancel Test", to: sleepInPDF)
        let cancelTask = Task {
            try await mockBridge.compressPDF(sourcePDF: sleepInPDF, outputPDF: sleepOutPDF) { _ in }
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        cancelTask.cancel()
        mockBridge.cancelActiveProcess()
        var threwCancellation = false
        do {
            _ = try await cancelTask.value
        } catch is CancellationError {
            threwCancellation = true
        } catch {
            assertTrue(false, "P1-7 expected CancellationError on cancel, got \(error)")
        }
        assertTrue(threwCancellation, "P1-7 intentional cancel must throw CancellationError")
    }

    static func samplePixelRGB(atX x: Int, y: Int, inImageAt url: URL) -> (r: Int, g: Int, b: Int) {
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(
            data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let cx = min(max(0, x), w - 1)
        let cy = min(max(0, y), h - 1)
        let off = (cy * w + cx) * 4
        return (Int(buf[off]), Int(buf[off + 1]), Int(buf[off + 2]))
    }

    static func makeOCRTextCGImage(lines: [String], skewRadians: CGFloat = 0.0) throws -> CGImage {
        let w = 1000
        let h = max(420, 180 + lines.count * 64)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "OCRTest", code: 1)
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 32, nil)
        let attr = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        ] as CFDictionary
        for (idx, lineText) in lines.enumerated() {
            let ctLine = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, lineText as CFString, attr)!)
            ctx.textPosition = CGPoint(x: 60, y: CGFloat(h - 110 - idx * 60))
            CTLineDraw(ctLine, ctx)
        }
        guard let cg = ctx.makeImage() else {
            throw NSError(domain: "OCRTest", code: 2)
        }
        guard abs(skewRadians) > 0.001 else { return cg }
        let ci = CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(rotationAngle: skewRadians))
            .composited(over: CIImage(color: .white).cropped(to: CGRect(x: -250, y: -250, width: w + 500, height: h + 500)))
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        let norm = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
        guard let skewed = CIContext().createCGImage(norm, from: norm.extent) else {
            throw NSError(domain: "OCRTest", code: 3)
        }
        return skewed
    }

    static func rotateCGImageCW(_ cg: CGImage, degrees: Int) throws -> CGImage {
        let deg = ((degrees % 360) + 360) % 360
        if deg == 0 { return cg }
        let ci = CIImage(cgImage: cg)
        let rotated: CIImage
        switch deg {
        case 90: rotated = ci.oriented(.right)
        case 180: rotated = ci.oriented(.down)
        case 270: rotated = ci.oriented(.left)
        default: rotated = ci
        }
        let norm = rotated.transformed(by: CGAffineTransform(translationX: -rotated.extent.minX, y: -rotated.extent.minY))
        guard let out = CIContext().createCGImage(norm, from: norm.extent) else {
            throw NSError(domain: "OCRTest", code: 4)
        }
        return out
    }

    static func makeOCRTestImage(text: String, to url: URL) throws {
        let cg = try makeOCRTextCGImage(lines: [text])
        saveImage(cg, to: url, utType: .png)
    }

    static func makeVectorTextPDF(text: String, to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw NSError(domain: "VecTest", code: 1)
        }
        ctx.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, [kCTFontAttributeName: font] as CFDictionary)!)
        ctx.textPosition = CGPoint(x: 72, y: 740)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
    }
}
