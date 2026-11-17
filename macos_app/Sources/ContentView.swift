import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct PendingOverwriteAction: Identifiable {
    let id = UUID()
    let targetURL: URL
    let onProceed: (URL) -> Void
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

    @Published var compressSourceURL: URL?
    @Published var compressSourceBytes: Int64 = 0
    @Published var compressDPI: Int = 150
    @Published var compressMode: EnhanceMode = .magicColor
    @Published var compressAutoCrop: Bool = false
    @Published var lastCompressionReport: String = ""

    @Published var selectedOriginalImage: NSImage?
    @Published var selectedProcessedImage: NSImage?

    private var bridge: ScannerBridge?
    private var autoScanTask: Task<Void, Never>?
    private var activeScanTargetIDs: [UUID] = []

    init() {
        do {
            let b = try ScannerBridge()
            self.bridge = b
            self.outputPDFPath = b.defaultOutputDir
                .appendingPathComponent("Scanned_Document_HD.pdf")
                .path
            appendLog("[Init] Workspace: \(b.workspaceRoot.path)")
            appendLog("[Init] Python: \(b.pythonURL.path)")
        } catch {
            self.errorMessage = error.localizedDescription
            appendLog("[ERROR] \(error.localizedDescription)")
        }
    }

    var workspaceRoot: URL? { bridge?.workspaceRoot }
    var defaultOutputDir: URL? { bridge?.defaultOutputDir }

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
        guard let item = selectedItem else {
            selectedOriginalImage = nil
            selectedProcessedImage = nil
            return
        }
        let targetID = item.id
        let itemCopy = item
        Task.detached(priority: .userInitiated) {
            let orig = PDFToolsService.loadDisplayImage(for: itemCopy, maxSide: 1800)
            let proc = itemCopy.processedPreviewURL.flatMap {
                PDFToolsService.makeImageThumbnail(url: $0, maxSide: 1800)
            }
            await MainActor.run {
                guard self.selectedItem?.id == targetID else { return }
                self.selectedOriginalImage = orig
                self.selectedProcessedImage = proc
            }
        }
    }

    func invalidatePreviewsAndRefresh() {
        stopAutoScanTask()
        for idx in queue.indices {
            queue[idx].processedPreviewURL = nil
        }
        selectedProcessedImage = nil
        if activeTask == .scan && !queue.isEmpty {
            startAutoScanAfterImport()
        }
    }

    func scheduleAutoPreview() {
        guard activeTask == .scan, let item = selectedItem, item.processedPreviewURL == nil, !isBusy else { return }
        if previewDisplayMode == .pdfResult { return }

        if isPreviewing {
            if activeScanTargetIDs.first == item.id { return }
            var reordered = [item.id] + activeScanTargetIDs.filter { $0 != item.id }
            reordered = reordered.filter { targetID in
                queue.first(where: { $0.id == targetID })?.processedPreviewURL == nil
            }
            if !reordered.isEmpty {
                runBackgroundScan(targetIDs: reordered, debounceNs: 120_000_000)
            }
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

    func handleDroppedURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let expanded = PDFToolsService.expandURLs(urls)
        let pdfs = expanded.filter { $0.pathExtension.lowercased() == "pdf" }

        switch activeTask {
        case .scan:
            addURLs(urls)

        case .pair:
            if let firstPDF = pdfs.first {
                pairFrontPDFURL = firstPDF
                pairUseQueueAsFront = false
                if previewDisplayMode == .pdfResult {
                    previewDisplayMode = .splitSlider
                }
                let pageCount = PDFDocument(url: firstPDF)?.pageCount ?? 0
                statusText = "Đã nạp Mặt trước: \(firstPDF.lastPathComponent) (\(pageCount) trang)"
                appendLog("[Pair] Đã nạp file mặt trước: \(firstPDF.path)")
            } else if !expanded.isEmpty {
                pairUseQueueAsFront = true
                addURLs(urls)
            } else {
                statusText = "Không tìm thấy PDF hoặc ảnh hợp lệ"
            }

        case .split:
            if let firstPDF = pdfs.first {
                splitSourceURL = firstPDF
                splitSourcePageCount = PDFDocument(url: firstPDF)?.pageCount ?? 0
                if previewDisplayMode == .pdfResult {
                    previewDisplayMode = .splitSlider
                }
                statusText = "Đã nạp PDF tách: \(firstPDF.lastPathComponent) (\(splitSourcePageCount) trang)"
                appendLog("[Split] Đã nạp nguồn: \(firstPDF.path)")
            } else if !expanded.isEmpty {
                pendingImageRedirectURLs = urls
            } else {
                statusText = "Vui lòng thả file PDF hợp lệ"
            }

        case .mergeRotate:
            if pdfs.count == 1 && expanded.count == 1, let singlePDF = pdfs.first {
                rotateSourceURL = singlePDF
                rotateSourcePageCount = PDFDocument(url: singlePDF)?.pageCount ?? 0
                if previewDisplayMode == .pdfResult {
                    previewDisplayMode = .splitSlider
                }
                statusText = "Đã nạp PDF cần xoay: \(singlePDF.lastPathComponent) (\(rotateSourcePageCount) trang)"
                appendLog("[Rotate] Đã nạp nguồn: \(singlePDF.path)")
            } else if !expanded.isEmpty {
                addURLs(urls)
            } else {
                statusText = "Không tìm thấy PDF hoặc ảnh hợp lệ"
            }

        case .compress:
            if let firstPDF = pdfs.first {
                compressSourceURL = firstPDF
                let attrs = try? FileManager.default.attributesOfItem(atPath: firstPDF.path)
                compressSourceBytes = (attrs?[.size] as? Int64) ?? 0
                lastCompressionReport = ""
                if previewDisplayMode == .pdfResult {
                    previewDisplayMode = .splitSlider
                }
                statusText = "Đã nạp PDF cần nén: \(firstPDF.lastPathComponent) (\(PDFToolsService.formatBytes(compressSourceBytes)))"
                appendLog("[Compress] Đã nạp nguồn: \(firstPDF.path)")
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
        guard !urls.isEmpty else { return }
        activeTask = .scan
        addURLs(urls)
    }

    func addURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        statusText = "Đang nạp & sắp xếp A→Z..."
        let currentTask = activeTask
        Task.detached(priority: .userInitiated) {
            let loaded = PDFToolsService.loadInputItems(from: urls)
            await MainActor.run {
                if loaded.isEmpty {
                    self.statusText = "Không tìm thấy ảnh hoặc PDF hợp lệ"
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
                if currentTask == .scan {
                    self.startAutoScanAfterImport()
                }
            }
        }
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
        stopAutoScanTask()
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
        }
        statusText = "Sẵn sàng cho bộ tài liệu mới"
    }

    func rotateItem(id: UUID, deltaDegrees: Int) {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        let updatedDeg = ((queue[idx].rotationDegrees + deltaDegrees) % 360 + 360) % 360
        queue[idx].rotationDegrees = updatedDeg
        queue[idx].orientationChecked = true
        queue[idx].processedPreviewURL = nil
        if let thumb = queue[idx].thumbnail {
            queue[idx].thumbnail = PDFToolsService.rotatedNSImage(thumb, clockwiseDegrees: deltaDegrees)
        }
        if selectedItem?.id == id {
            refreshSelectedImages()
            scheduleAutoPreview()
        }
    }

    func rotateAll(deltaDegrees: Int) {
        stopAutoScanTask()
        for idx in queue.indices {
            queue[idx].rotationDegrees = ((queue[idx].rotationDegrees + deltaDegrees) % 360 + 360) % 360
            queue[idx].orientationChecked = true
            queue[idx].processedPreviewURL = nil
            if let thumb = queue[idx].thumbnail {
                queue[idx].thumbnail = PDFToolsService.rotatedNSImage(thumb, clockwiseDegrees: deltaDegrees)
            }
        }
        refreshSelectedImages()
        scheduleAutoPreview()
    }

    func moveItem(id: UUID, offset: Int) {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        let target = idx + offset
        guard target >= 0 && target < queue.count else { return }
        queue.swapAt(idx, target)
    }

    func removeItem(id: UUID) {
        queue.removeAll(where: { $0.id == id })
        if selectedItemID == id {
            selectedItemID = queue.first?.id
            refreshSelectedImages()
            scheduleAutoPreview()
        }
    }

    func clearQueue() {
        stopAutoScanTask()
        queue.removeAll()
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
        autoScanTask?.cancel()
        autoScanTask = nil
        if isPreviewing && !isBusy {
            bridge?.cancelActiveProcess()
        }
        isPreviewing = false
        activeScanTargetIDs = []
    }

    func startAutoScanAfterImport() {
        let unscanned = queue.filter { $0.processedPreviewURL == nil }.map(\.id)
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
        let unscanned = queue.filter { $0.processedPreviewURL == nil }.map(\.id)
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
        if forceRefresh, let idx = queue.firstIndex(where: { $0.id == item.id }) {
            queue[idx].processedPreviewURL = nil
            selectedProcessedImage = nil
        }
        runBackgroundScan(targetIDs: [item.id], debounceNs: 0)
    }

    private func runBackgroundScan(targetIDs: [UUID], debounceNs: UInt64) {
        guard let bridge, !isBusy else { return }
        let previousTask = autoScanTask
        stopAutoScanTask()
        activeScanTargetIDs = targetIDs
        isPreviewing = true

        autoScanTask = Task { [weak self] in
            guard let self else { return }
            await previousTask?.value
            if debounceNs > 0 {
                try? await Task.sleep(nanoseconds: debounceNs)
            }
            guard !Task.isCancelled else { return }

            let total = targetIDs.count
            let logSink = self.makeLogSink()

            for (stepIdx, targetID) in targetIDs.enumerated() {
                if Task.isCancelled || self.isBusy { break }
                guard let currentIdx = self.queue.firstIndex(where: { $0.id == targetID }) else { continue }
                if self.queue[currentIdx].processedPreviewURL != nil { continue }

                var item = self.queue[currentIdx]
                self.statusText = total > 1
                    ? "Đang dò hướng & scan (\(stepIdx + 1)/\(total)): \(item.displayName)..."
                    : "Đang dò hướng & làm nét: \(item.displayName)..."

                if !item.orientationChecked {
                    let itemCopy = item
                    let deltaDeg = await PDFToolsService.detectReadingOrientationDegreesAsync(for: itemCopy)
                    if Task.isCancelled { break }
                    if let idxNow = self.queue.firstIndex(where: { $0.id == targetID }) {
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
                    }
                }

                if Task.isCancelled || self.isBusy { break }
                let settingsSnapshot = self.settings
                let rotationSnapshot = item.rotationDegrees

                do {
                    let previewURL = try await bridge.previewSinglePage(
                        item: item,
                        settings: settingsSnapshot,
                        onLog: logSink
                    )
                    if Task.isCancelled { break }
                    if let idxNow = self.queue.firstIndex(where: { $0.id == targetID }),
                       self.queue[idxNow].rotationDegrees == rotationSnapshot,
                       self.settings == settingsSnapshot {
                        self.queue[idxNow].processedPreviewURL = previewURL
                        if self.selectedItem?.id == targetID {
                            self.refreshSelectedImages()
                        }
                    }
                } catch {
                    if Task.isCancelled { break }
                    self.appendLog("[Preview] Bỏ qua \(item.displayName): \(error.localizedDescription)")
                }
            }

            if !Task.isCancelled {
                self.isPreviewing = false
                self.activeScanTargetIDs = []
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

    private func executeBatchScan(to targetURL: URL) {
        guard let bridge else { return }
        let previousTask = autoScanTask
        stopAutoScanTask()
        let settingsSnapshot = settings
        let logSink = makeLogSink()
        isBusy = true
        statusText = "Đang kiểm tra hướng đọc & xuất \(queue.count) trang..."

        Task { [weak self] in
            guard let self else { return }
            await previousTask?.value
            do {
                // Ensure any remaining unchecked pages have their reading orientation verified before batch scan
                for idx in self.queue.indices where !self.queue[idx].orientationChecked && self.queue[idx].processedPreviewURL == nil {
                    let itemCopy = self.queue[idx]
                    let targetID = itemCopy.id
                    let deltaDeg = await PDFToolsService.detectReadingOrientationDegreesAsync(for: itemCopy)
                    if let idxNow = self.queue.firstIndex(where: { $0.id == targetID }) {
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

                let itemsSnapshot = self.queue
                self.statusText = "Đang đóng gói PDF (\(itemsSnapshot.count) trang)..."
                let previews = try await bridge.runBatchScan(
                    items: itemsSnapshot,
                    settings: settingsSnapshot,
                    outputPDF: targetURL,
                    onLog: logSink
                )
                for (idx, previewURL) in previews.enumerated() where idx < self.queue.count {
                    if self.queue[idx].id == itemsSnapshot[idx].id {
                        self.queue[idx].processedPreviewURL = previewURL
                    }
                }
                self.lastExportedPDFURL = targetURL
                self.lastExportedFolderURL = targetURL.deletingLastPathComponent()
                let attrs = try? FileManager.default.attributesOfItem(atPath: targetURL.path)
                let bytes = (attrs?[.size] as? Int64) ?? 0
                let pages = PDFDocument(url: targetURL)?.pageCount ?? itemsSnapshot.count
                self.lastExportedInfo = "\(pages) trang • \(PDFToolsService.formatBytes(bytes))"
                self.previewDisplayMode = .pdfResult
                self.refreshSelectedImages()
                self.statusText = "Hoàn tất: \(targetURL.lastPathComponent) (\(self.lastExportedInfo))"
                self.appendLog("[DONE] Đã xuất \(targetURL.path) (\(self.lastExportedInfo))")
            } catch {
                self.errorMessage = error.localizedDescription
                self.appendLog("[ERROR] \(error.localizedDescription)")
                self.showConsole = true
                self.statusText = "Lỗi xuất PDF"
            }
            self.isBusy = false
        }
    }

    func cancelRunningTask() {
        stopAutoScanTask()
        bridge?.cancelActiveProcess()
        appendLog("[Cancel] Đã gửi tín hiệu dừng tiến trình.")
        statusText = "Đã hủy"
    }

    // MARK: - Overwrite Safety Checkpoint

    func confirmWriteURL(_ targetURL: URL, onProceed: @escaping (URL) -> Void) {
        if FileManager.default.fileExists(atPath: targetURL.path) {
            pendingOverwrite = PendingOverwriteAction(targetURL: targetURL, onProceed: onProceed)
        } else {
            onProceed(targetURL)
        }
    }

    // MARK: - PDF Tools Actions

    func runPairFrontAndBack(destinationURL: URL) {
        guard !isBusy else { return }
        guard let backURL = pairBackSourceURL else {
            errorMessage = "Vui lòng chọn file trang mặt sau (PDF hoặc ảnh)."
            return
        }
        let frontURL = pairUseQueueAsFront ? nil : pairFrontPDFURL
        if !pairUseQueueAsFront && frontURL == nil {
            errorMessage = "Vui lòng chọn file PDF mặt trước hoặc bật 'Dùng danh sách trang hiện tại'."
            return
        }
        let queueSnapshot = queue
        let mode = pairOutputMode
        let prefix = pairFilePrefix
        let startIdx = pairStartIndex

        let performPair: (URL) -> Void = { [weak self] finalDest in
            guard let self else { return }
            self.isBusy = true
            self.statusText = "Đang ghép cặp trang..."
            Task.detached(priority: .userInitiated) {
                do {
                    let outputs = try PDFToolsService.pairFrontAndBack(
                        frontPDFURL: frontURL,
                        queueItems: queueSnapshot,
                        backSourceURL: backURL,
                        outputMode: mode,
                        destinationURL: finalDest,
                        filePrefix: prefix,
                        startIndex: startIdx
                    )
                    await MainActor.run {
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
                        self.isBusy = false
                    }
                } catch {
                    await MainActor.run {
                        self.errorMessage = error.localizedDescription
                        self.appendLog("[ERROR] \(error.localizedDescription)")
                        self.statusText = "Lỗi ghép cặp"
                        self.isBusy = false
                    }
                }
            }
        }

        if mode == .singleCombined {
            confirmWriteURL(destinationURL, onProceed: performPair)
        } else {
            performPair(destinationURL)
        }
    }

    func runSplitPDF(destinationURL: URL) {
        guard !isBusy, let src = splitSourceURL else {
            errorMessage = "Vui lòng chọn file PDF nguồn để tách."
            return
        }
        let mode = splitMode
        let range = splitRangeSpec

        let performSplit: (URL) -> Void = { [weak self] finalDest in
            guard let self else { return }
            self.isBusy = true
            self.statusText = "Đang tách PDF..."
            Task.detached(priority: .userInitiated) {
                do {
                    let outputs = try PDFToolsService.splitPDF(
                        sourceURL: src,
                        mode: mode,
                        rangeSpec: range,
                        destinationURL: finalDest
                    )
                    await MainActor.run {
                        self.appendLog("[Split] Đã xuất \(outputs.count) file từ \(src.lastPathComponent)")
                        if outputs.count == 1, let single = outputs.first {
                            self.lastExportedPDFURL = single
                            let attrs = try? FileManager.default.attributesOfItem(atPath: single.path)
                            let bytes = (attrs?[.size] as? Int64) ?? 0
                            let pCount = PDFDocument(url: single)?.pageCount ?? 0
                            self.lastExportedInfo = "\(pCount) trang • \(PDFToolsService.formatBytes(bytes))"
                            self.previewDisplayMode = .pdfResult
                        } else {
                            NSWorkspace.shared.open(finalDest)
                        }
                        self.statusText = "Đã tách \(outputs.count) file"
                        self.isBusy = false
                    }
                } catch {
                    await MainActor.run {
                        self.errorMessage = error.localizedDescription
                        self.appendLog("[ERROR] \(error.localizedDescription)")
                        self.statusText = "Lỗi tách PDF"
                        self.isBusy = false
                    }
                }
            }
        }

        if mode == .customRange {
            confirmWriteURL(destinationURL, onProceed: performSplit)
        } else {
            performSplit(destinationURL)
        }
    }

    func runMergeQueue(destinationURL: URL) {
        guard !isBusy, !queue.isEmpty else { return }
        let itemsSnapshot = queue
        confirmWriteURL(destinationURL) { [weak self] finalDest in
            guard let self else { return }
            self.isBusy = true
            self.statusText = "Đang gộp \(itemsSnapshot.count) trang..."
            Task.detached(priority: .userInitiated) {
                do {
                    let count = try PDFToolsService.mergeQueueToPDF(items: itemsSnapshot, destinationURL: finalDest)
                    await MainActor.run {
                        let attrs = try? FileManager.default.attributesOfItem(atPath: finalDest.path)
                        let bytes = (attrs?[.size] as? Int64) ?? 0
                        self.lastExportedPDFURL = finalDest
                        self.lastExportedInfo = "\(count) trang • \(PDFToolsService.formatBytes(bytes))"
                        self.previewDisplayMode = .pdfResult
                        self.appendLog("[Merge] Đã gộp \(count) trang -> \(finalDest.path)")
                        self.statusText = "Gộp PDF hoàn tất"
                        self.isBusy = false
                    }
                } catch {
                    await MainActor.run {
                        self.errorMessage = error.localizedDescription
                        self.appendLog("[ERROR] \(error.localizedDescription)")
                        self.statusText = "Lỗi gộp PDF"
                        self.isBusy = false
                    }
                }
            }
        }
    }

    func runMergeExternalPDFs(urls: [URL], destinationURL: URL) {
        guard !isBusy, !urls.isEmpty else { return }
        confirmWriteURL(destinationURL) { [weak self] finalDest in
            guard let self else { return }
            self.isBusy = true
            self.statusText = "Đang gộp \(urls.count) file PDF..."
            Task.detached(priority: .userInitiated) {
                do {
                    let count = try PDFToolsService.mergePDFFiles(urls: urls, destinationURL: finalDest)
                    await MainActor.run {
                        let attrs = try? FileManager.default.attributesOfItem(atPath: finalDest.path)
                        let bytes = (attrs?[.size] as? Int64) ?? 0
                        self.lastExportedPDFURL = finalDest
                        self.lastExportedInfo = "\(count) trang • \(PDFToolsService.formatBytes(bytes))"
                        self.previewDisplayMode = .pdfResult
                        self.appendLog("[Merge] Đã gộp \(urls.count) file (\(count) trang) -> \(finalDest.path)")
                        self.statusText = "Gộp \(urls.count) PDF hoàn tất"
                        self.isBusy = false
                    }
                } catch {
                    await MainActor.run {
                        self.errorMessage = error.localizedDescription
                        self.appendLog("[ERROR] \(error.localizedDescription)")
                        self.statusText = "Lỗi gộp PDF"
                        self.isBusy = false
                    }
                }
            }
        }
    }

    func runRotatePDF(destinationURL: URL) {
        guard !isBusy, let src = rotateSourceURL else {
            errorMessage = "Vui lòng chọn file PDF cần xoay."
            return
        }
        let deg = rotateDegrees
        let autoP = rotateAutoPortrait
        let spec = rotateRangeSpec

        confirmWriteURL(destinationURL) { [weak self] finalDest in
            guard let self else { return }
            self.isBusy = true
            self.statusText = "Đang xoay PDF..."
            Task.detached(priority: .userInitiated) {
                do {
                    let rotated = try PDFToolsService.rotatePDFFile(
                        sourceURL: src,
                        destinationURL: finalDest,
                        clockwiseDegrees: deg,
                        autoPortrait: autoP,
                        rangeSpec: spec
                    )
                    await MainActor.run {
                        let attrs = try? FileManager.default.attributesOfItem(atPath: finalDest.path)
                        let bytes = (attrs?[.size] as? Int64) ?? 0
                        let pCount = PDFDocument(url: finalDest)?.pageCount ?? 0
                        self.lastExportedPDFURL = finalDest
                        self.lastExportedInfo = "\(pCount) trang • \(PDFToolsService.formatBytes(bytes))"
                        self.previewDisplayMode = .pdfResult
                        self.appendLog("[Rotate] Đã xoay \(rotated) trang -> \(finalDest.path)")
                        self.statusText = "Đã xoay \(rotated) trang"
                        self.isBusy = false
                    }
                } catch {
                    await MainActor.run {
                        self.errorMessage = error.localizedDescription
                        self.appendLog("[ERROR] \(error.localizedDescription)")
                        self.statusText = "Lỗi xoay PDF"
                        self.isBusy = false
                    }
                }
            }
        }
    }

    func runCompressPDF(destinationURL: URL) {
        guard !isBusy, let bridge, let src = compressSourceURL else {
            errorMessage = "Vui lòng chọn file PDF cần nén."
            return
        }
        let dpi = compressDPI
        let mode = compressMode
        let autoCrop = compressAutoCrop

        confirmWriteURL(destinationURL) { [weak self] finalDest in
            guard let self else { return }
            self.isBusy = true
            self.lastCompressionReport = ""
            self.statusText = "Đang nén PDF ở \(dpi) DPI..."
            let logSink = self.makeLogSink()

            Task { [weak self] in
                guard let self else { return }
                do {
                    let res = try await bridge.compressPDF(
                        sourcePDF: src,
                        outputPDF: finalDest,
                        dpi: dpi,
                        mode: mode,
                        autoCrop: autoCrop,
                        onLog: logSink
                    )
                    let beforeStr = PDFToolsService.formatBytes(res.beforeBytes)
                    let afterStr = PDFToolsService.formatBytes(res.afterBytes)
                    let report = String(format: "Trước: %@ → Sau: %@ (Giảm %.1f%%)", beforeStr, afterStr, res.savedPercent)
                    self.lastCompressionReport = report
                    self.lastExportedPDFURL = finalDest
                    self.lastExportedInfo = "\(res.pageCount) trang • \(afterStr)"
                    self.previewDisplayMode = .pdfResult
                    self.appendLog("[Compress] \(report)")
                    self.statusText = "Nén PDF hoàn tất"
                } catch {
                    self.errorMessage = error.localizedDescription
                    self.appendLog("[ERROR] \(error.localizedDescription)")
                    self.showConsole = true
                    self.statusText = "Lỗi nén PDF"
                }
                self.isBusy = false
            }
        }
    }
}

// MARK: - Main ContentView (Layout A: Task-First Studio + Preview 1: Split Slider)

struct ContentView: View {
    @StateObject private var vm = AppViewModel()
    @State private var isDropTargeted = false

    private var shouldShowPageStrip: Bool {
        guard !vm.queue.isEmpty, vm.previewDisplayMode != .pdfResult else { return false }
        switch vm.activeTask {
        case .scan:
            return true
        case .pair:
            return vm.pairUseQueueAsFront
        case .mergeRotate:
            return vm.rotateSourceURL == nil
        case .split, .compress:
            return false
        }
    }

    private var shouldShowInspector: Bool {
        !vm.isCurrentTaskEmpty || vm.previewDisplayMode == .pdfResult
    }

    var body: some View {
        HStack(spacing: 0) {
            TaskRailView(vm: vm, onAddFiles: pickInputFilesOrFolders)
                .frame(width: 78)

            Divider()

            if shouldShowPageStrip {
                CompactPageStripView(vm: vm, onAddFiles: pickInputFilesOrFolders)
                    .frame(width: 170)

                Divider()
            }

            CenterCanvasView(
                vm: vm,
                isDropTargeted: $isDropTargeted,
                onAddFiles: pickInputFilesOrFolders
            )
            .frame(minWidth: 480, maxWidth: .infinity)

            if shouldShowInspector {
                Divider()

                TaskInspectorView(vm: vm)
                    .frame(width: 315)
            }
        }
        .frame(minWidth: 1080, minHeight: 680)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .alert(
            "File PDF đã tồn tại",
            isPresented: Binding(
                get: { vm.pendingOverwrite != nil },
                set: { if !$0 { vm.pendingOverwrite = nil } }
            ),
            presenting: vm.pendingOverwrite
        ) { pending in
            Button("Ghi đè file cũ", role: .destructive) {
                let action = pending.onProceed
                let url = pending.targetURL
                vm.pendingOverwrite = nil
                action(url)
            }
            Button("Lưu tên mới (_1, _2...)") {
                let unique = PDFToolsService.uniqueURLIfExists(pending.targetURL)
                let action = pending.onProceed
                vm.pendingOverwrite = nil
                action(unique)
            }
            Button("Hủy", role: .cancel) {
                vm.pendingOverwrite = nil
            }
        } message: { pending in
            Text("\"\(pending.targetURL.lastPathComponent)\" đã có trên đĩa. Bạn muốn ghi đè hay tự động lưu bản mới?")
        }
        .alert(
            "Tab \(vm.activeTask.title) chỉ nhận file PDF",
            isPresented: Binding(
                get: { !vm.pendingImageRedirectURLs.isEmpty },
                set: { if !$0 { vm.pendingImageRedirectURLs = [] } }
            )
        ) {
            Button("Chuyển sang Scan & nạp ảnh") {
                vm.redirectPendingImagesToScan()
            }
            Button("Đóng", role: .cancel) {
                vm.pendingImageRedirectURLs = []
            }
        } message: {
            Text("Bạn vừa thả file ảnh vào công cụ \"\(vm.activeTask.title)\". Bạn có muốn chuyển sang tab Scan để làm nét và xuất thành PDF trước không?")
        }
        .alert("Thông báo lỗi", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("Đóng", role: .cancel) { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let validProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !validProviders.isEmpty else { return false }

        let group = DispatchGroup()
        let lock = NSLock()
        var droppedURLs: [URL] = []

        for provider in validProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var resolvedURL: URL?
                if let data = item as? Data {
                    resolvedURL = URL(dataRepresentation: data, relativeTo: nil)
                } else if let url = item as? URL {
                    resolvedURL = url
                }
                if let url = resolvedURL {
                    lock.lock()
                    droppedURLs.append(url)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            if !droppedURLs.isEmpty {
                vm.handleDroppedURLs(droppedURLs)
            }
        }
        return true
    }

    private func pickInputFilesOrFolders() {
        let panel = NSOpenPanel()
        panel.title = vm.activeTask.dropzonePrimaryButtonTitle
        panel.canChooseFiles = true
        if vm.activeTask.acceptsImagesDirectly {
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.allowedContentTypes = [.image, .pdf, .folder]
        } else {
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.pdf]
        }
        if let root = vm.workspaceRoot {
            panel.directoryURL = root
        }
        if panel.runModal() == .OK {
            vm.handleDroppedURLs(panel.urls)
        }
    }
}

// MARK: - Zone 1: Left Task Rail

struct TaskRailView: View {
    @ObservedObject var vm: AppViewModel
    let onAddFiles: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 3) {
                Image(systemName: "doc.viewfinder.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("PDF Scanner")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 12)
            .padding(.bottom, 6)

            ForEach(StudioTask.allCases) { task in
                let active = vm.activeTask == task
                Button {
                    vm.activeTask = task
                    if vm.previewDisplayMode == .pdfResult {
                        vm.previewDisplayMode = .splitSlider
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: task.icon)
                            .font(.system(size: 17))
                        Text(task.title)
                            .font(.system(size: 10, weight: active ? .semibold : .medium))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 4)
                    .background(active ? Color.accentColor : Color.clear)
                    .foregroundStyle(active ? Color.white : Color.primary)
                    .cornerRadius(8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .help(task.fullTitle)
            }

            Spacer()

            Divider()
                .padding(.horizontal, 10)

            VStack(spacing: 6) {
                Button(action: onAddFiles) {
                    VStack(spacing: 2) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                        Text("Thêm file")
                            .font(.system(size: 9))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.borderless)
                .help("Chọn ảnh, PDF hoặc thư mục")

                Button {
                    vm.loadFromDefaultInput()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 15))
                        Text("Nạp input/")
                            .font(.system(size: 9))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.borderless)
                .help("Nạp file mẫu từ thư mục input/")

                Button {
                    vm.openDefaultOutputFolder()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "folder")
                            .font(.system(size: 15))
                        Text("output/")
                            .font(.system(size: 9))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.borderless)
                .help("Mở thư mục output/ trong Finder")
            }
            .padding(.bottom, 10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Zone 2: Compact Page Strip

struct CompactPageStripView: View {
    @ObservedObject var vm: AppViewModel
    let onAddFiles: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Trang (\(vm.queue.count))")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    vm.rotateAll(deltaDegrees: 90)
                } label: {
                    Image(systemName: "rotate.right")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Xoay tất cả trang 90° sang phải")

                Button(role: .destructive) {
                    vm.clearQueue()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Xóa toàn bộ danh sách")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(Array(vm.queue.enumerated()), id: \.element.id) { index, item in
                        CompactPageCard(
                            index: index,
                            total: vm.queue.count,
                            item: item,
                            isSelected: vm.selectedItem?.id == item.id,
                            onSelect: { vm.selectItem(item.id) },
                            onRotateLeft: { vm.rotateItem(id: item.id, deltaDegrees: -90) },
                            onRotateRight: { vm.rotateItem(id: item.id, deltaDegrees: 90) },
                            onMoveUp: { vm.moveItem(id: item.id, offset: -1) },
                            onMoveDown: { vm.moveItem(id: item.id, offset: 1) },
                            onDelete: { vm.removeItem(id: item.id) }
                        )
                    }
                }
                .padding(8)
            }

            Divider()

            Button(action: onAddFiles) {
                Label("Thêm trang", systemImage: "plus")
                    .font(.caption.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderless)
            .background(.bar)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct CompactPageCard: View {
    let index: Int
    let total: Int
    let item: InputPageItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onRotateLeft: () -> Void
    let onRotateRight: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 7) {
                ZStack(alignment: .topLeading) {
                    if let thumb = item.thumbnail {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 38, height: 50)
                            .background(Color.white)
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.15))
                            .frame(width: 38, height: 50)
                            .overlay(Image(systemName: "doc").font(.caption).foregroundStyle(.secondary))
                    }

                    Text("\(index + 1)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(isSelected ? Color.accentColor : Color.black.opacity(0.65))
                        .cornerRadius(3)
                        .offset(x: -2, y: -2)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(2)

                    HStack(spacing: 4) {
                        if item.processedPreviewURL != nil {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                                .help("Đã có ảnh xem trước sau scan")
                        }
                        if item.rotationDegrees != 0 {
                            Text("\(item.rotationDegrees)°")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.18))
                                .foregroundStyle(.orange)
                                .cornerRadius(3)
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Button(action: onRotateLeft) {
                    Image(systemName: "rotate.left").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Xoay trái 90°")

                Button(action: onRotateRight) {
                    Image(systemName: "rotate.right").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Xoay phải 90°")

                Spacer()

                Button(action: onMoveUp) {
                    Image(systemName: "chevron.up").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .disabled(index == 0)

                Button(action: onMoveDown) {
                    Image(systemName: "chevron.down").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .disabled(index >= total - 1)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "xmark").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Xóa trang")
            }
            .foregroundStyle(.secondary)
        }
        .padding(6)
        .background(isSelected ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
        .cornerRadius(7)
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.16), lineWidth: isSelected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - Zone 3: Center Document Canvas & Split Slider

struct CenterCanvasView: View {
    @ObservedObject var vm: AppViewModel
    @Binding var isDropTargeted: Bool
    let onAddFiles: () -> Void

    private var showTopToolbar: Bool {
        if vm.previewDisplayMode == .pdfResult {
            return true
        }
        return !vm.isCurrentTaskEmpty && vm.activeTask != .scan
    }

    var body: some View {
        VStack(spacing: 0) {
            if showTopToolbar {
                // Top Canvas Toolbar (shown for PDF tools source preview or post-export PDF result)
                HStack(spacing: 10) {
                    if vm.previewDisplayMode == .pdfResult {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            Text("Kết quả PDF đã xuất")
                                .font(.caption.weight(.semibold))
                            if !vm.isCurrentTaskEmpty {
                                Button(vm.activeTask == .scan ? "← Quay lại trang Scan" : "Xem file nguồn") {
                                    vm.previewDisplayMode = .splitSlider
                                }
                                .controlSize(.small)
                            }
                        }
                    } else if let srcURL = vm.activePDFSourceURL {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.richtext")
                                .foregroundStyle(Color.accentColor)
                            Text("PDF nguồn: \(srcURL.lastPathComponent)")
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                        }
                    } else {
                        Text("\(vm.activeTask.fullTitle) • \(vm.queue.count) trang")
                            .font(.caption.weight(.semibold))
                    }

                    Spacer()

                    if vm.previewDisplayMode == .pdfResult {
                        if let pdfURL = vm.lastExportedPDFURL {
                            Text(vm.lastExportedInfo)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Mở Preview") {
                                NSWorkspace.shared.open(pdfURL)
                            }
                            .controlSize(.small)
                            Button("Mở trong Finder") {
                                if let folder = vm.lastExportedFolderURL, vm.activeTask == .pair, vm.pairOutputMode == .separateFiles {
                                    NSWorkspace.shared.open(folder)
                                } else {
                                    NSWorkspace.shared.activateFileViewerSelecting([pdfURL])
                                }
                            }
                            .controlSize(.small)
                            Button {
                                vm.resetCurrentTaskToNewBatch()
                            } label: {
                                Label("Bắt đầu bộ mới", systemImage: "plus.circle.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    } else {
                        HStack(spacing: 6) {
                            Button("Đổi file...", action: onAddFiles)
                                .controlSize(.small)
                            Button("Xóa") {
                                vm.resetCurrentTaskToNewBatch()
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)

                Divider()
            }

            // Main Stage
            ZStack {
                Color(nsColor: .textBackgroundColor).opacity(0.55)

                if vm.previewDisplayMode == .pdfResult {
                    if let pdfURL = vm.lastExportedPDFURL {
                        PDFKitPreviewView(url: pdfURL)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "doc.richtext")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                            Text("Chưa có file PDF nào được xuất trong phiên này")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if vm.isCurrentTaskEmpty {
                    WelcomeDropzoneView(
                        task: vm.activeTask,
                        isDropTargeted: isDropTargeted,
                        onAddFiles: onAddFiles,
                        onLoadSample: { vm.loadFromDefaultInput() }
                    )
                } else if vm.activeTask != .scan {
                    if let srcURL = vm.activePDFSourceURL {
                        PDFKitPreviewView(url: srcURL)
                    } else {
                        ImageStagePane(
                            title: "Trang mặt trước / Hàng đợi (\(vm.queue.count) trang)",
                            image: vm.selectedOriginalImage,
                            placeholder: "Chọn một trang ở cột bên trái để xem",
                            fitToViewport: vm.fitToViewport,
                            zoomScale: vm.zoomScale,
                            actionTitle: nil,
                            action: nil
                        )
                        .padding(12)
                    }
                } else {
                    InteractiveSplitComparisonView(
                        originalImage: vm.selectedOriginalImage,
                        processedImage: vm.selectedProcessedImage,
                        modeTitle: vm.settings.mode.title,
                        isBusy: vm.isBusy || vm.isPreviewing,
                        fitToViewport: $vm.fitToViewport,
                        zoomScale: $vm.zoomScale,
                        splitPosition: $vm.splitSliderPosition,
                        onRenderPreview: { vm.previewSelectedPage(forceRefresh: true) }
                    )
                }

                if isDropTargeted && !vm.isCurrentTaskEmpty {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [8]))
                        .background(Color.accentColor.opacity(0.08).cornerRadius(12))
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Collapsed 1-Line Bottom Status Bar + Expandable Console Drawer
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if vm.isBusy || vm.isPreviewing {
                        ProgressView().controlSize(.small)
                    } else {
                        Circle()
                            .fill(vm.errorMessage == nil ? Color.green : Color.red)
                            .frame(width: 7, height: 7)
                    }

                    Text(vm.statusText)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)

                    Spacer()

                    if !vm.queue.isEmpty && vm.activeTask == .scan {
                        Text("\(vm.queue.count) trang • \(vm.settings.mode.title) • \(vm.settings.dpi) DPI")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if vm.showConsole && !vm.logs.isEmpty {
                        Button("Xóa") { vm.clearLogs() }
                            .buttonStyle(.borderless)
                            .font(.caption2)
                    }

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            vm.showConsole.toggle()
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text("Nhật ký (\(vm.logs.count))")
                            Image(systemName: vm.showConsole ? "chevron.down" : "chevron.up")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)

                if vm.showConsole {
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(vm.logs.enumerated()), id: \.offset) { idx, line in
                                    Text(line)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(line.contains("[ERROR]") || line.contains("[stderr]") ? .red : .primary)
                                        .textSelection(.enabled)
                                        .id(idx)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        }
                        .frame(height: 110)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .onChange(of: vm.logs.count) { _, newCount in
                            if newCount > 0 {
                                proxy.scrollTo(newCount - 1, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct WelcomeDropzoneView: View {
    let task: StudioTask
    let isDropTargeted: Bool
    let onAddFiles: () -> Void
    let onLoadSample: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(isDropTargeted ? 0.22 : 0.11))
                    .frame(width: 72, height: 72)
                Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : task.icon)
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 6) {
                Text(task.dropzoneTitle)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(task.dropzoneSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button(action: onAddFiles) {
                    Label(task.dropzonePrimaryButtonTitle, systemImage: "plus.rectangle.on.folder")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if task == .scan || task == .pair {
                    Button(action: onLoadSample) {
                        Label("Nạp mẫu từ input/", systemImage: "tray.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
        }
        .padding(36)
        .frame(maxWidth: 500)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.28),
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2.5 : 1.5, dash: [8])
                )
        )
        .padding(24)
    }
}

// MARK: - Preview 1: Interactive Split Slider

struct InteractiveSplitComparisonView: View {
    let originalImage: NSImage?
    let processedImage: NSImage?
    let modeTitle: String
    let isBusy: Bool
    @Binding var fitToViewport: Bool
    @Binding var zoomScale: CGFloat
    @Binding var splitPosition: Double
    let onRenderPreview: () -> Void

    @State private var pinchBaseZoom: CGFloat?

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let refSize = (processedImage ?? originalImage)?.size ?? NSSize(width: 600, height: 800)
                let pad: CGFloat = 16
                let availW = max(180, geo.size.width - pad * 2)
                let availH = max(180, geo.size.height - pad * 2)
                let baseScale = min(availW / max(refSize.width, 1), availH / max(refSize.height, 1))
                let effectiveScale = fitToViewport ? baseScale : baseScale * zoomScale
                let boxW = max(160, refSize.width * effectiveScale)
                let boxH = max(160, refSize.height * effectiveScale)
                let lineX = boxW * splitPosition

                let content = ZStack {
                    // Base Layer: AFTER (Processed)
                    ZStack(alignment: .topTrailing) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor))

                        if let processedImage {
                            Image(nsImage: processedImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: boxW, height: boxH)

                            Text("SAU • \(modeTitle)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.green.opacity(0.85))
                                .cornerRadius(5)
                                .padding(8)
                        } else {
                            if let originalImage {
                                Image(nsImage: originalImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: boxW, height: boxH)
                                    .opacity(0.28)
                            }
                            VStack(spacing: 8) {
                                if isBusy {
                                    ProgressView()
                                    Text("Đang xử lý xem thử...")
                                        .font(.caption.weight(.medium))
                                } else {
                                    Text("Chưa có bản xem thử Sau Scan")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Button("Tạo xem thử ngay", action: onRenderPreview)
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                }
                            }
                            .padding(12)
                            .background(.ultraThinMaterial)
                            .cornerRadius(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(width: boxW, height: boxH)

                    // Top Clipped Layer: BEFORE (Original)
                    if let originalImage {
                        ZStack(alignment: .topLeading) {
                            Image(nsImage: originalImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: boxW, height: boxH)

                            Text("TRƯỚC • Ảnh gốc")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.orange.opacity(0.90))
                                .cornerRadius(5)
                                .padding(8)
                        }
                        .frame(width: boxW, height: boxH)
                        .mask(
                            HStack(spacing: 0) {
                                Rectangle()
                                    .frame(width: max(0, boxW * splitPosition))
                                Spacer(minLength: 0)
                            }
                            .frame(width: boxW, height: boxH)
                        )
                    }

                    // Interactive Vertical Split Line + Knob (dedicated 44px drag strip so ScrollView panning remains free)
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 2.5, height: boxH)
                        .shadow(color: .black.opacity(0.3), radius: 2)
                        .position(x: lineX, y: boxH / 2)
                        .allowsHitTesting(false)

                    ZStack {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 30, height: 30)
                            .shadow(color: .black.opacity(0.28), radius: 3, y: 1)
                        Image(systemName: "arrow.left.and.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .position(x: lineX, y: boxH / 2)
                    .allowsHitTesting(false)

                    Color.clear
                        .frame(width: 44, height: boxH)
                        .contentShape(Rectangle())
                        .position(x: lineX, y: boxH / 2)
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("splitStage"))
                                .onChanged { value in
                                    let ratio = Double(value.location.x / max(boxW, 1))
                                    splitPosition = min(0.95, max(0.05, ratio))
                                }
                        )
                }
                .frame(width: boxW, height: boxH)
                .coordinateSpace(name: "splitStage")
                .cornerRadius(6)
                .shadow(color: .black.opacity(0.14), radius: 6, y: 2)

                Group {
                    if fitToViewport {
                        content
                            .frame(width: geo.size.width, height: geo.size.height)
                    } else {
                        ScrollView([.horizontal, .vertical]) {
                            content
                                .padding(pad)
                                .frame(
                                    minWidth: geo.size.width,
                                    minHeight: geo.size.height
                                )
                        }
                    }
                }
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            if pinchBaseZoom == nil {
                                pinchBaseZoom = fitToViewport ? 1.0 : zoomScale
                            }
                            fitToViewport = false
                            let base = pinchBaseZoom ?? zoomScale
                            zoomScale = min(4.0, max(0.5, base * value))
                        }
                        .onEnded { _ in
                            pinchBaseZoom = nil
                        }
                )
            }

            // Bottom quick split + zoom + refresh bar
            HStack(spacing: 8) {
                Text("TRƯỚC")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                Slider(value: $splitPosition, in: 0.05...0.95)
                    .frame(width: 115)
                Text("SAU")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.green)

                Divider().frame(height: 14)

                Button {
                    let current = fitToViewport ? 1.0 : zoomScale
                    fitToViewport = false
                    zoomScale = max(0.5, current - 0.25)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Thu nhỏ")

                Slider(
                    value: Binding(
                        get: { fitToViewport ? 1.0 : Double(zoomScale) },
                        set: { newVal in
                            fitToViewport = false
                            zoomScale = CGFloat(newVal)
                        }
                    ),
                    in: 0.5...4.0
                )
                .frame(width: 85)

                Button {
                    let current = fitToViewport ? 1.0 : zoomScale
                    fitToViewport = false
                    zoomScale = min(4.0, current + 0.25)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Phóng to")

                Button(fitToViewport ? "Fit" : "\(Int(round(zoomScale * 100)))%") {
                    fitToViewport = true
                    zoomScale = 1.0
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(fitToViewport)
                .help("Đặt lại vừa khung (Fit 100%)")

                Divider().frame(height: 14)

                Button {
                    onRenderPreview()
                } label: {
                    Label("Làm mới", systemImage: "arrow.clockwise")
                        .font(.caption2.weight(.medium))
                }
                .buttonStyle(.borderless)
                .disabled(isBusy || (originalImage == nil && processedImage == nil))
                .help("Chạy lại bộ lọc cho trang đang chọn")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
    }
}

struct ToggleSingleComparisonView: View {
    let originalImage: NSImage?
    let processedImage: NSImage?
    let modeTitle: String
    let isBusy: Bool
    let fitToViewport: Bool
    let zoomScale: CGFloat
    @Binding var showProcessed: Bool
    let onRenderPreview: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            let activeImg = showProcessed ? processedImage : originalImage
            ImageStagePane(
                title: showProcessed ? "SAU SCAN • \(modeTitle)" : "TRƯỚC • Ảnh gốc",
                image: activeImg,
                placeholder: showProcessed
                    ? (isBusy ? "Đang tạo bản xem thử..." : "Chưa có bản xem thử Sau Scan")
                    : "Chọn một trang để xem",
                fitToViewport: fitToViewport,
                zoomScale: zoomScale,
                actionTitle: showProcessed && !isBusy ? "Tạo xem thử ngay" : nil,
                action: onRenderPreview
            )
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Button {
                showProcessed.toggle()
            } label: {
                Label(
                    showProcessed ? "Đang xem: SAU SCAN (Bấm để xem Ảnh gốc)" : "Đang xem: ẢNH GỐC (Bấm để xem Sau Scan)",
                    systemImage: showProcessed ? "sparkles" : "photo"
                )
                .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(showProcessed ? .accentColor : .orange)
            .controlSize(.small)
            .padding(.bottom, 8)
        }
    }
}

struct ImageStagePane: View {
    let title: String
    let image: NSImage?
    let placeholder: String
    let fitToViewport: Bool
    let zoomScale: CGFloat
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let image {
                    Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            GeometryReader { geo in
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )

                    if let image {
                        if fitToViewport {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .padding(8)
                        } else {
                            ScrollView([.horizontal, .vertical]) {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(
                                        width: max(geo.size.width - 20, image.size.width * zoomScale * 0.45),
                                        height: max(geo.size.height - 20, image.size.height * zoomScale * 0.45)
                                    )
                                    .padding(10)
                            }
                        }
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                            Text(placeholder)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let actionTitle, let action {
                                Button(actionTitle, action: action)
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                            }
                        }
                        .padding()
                    }
                }
            }
        }
    }
}

struct PDFKitPreviewView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = NSColor.controlBackgroundColor
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
    }
}

// MARK: - Zone 4: Task-Specific Right Inspector

struct TaskInspectorView: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: vm.activeTask.icon)
                        .foregroundStyle(Color.accentColor)
                    Text(vm.activeTask.fullTitle)
                        .font(.subheadline.weight(.semibold))
                }
                Text(vm.activeTask.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.bar)

            Divider()

            switch vm.activeTask {
            case .scan:
                ScanTaskPanel(vm: vm)
            case .pair:
                PairTaskPanel(vm: vm)
            case .split:
                SplitTaskPanel(vm: vm)
            case .mergeRotate:
                MergeRotateTaskPanel(vm: vm)
            case .compress:
                CompressTaskPanel(vm: vm)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Task 1: Scan & Làm Nét (Progressive Disclosure)

struct ScanTaskPanel: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Step 1: Filter Mode
                    InspectorCard(title: "1. Chọn kiểu làm nét") {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                            ForEach(EnhanceMode.allCases) { mode in
                                let selected = vm.settings.mode == mode
                                Button {
                                    if vm.settings.mode != mode {
                                        vm.settings.mode = mode
                                        vm.invalidatePreviewsAndRefresh()
                                    }
                                } label: {
                                    Text(mode.title)
                                        .font(.caption.weight(selected ? .semibold : .regular))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 7)
                                        .background(selected ? Color.accentColor : Color(nsColor: .windowBackgroundColor))
                                        .foregroundStyle(selected ? .white : .primary)
                                        .cornerRadius(6)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.22), lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Text(vm.settings.mode.descriptionText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    // Step 2: Quality Presets
                    InspectorCard(title: "2. Chất lượng & Dung lượng PDF") {
                        HStack(spacing: 6) {
                            ForEach([
                                (125, "Nhẹ <10MB", "125 DPI"),
                                (200, "HD Chuẩn", "200 DPI"),
                                (300, "In ấn", "300 DPI")
                            ], id: \.0) { dpiVal, title, sub in
                                let active = abs(vm.settings.dpi - dpiVal) <= 15
                                Button {
                                    if vm.settings.dpi != dpiVal {
                                        vm.settings.dpi = dpiVal
                                        vm.invalidatePreviewsAndRefresh()
                                    }
                                } label: {
                                    VStack(spacing: 2) {
                                        Text(title)
                                            .font(.caption.weight(.semibold))
                                        Text(sub)
                                            .font(.system(size: 10))
                                            .opacity(0.85)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                    .background(active ? Color.accentColor : Color(nsColor: .windowBackgroundColor))
                                    .foregroundStyle(active ? .white : .primary)
                                    .cornerRadius(6)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(active ? Color.accentColor : Color.secondary.opacity(0.22), lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        HStack {
                            Text("Tên đề xuất:")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(vm.suggestedScanOutputFilename())
                                .font(.caption2.weight(.medium))
                                .lineLimit(1)
                        }
                        .padding(.top, 2)
                    }

                    // Step 3: Collapsed Advanced Settings
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                vm.showAdvancedSettings.toggle()
                            }
                        } label: {
                            HStack {
                                Label("Tuỳ chỉnh nâng cao", systemImage: "gearshape")
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text(vm.showAdvancedSettings ? "Thu gọn" : "Vision, 128-pt, Khổ...")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Image(systemName: vm.showAdvancedSettings ? "chevron.down" : "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if vm.showAdvancedSettings {
                            InspectorCard(title: "Kỹ thuật & Hình học") {
                                Picker("Engine", selection: $vm.settings.engine) {
                                    ForEach(PipelineEngine.allCases) { eng in
                                        Text(eng.title).tag(eng)
                                    }
                                }
                                .font(.caption)
                                .onChange(of: vm.settings.engine) { _, _ in
                                    vm.invalidatePreviewsAndRefresh()
                                }

                                if vm.settings.engine == .pureSwiftVision &&
                                    (vm.settings.mode == .magicColor || vm.settings.mode == .grayscale) {
                                    Text("Pure Swift Vision sẽ dùng chế độ 'Clean'.")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }

                                Toggle("Tự cắt viền 4 góc (Auto-Crop)", isOn: $vm.settings.autoCrop)
                                    .font(.caption)
                                    .onChange(of: vm.settings.autoCrop) { _, _ in
                                        vm.invalidatePreviewsAndRefresh()
                                    }

                                if vm.settings.autoCrop {
                                    if vm.settings.engine == .hybridOpenCV {
                                        Picker("Crop Engine", selection: $vm.settings.cropEngine) {
                                            ForEach(CropEngine.allCases) { eng in
                                                Text(eng.title).tag(eng)
                                            }
                                        }
                                        .font(.caption)
                                        .onChange(of: vm.settings.cropEngine) { _, _ in
                                            vm.invalidatePreviewsAndRefresh()
                                        }
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text("Độ tin cậy nhận diện")
                                                .font(.caption2)
                                            Spacer()
                                            Text(String(format: "%.2f", vm.settings.minConfidence))
                                                .font(.caption2.monospacedDigit())
                                        }
                                        Slider(value: $vm.settings.minConfidence, in: 0.10...0.95, step: 0.05)
                                    }

                                    if vm.settings.engine == .hybridOpenCV {
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack {
                                                Text("Crop Đa Điểm lọc nền rìa")
                                                    .font(.caption2)
                                                Spacer()
                                                Text(vm.settings.multipointPoints == 0 ? "Tắt" : "\(vm.settings.multipointPoints * 4) đỉnh")
                                                    .font(.caption2.monospacedDigit())
                                            }
                                            Slider(
                                                value: Binding(
                                                    get: { Double(vm.settings.multipointPoints) },
                                                    set: { vm.settings.multipointPoints = Int($0) }
                                                ),
                                                in: 0...64,
                                                step: 4
                                            )
                                        }

                                        Toggle("Nắn phẳng mặt cong 3D (Flatten)", isOn: $vm.settings.flattenSurface)
                                            .font(.caption)
                                            .onChange(of: vm.settings.flattenSurface) { _, _ in
                                                vm.invalidatePreviewsAndRefresh()
                                            }
                                        Toggle("Cân đối lề 4 phía (Symmetry)", isOn: $vm.settings.balanceSymmetry)
                                            .font(.caption)
                                            .onChange(of: vm.settings.balanceSymmetry) { _, _ in
                                                vm.invalidatePreviewsAndRefresh()
                                            }
                                    }
                                }

                                Divider()

                                Picker("Khổ giấy", selection: $vm.settings.pageSize) {
                                    ForEach(PageSizePreset.allCases) { ps in
                                        Text(ps.title).tag(ps)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .onChange(of: vm.settings.pageSize) { _, _ in
                                    vm.invalidatePreviewsAndRefresh()
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text("DPI chi tiết")
                                            .font(.caption2)
                                        Spacer()
                                        Text("\(vm.settings.dpi) DPI")
                                            .font(.caption2.monospacedDigit())
                                    }
                                    Slider(
                                        value: Binding(
                                            get: { Double(vm.settings.dpi) },
                                            set: { vm.settings.dpi = Int($0) }
                                        ),
                                        in: 72...600,
                                        step: 5
                                    )
                                    .onChange(of: vm.settings.dpi) { _, _ in
                                        vm.invalidatePreviewsAndRefresh()
                                    }
                                }

                                if vm.settings.pageSize != .fit {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text("Lề trang (Margin)")
                                                .font(.caption2)
                                            Spacer()
                                            Text("\(Int(vm.settings.margin)) pt")
                                                .font(.caption2.monospacedDigit())
                                        }
                                        Slider(value: $vm.settings.margin, in: 0...60, step: 2)
                                            .onChange(of: vm.settings.margin) { _, _ in
                                                vm.invalidatePreviewsAndRefresh()
                                            }
                                    }
                                }

                                TextField("Đường dẫn PDF đầu ra...", text: $vm.outputPDFPath)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .padding(12)
            }

            Divider()

            // Pinned Bottom Primary CTA
            VStack(spacing: 6) {
                if vm.isBusy {
                    Button(role: .destructive) {
                        vm.cancelRunningTask()
                    } label: {
                        Label("Dừng tiến trình đang chạy", systemImage: "stop.circle.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    if vm.isPreviewing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Đang tự động scan nền...")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Dừng") {
                                vm.stopAutoScanTask()
                            }
                            .buttonStyle(.borderless)
                            .font(.caption2)
                        }
                        .padding(.horizontal, 4)
                    } else if vm.unscannedPageCount > 0 {
                        Button {
                            vm.scanRemainingPages()
                        } label: {
                            Label("Scan tiếp (\(vm.unscannedPageCount) trang)", systemImage: "forward.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }

                    Button {
                        vm.requestBatchScan()
                    } label: {
                        Label(
                            vm.queue.isEmpty ? "Scan & Xuất PDF" : "Scan & Xuất PDF (\(vm.queue.count) trang)",
                            systemImage: "sparkles"
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(vm.queue.isEmpty)
                }
            }
            .padding(12)
            .background(.bar)
        }
    }
}

// MARK: - Task 2: Ghép 2 mặt (Front + Back)

struct PairTaskPanel: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    InspectorCard(title: "Bước 1: Nguồn các trang Mặt Trước") {
                        Toggle("Dùng \(vm.queue.count) trang đang mở bên trái", isOn: $vm.pairUseQueueAsFront)
                            .font(.caption)

                        if !vm.pairUseQueueAsFront {
                            HStack {
                                Text(vm.pairFrontPDFURL?.lastPathComponent ?? "Chưa chọn file PDF...")
                                    .font(.caption2)
                                    .foregroundStyle(vm.pairFrontPDFURL == nil ? .secondary : .primary)
                                    .lineLimit(1)
                                Spacer()
                                Button("Chọn PDF...") {
                                    if let url = PDFDialogHelpers.pickSingleFile(types: [.pdf], title: "Chọn PDF các trang mặt trước", root: vm.workspaceRoot) {
                                        vm.pairFrontPDFURL = url
                                    }
                                }
                                .controlSize(.small)
                            }
                        }
                    }

                    InspectorCard(title: "Bước 2: Chọn trang Mặt Sau chung") {
                        HStack {
                            Text(vm.pairBackSourceURL?.lastPathComponent ?? "Chưa chọn (PDF hoặc Ảnh)...")
                                .font(.caption2)
                                .foregroundStyle(vm.pairBackSourceURL == nil ? .secondary : .primary)
                                .lineLimit(1)
                            Spacer()
                            Button("Chọn...") {
                                if let url = PDFDialogHelpers.pickSingleFile(types: [.pdf, .image], title: "Chọn trang mặt sau (PDF hoặc ảnh)", root: vm.workspaceRoot) {
                                    vm.pairBackSourceURL = url
                                }
                            }
                            .controlSize(.small)
                        }
                    }

                    InspectorCard(title: "Bước 3: Kiểu xuất & Rule tên file") {
                        Picker("Kiểu xuất", selection: $vm.pairOutputMode) {
                            ForEach(PairOutputMode.allCases) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                        .labelsHidden()

                        if vm.pairOutputMode == .separateFiles {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Mẫu tên file (dùng xx cho số tăng dần):")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                TextField("vd: TaiLieu_xx hoặc Ngay_xx.11", text: $vm.pairFilePrefix)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption)

                                HStack(spacing: 6) {
                                    Text("Mốc bắt đầu:")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    TextField("1", value: $vm.pairStartIndex, format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.caption.monospacedDigit())
                                        .frame(width: 60)
                                    Stepper("", value: $vm.pairStartIndex, in: 0...9999)
                                        .labelsHidden()
                                }

                                let p1 = PDFToolsService.formatPairFileName(pattern: vm.pairFilePrefix, startIndex: vm.pairStartIndex, offset: 0)
                                let p2 = PDFToolsService.formatPairFileName(pattern: vm.pairFilePrefix, startIndex: vm.pairStartIndex, offset: 1)
                                Text("Ví dụ: \(p1), \(p2)...")
                                    .font(.caption2)
                                    .foregroundStyle(Color.accentColor)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .padding(12)
            }

            Divider()

            VStack {
                Button {
                    if vm.pairOutputMode == .separateFiles {
                        if let choice = PDFDialogHelpers.pickPairDestinationWithNamingRule(
                            defaultDir: vm.defaultOutputDir,
                            initialPattern: vm.pairFilePrefix,
                            initialStartIndex: vm.pairStartIndex
                        ) {
                            vm.pairFilePrefix = choice.pattern
                            vm.pairStartIndex = choice.startIndex
                            vm.runPairFrontAndBack(destinationURL: choice.directory)
                        }
                    } else {
                        if let file = PDFDialogHelpers.pickSavePDF(defaultName: "Paired_Combined.pdf", title: "Lưu file PDF ghép xen kẽ", defaultDir: vm.defaultOutputDir) {
                            vm.runPairFrontAndBack(destinationURL: file)
                        }
                    }
                } label: {
                    Label("Ghép Cặp & Lưu PDF...", systemImage: "rectangle.on.rectangle.angled")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(vm.isBusy)
            }
            .padding(12)
            .background(.bar)
        }
    }
}

// MARK: - Task 3: Tách PDF

struct SplitTaskPanel: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    InspectorCard(title: "Bước 1: Chọn file PDF nguồn") {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(vm.splitSourceURL?.lastPathComponent ?? "Chưa chọn file PDF...")
                                    .font(.caption2)
                                    .lineLimit(1)
                                if vm.splitSourcePageCount > 0 {
                                    Text("Tổng cộng: \(vm.splitSourcePageCount) trang")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Chọn PDF...") {
                                if let url = PDFDialogHelpers.pickSingleFile(types: [.pdf], title: "Chọn file PDF cần tách", root: vm.workspaceRoot) {
                                    vm.splitSourceURL = url
                                    vm.splitSourcePageCount = PDFDocument(url: url)?.pageCount ?? 0
                                }
                            }
                            .controlSize(.small)
                        }
                    }

                    InspectorCard(title: "Bước 2: Chọn kiểu tách") {
                        Picker("Chế độ tách", selection: $vm.splitMode) {
                            ForEach(SplitMode.allCases) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)

                        if vm.splitMode == .customRange {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Nhập dải trang muốn lấy:")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                TextField("ví dụ: 1-3, 5, 7-9", text: $vm.splitRangeSpec)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption)
                            }
                        } else {
                            Text("Sẽ tách mỗi trang thành 1 file PDF riêng biệt trong thư mục đích.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
            }

            Divider()

            VStack {
                Button {
                    if vm.splitMode == .allPages {
                        if let dir = PDFDialogHelpers.pickDirectory(title: "Chọn thư mục lưu các trang đã tách", defaultDir: vm.defaultOutputDir) {
                            vm.runSplitPDF(destinationURL: dir)
                        }
                    } else {
                        let stem = vm.splitSourceURL?.deletingPathExtension().lastPathComponent ?? "extracted"
                        if let file = PDFDialogHelpers.pickSavePDF(defaultName: "\(stem)_extract.pdf", title: "Lưu PDF đã trích xuất", defaultDir: vm.defaultOutputDir) {
                            vm.runSplitPDF(destinationURL: file)
                        }
                    }
                } label: {
                    Label("Thực Hiện Tách PDF...", systemImage: "scissors")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(vm.isBusy || vm.splitSourceURL == nil)
            }
            .padding(12)
            .background(.bar)
        }
    }
}

// MARK: - Task 4: Gộp & Xoay PDF

struct MergeRotateTaskPanel: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                InspectorCard(title: "1. Gộp nhanh giữ nguyên gốc") {
                    Text("Gộp trực tiếp bằng PDFKit, giữ nguyên độ phân giải và góc xoay đã chỉnh.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Button {
                        if let file = PDFDialogHelpers.pickSavePDF(defaultName: "Merged_Queue.pdf", title: "Lưu file PDF đã gộp", defaultDir: vm.defaultOutputDir) {
                            vm.runMergeQueue(destinationURL: file)
                        }
                    } label: {
                        Label("Gộp \(vm.queue.count) trang đang mở...", systemImage: "square.stack.3d.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(vm.isBusy || vm.queue.isEmpty)

                    Button {
                        let files = PDFDialogHelpers.pickMultiplePDFs(root: vm.workspaceRoot)
                        if !files.isEmpty,
                           let out = PDFDialogHelpers.pickSavePDF(defaultName: "Merged_Files.pdf", title: "Lưu file PDF gộp", defaultDir: vm.defaultOutputDir) {
                            vm.runMergeExternalPDFs(urls: files, destinationURL: out)
                        }
                    } label: {
                        Label("Chọn nhiều file PDF từ Finder...", systemImage: "folder.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(vm.isBusy)
                }

                InspectorCard(title: "2. Xoay chiều file PDF") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(vm.rotateSourceURL?.lastPathComponent ?? "Chưa chọn file PDF...")
                                .font(.caption2)
                                .lineLimit(1)
                            if vm.rotateSourcePageCount > 0 {
                                Text("\(vm.rotateSourcePageCount) trang")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Chọn PDF...") {
                            if let url = PDFDialogHelpers.pickSingleFile(types: [.pdf], title: "Chọn PDF cần xoay", root: vm.workspaceRoot) {
                                vm.rotateSourceURL = url
                                vm.rotateSourcePageCount = PDFDocument(url: url)?.pageCount ?? 0
                            }
                        }
                        .controlSize(.small)
                    }

                    Toggle("Tự động xoay trang ngang thành dọc", isOn: $vm.rotateAutoPortrait)
                        .font(.caption)

                    if !vm.rotateAutoPortrait {
                        Picker("Góc xoay", selection: $vm.rotateDegrees) {
                            Text("90° Phải").tag(90)
                            Text("180°").tag(180)
                            Text("270° Trái").tag(270)
                        }
                        .pickerStyle(.segmented)
                    }

                    TextField("Dải trang (để trống = tất cả)", text: $vm.rotateRangeSpec)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)

                    Button {
                        let stem = vm.rotateSourceURL?.deletingPathExtension().lastPathComponent ?? "rotated"
                        if let file = PDFDialogHelpers.pickSavePDF(defaultName: "\(stem)_rotated.pdf", title: "Lưu PDF đã xoay", defaultDir: vm.defaultOutputDir) {
                            vm.runRotatePDF(destinationURL: file)
                        }
                    } label: {
                        Label("Xoay & Lưu PDF...", systemImage: "rotate.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(vm.isBusy || vm.rotateSourceURL == nil)
                }
            }
            .padding(12)
        }
    }
}

// MARK: - Task 5: Nén nhẹ PDF

struct CompressTaskPanel: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    InspectorCard(title: "Bước 1: Chọn file PDF nặng") {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(vm.compressSourceURL?.lastPathComponent ?? "Chưa chọn file PDF...")
                                    .font(.caption2)
                                    .lineLimit(1)
                                if vm.compressSourceBytes > 0 {
                                    Text("Dung lượng gốc: \(PDFToolsService.formatBytes(vm.compressSourceBytes))")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            Button("Chọn PDF...") {
                                if let url = PDFDialogHelpers.pickSingleFile(types: [.pdf], title: "Chọn PDF cần nén", root: vm.workspaceRoot) {
                                    vm.compressSourceURL = url
                                    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                                    vm.compressSourceBytes = (attrs?[.size] as? Int64) ?? 0
                                    vm.lastCompressionReport = ""
                                }
                            }
                            .controlSize(.small)
                        }
                    }

                    InspectorCard(title: "Bước 2: Chọn mức nén & Bộ lọc") {
                        Picker("DPI nén", selection: $vm.compressDPI) {
                            Text("125 DPI").tag(125)
                            Text("150 DPI").tag(150)
                            Text("175 DPI").tag(175)
                            Text("200 DPI").tag(200)
                        }
                        .pickerStyle(.segmented)

                        Picker("Chế độ lọc", selection: $vm.compressMode) {
                            ForEach(EnhanceMode.allCases) { m in
                                Text(m.title).tag(m)
                            }
                        }
                        .font(.caption)

                        Toggle("Tự động cắt viền khi nén", isOn: $vm.compressAutoCrop)
                            .font(.caption)
                    }

                    if !vm.lastCompressionReport.isEmpty {
                        InspectorCard(title: "Kết quả nén") {
                            Text(vm.lastCompressionReport)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                    }
                }
                .padding(12)
            }

            Divider()

            VStack {
                if vm.isBusy {
                    Button(role: .destructive) {
                        vm.cancelRunningTask()
                    } label: {
                        Label("Dừng nén PDF", systemImage: "stop.circle.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button {
                        let stem = vm.compressSourceURL?.deletingPathExtension().lastPathComponent ?? "compressed"
                        if let file = PDFDialogHelpers.pickSavePDF(defaultName: "\(stem)_\(vm.compressDPI)dpi.pdf", title: "Lưu PDF đã nén", defaultDir: vm.defaultOutputDir) {
                            vm.runCompressPDF(destinationURL: file)
                        }
                    } label: {
                        Label("Nén & Xuất PDF...", systemImage: "arrow.down.right.and.arrow.up.left")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(vm.compressSourceURL == nil)
                }
            }
            .padding(12)
            .background(.bar)
        }
    }
}

// MARK: - Shared Helpers

final class PairNamingRuleModel: ObservableObject {
    @Published var pattern: String
    @Published var startIndex: Int

    init(pattern: String, startIndex: Int) {
        self.pattern = pattern
        self.startIndex = startIndex
    }
}

struct PairNamingAccessoryView: View {
    @ObservedObject var model: PairNamingRuleModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quy tắc đặt tên hàng loạt (dùng xx cho số tăng dần)")
                .font(.caption.weight(.semibold))

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mẫu tên file:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("vd: TaiLieu_xx hoặc Ngay_xx.11", text: $model.pattern)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Mốc bắt đầu:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField("1", value: $model.startIndex, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption.monospacedDigit())
                            .frame(width: 56)
                        Stepper("", value: $model.startIndex, in: 0...9999)
                            .labelsHidden()
                    }
                }
            }

            let sample1 = PDFToolsService.formatPairFileName(pattern: model.pattern, startIndex: model.startIndex, offset: 0)
            let sample2 = PDFToolsService.formatPairFileName(pattern: model.pattern, startIndex: model.startIndex, offset: 1)
            let sample3 = PDFToolsService.formatPairFileName(pattern: model.pattern, startIndex: model.startIndex, offset: 2)
            Text("Xem trước: \(sample1), \(sample2), \(sample3)...")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
        }
        .padding(12)
        .frame(width: 460)
    }
}

