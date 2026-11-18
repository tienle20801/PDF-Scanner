import AppKit
import PDFKit
import SwiftUI

struct PendingOverwriteAction: Identifiable {
    let id = UUID()
    let targetURL: URL
    let existingCount: Int
    let onOverwrite: () -> Void
    let onSaveUnique: () -> Void

    init(
        targetURL: URL,
        existingCount: Int = 1,
        onOverwrite: @escaping () -> Void,
        onSaveUnique: @escaping () -> Void
    ) {
        self.targetURL = targetURL
        self.existingCount = existingCount
        self.onOverwrite = onOverwrite
        self.onSaveUnique = onSaveUnique
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var activeTask: StudioTask = .scan
    @Published var queue: [InputPageItem] = []
    @Published var selectedItemID: UUID?
    @Published var settings = ScanSettings()

    @Published var previewDisplayMode: PreviewDisplayMode = .splitSlider
    @Published var splitSliderPosition: Double = 0.50
    @Published var showProcessedInToggle: Bool = true
    @Published var zoomScale: CGFloat = 1.0
    @Published var fitToViewport: Bool = true

    @Published var showAdvancedSettings: Bool = false
    @Published var showConsole: Bool = false

    @Published var outputPDFPath: String = ""
    @Published var lastExportedPDFURL: URL?
    @Published var lastExportedFolderURL: URL?
    @Published var lastExportedInfo: String = ""

    @Published var isBusy: Bool = false
    @Published var isPreviewing: Bool = false
    @Published var statusText: String = "Sẵn sàng"
    @Published var logs: [String] = []
    @Published var errorMessage: String?
    @Published var pendingOverwrite: PendingOverwriteAction?
    @Published var pendingImageRedirectURLs: [URL] = []
    @Published var preflightReport: PreflightReport?
    @Published var dismissPreflightBanner: Bool = false

    // PDF Tools state
    @Published var pairUseQueueAsFront: Bool = false
    @Published var pairFrontPDFURL: URL?
    @Published var pairBackSourceURL: URL?
    @Published var pairOutputMode: PairOutputMode = .separateFiles
    @Published var pairFilePrefix: String = "TaiLieu_xx"
    @Published var pairStartIndex: Int = 1

    @Published var splitSourceURL: URL?
    @Published var splitSourcePageCount: Int = 0
    @Published var splitMode: SplitMode = .allPages
    @Published var splitRangeSpec: String = "1-3"

    @Published var rotateSourceURL: URL?
    @Published var rotateSourcePageCount: Int = 0
    @Published var rotateDegrees: Int = 90
    @Published var rotateAutoPortrait: Bool = false
    @Published var rotateRangeSpec: String = ""

    // B5 Vector-preserving PDF compression defaults
    @Published var compressSourceURL: URL?
    @Published var compressSourceBytes: Int64 = 0
    @Published var compressDPI: Int = AppConstants.defaultCompressDPI
    @Published var compressQuality: Int = AppConstants.defaultCompressJPEGQuality
    @Published var compressTargetMB: Double = AppConstants.defaultCompressTargetMB
    @Published var compressMode: EnhanceMode = .original
    @Published var compressAutoCrop: Bool = false
    @Published var lastCompressionReport: String = ""
    @Published var lastCompressionWarning: String = ""

    @Published var selectedOriginalImage: NSImage?
    @Published var selectedProcessedImage: NSImage?

    private var bridge: ScannerBridge?
    private var autoScanTask: Task<Void, Never>?
    private var activeWorkTask: Task<Void, Never>?
    private var activeWorkToken: UUID?
    private var activeScanTargetIDs: [UUID] = []
    private var activePreviewItemKey: (id: UUID, cacheKey: String)?
    private var queueEpoch: UInt64 = 0
    private var taskEpoch: UInt64 = 0
    private var autoScanEpoch: UInt64 = 0
    private var refreshGeneration: UInt64 = 0
    private var importTasks: [UUID: Task<Void, Never>] = [:]
    private var refreshImagesTask: Task<Void, Never>?
    private var previewCacheByKey: [String: URL] = [:]

    init() {
        ScannerBridge.cleanupTemporaryCaches()
        do {
            let b = try ScannerBridge()
            self.bridge = b
            self.outputPDFPath = b.defaultOutputDir
                .appendingPathComponent("Scanned_Document_HD.pdf")
                .path
            appendLog("[Init] Workspace: \(b.workspaceRoot.path)")
            appendLog("[Init] Python: \(b.pythonURL.path)")
            runPreflightAsync(using: b)
        } catch {
            self.errorMessage = error.localizedDescription
            appendLog("[ERROR] \(error.localizedDescription)")
        }
    }

    var workspaceRoot: URL? { bridge?.workspaceRoot }
    var defaultOutputDir: URL? { bridge?.defaultOutputDir }

    var effectiveModeTitle: String {
        settings.engine == .pureSwiftVision ? settings.mode.pureSwiftEffectiveTitle : settings.mode.title
    }

    var selectedItem: InputPageItem? {
        guard let id = selectedItemID else { return queue.first }
        return queue.first(where: { $0.id == id })
    }

    var unscannedPageCount: Int {
        queue.filter { $0.processedPreviewURL == nil }.count
    }

    var isCurrentTaskEmpty: Bool {
        switch activeTask {
        case .scan:
            return queue.isEmpty
        case .pair:
            return pairFrontPDFURL == nil && (!pairUseQueueAsFront || queue.isEmpty)
        case .split:
            return splitSourceURL == nil
        case .mergeRotate:
            return rotateSourceURL == nil && queue.isEmpty
        case .compress:
            return compressSourceURL == nil
        }
    }

    var activePDFSourceURL: URL? {
        switch activeTask {
        case .scan:
            return nil
        case .pair:
            return pairUseQueueAsFront ? nil : pairFrontPDFURL
        case .split:
            return splitSourceURL
        case .mergeRotate:
            return rotateSourceURL
        case .compress:
            return compressSourceURL
        }
    }

    private func runPreflightAsync(using bridge: ScannerBridge) {
        Task.detached(priority: .utility) {
            let report = bridge.runPreflightCheck()
            await MainActor.run { [weak self] in
                self?.preflightReport = report
                self?.appendLog("[Preflight] \(report.summary)")
                if let rem = report.remediation {
                    self?.appendLog("[Preflight WARN] \(rem)")
                }
            }
        }
    }

    func switchToPureSwiftEngine() {
        settings.engine = .pureSwiftVision
        dismissPreflightBanner = true
        invalidatePreviewsAndRefresh()
    }

    func terminateWorkers() {
        stopAutoScanTask()
        importTasks.values.forEach { $0.cancel() }
        importTasks.removeAll()
        refreshImagesTask?.cancel()
        refreshImagesTask = nil
        activeWorkTask?.cancel()
        bridge?.cancelActiveProcess()
    }

    func suggestedScanOutputFilename() -> String {
        guard let first = queue.first else {
            return "Scanned_Document_HD.pdf"
        }
        if let folder = first.sourceFolderName, !folder.isEmpty {
            return "\(folder)_Scanned.pdf"
        }
        let stem = first.sourceURL.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? "Scanned_Document_HD.pdf" : "\(stem)_Scanned.pdf"
    }

    func appendLog(_ line: String) {
        logs.append(line)
        if logs.count > 500 {
            logs.removeFirst(logs.count - 500)
        }
    }

    func clearLogs() {
        logs.removeAll()
    }

    func selectItem(_ id: UUID?) {
        selectedItemID = id
        if previewDisplayMode == .pdfResult {
            previewDisplayMode = .splitSlider
        }
        refreshSelectedImages()
        scheduleAutoPreview()
    }

    func refreshSelectedImages() {
        refreshImagesTask?.cancel()
        refreshGeneration &+= 1
        let gen = refreshGeneration
        guard let item = selectedItem else {
            selectedOriginalImage = nil
            selectedProcessedImage = nil
            refreshImagesTask = nil
            return
        }
        let targetID = item.id
        let itemCopy = item
        refreshImagesTask = Task { [weak self] in
            guard let self else { return }
            let pair = await Task.detached(priority: .userInitiated) { () -> (NSImage?, NSImage?) in
                if Task.isCancelled { return (nil, nil) }
                let orig = PDFToolsService.loadDisplayImage(for: itemCopy, maxSide: AppConstants.previewMaxSide)
                if Task.isCancelled { return (nil, nil) }
                let proc = itemCopy.processedPreviewURL.flatMap {
                    PDFToolsService.makeImageThumbnail(url: $0, maxSide: AppConstants.previewMaxSide)
                }
                return (orig, proc)
            }.value
            guard !Task.isCancelled, self.refreshGeneration == gen, self.selectedItem?.id == targetID else { return }
            self.selectedOriginalImage = pair.0
            self.selectedProcessedImage = pair.1
        }
    }

    func syncPreviewsToCurrentSettings(refreshMissing: Bool = true) {
        stopAutoScanTask()
        let fm = FileManager.default
        for idx in queue.indices {
            let key = PDFToolsService.previewCacheKey(for: queue[idx], settings: settings)
            if queue[idx].processedCacheKey == key,
               let cur = queue[idx].processedPreviewURL,
               fm.fileExists(atPath: cur.path) {
                continue
            }
            if let cached = previewCacheByKey[key], fm.fileExists(atPath: cached.path) {
                queue[idx].processedPreviewURL = cached
                queue[idx].processedCacheKey = key
                queue[idx].scanError = nil
            } else {
                queue[idx].processedPreviewURL = nil
                queue[idx].processedCacheKey = nil
                queue[idx].scanError = nil
            }
        }
        refreshSelectedImages()
        if refreshMissing && activeTask == .scan && !queue.isEmpty {
            startAutoScanAfterImport()
        }
    }

    func invalidatePreviewsAndRefresh() {
        syncPreviewsToCurrentSettings(refreshMissing: true)
    }

    func scheduleAutoPreview() {
        guard activeTask == .scan, let item = selectedItem, item.processedPreviewURL == nil, item.scanError == nil, !isBusy else { return }
        if previewDisplayMode == .pdfResult { return }

        let desiredKey = PDFToolsService.previewCacheKey(for: item, settings: settings)
        if isPreviewing {
            if activePreviewItemKey?.id == item.id && activePreviewItemKey?.cacheKey == desiredKey { return }
            var reordered = [item.id] + activeScanTargetIDs.filter { $0 != item.id }
            reordered = reordered.filter { targetID in
                guard let found = queue.first(where: { $0.id == targetID }) else { return false }
                return found.processedPreviewURL == nil && found.scanError == nil
            }
            if reordered.isEmpty {
                reordered = [item.id]
            }
            runBackgroundScan(targetIDs: reordered, debounceNs: 120_000_000)
            return
        }

        runBackgroundScan(targetIDs: [item.id], debounceNs: 180_000_000)
    }

    // MARK: - Queue & Contextual Drop Routing

    private func sortQueueNaturally() {
        queue.sort { lhs, rhs in
            let nameCmp = lhs.sourceURL.lastPathComponent.localizedStandardCompare(rhs.sourceURL.lastPathComponent)
            if nameCmp != .orderedSame {
                return nameCmp == .orderedAscending
            }
            let idxL = lhs.pageIndexInPDF ?? 0
            let idxR = rhs.pageIndexInPDF ?? 0
            if idxL != idxR {
                return idxL < idxR
            }
            return lhs.sourceURL.path.localizedStandardCompare(rhs.sourceURL.path) == .orderedAscending
        }
    }

    private func validateUnlockedPDF(_ url: URL) -> PDFDocument? {
        guard let doc = PDFDocument(url: url.resolvingSymlinksInPath()) else {
            errorMessage = PDFToolError.invalidPDF(url).localizedDescription
            return nil
        }
        if doc.isLocked {
            errorMessage = PDFToolError.lockedPDF(url).localizedDescription
            statusText = "File PDF đang bị khóa mật khẩu"
            return nil
        }
        guard doc.pageCount > 0 else {
            errorMessage = PDFToolError.invalidPDF(url).localizedDescription
            return nil
        }
        return doc
    }

    func setPairFrontPDF(_ url: URL) {
        guard !isBusy, let doc = validateUnlockedPDF(url) else { return }
        pairFrontPDFURL = url
        pairUseQueueAsFront = false
        if previewDisplayMode == .pdfResult { previewDisplayMode = .splitSlider }
        statusText = "Đã nạp Mặt trước: \(url.lastPathComponent) (\(doc.pageCount) trang)"
        appendLog("[Pair] Đã nạp file mặt trước: \(url.path)")
    }

    func setPairBackSource(_ url: URL) {
        guard !isBusy else { return }
        if url.pathExtension.lowercased() == "pdf", validateUnlockedPDF(url) == nil { return }
        pairBackSourceURL = url
    }

    func setSplitSource(_ url: URL) {
        guard !isBusy, let doc = validateUnlockedPDF(url) else { return }
        splitSourceURL = url
        splitSourcePageCount = doc.pageCount
        if previewDisplayMode == .pdfResult { previewDisplayMode = .splitSlider }
        statusText = "Đã nạp PDF tách: \(url.lastPathComponent) (\(splitSourcePageCount) trang)"
        appendLog("[Split] Đã nạp nguồn: \(url.path)")
    }

    func setRotateSource(_ url: URL) {
        guard !isBusy, let doc = validateUnlockedPDF(url) else { return }
        rotateSourceURL = url
        rotateSourcePageCount = doc.pageCount
        if previewDisplayMode == .pdfResult { previewDisplayMode = .splitSlider }
        statusText = "Đã nạp PDF cần xoay: \(url.lastPathComponent) (\(rotateSourcePageCount) trang)"
        appendLog("[Rotate] Đã nạp nguồn: \(url.path)")
    }

    func setCompressSource(_ url: URL) {
        guard !isBusy, validateUnlockedPDF(url) != nil else { return }
        compressSourceURL = url
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        compressSourceBytes = (attrs?[.size] as? Int64) ?? 0
        lastCompressionReport = ""
        lastCompressionWarning = ""
        if previewDisplayMode == .pdfResult { previewDisplayMode = .splitSlider }
        statusText = "Đã nạp PDF cần nén: \(url.lastPathComponent) (\(PDFToolsService.formatBytes(compressSourceBytes)))"
        appendLog("[Compress] Đã nạp nguồn: \(url.path)")
    }

    func handleDroppedURLs(_ urls: [URL]) {
        guard !isBusy, !urls.isEmpty else { return }
        let expanded = PDFToolsService.expandURLs(urls)
        let pdfs = expanded.filter { $0.pathExtension.lowercased() == "pdf" }

        switch activeTask {
        case .scan:
            addURLs(urls)

        case .pair:
            if let firstPDF = pdfs.first {
                setPairFrontPDF(firstPDF)
            } else if !expanded.isEmpty {
                pairUseQueueAsFront = true
                addURLs(urls)
            } else {
                statusText = "Không tìm thấy PDF hoặc ảnh hợp lệ"
            }

        case .split:
            if let firstPDF = pdfs.first {
                setSplitSource(firstPDF)
            } else if !expanded.isEmpty {
                pendingImageRedirectURLs = urls
            } else {
                statusText = "Vui lòng thả file PDF hợp lệ"
            }

        case .mergeRotate:
            if pdfs.count == 1 && expanded.count == 1, let singlePDF = pdfs.first {
                setRotateSource(singlePDF)
            } else if !expanded.isEmpty {
                addURLs(urls)
            } else {
                statusText = "Không tìm thấy PDF hoặc ảnh hợp lệ"
            }

        case .compress:
            if let firstPDF = pdfs.first {
                setCompressSource(firstPDF)
            } else if !expanded.isEmpty {
                pendingImageRedirectURLs = urls
            } else {
                statusText = "Vui lòng thả file PDF hợp lệ"
            }
        }
    }

    func redirectPendingImagesToScan() {
        let urls = pendingImageRedirectURLs
        pendingImageRedirectURLs = []
        guard !isBusy, !urls.isEmpty else { return }
        activeTask = .scan
        addURLs(urls)
    }

    func addURLs(_ urls: [URL]) {
        guard !isBusy, !urls.isEmpty else { return }
        statusText = "Đang nạp & sắp xếp A→Z..."
        let currentTask = activeTask
        let importEpoch = queueEpoch
        let taskID = UUID()

        let task = Task { [weak self] in
            guard let self else { return }
            let result = await Task.detached(priority: .userInitiated) {
                PDFToolsService.loadInputItemsCheckingLocked(from: urls)
            }.value
            self.importTasks.removeValue(forKey: taskID)
            guard !Task.isCancelled, self.queueEpoch == importEpoch, !self.isBusy else { return }

            if let lockedFirst = result.lockedPDFs.first {
                let errText = PDFToolError.lockedPDF(lockedFirst).localizedDescription
                self.errorMessage = errText
                self.appendLog("[WARN] \(errText)")
            }

            let loaded = result.items
            if loaded.isEmpty {
                self.statusText = result.lockedPDFs.isEmpty
                    ? "Không tìm thấy ảnh hoặc PDF hợp lệ"
                    : "PDF đang bị khóa mật khẩu"
                return
            }
            self.queue.append(contentsOf: loaded)
            self.sortQueueNaturally()
            if self.selectedItemID == nil || !self.queue.contains(where: { $0.id == self.selectedItemID }) {
                self.selectedItemID = self.queue.first?.id
            }
            if self.previewDisplayMode == .pdfResult {
                self.previewDisplayMode = .splitSlider
            }
            self.refreshSelectedImages()
            self.appendLog("[Queue] Đã nạp \(loaded.count) trang (tổng \(self.queue.count), đã sắp xếp A→Z).")
            self.statusText = "Đã nạp \(loaded.count) trang (tổng \(self.queue.count) trang)"
            if currentTask == .scan && self.activeTask == .scan {
                self.startAutoScanAfterImport()
            }
        }
        importTasks[taskID] = task
    }

    func loadFromDefaultInput() {
        guard let inputDir = bridge?.defaultInputDir else { return }
        try? FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        if PDFToolsService.expandURLs([inputDir]).isEmpty {
            statusText = "Thư mục input/ đang trống — kéo thả ảnh hoặc PDF vào để bắt đầu"
            NSWorkspace.shared.open(inputDir)
            return
        }
        handleDroppedURLs([inputDir])
    }

    func openDefaultOutputFolder() {
        guard let outDir = bridge?.defaultOutputDir else { return }
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(outDir)
    }

    func resetCurrentTaskToNewBatch() {
        taskEpoch &+= 1
        stopAutoScanTask()
        if activeWorkTask != nil {
            activeWorkTask?.cancel()
            bridge?.cancelActiveProcess()
        }
        lastExportedPDFURL = nil
        lastExportedFolderURL = nil
        lastExportedInfo = ""
        previewDisplayMode = .splitSlider

        switch activeTask {
        case .scan:
            clearQueue()
        case .pair:
            if pairUseQueueAsFront {
                clearQueue()
                pairUseQueueAsFront = false
            }
            pairFrontPDFURL = nil
        case .split:
            splitSourceURL = nil
            splitSourcePageCount = 0
        case .mergeRotate:
            rotateSourceURL = nil
            rotateSourcePageCount = 0
            clearQueue()
        case .compress:
            compressSourceURL = nil
            compressSourceBytes = 0
            lastCompressionReport = ""
            lastCompressionWarning = ""
        }
        statusText = "Sẵn sàng cho bộ tài liệu mới"
    }

    func rotateItem(id: UUID, deltaDegrees: Int) {
        guard !isBusy else { return }
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        let updatedDeg = ((queue[idx].rotationDegrees + deltaDegrees) % 360 + 360) % 360
        queue[idx].rotationDegrees = updatedDeg
        queue[idx].orientationChecked = true
        let targetKey = PDFToolsService.previewCacheKey(for: queue[idx], settings: settings)
        if let cached = previewCacheByKey[targetKey], FileManager.default.fileExists(atPath: cached.path) {
            queue[idx].processedPreviewURL = cached
            queue[idx].processedCacheKey = targetKey
        } else {
            queue[idx].processedPreviewURL = nil
            queue[idx].processedCacheKey = nil
        }
        queue[idx].scanError = nil
        if let thumb = queue[idx].thumbnail {
            queue[idx].thumbnail = PDFToolsService.rotatedNSImage(thumb, clockwiseDegrees: deltaDegrees)
        }
        if selectedItem?.id == id {
            refreshSelectedImages()
            scheduleAutoPreview()
        }
    }

    func rotateAll(deltaDegrees: Int) {
        guard !isBusy else { return }
        stopAutoScanTask()
        for idx in queue.indices {
            queue[idx].rotationDegrees = ((queue[idx].rotationDegrees + deltaDegrees) % 360 + 360) % 360
            queue[idx].orientationChecked = true
            let targetKey = PDFToolsService.previewCacheKey(for: queue[idx], settings: settings)
            if let cached = previewCacheByKey[targetKey], FileManager.default.fileExists(atPath: cached.path) {
                queue[idx].processedPreviewURL = cached
                queue[idx].processedCacheKey = targetKey
            } else {
                queue[idx].processedPreviewURL = nil
                queue[idx].processedCacheKey = nil
            }
            queue[idx].scanError = nil
            if let thumb = queue[idx].thumbnail {
                queue[idx].thumbnail = PDFToolsService.rotatedNSImage(thumb, clockwiseDegrees: deltaDegrees)
            }
        }
        refreshSelectedImages()
        scheduleAutoPreview()
    }

    func moveItem(id: UUID, offset: Int) {
        guard !isBusy else { return }
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        let target = idx + offset
        guard target >= 0 && target < queue.count else { return }
        queue.swapAt(idx, target)
    }

    func removeItem(id: UUID) {
        guard !isBusy else { return }
        queue.removeAll(where: { $0.id == id })
        if selectedItemID == id {
            selectedItemID = queue.first?.id
            refreshSelectedImages()
            scheduleAutoPreview()
        }
    }

    func clearQueue() {
        queueEpoch &+= 1
        importTasks.values.forEach { $0.cancel() }
        importTasks.removeAll()
        refreshGeneration &+= 1
        refreshImagesTask?.cancel()
        refreshImagesTask = nil
        stopAutoScanTask()
        queue.removeAll()
        previewCacheByKey.removeAll()
        selectedItemID = nil
        selectedOriginalImage = nil
        selectedProcessedImage = nil
        statusText = "Sẵn sàng"
    }

    private func makeLogSink() -> @Sendable (String) -> Void {
        return { [weak self] line in
            Task { @MainActor in
                self?.appendLog(line)
            }
        }
    }

    // MARK: - Non-blocking Auto-Scan, Reading Orientation & Preview

    func stopAutoScanTask() {
        autoScanEpoch &+= 1
        autoScanTask?.cancel()
        autoScanTask = nil
        activePreviewItemKey = nil
        if isPreviewing && !isBusy {
            bridge?.cancelActiveProcess()
        }
        isPreviewing = false
        activeScanTargetIDs = []
    }

    func startAutoScanAfterImport() {
        let unscanned = queue.filter { $0.processedPreviewURL == nil && $0.scanError == nil }.map(\.id)
        guard !unscanned.isEmpty, !isBusy else { return }

        var targets: [UUID]
        if queue.count <= 5 {
            targets = unscanned
        } else {
            let cap = min(5, unscanned.count)
            targets = Array(unscanned.prefix(cap))
            if let sel = selectedItem?.id, unscanned.contains(sel), !targets.contains(sel) {
                targets.insert(sel, at: 0)
            }
        }

        if let sel = selectedItem?.id, let pos = targets.firstIndex(of: sel), pos > 0 {
            targets.remove(at: pos)
            targets.insert(sel, at: 0)
        }

        runBackgroundScan(targetIDs: targets, debounceNs: 150_000_000)
    }

    func scanRemainingPages() {
        let unscanned = queue.filter { $0.processedPreviewURL == nil && $0.scanError == nil }.map(\.id)
        guard !unscanned.isEmpty, !isBusy else { return }
        var targets = unscanned
        if let sel = selectedItem?.id, let pos = targets.firstIndex(of: sel), pos > 0 {
            targets.remove(at: pos)
            targets.insert(sel, at: 0)
        }
        runBackgroundScan(targetIDs: targets, debounceNs: 0)
    }

    func previewSelectedPage(forceRefresh: Bool = false) {
        guard !isBusy, let item = selectedItem else { return }
        if let idx = queue.firstIndex(where: { $0.id == item.id }) {
            if forceRefresh {
                queue[idx].processedPreviewURL = nil
                selectedProcessedImage = nil
            }
            queue[idx].scanError = nil
        }
        runBackgroundScan(targetIDs: [item.id], debounceNs: 0)
    }

    private func runBackgroundScan(targetIDs: [UUID], debounceNs: UInt64) {
        guard let bridge, !isBusy else { return }
        let previousTask = autoScanTask
        stopAutoScanTask()
        let scanEpoch = autoScanEpoch
        let myQueueEpoch = queueEpoch
        activeScanTargetIDs = targetIDs
        isPreviewing = true

        autoScanTask = Task { [weak self] in
            guard let self else { return }
            await previousTask?.value
            if debounceNs > 0 {
                try? await Task.sleep(nanoseconds: debounceNs)
            }
            guard !Task.isCancelled, self.autoScanEpoch == scanEpoch, self.queueEpoch == myQueueEpoch else { return }

            let total = targetIDs.count
            let logSink = self.makeLogSink()

            for (stepIdx, targetID) in targetIDs.enumerated() {
                if Task.isCancelled || self.isBusy || self.autoScanEpoch != scanEpoch || self.queueEpoch != myQueueEpoch { break }
                guard let currentIdx = self.queue.firstIndex(where: { $0.id == targetID }) else { continue }
                if self.queue[currentIdx].processedPreviewURL != nil { continue }

                var item = self.queue[currentIdx]
                self.activePreviewItemKey = (targetID, PDFToolsService.previewCacheKey(for: item, settings: self.settings))
                self.statusText = total > 1
                    ? "Đang dò hướng & scan (\(stepIdx + 1)/\(total)): \(item.displayName)..."
                    : "Đang dò hướng & làm nét: \(item.displayName)..."

                if !item.orientationChecked {
                    let itemCopy = item
                    let shareOCR = self.settings.enableOCR && !self.settings.autoCrop
                    let deltaDeg = await PDFToolsService.detectReadingOrientationDegreesAsync(
                        for: itemCopy,
                        cacheAccurateOCR: shareOCR
                    )
                    if Task.isCancelled || self.autoScanEpoch != scanEpoch || self.queueEpoch != myQueueEpoch { break }
                    if let idxNow = self.queue.firstIndex(where: { $0.id == targetID }),
                       !self.queue[idxNow].orientationChecked,
                       self.queue[idxNow].rotationDegrees == itemCopy.rotationDegrees {
                        self.queue[idxNow].orientationChecked = true
                        if deltaDeg != 0 {
                            self.queue[idxNow].rotationDegrees = ((self.queue[idxNow].rotationDegrees + deltaDeg) % 360 + 360) % 360
                            if let thumb = self.queue[idxNow].thumbnail {
                                self.queue[idxNow].thumbnail = PDFToolsService.rotatedNSImage(thumb, clockwiseDegrees: deltaDeg)
                            }
                            self.appendLog("[Orient] Tự xoay \(self.queue[idxNow].displayName) +\(deltaDeg)° về hướng đọc.")
                            if self.selectedItem?.id == targetID {
                                self.refreshSelectedImages()
                            }
                        }
                        item = self.queue[idxNow]
                    } else if let idxNow = self.queue.firstIndex(where: { $0.id == targetID }) {
                        item = self.queue[idxNow]
                    }
                }

                if Task.isCancelled || self.isBusy || self.autoScanEpoch != scanEpoch || self.queueEpoch != myQueueEpoch { break }
                let settingsSnapshot = self.settings
                let itemSnapshot = item
                let cacheKey = PDFToolsService.previewCacheKey(for: itemSnapshot, settings: settingsSnapshot)
                self.activePreviewItemKey = (targetID, cacheKey)

                do {
                    let previewURL = try await bridge.previewSinglePage(
                        item: itemSnapshot,
                        settings: settingsSnapshot,
                        onLog: logSink
                    )
                    if Task.isCancelled || self.autoScanEpoch != scanEpoch || self.queueEpoch != myQueueEpoch { break }
                    self.previewCacheByKey[cacheKey] = previewURL
                    if let idxNow = self.queue.firstIndex(where: { $0.id == targetID }),
                       PDFToolsService.previewCacheKey(for: self.queue[idxNow], settings: self.settings) == cacheKey {
                        self.queue[idxNow].processedPreviewURL = previewURL
                        self.queue[idxNow].processedCacheKey = cacheKey
                        self.queue[idxNow].scanError = nil
                        if self.selectedItem?.id == targetID {
                            self.refreshSelectedImages()
                        }
                    }
                } catch is CancellationError {
                    break
                } catch {
                    if Task.isCancelled || self.autoScanEpoch != scanEpoch || self.queueEpoch != myQueueEpoch { break }
                    if let idxNow = self.queue.firstIndex(where: { $0.id == targetID }) {
                        self.queue[idxNow].scanError = error.localizedDescription
                    }
                    self.appendLog("[Preview] Lỗi trang \(item.displayName): \(error.localizedDescription)")
                }
            }

            if !Task.isCancelled, self.autoScanEpoch == scanEpoch {
                self.isPreviewing = false
                self.activeScanTargetIDs = []
                self.activePreviewItemKey = nil
                let scannedCount = self.queue.count - self.unscannedPageCount
                if !self.queue.isEmpty {
                    self.statusText = self.unscannedPageCount == 0
                        ? "Sẵn sàng • Đã scan \(scannedCount)/\(self.queue.count) trang"
                        : "Đã scan \(scannedCount)/\(self.queue.count) trang • Còn \(self.unscannedPageCount) trang chờ"
                } else {
                    self.statusText = "Sẵn sàng"
                }
            }
        }
    }

    func requestBatchScan() {
        guard !isBusy, !queue.isEmpty else { return }
        stopAutoScanTask()

        let currentOutURL = URL(fileURLWithPath: outputPDFPath.trimmingCharacters(in: .whitespacesAndNewlines))
        let initialDir = outputPDFPath.isEmpty ? defaultOutputDir : currentOutURL.deletingLastPathComponent()
        let suggestedName = suggestedScanOutputFilename()

        if let chosenURL = PDFDialogHelpers.pickSavePDF(
            defaultName: suggestedName,
            title: "Lưu file PDF đã Scan",
            defaultDir: initialDir
        ) {
            outputPDFPath = chosenURL.path
            executeBatchScan(to: chosenURL)
        }
    }

    func executeBatchScan(to targetURL: URL) {
        guard let bridge else { return }
        let previousTask = autoScanTask
        stopAutoScanTask()
        activeWorkTask?.cancel()
        let workToken = UUID()
        let myTaskEpoch = taskEpoch
        let myQueueEpoch = queueEpoch
        activeWorkToken = workToken

        let settingsSnapshot = settings
        let logSink = makeLogSink()
        isBusy = true
        statusText = "Đang kiểm tra hướng đọc & xuất \(queue.count) trang..."

        activeWorkTask = Task { [weak self] in
            guard let self else { return }
            await previousTask?.value
            do {
                try Task.checkCancellation()
                guard self.taskEpoch == myTaskEpoch, self.queueEpoch == myQueueEpoch else {
                    throw CancellationError()
                }
                let shareOCR = settingsSnapshot.enableOCR && !settingsSnapshot.autoCrop
                let orientTargetIDs = self.queue
                    .filter { !$0.orientationChecked && $0.processedPreviewURL == nil }
                    .map(\.id)

                for targetID in orientTargetIDs {
                    try Task.checkCancellation()
                    guard self.taskEpoch == myTaskEpoch, self.queueEpoch == myQueueEpoch else {
                        throw CancellationError()
                    }
                    guard let idxBefore = self.queue.firstIndex(where: { $0.id == targetID }) else { continue }
                    let itemCopy = self.queue[idxBefore]
                    guard !itemCopy.orientationChecked && itemCopy.processedPreviewURL == nil else { continue }

                    let deltaDeg = await PDFToolsService.detectReadingOrientationDegreesAsync(
                        for: itemCopy,
                        cacheAccurateOCR: shareOCR
                    )
                    try Task.checkCancellation()
                    guard self.taskEpoch == myTaskEpoch, self.queueEpoch == myQueueEpoch else {
                        throw CancellationError()
                    }
                    if let idxNow = self.queue.firstIndex(where: { $0.id == targetID }),
                       !self.queue[idxNow].orientationChecked,
                       self.queue[idxNow].rotationDegrees == itemCopy.rotationDegrees {
                        self.queue[idxNow].orientationChecked = true
                        if deltaDeg != 0 {
                            self.queue[idxNow].rotationDegrees = ((self.queue[idxNow].rotationDegrees + deltaDeg) % 360 + 360) % 360
                            if let thumb = self.queue[idxNow].thumbnail {
                                self.queue[idxNow].thumbnail = PDFToolsService.rotatedNSImage(thumb, clockwiseDegrees: deltaDeg)
                            }
                            self.appendLog("[Orient] Tự xoay \(self.queue[idxNow].displayName) +\(deltaDeg)° về hướng đọc.")
                        }
                    }
                }

                try Task.checkCancellation()
                guard self.taskEpoch == myTaskEpoch, self.queueEpoch == myQueueEpoch else {
                    throw CancellationError()
                }
                let itemsSnapshot = self.queue
                guard !itemsSnapshot.isEmpty else {
                    throw PDFToolError.emptyInput("Danh sách trang đang trống.")
                }
                self.statusText = settingsSnapshot.enableOCR
                    ? "Đang đóng gói PDF & nhúng lớp OCR (\(itemsSnapshot.count) trang)..."
                    : "Đang đóng gói PDF (\(itemsSnapshot.count) trang)..."
                let batchResult = try await bridge.runBatchScan(
                    items: itemsSnapshot,
                    settings: settingsSnapshot,
                    outputPDF: targetURL,
                    onLog: logSink
                )
                try Task.checkCancellation()
                guard self.taskEpoch == myTaskEpoch, self.queueEpoch == myQueueEpoch else {
                    throw CancellationError()
                }

                for item in itemsSnapshot {
                    guard let idx = self.queue.firstIndex(where: { $0.id == item.id }) else { continue }
                    if let previewURL = batchResult.resolvedURLs[item.id] {
                        let key = PDFToolsService.previewCacheKey(for: self.queue[idx], settings: settingsSnapshot)
                        self.previewCacheByKey[key] = previewURL
                        self.queue[idx].processedPreviewURL = previewURL
                        self.queue[idx].processedCacheKey = key
                        self.queue[idx].scanError = nil
                    } else if let err = batchResult.errors[item.id] {
                        self.queue[idx].processedPreviewURL = nil
                        self.queue[idx].processedCacheKey = nil
                        self.queue[idx].scanError = err
                    }
                }
                self.lastExportedPDFURL = targetURL
                self.lastExportedFolderURL = targetURL.deletingLastPathComponent()
                let attrs = try? FileManager.default.attributesOfItem(atPath: targetURL.path)
                let bytes = (attrs?[.size] as? Int64) ?? 0
                let pages = PDFDocument(url: targetURL)?.pageCount ?? batchResult.resolvedURLs.count
                self.lastExportedInfo = "\(pages) trang • \(PDFToolsService.formatBytes(bytes))"
                self.previewDisplayMode = .pdfResult
                self.refreshSelectedImages()
                if batchResult.errors.isEmpty {
                    self.statusText = "Hoàn tất: \(targetURL.lastPathComponent) (\(self.lastExportedInfo))"
                    self.appendLog("[DONE] Đã xuất \(targetURL.path) (\(self.lastExportedInfo))")
                } else {
                    let errCount = batchResult.errors.count
                    self.errorMessage = "Đã xuất \(pages) trang hợp lệ; \(errCount) trang lỗi không thể xử lý (xem đánh dấu đỏ ở dải trang)."
                    self.statusText = "Hoàn tất với \(errCount) trang lỗi: \(targetURL.lastPathComponent)"
                    self.appendLog("[WARN] Đã xuất \(targetURL.path) (\(self.lastExportedInfo)), bỏ qua \(errCount) trang lỗi.")
                }
            } catch is CancellationError {
                if self.taskEpoch == myTaskEpoch {
                    self.statusText = "Đã hủy"
                }
            } catch {
                if self.taskEpoch == myTaskEpoch {
                    self.errorMessage = error.localizedDescription
                    self.appendLog("[ERROR] \(error.localizedDescription)")
                    self.showConsole = true
                    self.statusText = "Lỗi xuất PDF"
                }
            }
            if self.activeWorkToken == workToken {
                self.isBusy = false
                self.activeWorkTask = nil
                self.activeWorkToken = nil
            }
        }
    }

    func cancelRunningTask() {
        stopAutoScanTask()
        if let work = activeWorkTask {
            work.cancel()
            bridge?.cancelActiveProcess()
            appendLog("[Cancel] Đã gửi tín hiệu dừng tiến trình.")
            statusText = "Đã hủy"
        } else {
            bridge?.cancelActiveProcess()
            isBusy = false
            appendLog("[Cancel] Đã gửi tín hiệu dừng tiến trình.")
            statusText = "Đã hủy"
        }
    }

    // MARK: - Overwrite Safety Checkpoint

    func confirmWriteURL(_ targetURL: URL, onProceed: @escaping (URL) -> Void) {
        if FileManager.default.fileExists(atPath: targetURL.path) {
            pendingOverwrite = PendingOverwriteAction(
                targetURL: targetURL,
                existingCount: 1,
                onOverwrite: { onProceed(targetURL) },
                onSaveUnique: { onProceed(PDFToolsService.uniqueURLIfExists(targetURL)) }
            )
        } else {
            onProceed(targetURL)
        }
    }

    private func confirmDirectoryBatchWrite(
        plannedFiles: [URL],
        onProceed: @escaping (_ autoRenameExisting: Bool) -> Void
    ) {
        let fm = FileManager.default
        let existing = plannedFiles.filter { fm.fileExists(atPath: $0.path) }
        if let firstExisting = existing.first {
            pendingOverwrite = PendingOverwriteAction(
                targetURL: firstExisting,
                existingCount: existing.count,
                onOverwrite: { onProceed(false) },
                onSaveUnique: { onProceed(true) }
            )
        } else {
            onProceed(false)
        }
    }

    private func runTrackedPDFToolTask<T: Sendable>(
        busyStatus: String,
        errorStatus: String,
        work: @escaping @Sendable () throws -> T,
        onSuccess: @escaping @MainActor (T) -> Void
    ) {
        activeWorkTask?.cancel()
        let workToken = UUID()
        let myTaskEpoch = taskEpoch
        activeWorkToken = workToken
        isBusy = true
        statusText = busyStatus

        activeWorkTask = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                let detached = Task.detached(priority: .userInitiated) {
                    try work()
                }
                let result = try await withTaskCancellationHandler {
                    try await detached.value
                } onCancel: {
                    detached.cancel()
                }
                try Task.checkCancellation()
                guard self.taskEpoch == myTaskEpoch else {
                    throw CancellationError()
                }
                onSuccess(result)
            } catch is CancellationError {
                if self.taskEpoch == myTaskEpoch {
                    self.statusText = "Đã hủy"
                }
            } catch {
                if self.taskEpoch == myTaskEpoch {
                    self.errorMessage = error.localizedDescription
                    self.appendLog("[ERROR] \(error.localizedDescription)")
                    self.statusText = errorStatus
                }
            }
            if self.activeWorkToken == workToken {
                self.isBusy = false
                self.activeWorkTask = nil
                self.activeWorkToken = nil
            }
        }
    }

    // MARK: - PDF Tools Actions

    @discardableResult
    func validatePairInputs() -> Bool {
        if pairBackSourceURL == nil {
            errorMessage = "Vui lòng chọn file trang mặt sau (PDF hoặc ảnh)."
            return false
        }
        if !pairUseQueueAsFront && pairFrontPDFURL == nil {
            errorMessage = "Vui lòng chọn file PDF mặt trước hoặc bật 'Dùng danh sách trang hiện tại'."
            return false
        }
        if pairUseQueueAsFront && queue.isEmpty {
            errorMessage = "Danh sách trang mặt trước đang trống."
            return false
        }
        return true
    }

    func runPairFrontAndBack(destinationURL: URL, confirmOverwrite: Bool = true) {
        guard !isBusy else { return }
        guard validatePairInputs(), let backURL = pairBackSourceURL else { return }
        let frontURL = pairUseQueueAsFront ? nil : pairFrontPDFURL
        if let frontURL, validateUnlockedPDF(frontURL) == nil { return }
        if backURL.pathExtension.lowercased() == "pdf", validateUnlockedPDF(backURL) == nil { return }

        let queueSnapshot = queue
        let mode = pairOutputMode
        let prefix = pairFilePrefix
        let startIdx = max(1, pairStartIndex)

        let performPair: (URL, Bool) -> Void = { [weak self] finalDest, autoRename in
            guard let self else { return }
            self.runTrackedPDFToolTask(
                busyStatus: "Đang ghép cặp trang...",
                errorStatus: "Lỗi ghép cặp",
                work: {
                    try PDFToolsService.pairFrontAndBack(
                        frontPDFURL: frontURL,
                        queueItems: queueSnapshot,
                        backSourceURL: backURL,
                        outputMode: mode,
                        destinationURL: finalDest,
                        filePrefix: prefix,
                        startIndex: startIdx,
                        autoRenameExisting: autoRename
                    )
                },
                onSuccess: { outputs in
                    self.appendLog("[Pair] Đã tạo \(outputs.count) file PDF tại: \(finalDest.path)")
                    if outputs.count == 1, let single = outputs.first {
                        self.lastExportedPDFURL = single
                        self.lastExportedFolderURL = single.deletingLastPathComponent()
                        let attrs = try? FileManager.default.attributesOfItem(atPath: single.path)
                        let bytes = (attrs?[.size] as? Int64) ?? 0
                        let pCount = PDFDocument(url: single)?.pageCount ?? 0
                        self.lastExportedInfo = "\(pCount) trang • \(PDFToolsService.formatBytes(bytes))"
                        self.previewDisplayMode = .pdfResult
                    } else if let firstOut = outputs.first {
                        self.lastExportedPDFURL = firstOut
                        self.lastExportedFolderURL = finalDest
                        self.lastExportedInfo = "\(outputs.count) file PDF • \(firstOut.lastPathComponent)..."
                        self.previewDisplayMode = .pdfResult
                        NSWorkspace.shared.open(finalDest)
                    }
                    self.statusText = "Ghép cặp hoàn tất (\(outputs.count) file)"
                }
            )
        }

        if mode == .singleCombined {
            if confirmOverwrite {
                confirmWriteURL(destinationURL) { chosenDest in
                    performPair(chosenDest, false)
                }
            } else {
                performPair(destinationURL, false)
            }
        } else {
            let pageCount = frontURL.flatMap { PDFDocument(url: $0)?.pageCount } ?? queueSnapshot.count
            let planned = (0..<max(0, pageCount)).map { idx in
                destinationURL.appendingPathComponent(
                    PDFToolsService.formatPairFileName(pattern: prefix, startIndex: startIdx, offset: idx)
                )
            }
            if confirmOverwrite {
                confirmDirectoryBatchWrite(plannedFiles: planned) { autoRename in
                    performPair(destinationURL, autoRename)
                }
            } else {
                performPair(destinationURL, false)
            }
        }
    }

    func runSplitPDF(destinationURL: URL, confirmOverwrite: Bool = true) {
        guard !isBusy else { return }
        guard let src = splitSourceURL else {
            errorMessage = "Vui lòng chọn file PDF nguồn để tách."
            return
        }
        guard let doc = validateUnlockedPDF(src) else { return }
        let mode = splitMode
        let range = splitRangeSpec

        let performSplit: (URL, Bool) -> Void = { [weak self] finalDest, autoRename in
            guard let self else { return }
            self.runTrackedPDFToolTask(
                busyStatus: "Đang tách PDF...",
                errorStatus: "Lỗi tách PDF",
                work: {
                    try PDFToolsService.splitPDF(
                        sourceURL: src,
                        mode: mode,
                        rangeSpec: range,
                        destinationURL: finalDest,
                        autoRenameExisting: autoRename
                    )
                },
                onSuccess: { outputs in
                    self.appendLog("[Split] Đã xuất \(outputs.count) file từ \(src.lastPathComponent)")
                    if outputs.count == 1, let single = outputs.first {
                        self.lastExportedPDFURL = single
                        self.lastExportedFolderURL = single.deletingLastPathComponent()
                        let attrs = try? FileManager.default.attributesOfItem(atPath: single.path)
                        let bytes = (attrs?[.size] as? Int64) ?? 0
                        let pCount = PDFDocument(url: single)?.pageCount ?? 0
                        self.lastExportedInfo = "\(pCount) trang • \(PDFToolsService.formatBytes(bytes))"
                        self.previewDisplayMode = .pdfResult
                    } else {
                        self.lastExportedFolderURL = finalDest
                        NSWorkspace.shared.open(finalDest)
                    }
                    self.statusText = "Đã tách \(outputs.count) file"
                }
            )
        }

        if mode == .customRange {
            if confirmOverwrite {
                confirmWriteURL(destinationURL) { chosenDest in
                    performSplit(chosenDest, false)
                }
            } else {
                performSplit(destinationURL, false)
            }
        } else {
            let stem = src.deletingPathExtension().lastPathComponent
            let planned = (0..<doc.pageCount).map { idx in
                destinationURL.appendingPathComponent(String(format: "%@_page_%02d.pdf", stem, idx + 1))
            }
            if confirmOverwrite {
                confirmDirectoryBatchWrite(plannedFiles: planned) { autoRename in
                    performSplit(destinationURL, autoRename)
                }
            } else {
                performSplit(destinationURL, false)
            }
        }
    }

    func runMergeQueue(destinationURL: URL, confirmOverwrite: Bool = true) {
        guard !isBusy, !queue.isEmpty else { return }
        let itemsSnapshot = queue
        let startMerge: (URL) -> Void = { [weak self] finalDest in
            guard let self else { return }
            self.runTrackedPDFToolTask(
                busyStatus: "Đang gộp \(itemsSnapshot.count) trang...",
                errorStatus: "Lỗi gộp PDF",
                work: {
                    try PDFToolsService.mergeQueueToPDF(items: itemsSnapshot, destinationURL: finalDest)
                },
                onSuccess: { count in
                    let attrs = try? FileManager.default.attributesOfItem(atPath: finalDest.path)
                    let bytes = (attrs?[.size] as? Int64) ?? 0
                    self.lastExportedPDFURL = finalDest
                    self.lastExportedFolderURL = finalDest.deletingLastPathComponent()
                    self.lastExportedInfo = "\(count) trang • \(PDFToolsService.formatBytes(bytes))"
                    self.previewDisplayMode = .pdfResult
                    self.appendLog("[Merge] Đã gộp \(count) trang -> \(finalDest.path)")
                    self.statusText = "Gộp PDF hoàn tất"
                }
            )
        }
        if confirmOverwrite {
            confirmWriteURL(destinationURL, onProceed: startMerge)
        } else {
            startMerge(destinationURL)
        }
    }

    func runMergeExternalPDFs(urls: [URL], destinationURL: URL, confirmOverwrite: Bool = true) {
        guard !isBusy, !urls.isEmpty else { return }
        let startMerge: (URL) -> Void = { [weak self] finalDest in
            guard let self else { return }
            self.runTrackedPDFToolTask(
                busyStatus: "Đang gộp \(urls.count) file PDF...",
                errorStatus: "Lỗi gộp PDF",
                work: {
                    try PDFToolsService.mergePDFFiles(urls: urls, destinationURL: finalDest)
                },
                onSuccess: { count in
                    let attrs = try? FileManager.default.attributesOfItem(atPath: finalDest.path)
                    let bytes = (attrs?[.size] as? Int64) ?? 0
                    self.lastExportedPDFURL = finalDest
                    self.lastExportedFolderURL = finalDest.deletingLastPathComponent()
                    self.lastExportedInfo = "\(count) trang • \(PDFToolsService.formatBytes(bytes))"
                    self.previewDisplayMode = .pdfResult
                    self.appendLog("[Merge] Đã gộp \(urls.count) file (\(count) trang) -> \(finalDest.path)")
                    self.statusText = "Gộp \(urls.count) PDF hoàn tất"
                }
            )
        }
        if confirmOverwrite {
            confirmWriteURL(destinationURL, onProceed: startMerge)
        } else {
            startMerge(destinationURL)
        }
    }

    func runRotatePDF(destinationURL: URL, confirmOverwrite: Bool = true) {
        guard !isBusy else { return }
        guard let src = rotateSourceURL else {
            errorMessage = "Vui lòng chọn file PDF cần xoay."
            return
        }
        guard validateUnlockedPDF(src) != nil else { return }
        let deg = rotateDegrees
        let autoP = rotateAutoPortrait
        let spec = rotateRangeSpec

        let startRotate: (URL) -> Void = { [weak self] finalDest in
            guard let self else { return }
            self.runTrackedPDFToolTask(
                busyStatus: "Đang xoay PDF...",
                errorStatus: "Lỗi xoay PDF",
                work: {
                    try PDFToolsService.rotatePDFFile(
                        sourceURL: src,
                        destinationURL: finalDest,
                        clockwiseDegrees: deg,
                        autoPortrait: autoP,
                        rangeSpec: spec
                    )
                },
                onSuccess: { rotated in
                    let attrs = try? FileManager.default.attributesOfItem(atPath: finalDest.path)
                    let bytes = (attrs?[.size] as? Int64) ?? 0
                    let pCount = PDFDocument(url: finalDest)?.pageCount ?? 0
                    self.lastExportedPDFURL = finalDest
                    self.lastExportedFolderURL = finalDest.deletingLastPathComponent()
                    self.lastExportedInfo = "\(pCount) trang • \(PDFToolsService.formatBytes(bytes))"
                    self.previewDisplayMode = .pdfResult
                    self.appendLog("[Rotate] Đã xoay \(rotated) trang -> \(finalDest.path)")
                    self.statusText = "Đã xoay \(rotated) trang"
                }
            )
        }
        if confirmOverwrite {
            confirmWriteURL(destinationURL, onProceed: startRotate)
        } else {
            startRotate(destinationURL)
        }
    }

    func runCompressPDF(destinationURL: URL, confirmOverwrite: Bool = true) {
        guard !isBusy, let bridge else { return }
        guard let src = compressSourceURL else {
            errorMessage = "Vui lòng chọn file PDF cần nén."
            return
        }
        guard validateUnlockedPDF(src) != nil else { return }
        let dpi = compressDPI
        let qual = compressQuality
        let targetMB = compressTargetMB
        let mode = compressMode
        let autoCrop = compressAutoCrop

        let startCompress: (URL) -> Void = { [weak self] finalDest in
            guard let self else { return }
            self.activeWorkTask?.cancel()
            let workToken = UUID()
            let myTaskEpoch = self.taskEpoch
            self.activeWorkToken = workToken
            self.isBusy = true
            self.lastCompressionReport = ""
            self.lastCompressionWarning = ""
            self.statusText = "Đang nén PDF giữ trang vector..."
            let logSink = self.makeLogSink()

            self.activeWorkTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try Task.checkCancellation()
                    let res = try await bridge.compressPDF(
                        sourcePDF: src,
                        outputPDF: finalDest,
                        dpi: dpi,
                        jpegQuality: qual,
                        targetMB: targetMB,
                        mode: mode,
                        autoCrop: autoCrop,
                        onLog: logSink
                    )
                    try Task.checkCancellation()
                    guard self.taskEpoch == myTaskEpoch else {
                        throw CancellationError()
                    }
                    let beforeStr = PDFToolsService.formatBytes(res.beforeBytes)
                    let afterStr = PDFToolsService.formatBytes(res.afterBytes)
                    let summary = String(format: "Trước: %@ → Sau: %@ (Giảm %.1f%%)", beforeStr, afterStr, res.savedPercent)
                    self.lastCompressionReport = res.detailsMessage.isEmpty ? summary : "\(summary)\n\(res.detailsMessage)"
                    self.lastCompressionWarning = res.targetAchieved ? "" : "Chưa đạt mục tiêu dung lượng nhưng đã giữ nguyên text vector và độ đọc."
                    self.lastExportedPDFURL = finalDest
                    self.lastExportedFolderURL = finalDest.deletingLastPathComponent()
                    self.lastExportedInfo = "\(res.pageCount) trang • \(afterStr)"
                    self.previewDisplayMode = .pdfResult
                    self.appendLog("[Compress] \(summary) | \(res.detailsMessage)")
                    self.statusText = "Nén PDF hoàn tất"
                } catch is CancellationError {
                    if self.taskEpoch == myTaskEpoch {
                        self.statusText = "Đã hủy nén PDF"
                    }
                } catch {
                    if self.taskEpoch == myTaskEpoch {
                        self.errorMessage = error.localizedDescription
                        self.appendLog("[ERROR] \(error.localizedDescription)")
                        self.showConsole = true
                        self.statusText = "Lỗi nén PDF"
                    }
                }
                if self.activeWorkToken == workToken {
                    self.isBusy = false
                    self.activeWorkTask = nil
                    self.activeWorkToken = nil
                }
            }
        }
        if confirmOverwrite {
            confirmWriteURL(destinationURL, onProceed: startCompress)
        } else {
            startCompress(destinationURL)
        }
    }
}
