#!/usr/bin/env swift
import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import Vision

enum ScanMode: String {
    case clean
    case bw
    case grayscale
    case original
}

enum PageSizeOption: String {
    case a4
    case letter
    case fit
}

struct Config {
    var outputPath: String = ""
    var mode: ScanMode = .clean
    var pageSize: PageSizeOption = .a4
    var dpi: Double = 200.0
    var margin: Double = 20.0
    var jpegQuality: Int = 88
    var minConfidence: Float = 0.45
    var noCrop: Bool = false
    var quadOnly: Bool = false
    var emitDir: String? = nil
    var manifestPath: String? = nil
    var saveDebugDir: String? = nil
    var inputs: [String] = []
}

struct PageResult: Codable {
    let index: Int
    let input: String
    let file: String
    let status: String
    let output: String?
    let message: String
    let detected: Bool
    let method: String
    let confidence: Float
    let width: Int
    let height: Int
    let quad: [[Double]]?
}

struct SummaryOutput: Codable {
    let engine: String
    let output: String?
    let pages: Int
    let pages_error: Int
    let size_bytes: Int64
    let results: [PageResult]
}

func printUsage() {
    let usage = """
    Usage: doc_scanner.swift [--output <out.pdf>] [options] <image_or_dir...>

    Options:
      --output <file.pdf>       Output PDF file path (required unless --emit-dir or --quad-only is set)
      --mode clean|bw|grayscale|original
                                Enhancement mode (default: clean)
      --page-size a4|letter|fit PDF page size (default: a4)
      --dpi <number>            Target DPI for downscaling & fit sizing (default: 200)
      --margin <pts>            Page margin in points for a4/letter (default: 20)
      --jpeg-quality <1..100>   JPEG compression quality (default: 88)
      --min-confidence <0..1>   Minimum boundary detection confidence (default: 0.45)
      --no-crop                 Skip automatic document boundary detection
      --quad-only               Detect document 4-corner quads only and write JSON/manifest (no image/PDF encode)
      --emit-dir <dir>          Directory to emit per-page processed JPEGs
      --manifest <file.json>    Path to write JSON manifest of per-page results
      --save-debug <dir>        Save cropped & enhanced images for inspection
      -h, --help                Show this help
    """
    fputs(usage + "\n", stderr)
}

func parseArgs() -> Config? {
    var config = Config()
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "-h", "--help":
            printUsage()
            return nil
        case "--output":
            i += 1
            guard i < args.count else { fputs("Missing value for --output\n", stderr); return nil }
            config.outputPath = args[i]
        case "--mode":
            i += 1
            guard i < args.count, let m = ScanMode(rawValue: args[i].lowercased()) else {
                fputs("Invalid --mode (expected clean|bw|grayscale|original)\n", stderr)
                return nil
            }
            config.mode = m
        case "--page-size":
            i += 1
            guard i < args.count, let p = PageSizeOption(rawValue: args[i].lowercased()) else {
                fputs("Invalid --page-size (expected a4|letter|fit)\n", stderr)
                return nil
            }
            config.pageSize = p
        case "--dpi":
            i += 1
            guard i < args.count, let v = Double(args[i]), v >= 72, v <= 600 else {
                fputs("Invalid --dpi (expected 72..600)\n", stderr)
                return nil
            }
            config.dpi = v
        case "--margin":
            i += 1
            guard i < args.count, let v = Double(args[i]), v >= 0 else {
                fputs("Invalid --margin\n", stderr)
                return nil
            }
            config.margin = v
        case "--jpeg-quality":
            i += 1
            guard i < args.count, let q = Int(args[i]), q >= 1, q <= 100 else {
                fputs("Invalid --jpeg-quality (expected 1..100)\n", stderr)
                return nil
            }
            config.jpegQuality = q
        case "--min-confidence":
            i += 1
            guard i < args.count, let v = Float(args[i]), v >= 0.0, v <= 1.0 else {
                fputs("Invalid --min-confidence (expected 0.0..1.0)\n", stderr)
                return nil
            }
            config.minConfidence = v
        case "--no-crop":
            config.noCrop = true
        case "--quad-only":
            config.quadOnly = true
        case "--emit-dir":
            i += 1
            guard i < args.count else { fputs("Missing value for --emit-dir\n", stderr); return nil }
            config.emitDir = args[i]
        case "--manifest":
            i += 1
            guard i < args.count else { fputs("Missing value for --manifest\n", stderr); return nil }
            config.manifestPath = args[i]
        case "--save-debug":
            i += 1
            guard i < args.count else { fputs("Missing value for --save-debug\n", stderr); return nil }
            config.saveDebugDir = args[i]
        case "--":
            config.inputs.append(contentsOf: args[(i + 1)...])
            i = args.count
        default:
            if arg.hasPrefix("-") {
                fputs("Unknown option: \(arg)\n", stderr)
                return nil
            }
            config.inputs.append(arg)
        }
        i += 1
    }
    if (config.outputPath.isEmpty && config.emitDir == nil && !config.quadOnly) || config.inputs.isEmpty {
        printUsage()
        return nil
    }
    return config
}

