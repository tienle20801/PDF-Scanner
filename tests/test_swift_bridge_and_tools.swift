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

        assertEqual(kA4, kLetter, "A4 <-> Letter & margin change must keep same preview cache key")
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
