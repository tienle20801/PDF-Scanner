import AppKit
import CoreImage
import CoreText
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

enum PDFToolError: LocalizedError {
    case emptyInput(String)
    case invalidPDF(URL)
    case invalidBackSource(URL)
    case invalidPageRange(String)
    case writeFailed(URL)
    case imageLoadFailed(URL)

    var errorDescription: String? {
        switch self {
        case .emptyInput(let msg): return msg
        case .invalidPDF(let url): return "Không thể mở file PDF: \(url.lastPathComponent)"
        case .invalidBackSource(let url): return "Không thể đọc trang mặt sau từ: \(url.lastPathComponent)"
        case .invalidPageRange(let spec): return "Dải trang không hợp lệ: '\(spec)'. Ví dụ hợp lệ: 1-3, 5, 7-9"
        case .writeFailed(let url): return "Không thể ghi file PDF đích: \(url.path)"
        case .imageLoadFailed(let url): return "Không thể đọc ảnh: \(url.lastPathComponent)"
        }
    }
}

enum SplitMode: String, CaseIterable, Identifiable {
    case allPages = "Tách từng trang lẻ"
    case customRange = "Trích xuất dải trang"

    var id: String { rawValue }
}

enum PairOutputMode: String, CaseIterable, Identifiable {
    case separateFiles = "Nhiều file 2 trang (ngày_01.pdf...)"
    case singleCombined = "1 file PDF ghép xen kẽ"

    var id: String { rawValue }
}