let supportedExts = Set(["jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff", "bmp"])

struct InputCandidate {
    let url: URL
    let canonicalPath: String
    let preflightError: String?
}

func canonicalPath(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping
}

func sanitizeFileStem(_ raw: String) -> String {
    let nfc = raw.precomposedStringWithCanonicalMapping
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    let scalars = nfc.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
    let s = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    return s.isEmpty ? "page" : s
}

func collectInputCandidates(inputs: [String]) -> [InputCandidate] {
    let fm = FileManager.default
    var candidates: [InputCandidate] = []
    for path in inputs {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        let canon = canonicalPath(url)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: expanded, isDirectory: &isDir) else {
            fputs("[WARN] Input path not found: \(expanded)\n", stderr)
            candidates.append(InputCandidate(url: url, canonicalPath: canon, preflightError: "Input path not found: \(url.lastPathComponent)"))
            continue
        }
        if isDir.boolValue {
            if let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                let imgs = items.filter { supportedExts.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                for item in imgs {
                    candidates.append(InputCandidate(url: item, canonicalPath: canonicalPath(item), preflightError: nil))
                }
            }
        } else if supportedExts.contains(url.pathExtension.lowercased()) {
            candidates.append(InputCandidate(url: url, canonicalPath: canon, preflightError: nil))
        } else {
            fputs("[WARN] Unsupported file extension: \(url.lastPathComponent)\n", stderr)
            candidates.append(InputCandidate(url: url, canonicalPath: canon, preflightError: "Unsupported file extension: \(url.lastPathComponent)"))
        }
    }
    return candidates
}

func normalizeOrigin(_ image: CIImage) -> CIImage {
    let ext = image.extent
    if ext.origin.x == 0 && ext.origin.y == 0 {
        return image
    }
    return image.transformed(by: CGAffineTransform(translationX: -ext.origin.x, y: -ext.origin.y))
}

func detectDocumentQuad(in image: CIImage, minConfidence: Float) -> (VNRectangleObservation, String)? {
    let handler = VNImageRequestHandler(ciImage: image, options: [:])

    if #available(macOS 12.0, *) {
        let docRequest = VNDetectDocumentSegmentationRequest()
        do {
            try handler.perform([docRequest])
            if let obs = docRequest.results?.first, obs.confidence >= minConfidence {
                return (obs, "document_segmentation")
            }
        } catch {
            fputs("[WARN] Document segmentation error: \(error.localizedDescription)\n", stderr)
        }
    }

    let rectRequest = VNDetectRectanglesRequest()
    rectRequest.minimumAspectRatio = 0.25
    rectRequest.maximumAspectRatio = 1.0
    rectRequest.quadratureTolerance = 45.0
    rectRequest.minimumSize = 0.2
    rectRequest.minimumConfidence = minConfidence
    rectRequest.maximumObservations = 1

    do {
        try handler.perform([rectRequest])
        if let obs = rectRequest.results?.first, obs.confidence >= minConfidence {
            return (obs, "rectangle")
        }
    } catch {
        fputs("[WARN] Rectangle detection error: \(error.localizedDescription)\n", stderr)
    }

    return nil
}

