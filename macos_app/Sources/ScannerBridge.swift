import Foundation

enum ScannerBridgeError: LocalizedError {
    case workspaceNotFound
    case scriptNotFound(String)
    case processFailed(Int32, String)
    case noPreviewGenerated

    var errorDescription: String? {
        switch self {
        case .workspaceNotFound:
            return "Không tìm thấy thư mục tài nguyên PDF Scanner (chứa scripts/batch_scanner.py)."
        case .scriptNotFound(let path):
            return "Không tìm thấy script xử lý tại: \(path)"
        case .processFailed(let code, let details):
            return "Tiến trình thất bại (mã \(code)): \(details)"
        case .noPreviewGenerated:
            return "Pipeline hoàn tất nhưng không tạo được ảnh xem trước."
        }
    }
}

private final class LinePipeAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var remainder = ""
    private let prefix: String
    private let onLog: (String) -> Void

    init(prefix: String, onLog: @escaping (String) -> Void) {
        self.prefix = prefix
        self.onLog = onLog
    }

    func append(_ data: Data) {
        guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        remainder.append(chunk)
        let lines = remainder.components(separatedBy: "\n")
        remainder = lines.last ?? ""
        lock.unlock()

        for line in lines.dropLast() {
            let clean = line.trimmingCharacters(in: .newlines)
            if !clean.isEmpty {
                onLog(prefix.isEmpty ? clean : "\(prefix)\(clean)")
            }
        }
    }

    func flush(trailingData: Data) {
        append(trailingData)
        lock.lock()
        let left = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        remainder = ""
        lock.unlock()
        if !left.isEmpty {
            onLog(prefix.isEmpty ? left : "\(prefix)\(left)")
        }
    }
}

final class ScannerBridge {
    let workspaceRoot: URL
    let pythonURL: URL
    let swiftURL: URL
    let batchScannerScript: URL
    let docScannerScript: URL

    private var activeProcess: Process?
    private let processLock = NSLock()

    init() throws {
        let root = try Self.discoverWorkspaceRoot()
        self.workspaceRoot = root
        self.batchScannerScript = root.appendingPathComponent("scripts/batch_scanner.py")
        self.docScannerScript = root.appendingPathComponent("scripts/doc_scanner.swift")
        self.pythonURL = Self.discoverPython(root: root)
        self.swiftURL = URL(fileURLWithPath: "/usr/bin/swift")
    }

    private var isBundledResourcesRoot: Bool {
        guard let resURL = Bundle.main.resourceURL else { return false }
        return workspaceRoot.standardizedFileURL == resURL.standardizedFileURL
    }

    var defaultInputDir: URL {
        if isBundledResourcesRoot {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/PDF Scanner/input")
        }
        return workspaceRoot.appendingPathComponent("input")
    }

    var defaultOutputDir: URL {
        if isBundledResourcesRoot {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/PDF Scanner/output")
        }
        return workspaceRoot.appendingPathComponent("output")
    }