enum PDFToolsService {
    static let supportedImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff", "bmp"
    ]

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    static func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024.0 * 1024.0)
        if mb >= 1.0 {
            return String(format: "%.2f MiB", mb)
        }
        let kb = Double(bytes) / 1024.0
        return String(format: "%.1f KiB", kb)
    }

    static func uniqueURLIfExists(_ url: URL) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            return url
        }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var idx = 1
        while true {
            let candidateName = ext.isEmpty ? "\(stem)_\(idx)" : "\(stem)_\(idx).\(ext)"
            let candidate = dir.appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            idx += 1
        }
    }

    static func naturalCompare(_ lhs: URL, _ rhs: URL) -> Bool {
        let cmp = lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
        if cmp != .orderedSame {
            return cmp == .orderedAscending
        }
        return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }

    static func expandURLs(_ urls: [URL]) -> [URL] {
        expandURLsWithFolderMeta(urls).map { $0.url }
    }

    static func expandURLsWithFolderMeta(_ urls: [URL]) -> [(url: URL, folderName: String?)] {
        let fm = FileManager.default
        var collected: [(url: URL, folderName: String?)] = []

        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let folderName = url.lastPathComponent
                if let entries = try? fm.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) {
                    let valid = entries
                        .filter { entry in
                            let isFile = (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                            guard isFile else { return false }
                            let ext = entry.pathExtension.lowercased()
                            return ext == "pdf" || supportedImageExtensions.contains(ext)
                        }
                        .sorted { naturalCompare($0, $1) }
                    collected.append(contentsOf: valid.map { ($0, folderName) })
                }
            } else {
                let ext = url.pathExtension.lowercased()
                if ext == "pdf" || supportedImageExtensions.contains(ext) {
                    collected.append((url, nil))
                }
            }
        }
        return collected.sorted { naturalCompare($0.url, $1.url) }
    }

    static func loadInputItems(from urls: [URL]) -> [InputPageItem] {
        let resolved = expandURLsWithFolderMeta(urls)
        var items: [InputPageItem] = []

        for entry in resolved {
            let url = entry.url
            let folderName = entry.folderName
            let ext = url.pathExtension.lowercased()
            if ext == "pdf" {
                guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { continue }
                for idx in 0..<doc.pageCount {
                    guard let page = doc.page(at: idx) else { continue }
                    let thumb = page.thumbnail(of: NSSize(width: 160, height: 220), for: .cropBox)
                    let name = "\(url.lastPathComponent) [Trang \(idx + 1)/\(doc.pageCount)]"
                    items.append(
                        InputPageItem(
                            sourceURL: url,
                            pageIndexInPDF: idx,
                            displayName: name,
                            sourceFolderName: folderName,
                            rotationDegrees: 0,
                            thumbnail: thumb
                        )
                    )
                }
            } else if supportedImageExtensions.contains(ext) {
                let thumb = makeImageThumbnail(url: url, maxSide: 220)
                items.append(
                    InputPageItem(
                        sourceURL: url,
                        pageIndexInPDF: nil,
                        displayName: url.lastPathComponent,
                        sourceFolderName: folderName,
                        rotationDegrees: 0,
                        thumbnail: thumb
                    )
                )
            }
        }
        return items
    }

    static func makeImageThumbnail(url: URL, maxSide: CGFloat = AppConstants.thumbnailMaxSide) -> NSImage? {
        guard let cgThumb = makeDownscaledCGImage(url: url, maxSide: maxSide) else {
            return NSImage(contentsOf: url)
        }
        return NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width, height: cgThumb.height))
    }

    static func makeDownscaledCGImage(url: URL, maxSide: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func loadDisplayImage(for item: InputPageItem, maxSide: CGFloat = AppConstants.previewMaxSide) -> NSImage? {
        let baseImage: NSImage?
        if let pageIdx = item.pageIndexInPDF {
            guard let doc = PDFDocument(url: item.sourceURL),
                  let page = doc.page(at: pageIdx) else { return nil }
            let box = page.bounds(for: .cropBox)
            let longest = max(box.width, box.height, 1.0)
            let scale = min(maxSide / longest, 3.0)
            let targetSize = NSSize(width: box.width * scale, height: box.height * scale)
            baseImage = page.thumbnail(of: targetSize, for: .cropBox)
        } else {
            baseImage = makeImageThumbnail(url: item.sourceURL, maxSide: maxSide)
        }

        guard let img = baseImage else { return nil }
        return rotatedNSImage(img, clockwiseDegrees: item.rotationDegrees)
    }

    static func rotatedNSImage(_ image: NSImage, clockwiseDegrees: Int) -> NSImage {
        let deg = ((clockwiseDegrees % 360) + 360) % 360
        if deg == 0 { return image }
        guard let tiff = image.tiffRepresentation,
              var ci = CIImage(data: tiff) else {
            return image
        }
        ci = applyClockwiseRotation(ci, degrees: deg)
        let normalized = ci.transformed(
            by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY)
        )
        guard let cg = ciContext.createCGImage(normalized, from: normalized.extent) else {
            return image
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static func applyClockwiseRotation(_ image: CIImage, degrees: Int) -> CIImage {
        switch ((degrees % 360) + 360) % 360 {
        case 90:
            return image.oriented(.right)
        case 180:
            return image.oriented(.down)
        case 270:
            return image.oriented(.left)
        default:
            return image
        }
    }

    struct OCRTextLine: Equatable {
        let text: String
        let boundingBox: CGRect
    }

    private static let orientationQueue = DispatchQueue(
        label: "com.pdfscanner.app.orientation",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private static let ocrCacheLock = NSLock()
    private static var ocrCacheByKey: [String: [OCRTextLine]] = [:]

    private static let resolvedOCRLanguages: [String] = {
        let req = VNRecognizeTextRequest()
        let supported = Set((try? req.supportedRecognitionLanguages()) ?? ["en-US"])
        let chosen = AppConstants.ocrPreferredLanguages.filter { supported.contains($0) }
        return chosen.isEmpty ? ["en-US"] : chosen
    }()

    static func ocrCacheKey(for url: URL, pageIndex: Int? = nil, rotationDegrees: Int = 0) -> String {
        let deg = ((rotationDegrees % 360) + 360) % 360
        let mtimeMs = fileModificationTimestamp(for: url)
        let pageToken = pageIndex.map(String.init) ?? "img"
        return "\(url.standardizedFileURL.resolvingSymlinksInPath().path)::\(pageToken)::\(mtimeMs)::\(deg)"
    }

    static func cachedOCRTextLines(forKey key: String) -> [OCRTextLine]? {
        ocrCacheLock.lock()
        defer { ocrCacheLock.unlock() }
        return ocrCacheByKey[key]
    }

    private static func storeOCRTextLines(_ lines: [OCRTextLine], forKey key: String) {
        ocrCacheLock.lock()
        defer { ocrCacheLock.unlock() }
        if ocrCacheByKey.count > 200 {
            ocrCacheByKey.removeAll(keepingCapacity: true)
        }
        ocrCacheByKey[key] = lines
    }

    static func clearOCRCache() {
        ocrCacheLock.lock()
        ocrCacheByKey.removeAll()
        ocrCacheLock.unlock()
    }

    private static func loadDirectCGImageForOCR(for item: InputPageItem, maxSide: CGFloat) -> CGImage? {
        let deg = ((item.rotationDegrees % 360) + 360) % 360
        if let pageIdx = item.pageIndexInPDF {
            guard let doc = PDFDocument(url: item.sourceURL),
                  let page = doc.page(at: pageIdx) else { return nil }
            let box = page.bounds(for: .cropBox)
            let longest = max(box.width, box.height, 1.0)
            let targetDPI = max(72.0, min(200.0, (maxSide / longest) * 72.0))
            return try? renderPDFPageToCGImage(page: page, dpi: targetDPI, extraClockwiseRotation: deg)
        }
        guard let cg = makeDownscaledCGImage(url: item.sourceURL, maxSide: maxSide) else {
            return nil
        }
        if deg == 0 { return cg }
        let ci = applyClockwiseRotation(CIImage(cgImage: cg), degrees: deg)
        let norm = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
        return ciContext.createCGImage(norm, from: norm.extent) ?? cg
    }

    static func recognizeTextLines(
        in cgImage: CGImage,
        recognitionLevel: VNRequestTextRecognitionLevel = .accurate,
        cacheKey: String? = nil
    ) -> [OCRTextLine] {
        if let cacheKey, let cached = cachedOCRTextLines(forKey: cacheKey) {
            return cached
        }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = recognitionLevel
        req.usesLanguageCorrection = true
        req.recognitionLanguages = resolvedOCRLanguages

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([req])
        } catch {
            return []
        }

        var lines: [OCRTextLine] = []
        for obs in (req.results ?? []) {
            guard let top = obs.topCandidates(1).first else { continue }
            let str = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !str.isEmpty else { continue }
            lines.append(OCRTextLine(text: str, boundingBox: obs.boundingBox))
        }
        if let cacheKey, recognitionLevel == .accurate {
            storeOCRTextLines(lines, forKey: cacheKey)
        }
        return lines
    }

    static func detectReadingOrientationDegreesAsync(
        for item: InputPageItem,
        cacheAccurateOCR: Bool = false
    ) async -> Int {
        await withCheckedContinuation { continuation in
            orientationQueue.async {
                let result = detectReadingOrientationDegrees(for: item, cacheAccurateOCR: cacheAccurateOCR)
                continuation.resume(returning: result)
            }
        }
    }

    /// Detects the clockwise rotation (0, 90, 180, or 270 degrees) needed to make document text upright.
    static func detectReadingOrientationDegrees(
        for item: InputPageItem,
        cacheAccurateOCR: Bool = false
    ) -> Int {
        guard let directCG = loadDirectCGImageForOCR(for: item, maxSide: AppConstants.ocrOrientationMaxSide) else {
            return 0
        }
        let finalRotBase = ((item.rotationDegrees % 360) + 360) % 360
        let (deg, linesForUpright) = detectReadingOrientationWithOCR(from: directCG)
        // Cache only when input is already upright (`deg == 0`); rotated pages get post-rotation OCR on export.
        if cacheAccurateOCR, deg == 0, !linesForUpright.isEmpty {
            let key = ocrCacheKey(for: item.sourceURL, pageIndex: item.pageIndexInPDF, rotationDegrees: finalRotBase)
            storeOCRTextLines(linesForUpright, forKey: key)
        }
        return deg
    }

    static func detectReadingOrientationDegrees(from cgImage: CGImage) -> Int {
        let prepared = downscaleCGImageIfNeeded(cgImage, maxSide: AppConstants.ocrOrientationMaxSide)
        return detectReadingOrientationWithOCR(from: prepared).0
    }

    private static func downscaleCGImageIfNeeded(_ cgImage: CGImage, maxSide: CGFloat) -> CGImage {
        let longest = CGFloat(max(cgImage.width, cgImage.height))
        guard longest > maxSide, longest > 0 else { return cgImage }
        let scale = maxSide / longest
        let ci = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return cgImage }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard let scaled = filter.outputImage else { return cgImage }
        let norm = scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX, y: -scaled.extent.minY))
        return ciContext.createCGImage(norm, from: norm.extent) ?? cgImage
    }

    /// Runs a single `.accurate` Vision OCR pass and determines reading orientation from each text
    /// observation's true corner geometry (`topLeft -> topRight`), because Vision `.accurate` internally
    /// decodes rotated text with high confidence across all 4 multiples of 90° while keeping corners unrotated.
    private static func detectReadingOrientationWithOCR(
        from cgImage: CGImage
    ) -> (Int, [OCRTextLine]) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = resolvedOCRLanguages

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return (0, [])
        }

        let width = Double(cgImage.width)
        let height = Double(cgImage.height)
        var votes: [Int: Double] = [0: 0, 90: 0, 180: 0, 270: 0]
        var totalChars = 0
        var lines: [OCRTextLine] = []

        for obs in (request.results ?? []) {
            guard let top = obs.topCandidates(1).first else { continue }
            let trimmed = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.contains("\u{FFFD}") { continue }
            lines.append(OCRTextLine(text: trimmed, boundingBox: obs.boundingBox))

            let alnumCount = trimmed.unicodeScalars.filter {
                CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
            }.count
            guard alnumCount >= AppConstants.ocrMinLineAlnumCount else { continue }

            // Vision normalized coordinates use a bottom-left origin; scale by pixels for aspect-true angles.
            let ux = Double(obs.topRight.x - obs.topLeft.x) * width
            let uy = Double(obs.topRight.y - obs.topLeft.y) * height
            let vx = Double(obs.topLeft.x - obs.bottomLeft.x) * width
            let vy = Double(obs.topLeft.y - obs.bottomLeft.y) * height
            let uLen = hypot(ux, uy)
            let vLen = hypot(vx, vy)
            guard uLen >= 4.0, vLen >= 2.0 else { continue }
            let cross = ux * vy - uy * vx
            guard cross > 0.2 * uLen * vLen else { continue }

            let phiDeg = atan2(uy, ux) * 180.0 / .pi
            let normPhi = ((phiDeg.truncatingRemainder(dividingBy: 360.0)) + 360.0).truncatingRemainder(dividingBy: 360.0)
            let snappedCWFix = (Int((normPhi + 45.0) / 90.0) * 90) % 360

            let conf = Double(max(0, top.confidence))
            votes[snappedCWFix, default: 0] += conf * conf * Double(alnumCount)
            totalChars += alnumCount
        }

        guard totalChars >= AppConstants.ocrMinCharacters else {
            return (0, lines)
        }
        let totalWeight = votes.values.reduce(0, +)
        guard totalWeight > 0, let best = votes.max(by: { $0.value < $1.value }) else {
            return (0, lines)
        }
        if best.key == 0 {
            return (0, lines)
        }
        let uprightWeight = votes[0, default: 0]
        let hasMarginOverUpright = best.value > uprightWeight * AppConstants.ocrImprovementFactor
        let isDominant = best.value >= totalWeight * AppConstants.ocrDominanceRatio
        return (hasMarginOverUpright && isDominant) ? (best.key, []) : (0, lines)
    }

    static func fileModificationTimestamp(for url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let date = attrs?[.modificationDate] as? Date else { return 0 }
        return Int64((date.timeIntervalSince1970 * 1000.0).rounded())
    }

    static func previewCacheKey(for item: InputPageItem, settings: ScanSettings) -> String {
        let deg = ((item.rotationDegrees % 360) + 360) % 360
        let mtimeMs = fileModificationTimestamp(for: item.sourceURL)
        let pageToken = item.pageIndexInPDF.map(String.init) ?? "img"
        let raw = [
            item.sourceURL.standardizedFileURL.resolvingSymlinksInPath().path,
            pageToken,
            String(mtimeMs),
            String(deg),
            settings.imageProcessingSignature
        ].joined(separator: "::")
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static let fastCopyImageExtensions: Set<String> = ["jpg", "jpeg", "png"]

    static func stageItemToImageFile(
        item: InputPageItem,
        index: Int,
        stagingDir: URL
    ) throws -> URL {
        let deg = ((item.rotationDegrees % 360) + 360) % 360
        let ext = item.sourceURL.pathExtension.lowercased()

        // Fast copy only for unrotated JPEG/PNG; convert TIFF/BMP/WebP/HEIC or rotated images cleanly
        if item.pageIndexInPDF == nil && deg == 0 && fastCopyImageExtensions.contains(ext) {
            let safeStem = sanitizeStem(item.sourceURL.deletingPathExtension().lastPathComponent)
            let dest = stagingDir.appendingPathComponent(String(format: "%04d_%@.%@", index + 1, safeStem, ext))
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: item.sourceURL, to: dest)
            return dest
        }

        if let pageIdx = item.pageIndexInPDF {
            let dest = stagingDir.appendingPathComponent(String(format: "%04d_page.png", index + 1))
            guard let doc = PDFDocument(url: item.sourceURL),
                  let page = doc.page(at: pageIdx) else {
                throw PDFToolError.invalidPDF(item.sourceURL)
            }
            let cgImg = try renderPDFPageToCGImage(page: page, dpi: AppConstants.pdfRenderDPI, extraClockwiseRotation: deg)
            try writePNG(cgImage: cgImg, to: dest)
            return dest
        }

        let dest = stagingDir.appendingPathComponent(String(format: "%04d_page.png", index + 1))
        let ciLoaded: CIImage
        if let direct = CIImage(contentsOf: item.sourceURL, options: [.applyOrientationProperty: true]),
           direct.extent.width > 0, direct.extent.height > 0 {
            ciLoaded = direct
        } else if let src = CGImageSourceCreateWithURL(item.sourceURL as CFURL, nil),
                  let cgFallback = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            ciLoaded = CIImage(cgImage: cgFallback)
        } else {
            throw PDFToolError.imageLoadFailed(item.sourceURL)
        }

        let rotated = applyClockwiseRotation(ciLoaded, degrees: deg)
        let originNormalized = rotated.transformed(
            by: CGAffineTransform(translationX: -rotated.extent.minX, y: -rotated.extent.minY)
        )
        let whiteBG = CIImage(color: CIColor.white).cropped(to: originNormalized.extent)
        let flattened = originNormalized.composited(over: whiteBG)
        guard let cgImg = ciContext.createCGImage(flattened, from: flattened.extent) else {
            throw PDFToolError.imageLoadFailed(item.sourceURL)
        }
        try writePNG(cgImage: cgImg, to: dest)
        return dest
    }

    private static func renderPDFPageToCGImage(
        page: PDFPage,
        dpi: CGFloat,
        extraClockwiseRotation: Int
    ) throws -> CGImage {
        let scale = dpi / 72.0
        let box = page.bounds(for: .cropBox)
        let pageRot = ((page.rotation % 360) + 360) % 360
        let baseW = (pageRot == 90 || pageRot == 270) ? box.height : box.width
        let baseH = (pageRot == 90 || pageRot == 270) ? box.width : box.height
        let pxW = max(1, Int(round(baseW * scale)))
        let pxH = max(1, Int(round(baseH * scale)))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pxW,
            height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PDFToolError.emptyInput("Không thể khởi tạo CGContext render PDF")
        }

        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: ctx)

        guard let rawCG = ctx.makeImage() else {
            throw PDFToolError.emptyInput("Không thể xuất ảnh từ trang PDF")
        }

        let deg = ((extraClockwiseRotation % 360) + 360) % 360
        if deg == 0 { return rawCG }

        let ci = applyClockwiseRotation(CIImage(cgImage: rawCG), degrees: deg)
        let norm = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
        guard let rotatedCG = ciContext.createCGImage(norm, from: norm.extent) else {
            return rawCG
        }
        return rotatedCG
    }

    private static func writeJPEG(cgImage: CGImage, to url: URL, quality: CGFloat) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw PDFToolError.writeFailed(url)
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        if !CGImageDestinationFinalize(dest) {
            throw PDFToolError.writeFailed(url)
        }
    }

    private static func writePNG(cgImage: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw PDFToolError.writeFailed(url)
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        if !CGImageDestinationFinalize(dest) {
            throw PDFToolError.writeFailed(url)
        }
    }

    private static func sanitizeStem(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let s = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return s.isEmpty ? "page" : s
    }

    static func parsePageRanges(_ spec: String, totalPages: Int) throws -> [Int] {
        guard totalPages > 0 else { throw PDFToolError.emptyInput("PDF không có trang nào") }
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return Array(0..<totalPages)
        }
        var indices: [Int] = []
        let tokens = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        for token in tokens where !token.isEmpty {
            if token.contains("-") {
                let parts = token.split(separator: "-", omittingEmptySubsequences: false)
                guard parts.count == 2,
                      let start = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                      let end = Int(parts[1].trimmingCharacters(in: .whitespaces)),
                      start >= 1, end >= start, end <= totalPages else {
                    throw PDFToolError.invalidPageRange(spec)
                }
                for p in start...end {
                    indices.append(p - 1)
                }
            } else {
                guard let pageNum = Int(token), pageNum >= 1, pageNum <= totalPages else {
                    throw PDFToolError.invalidPageRange(spec)
                }
                indices.append(pageNum - 1)
            }
        }
        guard !indices.isEmpty else {
            throw PDFToolError.invalidPageRange(spec)
        }
        return indices
    }

    // MARK: - PDFKit Tools

    static func splitPDF(
        sourceURL: URL,
        mode: SplitMode,
        rangeSpec: String,
        destinationURL: URL
    ) throws -> [URL] {
        guard let doc = PDFDocument(url: sourceURL), doc.pageCount > 0 else {
            throw PDFToolError.invalidPDF(sourceURL)
        }

        let fm = FileManager.default
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        var created: [URL] = []

        switch mode {
        case .allPages:
            try fm.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            for idx in 0..<doc.pageCount {
                guard let page = doc.page(at: idx)?.copy() as? PDFPage else { continue }
                let single = PDFDocument()
                single.insert(page, at: 0)
                let outFile = destinationURL.appendingPathComponent(String(format: "%@_page_%02d.pdf", stem, idx + 1))
                guard single.write(to: outFile) else {
                    throw PDFToolError.writeFailed(outFile)
                }
                created.append(outFile)
            }
        case .customRange:
            let indices = try parsePageRanges(rangeSpec, totalPages: doc.pageCount)
            let outDoc = PDFDocument()
            for (insertAt, idx) in indices.enumerated() {
                if let page = doc.page(at: idx)?.copy() as? PDFPage {
                    outDoc.insert(page, at: insertAt)
                }
            }
            try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard outDoc.write(to: destinationURL) else {
                throw PDFToolError.writeFailed(destinationURL)
            }
            created.append(destinationURL)
        }
        return created
    }

    static func makePDFPage(from item: InputPageItem) throws -> PDFPage {
        if let idx = item.pageIndexInPDF {
            guard let doc = PDFDocument(url: item.sourceURL),
                  let page = doc.page(at: idx)?.copy() as? PDFPage else {
                throw PDFToolError.invalidPDF(item.sourceURL)
            }
            let extra = ((item.rotationDegrees % 360) + 360) % 360
            if extra != 0 {
                page.rotation = (page.rotation + extra) % 360
            }
            return page
        }
        guard let img = loadDisplayImage(for: item, maxSide: AppConstants.pdfMakeMaxSide),
              let page = PDFPage(image: img) else {
            throw PDFToolError.imageLoadFailed(item.sourceURL)
        }
        return page
    }

    static func makeSingleBackPage(from url: URL) throws -> PDFPage {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let doc = PDFDocument(url: url),
                  let page = doc.page(at: 0)?.copy() as? PDFPage else {
                throw PDFToolError.invalidBackSource(url)
            }
            return page
        }
        guard let img = makeImageThumbnail(url: url, maxSide: AppConstants.pdfMakeMaxSide),
              let page = PDFPage(image: img) else {
            throw PDFToolError.invalidBackSource(url)
        }
        return page
    }

    /// Formats a paired PDF filename from a pattern like "TaiLieu_xx" or "Ngay_xx.11" and a starting number.
    static func formatPairFileName(pattern: String, startIndex: Int, offset: Int) -> String {
        let num = startIndex + offset
        var clean = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.lowercased().hasSuffix(".pdf") {
            clean = String(clean.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if clean.isEmpty {
            clean = "page"
        }

        if let regex = try? NSRegularExpression(pattern: "(?<![a-zA-Z])([xX]+)(?![a-zA-Z])"),
           let match = regex.firstMatch(in: clean, range: NSRange(clean.startIndex..<clean.endIndex, in: clean)),
           let range = Range(match.range(at: 1), in: clean) {
            let tokenLen = clean.distance(from: range.lowerBound, to: range.upperBound)
            let formattedNum = tokenLen >= 2
                ? String(format: "%0\(tokenLen)d", num)
                : "\(num)"
            let replaced = clean.replacingCharacters(in: range, with: formattedNum)
            return "\(replaced).pdf"
        }

        return String(format: "%@_%02d.pdf", clean, num)
    }

    static func pairFrontAndBack(
        frontPDFURL: URL?,
        queueItems: [InputPageItem],
        backSourceURL: URL,
        outputMode: PairOutputMode,
        destinationURL: URL,
        filePrefix: String,
        startIndex: Int = 1
    ) throws -> [URL] {
        let backTemplate = try makeSingleBackPage(from: backSourceURL)
        var frontPages: [PDFPage] = []

        if let frontPDFURL {
            guard let doc = PDFDocument(url: frontPDFURL), doc.pageCount > 0 else {
                throw PDFToolError.invalidPDF(frontPDFURL)
            }
            for idx in 0..<doc.pageCount {
                if let p = doc.page(at: idx)?.copy() as? PDFPage {
                    frontPages.append(p)
                }
            }
        } else {
            if queueItems.isEmpty {
                throw PDFToolError.emptyInput("Chưa có trang mặt trước trong danh sách hoặc chưa chọn file PDF nguồn.")
            }
            for item in queueItems {
                frontPages.append(try makePDFPage(from: item))
            }
        }

        guard !frontPages.isEmpty else {
            throw PDFToolError.emptyInput("Không tìm thấy trang mặt trước nào để ghép.")
        }

        let fm = FileManager.default
        var outputs: [URL] = []

        switch outputMode {
        case .separateFiles:
            try fm.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            for (idx, front) in frontPages.enumerated() {
                let doc = PDFDocument()
                doc.insert(front, at: 0)
                if let backCopy = backTemplate.copy() as? PDFPage {
                    doc.insert(backCopy, at: 1)
                }
                let fileName = formatPairFileName(pattern: filePrefix, startIndex: startIndex, offset: idx)
                let outFile = destinationURL.appendingPathComponent(fileName)
                guard doc.write(to: outFile) else {
                    throw PDFToolError.writeFailed(outFile)
                }
                outputs.append(outFile)
            }
        case .singleCombined:
            try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let combined = PDFDocument()
            var insertIdx = 0
            for front in frontPages {
                combined.insert(front, at: insertIdx)
                insertIdx += 1
                if let backCopy = backTemplate.copy() as? PDFPage {
                    combined.insert(backCopy, at: insertIdx)
                    insertIdx += 1
                }
            }
            guard combined.write(to: destinationURL) else {
                throw PDFToolError.writeFailed(destinationURL)
            }
            outputs.append(destinationURL)
        }
        return outputs
    }

    private static func drawInvisibleOCRTextLayer(
        lines: [OCRTextLine],
        in ctx: CGContext,
        drawRect: CGRect
    ) {
        guard !lines.isEmpty else { return }
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for item in lines {
            let clean = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            let box = item.boundingBox
            let targetW = max(2.0, box.width * drawRect.width)
            let targetH = max(4.0, box.height * drawRect.height)
            let originX = drawRect.minX + box.minX * drawRect.width
            let originY = drawRect.minY + box.minY * drawRect.height

            let font = CTFontCreateWithName("Helvetica" as CFString, max(4.0, targetH * 0.85), nil)
            guard let attrStr = CFAttributedStringCreate(
                nil,
                clean as CFString,
                [kCTFontAttributeName: font] as CFDictionary
            ) else { continue }

            let ctLine = CTLineCreateWithAttributedString(attrStr)
            let typographicW = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            let scaleX = typographicW > 0.5 ? (targetW / CGFloat(typographicW)) : 1.0

            ctx.textMatrix = CGAffineTransform(
                a: scaleX, b: 0,
                c: 0, d: 1.0,
                tx: originX, ty: originY + targetH * 0.12
            )
            CTLineDraw(ctLine, ctx)
        }
        ctx.restoreGState()
    }

    static func compileProcessedImagesToPDF(
        imageURLs: [URL],
        destinationURL: URL,
        settings: ScanSettings,
        sourceItems: [InputPageItem]? = nil
    ) throws {
        guard !imageURLs.isEmpty else {
            throw PDFToolError.emptyInput("Không có ảnh đã xử lý để đóng gói PDF.")
        }

        let fm = FileManager.default
        try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var dummyBox = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        guard let pdfContext = CGContext(destinationURL as CFURL, mediaBox: &dummyBox, nil) else {
            throw PDFToolError.writeFailed(destinationURL)
        }

        var renderedPages = 0
        for (idx, imgURL) in imageURLs.enumerated() {
            let ext = imgURL.pathExtension.lowercased()
            var cgImg: CGImage?

            if (ext == "jpg" || ext == "jpeg"),
               let provider = CGDataProvider(url: imgURL as CFURL) {
                cgImg = CGImage(
                    jpegDataProviderSource: provider,
                    decode: nil,
                    shouldInterpolate: true,
                    intent: .defaultIntent
                )
            }
            if cgImg == nil,
               let src = CGImageSourceCreateWithURL(imgURL as CFURL, nil) {
                cgImg = CGImageSourceCreateImageAtIndex(src, 0, nil)
            }
            guard let loadedCG = cgImg else {
                throw PDFToolError.imageLoadFailed(imgURL)
            }

            let imgW = Double(loadedCG.width)
            let imgH = Double(loadedCG.height)
            let effectiveDPI = Double(max(72, settings.dpi))
            let isLandscape = imgW > imgH
            let pageSize: CGSize
            switch settings.pageSize {
            case .a4:
                pageSize = isLandscape
                    ? CGSize(width: 841.89, height: 595.28)
                    : CGSize(width: 595.28, height: 841.89)
            case .letter:
                pageSize = isLandscape
                    ? CGSize(width: 792.0, height: 612.0)
                    : CGSize(width: 612.0, height: 792.0)
            case .fit:
                pageSize = CGSize(
                    width: max(72.0, imgW * 72.0 / effectiveDPI),
                    height: max(72.0, imgH * 72.0 / effectiveDPI)
                )
            }

            let effectiveMargin = (settings.pageSize == .fit) ? 0.0 : settings.margin
            let availW = max(10.0, Double(pageSize.width) - 2.0 * effectiveMargin)
            let availH = max(10.0, Double(pageSize.height) - 2.0 * effectiveMargin)
            let drawScale = min(availW / max(imgW, 1.0), availH / max(imgH, 1.0))
            let drawW = imgW * drawScale
            let drawH = imgH * drawScale
            let drawX = (Double(pageSize.width) - drawW) / 2.0
            let drawY = (Double(pageSize.height) - drawH) / 2.0
            let drawRect = CGRect(x: drawX, y: drawY, width: drawW, height: drawH)

            var ocrLines: [OCRTextLine] = []
            if settings.enableOCR {
                // Share Q10 OCR observations when crop didn't alter page geometry; otherwise recognize processed image & cache
                if !settings.autoCrop,
                   let sourceItems, idx < sourceItems.count {
                    let srcKey = ocrCacheKey(
                        for: sourceItems[idx].sourceURL,
                        pageIndex: sourceItems[idx].pageIndexInPDF,
                        rotationDegrees: sourceItems[idx].rotationDegrees
                    )
                    if let reused = cachedOCRTextLines(forKey: srcKey) {
                        ocrLines = reused
                    }
                }
                if ocrLines.isEmpty {
                    let procKey = ocrCacheKey(for: imgURL)
                    ocrLines = recognizeTextLines(in: loadedCG, recognitionLevel: .accurate, cacheKey: procKey)
                }
            }

            var mediaBox = CGRect(origin: .zero, size: pageSize)
            let pageInfo: [CFString: Any] = [
                kCGPDFContextMediaBox: NSData(bytes: &mediaBox, length: MemoryLayout<CGRect>.size)
            ]
            pdfContext.beginPDFPage(pageInfo as CFDictionary)
            pdfContext.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
            pdfContext.fill(mediaBox)
            pdfContext.draw(loadedCG, in: drawRect)
            if settings.enableOCR && !ocrLines.isEmpty {
                drawInvisibleOCRTextLayer(lines: ocrLines, in: pdfContext, drawRect: drawRect)
            }
            pdfContext.endPDFPage()
            renderedPages += 1
        }

        pdfContext.closePDF()
        guard renderedPages > 0 else {
            try? fm.removeItem(at: destinationURL)
            throw PDFToolError.emptyInput("Không thể xuất trang nào vào PDF.")
        }
    }

    static func mergeQueueToPDF(items: [InputPageItem], destinationURL: URL) throws -> Int {
        guard !items.isEmpty else {
            throw PDFToolError.emptyInput("Danh sách trang đang trống.")
        }
        let doc = PDFDocument()
        for (idx, item) in items.enumerated() {
            let page = try makePDFPage(from: item)
            doc.insert(page, at: idx)
        }
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard doc.write(to: destinationURL) else {
            throw PDFToolError.writeFailed(destinationURL)
        }
        return doc.pageCount
    }

    static func mergePDFFiles(urls: [URL], destinationURL: URL) throws -> Int {
        guard !urls.isEmpty else {
            throw PDFToolError.emptyInput("Chưa chọn file PDF nào để gộp.")
        }
        let merged = PDFDocument()
        var insertAt = 0
        for url in urls {
            guard let src = PDFDocument(url: url) else {
                throw PDFToolError.invalidPDF(url)
            }
            for idx in 0..<src.pageCount {
                if let page = src.page(at: idx)?.copy() as? PDFPage {
                    merged.insert(page, at: insertAt)
                    insertAt += 1
                }
            }
        }
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard merged.write(to: destinationURL) else {
            throw PDFToolError.writeFailed(destinationURL)
        }
        return merged.pageCount
    }

    static func rotatePDFFile(
        sourceURL: URL,
        destinationURL: URL,
        clockwiseDegrees: Int,
        autoPortrait: Bool,
        rangeSpec: String
    ) throws -> Int {
        guard let doc = PDFDocument(url: sourceURL), doc.pageCount > 0 else {
            throw PDFToolError.invalidPDF(sourceURL)
        }
        let targetIndices = Set(try parsePageRanges(rangeSpec, totalPages: doc.pageCount))
        var rotatedCount = 0
        for idx in 0..<doc.pageCount where targetIndices.contains(idx) {
            guard let page = doc.page(at: idx) else { continue }
            if autoPortrait {
                let bounds = page.bounds(for: .cropBox)
                let curRot = ((page.rotation % 360) + 360) % 360
                let effectiveW = (curRot == 90 || curRot == 270) ? bounds.height : bounds.width
                let effectiveH = (curRot == 90 || curRot == 270) ? bounds.width : bounds.height
                if effectiveW > effectiveH {
                    page.rotation = (curRot + 90) % 360
                    rotatedCount += 1
                }
            } else if clockwiseDegrees != 0 {
                let curRot = ((page.rotation % 360) + 360) % 360
                page.rotation = (curRot + clockwiseDegrees) % 360
                rotatedCount += 1
            }
        }
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard doc.write(to: destinationURL) else {
            throw PDFToolError.writeFailed(destinationURL)
        }
        return rotatedCount
    }
}