func applyPerspectiveCorrection(to image: CIImage, observation: VNRectangleObservation) -> CIImage? {
    let ext = image.extent
    func toImagePoint(_ norm: CGPoint) -> CIVector {
        return CIVector(x: norm.x * ext.width, y: norm.y * ext.height)
    }

    guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
    filter.setValue(image, forKey: kCIInputImageKey)
    filter.setValue(toImagePoint(observation.topLeft), forKey: "inputTopLeft")
    filter.setValue(toImagePoint(observation.topRight), forKey: "inputTopRight")
    filter.setValue(toImagePoint(observation.bottomLeft), forKey: "inputBottomLeft")
    filter.setValue(toImagePoint(observation.bottomRight), forKey: "inputBottomRight")

    guard let output = filter.outputImage,
          !output.extent.isInfinite,
          !output.extent.isEmpty,
          output.extent.width >= 1,
          output.extent.height >= 1,
          output.extent.width <= 30000,
          output.extent.height <= 30000 else { return nil }
    return normalizeOrigin(output)
}

func flattenOverWhite(_ image: CIImage) -> CIImage {
    let ext = image.extent
    guard !ext.isInfinite, !ext.isEmpty, ext.width > 0, ext.height > 0 else {
        return image
    }
    let whiteBG = CIImage(color: CIColor.white).cropped(to: ext)
    return normalizeOrigin(image.composited(over: whiteBG))
}

func applyEnhancement(to image: CIImage, mode: ScanMode) -> CIImage {
    var current = image
    switch mode {
    case .original:
        return current
    case .clean:
        if let hs = CIFilter(name: "CIHighlightShadowAdjust") {
            hs.setValue(current, forKey: kCIInputImageKey)
            hs.setValue(0.45, forKey: "inputShadowAmount")
            hs.setValue(0.95, forKey: "inputHighlightAmount")
            if let out = hs.outputImage { current = out }
        }
        if let cc = CIFilter(name: "CIColorControls") {
            cc.setValue(current, forKey: kCIInputImageKey)
            cc.setValue(1.25, forKey: kCIInputContrastKey)
            cc.setValue(0.04, forKey: kCIInputBrightnessKey)
            cc.setValue(0.9, forKey: kCIInputSaturationKey)
            if let out = cc.outputImage { current = out }
        }
        if let usm = CIFilter(name: "CIUnsharpMask") {
            usm.setValue(current, forKey: kCIInputImageKey)
            usm.setValue(1.5, forKey: kCIInputRadiusKey)
            usm.setValue(0.6, forKey: kCIInputIntensityKey)
            if let out = usm.outputImage { current = out }
        }
    case .grayscale:
        if let hs = CIFilter(name: "CIHighlightShadowAdjust") {
            hs.setValue(current, forKey: kCIInputImageKey)
            hs.setValue(0.40, forKey: "inputShadowAmount")
            hs.setValue(0.95, forKey: "inputHighlightAmount")
            if let out = hs.outputImage { current = out }
        }
        if let cc = CIFilter(name: "CIColorControls") {
            cc.setValue(current, forKey: kCIInputImageKey)
            cc.setValue(1.35, forKey: kCIInputContrastKey)
            cc.setValue(0.05, forKey: kCIInputBrightnessKey)
            cc.setValue(0.0, forKey: kCIInputSaturationKey)
            if let out = cc.outputImage { current = out }
        }
        if let usm = CIFilter(name: "CIUnsharpMask") {
            usm.setValue(current, forKey: kCIInputImageKey)
            usm.setValue(1.5, forKey: kCIInputRadiusKey)
            usm.setValue(0.65, forKey: kCIInputIntensityKey)
            if let out = usm.outputImage { current = out }
        }
    case .bw:
        if let noir = CIFilter(name: "CIPhotoEffectNoir") {
            noir.setValue(current, forKey: kCIInputImageKey)
            if let out = noir.outputImage { current = out }
        }
        if let cc = CIFilter(name: "CIColorControls") {
            cc.setValue(current, forKey: kCIInputImageKey)
            cc.setValue(1.65, forKey: kCIInputContrastKey)
            cc.setValue(0.08, forKey: kCIInputBrightnessKey)
            if let out = cc.outputImage { current = out }
        }
        if let usm = CIFilter(name: "CIUnsharpMask") {
            usm.setValue(current, forKey: kCIInputImageKey)
            usm.setValue(1.5, forKey: kCIInputRadiusKey)
            usm.setValue(0.75, forKey: kCIInputIntensityKey)
            if let out = usm.outputImage { current = out }
        }
    }
    return normalizeOrigin(current)
}

