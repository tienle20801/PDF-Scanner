import Foundation
import PDFKit

enum ScannerBridgeError: LocalizedError {
    case workspaceNotFound
    case scriptNotFound(String)
    case processFailed(Int32, String)
    case noPreviewGenerated
    case pageProcessingFailed(String)

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
        case .pageProcessingFailed(let details):
            return details
        }
    }
}

struct ManifestPageResult: Decodable {
    let index: Int
    let input: String
    let file: String?
    let status: String
    let output: String?
    let message: String?
    let method: String?
    let confidence: Double?
    let width: Int?
    let height: Int?
}

struct PipelineManifest: Decodable {
    let engine: String?
    let output: String?
    let pages: Int?
    let pages_error: Int?
    let results: [ManifestPageResult]
}

struct BatchScanResult {
    let resolvedURLs: [UUID: URL]
    let errors: [UUID: String]
}

private let ignoreSIGPIPEOnce: Void = {
    signal(SIGPIPE, SIG_IGN)
}()

private final class LinePipeAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var byteBuffer = Data()
    private let prefix: String
    private let onLog: @Sendable (String) -> Void

    init(prefix: String, onLog: @escaping @Sendable (String) -> Void) {
        self.prefix = prefix
        self.onLog = onLog
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        var completedLines: [String] = []
        lock.lock()
        byteBuffer.append(data)
        var searchStart = byteBuffer.startIndex
        while let nlIndex = byteBuffer[searchStart...].firstIndex(of: 0x0A) {
            let lineSlice = byteBuffer[searchStart..<nlIndex]
            let clean = String(decoding: lineSlice, as: UTF8.self)
                .trimmingCharacters(in: .newlines)
            if !clean.isEmpty {
                completedLines.append(prefix.isEmpty ? clean : "\(prefix)\(clean)")
            }
            searchStart = byteBuffer.index(after: nlIndex)
        }
        if searchStart > byteBuffer.startIndex {
            byteBuffer.removeSubrange(byteBuffer.startIndex..<searchStart)
        }
        lock.unlock()

        for line in completedLines {
            onLog(line)
        }
    }

    func flush(trailingData: Data) {
        if !trailingData.isEmpty {
            append(trailingData)
        }
        let left: String?
        lock.lock()
        if !byteBuffer.isEmpty {
            let decoded = String(decoding: byteBuffer, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            byteBuffer.removeAll()
            left = decoded.isEmpty ? nil : (prefix.isEmpty ? decoded : "\(prefix)\(decoded)")
        } else {
            left = nil
        }
        lock.unlock()
        if let left {
            onLog(left)
        }
    }
}

private struct CompressorJSONReport: Decodable {
    let before_bytes: Int64
    let after_bytes: Int64
    let pages: Int
    let vector_pages: Int
    let image_pages: Int
    let recompressed_images: Int
    let target_bytes: Int64
    let target_achieved: Bool
    let used_dpi: Int
    let used_quality: Int
    let message: String
}

private struct WorkerJobResponse: Decodable {
    let id: String?
    let status: String
    let output: String?
    let message: String?
    let method: String?
    let confidence: Double?
    let width: Int?
    let height: Int?
}

private final class JobCancelState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private final class PersistentPythonWorker: @unchecked Sendable {
    private let pythonURL: URL
    private let pythonFlags: [String]
    private let scriptURL: URL
    private let environment: [String: String]
    private let workingDirectory: URL
    private let serialQueue = DispatchQueue(label: "com.pdfscanner.app.pythonworker", qos: .userInitiated)
    private let stateLock = NSLock()

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var logHandler: (@Sendable (String) -> Void)?

    init(
        pythonURL: URL,
        pythonFlags: [String],
        scriptURL: URL,
        environment: [String: String],
        workingDirectory: URL
    ) {
        _ = ignoreSIGPIPEOnce
        self.pythonURL = pythonURL
        self.pythonFlags = pythonFlags
        self.scriptURL = scriptURL
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    deinit {
        terminate()
    }

    func terminate() {
        stateLock.lock()
        let proc = process
        let inH = stdinHandle
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        logHandler = nil
        stateLock.unlock()

        try? inH?.close()
        if let proc, proc.isRunning {
            proc.terminate()
        }
    }

    private func ensureRunningLocked() throws {
        if let proc = process, proc.isRunning, stdinHandle != nil, stdoutHandle != nil {
            return
        }

        let proc = Process()
        proc.executableURL = pythonURL
        proc.arguments = pythonFlags + [scriptURL.path, "--worker-stdio"]
        proc.environment = environment
        proc.currentDirectoryURL = workingDirectory

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let errAccumulator = LinePipeAccumulator(prefix: "") { [weak self] cleanLine in
            guard let self else { return }
            self.stateLock.lock()
            let sink = self.logHandler
            self.stateLock.unlock()
            sink?(cleanLine)
        }

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                errAccumulator.flush(trailingData: Data())
            } else {
                errAccumulator.append(data)
            }
        }