    private static func discoverWorkspaceRoot() throws -> URL {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let envRoot = ProcessInfo.processInfo.environment["PDF_SCANNER_ROOT"], !envRoot.isEmpty {
            candidates.append(URL(fileURLWithPath: envRoot))
        }
        candidates.append(Bundle.main.bundleURL.deletingLastPathComponent())
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL)
        }
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath))

        for dir in candidates {
            let probe = dir.appendingPathComponent("scripts/batch_scanner.py")
            if fm.fileExists(atPath: probe.path) {
                return dir
            }
        }
        throw ScannerBridgeError.workspaceNotFound
    }

    private static func discoverPython(root: URL) -> URL {
        let fm = FileManager.default
        let candidates = [
            root.appendingPathComponent(".venv/bin/python3").path,
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".venv/bin/python3").path,
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: "/usr/bin/python3")
    }

    func cancelActiveProcess() {
        processLock.lock()
        let proc = activeProcess
        processLock.unlock()
        if let proc, proc.isRunning {
            proc.terminate()
        }
    }

    func previewSinglePage(
        item: InputPageItem,
        settings: ScanSettings,
        onLog: @escaping (String) -> Void
    ) async throws -> URL {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("pdfscanner_preview_\(UUID().uuidString)")
        let stageDir = workDir.appendingPathComponent("stage")
        let debugDir = workDir.appendingPathComponent("debug")
        let dummyPDF = workDir.appendingPathComponent("preview.pdf")

        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: debugDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stageDir) }

        onLog("[Preview] Chuẩn bị trang: \(item.displayName)...")
        let staged = try PDFToolsService.stageItemToImageFile(item: item, index: 0, stagingDir: stageDir)

        try await executePipeline(
            inputPathOrFiles: settings.engine == .pureSwiftVision ? [staged.path] : [stageDir.path],
            outputPDF: dummyPDF,
            debugDir: debugDir,
            settings: settings,
            onLog: onLog
        )

        let generated = try findSortedDebugImages(in: debugDir)
        guard let firstImage = generated.first else {
            throw ScannerBridgeError.noPreviewGenerated
        }

        let cacheDir = fm.temporaryDirectory.appendingPathComponent("pdfscanner_app_previews")
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let persistentPreview = cacheDir.appendingPathComponent("\(item.id.uuidString)_\(UUID().uuidString.prefix(6)).jpg")
        try fm.copyItem(at: firstImage, to: persistentPreview)
        try? fm.removeItem(at: workDir)
        return persistentPreview
    }

    func runBatchScan(
        items: [InputPageItem],
        settings: ScanSettings,
        outputPDF: URL,
        onLog: @escaping (String) -> Void
    ) async throws -> [URL] {
        guard !items.isEmpty else {
            throw PDFToolError.emptyInput("Danh sách trang đang trống.")
        }

        let fm = FileManager.default
        try fm.createDirectory(at: outputPDF.deletingLastPathComponent(), withIntermediateDirectories: true)

        var resolvedURLs: [URL?] = Array(repeating: nil, count: items.count)
        var missingIndices: [Int] = []
        for (idx, item) in items.enumerated() {
            if let cached = item.processedPreviewURL, fm.fileExists(atPath: cached.path) {
                resolvedURLs[idx] = cached
            } else {
                missingIndices.append(idx)
            }
        }

        if missingIndices.isEmpty {
            let readyURLs = resolvedURLs.compactMap { $0 }
            onLog("[Cache] Tái sử dụng toàn bộ \(readyURLs.count) trang đã scan -> đóng gói PDF tức thì...")
            try PDFToolsService.compileProcessedImagesToPDF(
                imageURLs: readyURLs,
                destinationURL: outputPDF,
                settings: settings
            )
            return readyURLs
        }

        let workDir = fm.temporaryDirectory.appendingPathComponent("pdfscanner_batch_\(UUID().uuidString)")
        let stageDir = workDir.appendingPathComponent("stage")
        let debugDir = workDir.appendingPathComponent("debug")
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: debugDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let allMissing = missingIndices.count == items.count
        let reusedCount = items.count - missingIndices.count
        if reusedCount > 0 {
            onLog("[Batch] Tái sử dụng \(reusedCount) trang đã scan, chỉ xử lý \(missingIndices.count) trang còn lại...")
        } else {
            onLog("[Stage] Đang chuẩn hóa \(items.count) trang đầu vào...")
        }

        var stagedFiles: [URL] = []
        for (seq, idx) in missingIndices.enumerated() {
            let staged = try PDFToolsService.stageItemToImageFile(item: items[idx], index: seq, stagingDir: stageDir)
            stagedFiles.append(staged)
        }

        let inputArgs = settings.engine == .pureSwiftVision
            ? stagedFiles.map { $0.path }
            : [stageDir.path]
        let pipelinePDF = allMissing ? outputPDF : workDir.appendingPathComponent("partial.pdf")

        try await executePipeline(
            inputPathOrFiles: inputArgs,
            outputPDF: pipelinePDF,
            debugDir: debugDir,
            settings: settings,
            onLog: onLog
        )

        let debugImages = try findSortedDebugImages(in: debugDir)
        let cacheDir = fm.temporaryDirectory.appendingPathComponent("pdfscanner_app_previews")
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        for (seq, idx) in missingIndices.enumerated() where seq < debugImages.count {
            let dbg = debugImages[seq]
            let dest = cacheDir.appendingPathComponent("\(items[idx].id.uuidString)_\(UUID().uuidString.prefix(6)).jpg")
            try? fm.copyItem(at: dbg, to: dest)
            resolvedURLs[idx] = dest
        }

        let finalURLs = resolvedURLs.compactMap { $0 }
        guard finalURLs.count == items.count else {
            throw ScannerBridgeError.noPreviewGenerated
        }

        if !allMissing {
            onLog("[Batch] Đang đóng gói \(finalURLs.count) trang thành file PDF...")
            try PDFToolsService.compileProcessedImagesToPDF(
                imageURLs: finalURLs,
                destinationURL: outputPDF,
                settings: settings
            )
        }
        return finalURLs
    }

    func compressPDF(
        sourcePDF: URL,
        outputPDF: URL,
        dpi: Int,
        mode: EnhanceMode,
        autoCrop: Bool,
        onLog: @escaping (String) -> Void
    ) async throws -> CompressionResult {
        let fm = FileManager.default
        let beforeAttr = try fm.attributesOfItem(atPath: sourcePDF.path)
        let beforeBytes = (beforeAttr[.size] as? Int64) ?? 0

        let items = PDFToolsService.loadInputItems(from: [sourcePDF])
        guard !items.isEmpty else {
            throw PDFToolError.invalidPDF(sourcePDF)
        }

        var settings = ScanSettings()
        settings.engine = .hybridOpenCV
        settings.mode = mode
        settings.dpi = dpi
        settings.autoCrop = autoCrop
        settings.multipointPoints = autoCrop ? 32 : 0
        settings.flattenSurface = autoCrop
        settings.balanceSymmetry = autoCrop
        settings.pageSize = .a4

        _ = try await runBatchScan(
            items: items,
            settings: settings,
            outputPDF: outputPDF,
            onLog: onLog
        )

        let afterAttr = try fm.attributesOfItem(atPath: outputPDF.path)
        let afterBytes = (afterAttr[.size] as? Int64) ?? 0
        return CompressionResult(
            outputURL: outputPDF,
            beforeBytes: beforeBytes,
            afterBytes: afterBytes,
            pageCount: items.count
        )
    }

    private func findSortedDebugImages(in dir: URL) throws -> [URL] {
        let entries = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return entries
            .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func executePipeline(
        inputPathOrFiles: [String],
        outputPDF: URL,
        debugDir: URL,
        settings: ScanSettings,
        onLog: @escaping (String) -> Void
    ) async throws {
        let executable: URL
        var args: [String] = []

        switch settings.engine {
        case .hybridOpenCV:
            guard FileManager.default.fileExists(atPath: batchScannerScript.path) else {
                throw ScannerBridgeError.scriptNotFound(batchScannerScript.path)
            }
            executable = pythonURL
            args.append(batchScannerScript.path)
            args.append(contentsOf: inputPathOrFiles)
            args.append(contentsOf: ["--output", outputPDF.path])
            args.append(contentsOf: ["--mode", settings.mode.rawValue])
            args.append(contentsOf: ["--crop-engine", settings.cropEngine.rawValue])
            args.append(contentsOf: ["--multipoint-points", String(settings.multipointPoints)])
            args.append(contentsOf: ["--page-size", settings.pageSize.rawValue])
            args.append(contentsOf: ["--dpi", String(settings.dpi)])
            args.append(contentsOf: ["--margin", String(format: "%.1f", settings.margin)])
            args.append(contentsOf: ["--min-confidence", String(format: "%.2f", settings.minConfidence)])
            args.append(contentsOf: ["--save-debug", debugDir.path])
            if !settings.autoCrop { args.append("--no-crop") }
            if !settings.flattenSurface { args.append("--no-flatten") }
            if !settings.balanceSymmetry { args.append("--no-symmetry") }

        case .pureSwiftVision:
            guard FileManager.default.fileExists(atPath: docScannerScript.path) else {
                throw ScannerBridgeError.scriptNotFound(docScannerScript.path)
            }
            executable = swiftURL
            args.append(docScannerScript.path)
            args.append(contentsOf: ["--output", outputPDF.path])
            args.append(contentsOf: ["--mode", settings.mode.swiftVisionFallbackMode])
            args.append(contentsOf: ["--page-size", settings.pageSize.rawValue])
            args.append(contentsOf: ["--dpi", String(settings.dpi)])
            args.append(contentsOf: ["--margin", String(format: "%.1f", settings.margin)])
            args.append(contentsOf: ["--min-confidence", String(format: "%.2f", settings.minConfidence)])
            args.append(contentsOf: ["--save-debug", debugDir.path])
            if !settings.autoCrop { args.append("--no-crop") }
            args.append(contentsOf: inputPathOrFiles)
        }

        onLog("[Exec] \(executable.lastPathComponent) \(args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " "))")

        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"

        let status = try await runProcessStreaming(
            executableURL: executable,
            arguments: args,
            environment: env,
            workingDirectory: workspaceRoot,
            onLog: onLog
        )
        if status != 0 {
            throw ScannerBridgeError.processFailed(status, "Xem chi tiết trong Console Log bên dưới.")
        }
    }

    private func runProcessStreaming(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        onLog: @escaping (String) -> Void
    ) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = workingDirectory

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let outAccumulator = LinePipeAccumulator(prefix: "", onLog: onLog)
            let errAccumulator = LinePipeAccumulator(prefix: "[stderr] ", onLog: onLog)

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                outAccumulator.append(data)
            }

            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                errAccumulator.append(data)
            }

            process.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil

                let tailOut = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                let tailErr = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()

                outAccumulator.flush(trailingData: tailOut)
                errAccumulator.flush(trailingData: tailErr)

                self.processLock.lock()
                self.activeProcess = nil
                self.processLock.unlock()

                continuation.resume(returning: proc.terminationStatus)
            }

            do {
                self.processLock.lock()
                self.activeProcess = process
                self.processLock.unlock()
                try process.run()
            } catch {
                self.processLock.lock()
                self.activeProcess = nil
                self.processLock.unlock()
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