func pageDimensions(option: PageSizeOption, imageSize: CGSize, dpi: Double) -> CGSize {
    let isLandscape = imageSize.width > imageSize.height
    switch option {
    case .a4:
        let w = 595.28
        let h = 841.89
        return isLandscape ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    case .letter:
        let w = 612.0
        let h = 792.0
        return isLandscape ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    case .fit:
        return CGSize(
            width: max(72.0, imageSize.width * 72.0 / dpi),
            height: max(72.0, imageSize.height * 72.0 / dpi)
        )
    }
}

func downscaleIfNeeded(_ image: CIImage, maxPixelWidth: CGFloat, maxPixelHeight: CGFloat) -> CIImage {
    let w = image.extent.width
    let h = image.extent.height
    guard w > 0, h > 0 else { return image }
    let scale = min(1.0, min(maxPixelWidth / w, maxPixelHeight / h))
    if scale >= 0.99 {
        return image
    }
    if let lanczos = CIFilter(name: "CILanczosScaleTransform") {
        lanczos.setValue(image, forKey: kCIInputImageKey)
        lanczos.setValue(scale, forKey: kCIInputScaleKey)
        lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)
        if let out = lanczos.outputImage {
            return normalizeOrigin(out)
        }
    }
    return image
}

func writeManifest(_ summary: SummaryOutput, to manifestPath: String?) {
    guard let manifestPath else { return }
    let expanded = (manifestPath as NSString).expandingTildeInPath
    let manifestURL = URL(fileURLWithPath: expanded)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(summary)
        try data.write(to: manifestURL, options: .atomic)
    } catch {
        fputs("[WARN] Failed to write manifest to \(manifestURL.path): \(error.localizedDescription)\n", stderr)
    }
}