        proc.terminationHandler = { [weak self] finishedProc in
            errPipe.fileHandleForReading.readabilityHandler = nil
            errAccumulator.flush(trailingData: Data())
            self?.stateLock.lock()
            if self?.process === finishedProc {
                self?.process = nil
                self?.stdinHandle = nil
                self?.stdoutHandle = nil
            }
            self?.stateLock.unlock()
        }

        do {
            try proc.run()
        } catch {
            errPipe.fileHandleForReading.readabilityHandler = nil
            proc.terminationHandler = nil
            throw error
        }
        self.process = proc
        self.stdinHandle = inPipe.fileHandleForWriting
        self.stdoutHandle = outPipe.fileHandleForReading
    }

    private func readJSONLine(from handle: FileHandle) -> Data? {
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                return buffer.isEmpty ? nil : buffer
            }
            if let nlRange = chunk.firstIndex(of: 0x0A) {
                buffer.append(chunk[..<nlRange])
                return buffer
            }
            buffer.append(chunk)
        }
    }

    func runJob(
        payload: [String: Any],
        onLog: @escaping @Sendable (String) -> Void
    ) async throws -> WorkerJobResponse {
        try Task.checkCancellation()
        let reqData = try JSONSerialization.data(withJSONObject: payload, options: [])
        let lineData = reqData + Data([0x0A])
        let cancelState = JobCancelState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                serialQueue.async { [weak self] in
                    guard let self else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    if cancelState.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    do {
                        let (inH, outH): (FileHandle, FileHandle) = try {
                            self.stateLock.lock()
                            defer { self.stateLock.unlock() }
                            if cancelState.isCancelled {
                                throw CancellationError()
                            }
                            self.logHandler = onLog
                            try self.ensureRunningLocked()
                            guard let inH = self.stdinHandle, let outH = self.stdoutHandle else {
                                throw ScannerBridgeError.processFailed(-1, "Không khởi chạy được worker Python.")
                            }
                            return (inH, outH)
                        }()

                        try inH.write(contentsOf: lineData)
                        guard let respData = self.readJSONLine(from: outH) else {
                            if cancelState.isCancelled {
                                throw CancellationError()
                            }
                            throw ScannerBridgeError.processFailed(-1, "Worker Python đóng kết nối đột ngột.")
                        }
                        let decoded = try JSONDecoder().decode(WorkerJobResponse.self, from: respData)
                        self.stateLock.lock()
                        self.logHandler = nil
                        self.stateLock.unlock()
                        continuation.resume(returning: decoded)
                    } catch {
                        self.terminate()
                        continuation.resume(throwing: cancelState.isCancelled ? CancellationError() : error)
                    }
                }
            }
        } onCancel: { [weak self] in
            cancelState.cancel()
            self?.terminate()
        }
    }
}

private final class ProcessRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var resumed = false
    let process = Process()

    func markCancelled() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func claimResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        return true
    }
}

final class ScannerBridge: @unchecked Sendable {
    let workspaceRoot: URL
    let pythonURL: URL
    let bundledPythonRoot: URL?
    let swiftURL: URL
    let batchScannerScript: URL
    let pdfCompressorScript: URL
    let docScannerScript: URL
    let precompiledDocScannerURL: URL?

    private var activeInvocation: ProcessRunState?
    private let processLock = NSLock()
    private let workerLock = NSLock()
    private var persistentWorker: PersistentPythonWorker?

    init() throws {
        _ = ignoreSIGPIPEOnce
        let root = try Self.discoverWorkspaceRoot()
        self.workspaceRoot = root
        self.batchScannerScript = root.appendingPathComponent("scripts/batch_scanner.py")
        self.pdfCompressorScript = root.appendingPathComponent("scripts/pdf_compressor.py")
        self.docScannerScript = root.appendingPathComponent("scripts/doc_scanner.swift")
        let pyResolved = Self.discoverPython(root: root)
        self.pythonURL = pyResolved.pythonURL
        self.bundledPythonRoot = pyResolved.bundledRoot
        self.precompiledDocScannerURL = Self.discoverPrecompiledDocScanner(root: root)
        self.swiftURL = URL(fileURLWithPath: "/usr/bin/swift")
    }

