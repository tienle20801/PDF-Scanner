import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
        VStack(spacing: 0) {
            if let report = vm.preflightReport, !report.isHealthy, !vm.dismissPreflightBanner {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.summary)
                            .font(.caption.weight(.semibold))
                        if let rem = report.remediation {
                            Text(rem)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if vm.settings.engine != .pureSwiftVision {
                        Button("Dùng Pure Swift Vision") {
                            vm.switchToPureSwiftEngine()
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    }
                    Button("Ẩn") {
                        vm.dismissPreflightBanner = true
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.14))
                Divider()
            }

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
        }
        .frame(minWidth: 1080, minHeight: 680)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            vm.terminateWorkers()
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard !vm.isBusy else { return false }
            return handleDrop(providers: providers)
        }
        .onAppear {
            let pending = ExternalOpenURLRouter.drain()
            if !pending.isEmpty && !vm.isBusy {
                vm.handleDroppedURLs(pending)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pdfScannerOpenURLs)) { _ in
            let incoming = ExternalOpenURLRouter.drain()
            if !incoming.isEmpty && !vm.isBusy {
                vm.handleDroppedURLs(incoming)
            }
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
                let overwrite = pending.onOverwrite
                vm.pendingOverwrite = nil
                overwrite()
            }
            Button("Lưu tên mới (_1, _2...)") {
                let saveUnique = pending.onSaveUnique
                vm.pendingOverwrite = nil
                saveUnique()
            }
            Button("Hủy", role: .cancel) {
                vm.pendingOverwrite = nil
            }
        } message: { pending in
            if pending.existingCount > 1 {
                Text("Thư mục đích đã có \(pending.existingCount) file trùng tên (vd: \"\(pending.targetURL.lastPathComponent)\"). Bạn muốn ghi đè hay tự động lưu bản mới (_1, _2...)?")
            } else {
                Text("\"\(pending.targetURL.lastPathComponent)\" đã có trên đĩa. Bạn muốn ghi đè hay tự động lưu bản mới?")
            }
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

    private final class LockedURLCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []

        func append(_ url: URL) {
            lock.lock()
            urls.append(url)
            lock.unlock()
        }

        func snapshot() -> [URL] {
            lock.lock()
            defer { lock.unlock() }
            return urls
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !vm.isBusy else { return false }
        let validProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !validProviders.isEmpty else { return false }

        let group = DispatchGroup()
        let collector = LockedURLCollector()

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
                    collector.append(url)
                }
            }
        }

        group.notify(queue: .main) {
            let droppedURLs = collector.snapshot()
            if !droppedURLs.isEmpty {
                vm.handleDroppedURLs(droppedURLs)
            }
        }
        return true
    }

    private func pickInputFilesOrFolders() {
        guard !vm.isBusy else { return }
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