func main() -> Int32 {
    guard let config = parseArgs() else { return 1 }

    let candidates = collectInputCandidates(inputs: config.inputs)
    if candidates.isEmpty {
        fputs("[ERROR] No valid input images found.\n", stderr)
        writeManifest(
            SummaryOutput(
                engine: "pure_swift_vision",
                output: config.outputPath.isEmpty ? nil : config.outputPath,
                pages: 0,
                pages_error: 0,
                size_bytes: 0,
                results: []
            ),
            to: config.manifestPath
        )
        return 1
    }

    let fm = FileManager.default
    var outputURL: URL? = nil
    var pdfContext: CGContext? = nil
    if !config.outputPath.isEmpty {
        let outputExpanded = (config.outputPath as NSString).expandingTildeInPath
        let u = URL(fileURLWithPath: outputExpanded)
        try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        var dummyBox = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        guard let ctx = CGContext(u as CFURL, mediaBox: &dummyBox, nil) else {
            fputs("[ERROR] Could not create PDF context at \(u.path)\n", stderr)
            return 1
        }
        outputURL = u
        pdfContext = ctx
    }

    var emitDirURL: URL? = nil
    if let dir = config.emitDir {
        let expandedDir = (dir as NSString).expandingTildeInPath
        let u = URL(fileURLWithPath: expandedDir)
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        emitDirURL = u
    }

    var debugDirURL: URL? = nil
    if let dir = config.saveDebugDir {
        let expandedDir = (dir as NSString).expandingTildeInPath
        let u = URL(fileURLWithPath: expandedDir)
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        debugDirURL = u
    }

    let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    var results: [PageResult] = []
    var renderedPages = 0
    var errorPages = 0

    for (idx, candidate) in candidates.enumerated() {
        autoreleasepool {
            let imgURL = candidate.url
            if let preErr = candidate.preflightError {
                errorPages += 1
                results.append(PageResult(
                    index: idx,
                    input: candidate.canonicalPath,
                    file: imgURL.lastPathComponent,
                    status: "error",
                    output: nil,
                    message: preErr,
                    detected: false,
                    method: "none",
                    confidence: 0.0,
                    width: 0,
                    height: 0,
                    quad: nil
                ))
                return
            }

            guard let rawCI = CIImage(contentsOf: imgURL, options: [.applyOrientationProperty: true]),
                  rawCI.extent.width > 0, rawCI.extent.height > 0 else {
                let msg = "Failed to load image: \(imgURL.lastPathComponent)"
                fputs("[WARN] \(msg)\n", stderr)
                errorPages += 1
                results.append(PageResult(
                    index: idx,
                    input: candidate.canonicalPath,
                    file: imgURL.lastPathComponent,
                    status: "error",
                    output: nil,
                    message: msg,
                    detected: false,
                    method: "none",
                    confidence: 0.0,
                    width: 0,
                    height: 0,
                    quad: nil
                ))
                return
            }

            var working = normalizeOrigin(rawCI)
            var detected = false
            var method = "none"
            var confidence: Float = 0.0
            var quadPixels: [[Double]]? = nil
            let origW = Int(working.extent.width)
            let origH = Int(working.extent.height)

            if !config.noCrop {
                if let (obs, detMethod) = detectDocumentQuad(in: working, minConfidence: config.minConfidence) {
                    detected = true
                    method = detMethod
                    confidence = obs.confidence
                    let ext = working.extent
                    quadPixels = [
                        [Double(obs.topLeft.x * ext.width), Double((1.0 - obs.topLeft.y) * ext.height)],
                        [Double(obs.topRight.x * ext.width), Double((1.0 - obs.topRight.y) * ext.height)],
                        [Double(obs.bottomRight.x * ext.width), Double((1.0 - obs.bottomRight.y) * ext.height)],
                        [Double(obs.bottomLeft.x * ext.width), Double((1.0 - obs.bottomLeft.y) * ext.height)],
                    ]
                    if !config.quadOnly, let warped = applyPerspectiveCorrection(to: working, observation: obs) {
                        working = warped
                    }
                } else {
                    fputs("[WARN] No document boundary detected for \(imgURL.lastPathComponent), using full image\n", stderr)
                }
            }

            if config.quadOnly {
                renderedPages += 1
                results.append(PageResult(
                    index: idx,
                    input: candidate.canonicalPath,
                    file: imgURL.lastPathComponent,
                    status: "ok",
                    output: nil,
                    message: "",
                    detected: detected,
                    method: method,
                    confidence: confidence,
                    width: origW,
                    height: origH,
                    quad: quadPixels
                ))
                return
            }

            working = flattenOverWhite(working)
            working = applyEnhancement(to: working, mode: config.mode)

            let pageSize = pageDimensions(option: config.pageSize, imageSize: working.extent.size, dpi: config.dpi)
            let effectiveMargin = (config.pageSize == .fit) ? 0.0 : config.margin
            let availW = max(10.0, pageSize.width - 2.0 * effectiveMargin)
            let availH = max(10.0, pageSize.height - 2.0 * effectiveMargin)

            if config.pageSize != .fit {
                let maxPixW = availW * config.dpi / 72.0
                let maxPixH = availH * config.dpi / 72.0
                working = downscaleIfNeeded(working, maxPixelWidth: maxPixW, maxPixelHeight: maxPixH)
            }

            let jpegOpts: [CIImageRepresentationOption: Any] = [
                kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: Double(config.jpegQuality) / 100.0
            ]
            let targetCS = (config.mode == .grayscale || config.mode == .bw)
                ? CGColorSpaceCreateDeviceGray()
                : colorSpace
            guard let jpegData = ciContext.jpegRepresentation(of: working, colorSpace: targetCS, options: jpegOpts),
                  let dataProvider = CGDataProvider(data: jpegData as CFData),
                  let cgImg = CGImage(
                      jpegDataProviderSource: dataProvider,
                      decode: nil,
                      shouldInterpolate: true,
                      intent: .defaultIntent
                  ) else {
                let msg = "Failed to encode JPEG for \(imgURL.lastPathComponent)"
                fputs("[WARN] \(msg)\n", stderr)
                errorPages += 1
                results.append(PageResult(
                    index: idx,
                    input: candidate.canonicalPath,
                    file: imgURL.lastPathComponent,
                    status: "error",
                    output: nil,
                    message: msg,
                    detected: detected,
                    method: method,
                    confidence: confidence,
                    width: 0,
                    height: 0,
                    quad: quadPixels
                ))
                return
            }

            let safeStem = sanitizeFileStem(imgURL.deletingPathExtension().lastPathComponent)
            var emittedOutputPath: String? = nil

            if let emitDir = emitDirURL {
                let emitFile = emitDir.appendingPathComponent(String(format: "%04d_%@_scanned.jpg", idx + 1, safeStem))
                do {
                    try jpegData.write(to: emitFile, options: .atomic)
                    emittedOutputPath = canonicalPath(emitFile)
                } catch {
                    let msg = "Failed to write emitted image for \(imgURL.lastPathComponent): \(error.localizedDescription)"
                    fputs("[WARN] \(msg)\n", stderr)
                    errorPages += 1
                    results.append(PageResult(
                        index: idx,
                        input: candidate.canonicalPath,
                        file: imgURL.lastPathComponent,
                        status: "error",
                        output: nil,
                        message: msg,
                        detected: detected,
                        method: method,
                        confidence: confidence,
                        width: cgImg.width,
                        height: cgImg.height,
                        quad: quadPixels
                    ))
                    return
                }
            }

            if let debugDir = debugDirURL {
                let debugFile = debugDir.appendingPathComponent(String(format: "%02d_%@_scanned.jpg", idx + 1, safeStem))
                do {
                    try jpegData.write(to: debugFile, options: .atomic)
                    if emittedOutputPath == nil {
                        emittedOutputPath = canonicalPath(debugFile)
                    }
                } catch {
                    fputs("[WARN] Failed to write debug image to \(debugFile.path): \(error.localizedDescription)\n", stderr)
                }
            }

            if let pdfContext {
                let imgW = Double(cgImg.width)
                let imgH = Double(cgImg.height)
                let drawScale = min(availW / imgW, availH / imgH)
                let drawW = imgW * drawScale
                let drawH = imgH * drawScale
                let drawX = (pageSize.width - drawW) / 2.0
                let drawY = (pageSize.height - drawH) / 2.0
                let drawRect = CGRect(x: drawX, y: drawY, width: drawW, height: drawH)

                var mediaBox = CGRect(origin: .zero, size: pageSize)
                let pageInfo: [CFString: Any] = [kCGPDFContextMediaBox: NSData(bytes: &mediaBox, length: MemoryLayout<CGRect>.size)]
                pdfContext.beginPDFPage(pageInfo as CFDictionary)
                pdfContext.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
                pdfContext.fill(mediaBox)
                pdfContext.draw(cgImg, in: drawRect)
                pdfContext.endPDFPage()
            }

            renderedPages += 1
            results.append(PageResult(
                index: idx,
                input: candidate.canonicalPath,
                file: imgURL.lastPathComponent,
                status: "ok",
                output: emittedOutputPath,
                message: "",
                detected: detected,
                method: method,
                confidence: confidence,
                width: cgImg.width,
                height: cgImg.height,
                quad: quadPixels
            ))
        }
    }

    pdfContext?.closePDF()

    var fileSize: Int64 = 0
    if let outputURL {
        if renderedPages == 0 {
            try? fm.removeItem(at: outputURL)
        } else {
            let attrs = try? fm.attributesOfItem(atPath: outputURL.path)
            fileSize = (attrs?[.size] as? Int64) ?? 0
        }
    }

    let summary = SummaryOutput(
        engine: "pure_swift_vision",
        output: renderedPages > 0 ? outputURL?.path : nil,
        pages: renderedPages,
        pages_error: errorPages,
        size_bytes: fileSize,
        results: results
    )
    writeManifest(summary, to: config.manifestPath)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let jsonData = try? encoder.encode(summary), let jsonStr = String(data: jsonData, encoding: .utf8) {
        print(jsonStr)
    }

    if renderedPages == 0 {
        fputs("[ERROR] Zero pages rendered.\n", stderr)
        return 1
    }

    return 0
}

exit(main())
