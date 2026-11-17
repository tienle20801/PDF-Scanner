import AppKit
import CoreImage
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

    static func makeImageThumbnail(url: URL, maxSide: CGFloat = 220) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return NSImage(contentsOf: url)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide
        ]
        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(contentsOf: url)
        }
        return NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width, height: cgThumb.height))
    }

    static func loadDisplayImage(for item: InputPageItem, maxSide: CGFloat = 1800) -> NSImage? {
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

    private static let orientationQueue = DispatchQueue(
        label: "com.pdfscanner.app.orientation",
        qos: .userInitiated
    )
    private static let orientationLock = NSLock()

    static func detectReadingOrientationDegreesAsync(for item: InputPageItem) async -> Int {
        await withCheckedContinuation { continuation in
            orientationQueue.async {
                let result = detectReadingOrientationDegrees(for: item)
                continuation.resume(returning: result)
            }
        }
    }

    /// Detects the clockwise rotation (0, 90, 180, or 270 degrees) needed to make document text upright.
    static func detectReadingOrientationDegrees(for item: InputPageItem) -> Int {
        orientationLock.lock()
        defer { orientationLock.unlock() }
        guard let img = loadDisplayImage(for: item, maxSide: 2000),
              let tiff = img.tiffRepresentation,
              let ci = CIImage(data: tiff) else {
            return 0
        }
        return detectReadingOrientationDegrees(from: ci)
    }

    static func detectReadingOrientationDegrees(from cgImage: CGImage) -> Int {
        orientationLock.lock()
        defer { orientationLock.unlock() }
        return detectReadingOrientationDegrees(from: CIImage(cgImage: cgImage))
    }

    private static func isCleanWord(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
        guard trimmed.count >= 2 else { return false }
        let scalars = Array(trimmed.unicodeScalars)
        if scalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) { return true }
        guard scalars.allSatisfy({ CharacterSet.letters.contains($0) }) else { return false }
        let upper = CharacterSet.uppercaseLetters
        let upperCount = scalars.filter { upper.contains($0) }.count
        if upperCount == 0 || upperCount == scalars.count { return true }
        return upperCount == 1 && upper.contains(scalars[0])
    }

    private static func detectReadingOrientationDegrees(from baseCI: CIImage) -> Int {
        let baseNorm = baseCI.transformed(
            by: CGAffineTransform(translationX: -baseCI.extent.minX, y: -baseCI.extent.minY)
        )

        func scoreAngle(_ deg: Int) -> (score: Double, chars: Int) {
            let rotated = deg == 0 ? baseNorm : applyClockwiseRotation(baseNorm, degrees: deg)
            let norm = rotated.transformed(
                by: CGAffineTransform(translationX: -rotated.extent.minX, y: -rotated.extent.minY)
            )
            guard let cg = ciContext.createCGImage(norm, from: norm.extent) else {
                return (0, 0)
            }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return (0, 0)
            }

            var score = 0.0
            var totalChars = 0
            for obs in (request.results ?? []) {
                guard let top = obs.topCandidates(1).first else { continue }
                let trimmed = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.contains("\u{FFFD}") { continue }

                let alnumCount = trimmed.unicodeScalars.filter {
                    CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
                }.count
                guard alnumCount >= 3 else { continue }
                guard obs.boundingBox.width >= obs.boundingBox.height * 1.2 else { continue }

                let words = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                let cleanWordBonus = words.filter { isCleanWord($0) }.count * 2
                let c = Double(top.confidence)
                let confWeight = c >= 0.45 ? (c * c * 2.5) : (c * c)
                score += confWeight * Double(alnumCount + cleanWordBonus)
                totalChars += alnumCount
            }
            return (score, totalChars)
        }

        let res0 = scoreAngle(0)
        var bestDeg = 0
        var bestScore = res0.score
        var bestChars = res0.chars

        var candidates: [Int]
        if res0.score >= 60.0 {
            candidates = [180]
        } else {
            candidates = [90, 270]
        }

        var checked180 = false
        for deg in candidates {
            if deg == 180 { checked180 = true }
            let res = scoreAngle(deg)
            if res.score > bestScore {
                bestScore = res.score
                bestDeg = deg
                bestChars = res.chars
            }
        }

        // Sparse-page fallback: if neither horizontal (0) nor vertical (90/270) reached threshold, also test 180
        if !checked180 && bestScore < 60.0 {
            let res180 = scoreAngle(180)
            if res180.score > bestScore {
                bestScore = res180.score
                bestDeg = 180
                bestChars = res180.chars
            }
        }

        if bestDeg == 0 || bestChars < 6 {
            return 0
        }
        return bestScore > res0.score * 1.15 ? bestDeg : 0
    }

    static func stageItemToImageFile(
        item: InputPageItem,
        index: Int,
        stagingDir: URL
    ) throws -> URL {
        let deg = ((item.rotationDegrees % 360) + 360) % 360
        let ext = item.sourceURL.pathExtension.lowercased()

        // Fast copy when input is an unrotated non-HEIC image
        if item.pageIndexInPDF == nil && deg == 0 && ext != "heic" && ext != "heif" {
            let safeStem = sanitizeStem(item.sourceURL.deletingPathExtension().lastPathComponent)
            let dest = stagingDir.appendingPathComponent(String(format: "%04d_%@.%@", index + 1, safeStem, ext))
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: item.sourceURL, to: dest)
            return dest
        }

        let dest = stagingDir.appendingPathComponent(String(format: "%04d_page.jpg", index + 1))

        if let pageIdx = item.pageIndexInPDF {
            guard let doc = PDFDocument(url: item.sourceURL),
                  let page = doc.page(at: pageIdx) else {
                throw PDFToolError.invalidPDF(item.sourceURL)
            }
            let cgImg = try renderPDFPageToCGImage(page: page, dpi: 260, extraClockwiseRotation: deg)
            try writeJPEG(cgImage: cgImg, to: dest, quality: 0.94)
            return dest
        }

        guard let ciLoaded = CIImage(contentsOf: item.sourceURL, options: [.applyOrientationProperty: true]) else {
            throw PDFToolError.imageLoadFailed(item.sourceURL)
        }
        let rotated = applyClockwiseRotation(ciLoaded, degrees: deg)
        let originNormalized = rotated.transformed(
            by: CGAffineTransform(translationX: -rotated.extent.minX, y: -rotated.extent.minY)
        )
        guard let cgImg = ciContext.createCGImage(originNormalized, from: originNormalized.extent) else {
            throw PDFToolError.imageLoadFailed(item.sourceURL)
        }
        try writeJPEG(cgImage: cgImg, to: dest, quality: 0.94)
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
        guard let img = loadDisplayImage(for: item, maxSide: 4000),
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
        guard let img = makeImageThumbnail(url: url, maxSide: 4000),
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

    static func compileProcessedImagesToPDF(
        imageURLs: [URL],
        destinationURL: URL,
        settings: ScanSettings
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
        for imgURL in imageURLs {
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

            var mediaBox = CGRect(origin: .zero, size: pageSize)
            let pageInfo: [CFString: Any] = [
                kCGPDFContextMediaBox: NSData(bytes: &mediaBox, length: MemoryLayout<CGRect>.size)
            ]
            pdfContext.beginPDFPage(pageInfo as CFDictionary)
            pdfContext.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
            pdfContext.fill(mediaBox)
            pdfContext.draw(loadedCG, in: drawRect)
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
