import AppKit
import PDFKit
import SwiftUI

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
                                .disabled(vm.isBusy)
                            Button("Xóa") {
                                vm.resetCurrentTaskToNewBatch()
                            }
                            .controlSize(.small)
                            .disabled(vm.isBusy)
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
                        modeTitle: vm.effectiveModeTitle,
                        errorText: vm.selectedItem?.scanError,
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
                        Text("\(vm.queue.count) trang • \(vm.effectiveModeTitle) • \(vm.settings.dpi) DPI\(vm.settings.enableOCR ? " • OCR" : "")")
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
                        .onChange(of: vm.logs) { _, newLogs in
                            if !newLogs.isEmpty {
                                proxy.scrollTo(newLogs.count - 1, anchor: .bottom)
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

struct InteractiveSplitComparisonView: View {
    let originalImage: NSImage?
    let processedImage: NSImage?
    let modeTitle: String
    let errorText: String?
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
                                } else if let errorText {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.red)
                                    Text("Lỗi xử lý trang này")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.red)
                                    Text(errorText)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                        .frame(maxWidth: 260)
                                    Button("Thử lại", action: onRenderPreview)
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
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