    deinit {
        cancelActiveProcess()
    }

    var pythonIsolationFlags: [String] {
        bundledPythonRoot != nil ? ["-s"] : []
    }

    func configuredPythonEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        if let runtimeRoot = bundledPythonRoot {
            env["PYTHONHOME"] = runtimeRoot.path
            env["PYTHONPATH"] = runtimeRoot.appendingPathComponent("site-packages").path
        }
        return env
    }

    private static func discoverPrecompiledDocScanner(root: URL) -> URL? {
        let fm = FileManager.default
        let candidates: [URL] = [
            root.appendingPathComponent("bin/doc_scanner"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/doc_scanner"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/doc_scanner"),
            root.appendingPathComponent("scripts/doc_scanner")
        ]
        for url in candidates where fm.isExecutableFile(atPath: url.path) {
            return url
        }
        return nil
    }

    private static func discoverPython(root: URL) -> (pythonURL: URL, bundledRoot: URL?) {
        let fm = FileManager.default
        let bundledRoot = root.appendingPathComponent("python_runtime")
        let bundledBinDir = bundledRoot.appendingPathComponent("bin")
        if let binEntries = try? fm.contentsOfDirectory(
            at: bundledBinDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            let pyBins = binEntries
                .filter {
                    let name = $0.lastPathComponent
                    return (name == "python3" || name.hasPrefix("python3.")) && fm.isExecutableFile(atPath: $0.path)
                }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
            if let bundledPy = pyBins.first {
                return (bundledPy, bundledRoot)
            }
        }
        let candidates = [
            root.appendingPathComponent(".venv/bin/python3").path,
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".venv/bin/python3").path,
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return (URL(fileURLWithPath: path), nil)
        }
        return (URL(fileURLWithPath: "/usr/bin/python3"), nil)
    }

    private func getOrCreatePersistentWorker() -> PersistentPythonWorker {
        workerLock.lock()
        defer { workerLock.unlock() }
        if let existing = persistentWorker {
            return existing
        }
        let worker = PersistentPythonWorker(
            pythonURL: pythonURL,
            pythonFlags: pythonIsolationFlags,
            scriptURL: batchScannerScript,
            environment: configuredPythonEnvironment(),
            workingDirectory: workspaceRoot
        )
        persistentWorker = worker
        return worker
    }

    func terminateWorkers() {
        workerLock.lock()
        let worker = persistentWorker
        persistentWorker = nil
        workerLock.unlock()
        worker?.terminate()
    }

    func cancelActiveProcess() {
        terminateWorkers()
        processLock.lock()
        let inv = activeInvocation
        inv?.markCancelled()
        let proc = inv?.process
        processLock.unlock()
        if let proc, proc.isRunning {
            proc.terminate()
        }
    }

    private func cancelInvocationIfActive(_ state: ProcessRunState) {
        state.markCancelled()
        processLock.lock()
        let shouldTerminate = (activeInvocation === state)
        processLock.unlock()
        if shouldTerminate && state.process.isRunning {
            state.process.terminate()
        }
    }

    /// Preflight check (A1): verify Python dependencies (`cv2, numpy, PIL, pypdf`) and Vision helper binary/script.
    func runPreflightCheck() -> PreflightReport {
        let fm = FileManager.default
        let hasVision = precompiledDocScannerURL != nil ||
            (fm.isExecutableFile(atPath: swiftURL.path) && fm.fileExists(atPath: docScannerScript.path))

        guard fm.isExecutableFile(atPath: pythonURL.path) else {
            return PreflightReport(
                isHealthy: false,
                usingBundledPython: bundledPythonRoot != nil,
                pythonPath: pythonURL.path,
                pythonVersion: "Không tìm thấy",
                opencvVersion: "—",
                visionHelperAvailable: hasVision,
                summary: "Không tìm thấy Python runtime (\(pythonURL.lastPathComponent)).",
                remediation: "Build app qua macos_app/build_app.sh để đóng gói python_runtime hoặc chuyển sang chế độ Pure Swift Vision."
            )
        }

        let probeProc = Process()
        probeProc.executableURL = pythonURL
        probeProc.arguments = pythonIsolationFlags + [
            "-c",
            "import sys, cv2, numpy, PIL, pypdf; print(f'{sys.version.split()[0]}|{cv2.__version__}')"
        ]
        probeProc.environment = configuredPythonEnvironment()
        let outPipe = Pipe()
        let errPipe = Pipe()
        probeProc.standardOutput = outPipe
        probeProc.standardError = errPipe

        final class PipeDataBox: @unchecked Sendable {
            var data = Data()
        }
        let outBox = PipeDataBox()
        let errBox = PipeDataBox()
        let ioGroup = DispatchGroup()
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading

        do {
            try probeProc.run()
        } catch {
            return PreflightReport(
                isHealthy: false,
                usingBundledPython: bundledPythonRoot != nil,
                pythonPath: pythonURL.path,
                pythonVersion: "Lỗi khởi chạy",
                opencvVersion: "—",
                visionHelperAvailable: hasVision,
                summary: "Không chạy được Python: \(error.localizedDescription)",
                remediation: "Kiểm tra lại .venv hoặc chuyển Engine sang Pure Swift Vision."
            )
        }

        ioGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outBox.data = outHandle.readDataToEndOfFile()
            ioGroup.leave()
        }
        ioGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.data = errHandle.readDataToEndOfFile()
            ioGroup.leave()
        }
        ioGroup.wait()
        probeProc.waitUntilExit()

        let outStr = String(decoding: outBox.data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let errStr = String(decoding: errBox.data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let parts = outStr.split(separator: "|", maxSplits: 1).map(String.init)
        if probeProc.terminationStatus == 0,
           parts.count == 2,
           !parts[0].isEmpty,
           !parts[1].isEmpty {
            let pyVer = parts[0]
            let cvVer = parts[1]
            let runtimeLabel = bundledPythonRoot != nil ? "Bundled Python \(pyVer)" : "Python \(pyVer)"
            return PreflightReport(
                isHealthy: true,
                usingBundledPython: bundledPythonRoot != nil,
                pythonPath: pythonURL.path,
                pythonVersion: pyVer,
                opencvVersion: cvVer,
                visionHelperAvailable: hasVision,
                summary: "\(runtimeLabel) • OpenCV \(cvVer) • \(precompiledDocScannerURL != nil ? "Vision compiled" : (hasVision ? "Vision script" : "No Vision"))",
                remediation: nil
            )
        }

        return PreflightReport(
            isHealthy: false,
            usingBundledPython: bundledPythonRoot != nil,
            pythonPath: pythonURL.path,
            pythonVersion: "Thiếu thư viện",
            opencvVersion: "Thiếu",
            visionHelperAvailable: hasVision,
            summary: "Môi trường Python thiếu thư viện (cv2/numpy/Pillow/pypdf).",
            remediation: "Chạy `uv pip install -r requirements.txt` trong repo hoặc chọn Engine 'Pure Swift Vision'. Chi tiết: \(errStr.split(separator: "\n").last ?? "")"
        )
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

    static var previewCacheDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pdfscanner_app_previews_\(ProcessInfo.processInfo.processIdentifier)")
    }

    static func cleanupTemporaryCaches() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        try? fm.removeItem(at: previewCacheDirectory)
        let staleCutoff = Date().addingTimeInterval(-86_400)
        if let entries = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for url in entries {
                let name = url.lastPathComponent
                if name.hasPrefix("pdfscanner_preview_") || name.hasPrefix("pdfscanner_batch_") || name.hasPrefix("pdfscanner_app_previews_") {
                    if name == previewCacheDirectory.lastPathComponent {
                        continue
                    }
                    let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                    if mtime < staleCutoff {
                        try? fm.removeItem(at: url)
                    }
                }
            }
        }
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping
    }

    private func decodeManifest(at manifestURL: URL) throws -> PipelineManifest {
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(PipelineManifest.self, from: data)
    }

    func previewSinglePage(
        item: InputPageItem,
        settings: ScanSettings,
        onLog: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("pdfscanner_preview_\(UUID().uuidString)")
        let stageDir = workDir.appendingPathComponent("stage")
        let emitDir = workDir.appendingPathComponent("emit")
        let manifestURL = workDir.appendingPathComponent("manifest.json")

        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: emitDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        onLog("[Preview] Chuẩn bị trang: \(item.displayName)...")
        let staged = try PDFToolsService.stageItemToImageFile(item: item, index: 0, stagingDir: stageDir)

        var resolvedOutputPath: String?
        if settings.engine == .hybridOpenCV {
            guard fm.fileExists(atPath: batchScannerScript.path) else {
                throw ScannerBridgeError.scriptNotFound(batchScannerScript.path)
            }
            let worker = getOrCreatePersistentWorker()
            let payload: [String: Any] = [
                "id": item.id.uuidString,
                "input": staged.path,
                "emit_dir": emitDir.path,
                "mode": settings.mode.rawValue,
                "auto_crop": settings.autoCrop,
                "crop_engine": settings.cropEngine.rawValue,
                "multipoint_points": settings.multipointPoints,
                "page_size": settings.pageSize.rawValue,
                "dpi": settings.dpi,
                "margin": settings.margin,
                "flatten_surface": settings.flattenSurface,
                "balance_symmetry": settings.balanceSymmetry,
                "min_confidence": settings.minConfidence,
                "jpeg_quality": settings.jpegQuality
            ]
            let resp = try await worker.runJob(payload: payload, onLog: onLog)
            if resp.status != "ok" {
                let msg = (resp.message?.isEmpty == false) ? resp.message! : "Không tạo được ảnh xem trước."
                throw ScannerBridgeError.pageProcessingFailed(msg)
            }
            resolvedOutputPath = resp.output
        } else {
            do {
                try await executePipeline(
                    inputPathOrFiles: [staged.path],
                    outputPDF: nil,
                    emitDir: emitDir,
                    manifestURL: manifestURL,
                    settings: settings,
                    onLog: onLog
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if fm.fileExists(atPath: manifestURL.path),
                   let manifest = try? decodeManifest(at: manifestURL),
                   let entry = manifest.results.first,
                   entry.status != "ok",
                   let msg = entry.message, !msg.isEmpty {
                    throw ScannerBridgeError.pageProcessingFailed(msg)
                }
                throw error
            }

            guard fm.fileExists(atPath: manifestURL.path) else {
                throw ScannerBridgeError.noPreviewGenerated
            }
            let manifest = try decodeManifest(at: manifestURL)
            let targetKey = Self.canonicalPath(staged)
            let matched = manifest.results.first(where: { Self.canonicalPath(URL(fileURLWithPath: $0.input)) == targetKey })
                ?? manifest.results.first

            guard let entry = matched else {
                throw ScannerBridgeError.noPreviewGenerated
            }
            guard entry.status == "ok", let outPath = entry.output else {
                let msg = (entry.message?.isEmpty == false) ? entry.message! : "Không tạo được ảnh xem trước."
                throw ScannerBridgeError.pageProcessingFailed(msg)
            }
            resolvedOutputPath = outPath
        }

        guard let outPath = resolvedOutputPath, fm.fileExists(atPath: outPath) else {
            throw ScannerBridgeError.noPreviewGenerated
        }

        let outURL = URL(fileURLWithPath: outPath)
        let outExt = outURL.pathExtension.isEmpty ? "jpg" : outURL.pathExtension.lowercased()
        let cacheDir = Self.previewCacheDirectory
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let persistentPreview = cacheDir.appendingPathComponent("\(item.id.uuidString)_\(UUID().uuidString.prefix(6)).\(outExt)")
        try fm.copyItem(at: outURL, to: persistentPreview)
        return persistentPreview
    }

    func runBatchScan(
        items: [InputPageItem],
        settings: ScanSettings,
        outputPDF: URL,
        onLog: @escaping @Sendable (String) -> Void
    ) async throws -> BatchScanResult {
        try Task.checkCancellation()
        guard !items.isEmpty else {
            throw PDFToolError.emptyInput("Danh sách trang đang trống.")
        }

        let fm = FileManager.default
        try fm.createDirectory(at: outputPDF.deletingLastPathComponent(), withIntermediateDirectories: true)

        var resolvedMap: [UUID: URL] = [:]
        var itemErrors: [UUID: String] = [:]
        var missingIndices: [Int] = []

        for (idx, item) in items.enumerated() {
            let expectedKey = PDFToolsService.previewCacheKey(for: item, settings: settings)
            let keyValid = (item.processedCacheKey == expectedKey)
            if keyValid, let cached = item.processedPreviewURL, fm.fileExists(atPath: cached.path) {
                resolvedMap[item.id] = cached
            } else {
                missingIndices.append(idx)
            }
        }

        if missingIndices.isEmpty {
            let readyPairs = items.compactMap { item -> (URL, InputPageItem)? in
                resolvedMap[item.id].map { ($0, item) }
            }
            onLog("[Cache] Tái sử dụng toàn bộ \(readyPairs.count) trang đã scan -> đóng gói PDF tức thì...")
            try PDFToolsService.compileProcessedImagesToPDF(
                imageURLs: readyPairs.map { $0.0 },
                destinationURL: outputPDF,
                settings: settings,
                sourceItems: readyPairs.map { $0.1 }
            )
            return BatchScanResult(resolvedURLs: resolvedMap, errors: [:])
        }

        let workDir = fm.temporaryDirectory.appendingPathComponent("pdfscanner_batch_\(UUID().uuidString)")
        let stageDir = workDir.appendingPathComponent("stage")
        let emitDir = workDir.appendingPathComponent("emit")
        let manifestURL = workDir.appendingPathComponent("manifest.json")
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: emitDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let reusedCount = items.count - missingIndices.count
        if reusedCount > 0 {
            onLog("[Batch] Tái sử dụng \(reusedCount) trang đã scan, chỉ xử lý \(missingIndices.count) trang còn lại...")
        } else {
            onLog("[Stage] Đang chuẩn hóa \(items.count) trang đầu vào...")
        }

        var stagedFiles: [URL] = []
        var stagedPathToID: [String: UUID] = [:]
        for (seq, idx) in missingIndices.enumerated() {
            let item = items[idx]
            do {
                let staged = try PDFToolsService.stageItemToImageFile(item: item, index: seq, stagingDir: stageDir)
                stagedFiles.append(staged)
                stagedPathToID[Self.canonicalPath(staged)] = item.id
            } catch {
                let msg = error.localizedDescription
                itemErrors[item.id] = msg
                onLog("[WARN] Lỗi chuẩn hóa trang '\(item.displayName)': \(msg)")
            }
        }

        if !stagedFiles.isEmpty {
            let inputArgs = settings.engine == .pureSwiftVision
                ? stagedFiles.map { $0.path }
                : [stageDir.path]

            var pipelineFailure: Error?
            do {
                try await executePipeline(
                    inputPathOrFiles: inputArgs,
                    outputPDF: nil,
                    emitDir: emitDir,
                    manifestURL: manifestURL,
                    settings: settings,
                    onLog: onLog
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                pipelineFailure = error
            }
            try Task.checkCancellation()

            if fm.fileExists(atPath: manifestURL.path) {
                let manifest: PipelineManifest
                do {
                    manifest = try decodeManifest(at: manifestURL)
                } catch {
                    if let pipelineFailure { throw pipelineFailure }
                    throw error
                }
                let cacheDir = Self.previewCacheDirectory
                try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)

                var seenIDs: Set<UUID> = []
                for entry in manifest.results {
                    let canonInput = Self.canonicalPath(URL(fileURLWithPath: entry.input))
                    guard let itemID = stagedPathToID[canonInput] else { continue }
                    seenIDs.insert(itemID)

                    if entry.status == "ok", let outPath = entry.output, fm.fileExists(atPath: outPath) {
                        let outURL = URL(fileURLWithPath: outPath)
                        let outExt = outURL.pathExtension.isEmpty ? "jpg" : outURL.pathExtension.lowercased()
                        let dest = cacheDir.appendingPathComponent("\(itemID.uuidString)_\(UUID().uuidString.prefix(6)).\(outExt)")
                        do {
                            try fm.copyItem(at: outURL, to: dest)
                            resolvedMap[itemID] = dest
                        } catch {
                            itemErrors[itemID] = "Không thể lưu ảnh cache: \(error.localizedDescription)"
                        }
                    } else {
                        let msg = (entry.message?.isEmpty == false) ? entry.message! : "Không thể xử lý trang này."
                        itemErrors[itemID] = msg
                    }
                }

                for (_, itemID) in stagedPathToID where !seenIDs.contains(itemID) && itemErrors[itemID] == nil {
                    itemErrors[itemID] = "Trang không xuất hiện trong manifest kết quả."
                }
            } else if let pipelineFailure {
                throw pipelineFailure
            } else {
                throw ScannerBridgeError.noPreviewGenerated
            }
        }

        let validPairs = items.compactMap { item -> (URL, InputPageItem)? in
            resolvedMap[item.id].map { ($0, item) }
        }
        guard !validPairs.isEmpty else {
            let details = items.compactMap { item -> String? in
                guard let err = itemErrors[item.id] else { return nil }
                return "\(item.displayName): \(err)"
            }.joined(separator: "; ")
            throw ScannerBridgeError.pageProcessingFailed(
                details.isEmpty ? "Không có trang hợp lệ nào được xử lý." : "Tất cả trang đều lỗi (\(details))."
            )
        }

        onLog("[Batch] Đang đóng gói \(validPairs.count) trang hợp lệ thành file PDF...")
        try PDFToolsService.compileProcessedImagesToPDF(
            imageURLs: validPairs.map { $0.0 },
            destinationURL: outputPDF,
            settings: settings,
            sourceItems: validPairs.map { $0.1 }
        )
        return BatchScanResult(resolvedURLs: resolvedMap, errors: itemErrors)
    }

    /// Vector-preserving PDF compression (B5): preserves pure text/vector pages and shrinks embedded raster images with target-size search.
    func compressPDF(
        sourcePDF: URL,
        outputPDF: URL,
        dpi: Int = AppConstants.defaultCompressDPI,
        jpegQuality: Int = AppConstants.defaultCompressJPEGQuality,
        targetMB: Double = 0.0,
        mode: EnhanceMode = .original,
        autoCrop: Bool = false,
        onLog: @escaping @Sendable (String) -> Void
    ) async throws -> CompressionResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: pdfCompressorScript.path) else {
            throw ScannerBridgeError.scriptNotFound(pdfCompressorScript.path)
        }
        let reportURL = fm.temporaryDirectory.appendingPathComponent("pdfcomp_rep_\(UUID().uuidString).json")
        defer { try? fm.removeItem(at: reportURL) }

        var args = pythonIsolationFlags + [
            pdfCompressorScript.path,
            sourcePDF.path,
            outputPDF.path,
            "--dpi", String(max(72, dpi)),
            "--jpeg-quality", String(max(35, min(95, jpegQuality))),
            "--mode", mode.rawValue,
            "--json-report", reportURL.path
        ]
        if targetMB > 0 {
            args.append(contentsOf: ["--target-mb", String(format: "%.2f", targetMB)])
        }
        if autoCrop {
            args.append("--auto-crop")
        }

        onLog("[Compress] \(pythonURL.lastPathComponent) \(pdfCompressorScript.lastPathComponent) (dpi=\(dpi), target=\(targetMB > 0 ? String(format: "%.1f MB", targetMB) : "off"), mode=\(mode.title))")
        let status = try await runProcessStreaming(
            executableURL: pythonURL,
            arguments: args,
            environment: configuredPythonEnvironment(),
            workingDirectory: workspaceRoot,
            onLog: onLog
        )
        if status != 0 {
            throw ScannerBridgeError.processFailed(status, "Không thể nén PDF.")
        }

        if fm.fileExists(atPath: reportURL.path),
           let data = try? Data(contentsOf: reportURL),
           let rep = try? JSONDecoder().decode(CompressorJSONReport.self, from: data) {
            return CompressionResult(
                outputURL: outputPDF,
                beforeBytes: rep.before_bytes,
                afterBytes: rep.after_bytes,
                pageCount: rep.pages,
                vectorPagesPreserved: rep.vector_pages,
                imagePagesRecompressed: rep.image_pages,
                targetAchieved: rep.target_achieved,
                usedDPI: rep.used_dpi,
                usedQuality: rep.used_quality,
                detailsMessage: rep.message
            )
        }

        let beforeAttr = try fm.attributesOfItem(atPath: sourcePDF.path)
        let afterAttr = try fm.attributesOfItem(atPath: outputPDF.path)
        return CompressionResult(
            outputURL: outputPDF,
            beforeBytes: (beforeAttr[.size] as? Int64) ?? 0,
            afterBytes: (afterAttr[.size] as? Int64) ?? 0,
            pageCount: PDFDocument(url: outputPDF)?.pageCount ?? 0
        )
    }

    private func executePipeline(
        inputPathOrFiles: [String],
        outputPDF: URL?,
        emitDir: URL,
        manifestURL: URL,
        settings: ScanSettings,
        onLog: @escaping @Sendable (String) -> Void
    ) async throws {
        let executable: URL
        var args: [String] = []

        switch settings.engine {
        case .hybridOpenCV:
            guard FileManager.default.fileExists(atPath: batchScannerScript.path) else {
                throw ScannerBridgeError.scriptNotFound(batchScannerScript.path)
            }
            executable = pythonURL
            args.append(contentsOf: pythonIsolationFlags)
            args.append(batchScannerScript.path)
            args.append(contentsOf: inputPathOrFiles)
            if let outputPDF {
                args.append(contentsOf: ["--output", outputPDF.path])
            }
            args.append(contentsOf: ["--mode", settings.mode.rawValue])
            args.append(contentsOf: ["--crop-engine", settings.cropEngine.rawValue])
            args.append(contentsOf: ["--multipoint-points", String(settings.multipointPoints)])
            args.append(contentsOf: ["--page-size", settings.pageSize.rawValue])
            args.append(contentsOf: ["--dpi", String(settings.dpi)])
            args.append(contentsOf: ["--margin", String(format: "%.1f", settings.margin)])
            args.append(contentsOf: ["--jpeg-quality", String(settings.jpegQuality)])
            args.append(contentsOf: ["--min-confidence", String(format: "%.2f", settings.minConfidence)])
            args.append(contentsOf: ["--workers", "auto"])
            args.append(contentsOf: ["--emit-dir", emitDir.path])
            args.append(contentsOf: ["--manifest", manifestURL.path])
            if !settings.autoCrop { args.append("--no-crop") }
            if !settings.flattenSurface { args.append("--no-flatten") }
            if settings.balanceSymmetry {
                args.append("--symmetry")
            } else {
                args.append("--no-symmetry")
            }

        case .pureSwiftVision:
            if let compiled = precompiledDocScannerURL {
                executable = compiled
            } else {
                guard FileManager.default.fileExists(atPath: docScannerScript.path) else {
                    throw ScannerBridgeError.scriptNotFound(docScannerScript.path)
                }
                executable = swiftURL
                args.append(docScannerScript.path)
            }
            if let outputPDF {
                args.append(contentsOf: ["--output", outputPDF.path])
            }
            args.append(contentsOf: ["--mode", settings.mode.swiftVisionFallbackMode])
            args.append(contentsOf: ["--page-size", settings.pageSize.rawValue])
            args.append(contentsOf: ["--dpi", String(settings.dpi)])
            args.append(contentsOf: ["--margin", String(format: "%.1f", settings.margin)])
            args.append(contentsOf: ["--jpeg-quality", String(settings.jpegQuality)])
            args.append(contentsOf: ["--min-confidence", String(format: "%.2f", settings.minConfidence)])
            args.append(contentsOf: ["--emit-dir", emitDir.path])
            args.append(contentsOf: ["--manifest", manifestURL.path])
            if !settings.autoCrop { args.append("--no-crop") }
            args.append(contentsOf: inputPathOrFiles)
        }

        onLog("[Exec] \(executable.lastPathComponent) \(args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " "))")

        let env = configuredPythonEnvironment()
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
        onLog: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
        try Task.checkCancellation()
        let state = ProcessRunState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = state.process
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

                let ioGroup = DispatchGroup()
                ioGroup.enter()
                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        ioGroup.leave()
                    } else {
                        outAccumulator.append(data)
                    }
                }

                ioGroup.enter()
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        ioGroup.leave()
                    } else {
                        errAccumulator.append(data)
                    }
                }

                process.terminationHandler = { proc in
                    _ = ioGroup.wait(timeout: .now() + 2.0)
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil

                    outAccumulator.flush(trailingData: Data())
                    errAccumulator.flush(trailingData: Data())

                    self.processLock.lock()
                    if self.activeInvocation === state {
                        self.activeInvocation = nil
                    }
                    self.processLock.unlock()

                    guard state.claimResume() else { return }
                    if state.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(returning: proc.terminationStatus)
                    }
                }

                do {
                    self.processLock.lock()
                    if Task.isCancelled || state.isCancelled {
                        if self.activeInvocation === state {
                            self.activeInvocation = nil
                        }
                        self.processLock.unlock()
                        outPipe.fileHandleForReading.readabilityHandler = nil
                        errPipe.fileHandleForReading.readabilityHandler = nil
                        process.terminationHandler = nil
                        if state.claimResume() {
                            continuation.resume(throwing: CancellationError())
                        }
                        return
                    }
                    self.activeInvocation = state
                    self.processLock.unlock()

                    try process.run()
                } catch {
                    self.processLock.lock()
                    if self.activeInvocation === state {
                        self.activeInvocation = nil
                    }
                    self.processLock.unlock()
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    process.terminationHandler = nil
                    if state.claimResume() {
                        continuation.resume(throwing: state.isCancelled ? CancellationError() : error)
                    }
                }
            }
        } onCancel: {
            self.cancelInvocationIfActive(state)
        }
    }
}