enum PDFDialogHelpers {
    @MainActor
    static func pickSingleFile(types: [UTType], title: String, root: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = types
        if let root { panel.directoryURL = root }
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func pickMultiplePDFs(root: URL?) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Chọn các file PDF cần gộp (theo thứ tự)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf]
        if let root { panel.directoryURL = root }
        return panel.runModal() == .OK ? panel.urls : []
    }

    @MainActor
    static func pickDirectory(title: String, defaultDir: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if let defaultDir {
            try? FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
            panel.directoryURL = defaultDir
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func pickPairDestinationWithNamingRule(
        defaultDir: URL?,
        initialPattern: String,
        initialStartIndex: Int
    ) -> (directory: URL, pattern: String, startIndex: Int)? {
        let panel = NSOpenPanel()
        panel.title = "Chọn thư mục lưu & tạo Rule đặt tên PDF"
        panel.prompt = "Lưu vào thư mục này"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if let defaultDir {
            try? FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
            panel.directoryURL = defaultDir
        }

        let ruleModel = PairNamingRuleModel(pattern: initialPattern, startIndex: initialStartIndex)
        let hosting = NSHostingView(rootView: PairNamingAccessoryView(model: ruleModel))
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        panel.accessoryView = hosting
        panel.isAccessoryViewDisclosed = true

        guard panel.runModal() == .OK, let dir = panel.url else {
            return nil
        }
        return (dir, ruleModel.pattern, ruleModel.startIndex)
    }

    @MainActor
    static func pickSavePDF(defaultName: String, title: String, defaultDir: URL?) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = defaultName
        if let defaultDir {
            try? FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
            panel.directoryURL = defaultDir
        }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct InspectorCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }
}
