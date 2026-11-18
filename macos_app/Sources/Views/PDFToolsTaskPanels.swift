import PDFKit
import SwiftUI

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
                                        vm.setPairFrontPDF(url)
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
                                    vm.setPairBackSource(url)
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
                                    Stepper("", value: $vm.pairStartIndex, in: 1...9999)
                                        .labelsHidden()
                                }
                                .onChange(of: vm.pairStartIndex) { _, newValue in
                                    if newValue < 1 { vm.pairStartIndex = 1 }
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
                if vm.isBusy {
                    Button(role: .destructive) {
                        vm.cancelRunningTask()
                    } label: {
                        Label("Dừng ghép cặp", systemImage: "stop.circle.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button {
                        guard vm.validatePairInputs() else { return }
                        if vm.pairOutputMode == .separateFiles {
                            if let choice = PDFDialogHelpers.pickPairDestinationWithNamingRule(
                                defaultDir: vm.defaultOutputDir,
                                initialPattern: vm.pairFilePrefix,
                                initialStartIndex: vm.pairStartIndex
                            ) {
                                vm.pairFilePrefix = choice.pattern
                                vm.pairStartIndex = max(1, choice.startIndex)
                                vm.runPairFrontAndBack(destinationURL: choice.directory)
                            }
                        } else {
                            if let file = PDFDialogHelpers.pickSavePDF(defaultName: "Paired_Combined.pdf", title: "Lưu file PDF ghép xen kẽ", defaultDir: vm.defaultOutputDir) {
                                vm.runPairFrontAndBack(destinationURL: file, confirmOverwrite: false)
                            }
                        }
                    } label: {
                        Label("Ghép Cặp & Lưu PDF...", systemImage: "rectangle.on.rectangle.angled")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(12)
            .background(.bar)
        }
    }
}

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
                                    vm.setSplitSource(url)
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
                if vm.isBusy {
                    Button(role: .destructive) {
                        vm.cancelRunningTask()
                    } label: {
                        Label("Dừng tách PDF", systemImage: "stop.circle.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button {
                        if vm.splitMode == .allPages {
                            if let dir = PDFDialogHelpers.pickDirectory(title: "Chọn thư mục lưu các trang đã tách", defaultDir: vm.defaultOutputDir) {
                                vm.runSplitPDF(destinationURL: dir)
                            }
                        } else {
                            let stem = vm.splitSourceURL?.deletingPathExtension().lastPathComponent ?? "extracted"
                            if let file = PDFDialogHelpers.pickSavePDF(defaultName: "\(stem)_extract.pdf", title: "Lưu PDF đã trích xuất", defaultDir: vm.defaultOutputDir) {
                                vm.runSplitPDF(destinationURL: file, confirmOverwrite: false)
                            }
                        }
                    } label: {
                        Label("Thực Hiện Tách PDF...", systemImage: "scissors")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(vm.splitSourceURL == nil)
                }
            }
            .padding(12)
            .background(.bar)
        }
    }
}

struct MergeRotateTaskPanel: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    InspectorCard(title: "1. Gộp nhanh giữ nguyên gốc") {
                        Text("Gộp trực tiếp bằng PDFKit, giữ nguyên độ phân giải và góc xoay đã chỉnh.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Button {
                            if let file = PDFDialogHelpers.pickSavePDF(defaultName: "Merged_Queue.pdf", title: "Lưu file PDF đã gộp", defaultDir: vm.defaultOutputDir) {
                                vm.runMergeQueue(destinationURL: file, confirmOverwrite: false)
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
                                vm.runMergeExternalPDFs(urls: files, destinationURL: out, confirmOverwrite: false)
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
                                    vm.setRotateSource(url)
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
                                vm.runRotatePDF(destinationURL: file, confirmOverwrite: false)
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

            if vm.isBusy {
                Divider()
                VStack {
                    Button(role: .destructive) {
                        vm.cancelRunningTask()
                    } label: {
                        Label("Dừng tác vụ đang chạy", systemImage: "stop.circle.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(12)
                .background(.bar)
            }
        }
    }
}

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
                                    vm.setCompressSource(url)
                                }
                            }
                            .controlSize(.small)
                        }
                    }

                    InspectorCard(title: "Bước 2: Giữ Vector & Mục tiêu dung lượng") {
                        Text("Giữ nguyên 100% trang chữ/vector và khổ giấy gốc; chỉ nén lại ảnh bitmap nhúng bên trong.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Picker("Mục tiêu", selection: $vm.compressTargetMB) {
                            Text("≤ 10 MB").tag(10.0)
                            Text("≤ 5 MB").tag(5.0)
                            Text("≤ 2 MB").tag(2.0)
                            Text("Không giới hạn").tag(0.0)
                        }
                        .font(.caption)

                        Picker("DPI tối đa cho ảnh nhúng", selection: $vm.compressDPI) {
                            Text("125 DPI").tag(125)
                            Text("150 DPI").tag(150)
                            Text("200 DPI").tag(200)
                            Text("300 DPI").tag(300)
                        }
                        .pickerStyle(.segmented)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Chất lượng JPEG khởi điểm")
                                    .font(.caption2)
                                Spacer()
                                Text("\(vm.compressQuality)%")
                                    .font(.caption2.monospacedDigit())
                            }
                            Slider(
                                value: Binding(
                                    get: { Double(vm.compressQuality) },
                                    set: { vm.compressQuality = Int($0) }
                                ),
                                in: 45...95,
                                step: 5
                            )
                        }
                    }

                    InspectorCard(title: "Tuỳ chọn xử lý ảnh nhúng") {
                        Picker("Bộ lọc", selection: $vm.compressMode) {
                            ForEach(EnhanceMode.allCases) { m in
                                Text(m == .original ? "Original (Giữ màu gốc)" : m.title).tag(m)
                            }
                        }
                        .font(.caption)

                        Toggle("Tự cắt viền khi nén ảnh nhúng", isOn: $vm.compressAutoCrop)
                            .font(.caption)
                    }

                    if !vm.lastCompressionReport.isEmpty {
                        InspectorCard(title: "Kết quả nén") {
                            Text(vm.lastCompressionReport)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                            if !vm.lastCompressionWarning.isEmpty {
                                Text(vm.lastCompressionWarning)
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
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
                            vm.runCompressPDF(destinationURL: file, confirmOverwrite: false)
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
