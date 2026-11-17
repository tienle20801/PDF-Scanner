import SwiftUI

struct ScanTaskPanel: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
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

                        if vm.settings.engine == .pureSwiftVision && vm.settings.mode == .autoColor {
                            Text("Đang chạy chế độ thực tế: \(vm.settings.mode.pureSwiftEffectiveTitle) — Pure Swift không có bù nét/cân bằng trắng Auto Color của Hybrid.")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        } else {
                            Text(vm.settings.mode.descriptionText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

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

                        Toggle("Tạo lớp chữ tìm kiếm PDF (OCR ẩn vi/en)", isOn: $vm.settings.enableOCR)
                            .font(.caption)
                            .help("Tắt mặc định để ưu tiên tốc độ; bật sẽ nhận dạng text Tiếng Việt + Anh bằng Apple Vision và nhúng lớp text copy/Ctrl+F vào PDF xuất.")

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
                                .onChange(of: vm.settings.engine) { _, newEng in
                                    if newEng == .pureSwiftVision && vm.settings.jpegQuality == AppConstants.defaultJPEGQuality {
                                        vm.settings.jpegQuality = AppConstants.pureSwiftJPEGQuality
                                    } else if newEng == .hybridOpenCV && vm.settings.jpegQuality == AppConstants.pureSwiftJPEGQuality {
                                        vm.settings.jpegQuality = AppConstants.defaultJPEGQuality
                                    }
                                    vm.invalidatePreviewsAndRefresh()
                                }

                                if vm.settings.engine == .pureSwiftVision {
                                    Text("Pure Swift Vision hỗ trợ trực tiếp: \(vm.settings.mode.pureSwiftEffectiveTitle) (bỏ qua 128-pt, Flatten 3D và Symmetry).")
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
                                        Slider(
                                            value: $vm.settings.minConfidence,
                                            in: 0.10...0.95,
                                            step: 0.05,
                                            onEditingChanged: { editing in
                                                if !editing {
                                                    vm.syncPreviewsToCurrentSettings()
                                                }
                                            }
                                        )
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
                                                step: 4,
                                                onEditingChanged: { editing in
                                                    if !editing {
                                                        vm.syncPreviewsToCurrentSettings()
                                                    }
                                                }
                                            )
                                        }

                                        Toggle("Nắn phẳng mặt cong 3D (Flatten)", isOn: $vm.settings.flattenSurface)
                                            .font(.caption)
                                            .onChange(of: vm.settings.flattenSurface) { _, _ in
                                                vm.invalidatePreviewsAndRefresh()
                                            }
                                        Toggle("Căn giữa & cân lề 4 phía (Symmetry)", isOn: $vm.settings.balanceSymmetry)
                                            .font(.caption)
                                            .help("Mặc định tắt để giữ nguyên bố cục trang gốc. Bật sẽ căn giữa khối nội dung 4 phía.")
                                            .onChange(of: vm.settings.balanceSymmetry) { _, _ in
                                                vm.invalidatePreviewsAndRefresh()
                                            }
                                        if vm.settings.balanceSymmetry {
                                            Text("Đang bật Symmetry: nội dung sẽ được dời vào giữa lề.")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
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
                                    vm.syncPreviewsToCurrentSettings()
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
                                        step: 5,
                                        onEditingChanged: { editing in
                                            if !editing {
                                                vm.syncPreviewsToCurrentSettings()
                                            }
                                        }
                                    )
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text("Chất lượng JPEG")
                                            .font(.caption2)
                                        Spacer()
                                        Text("\(vm.settings.jpegQuality)%")
                                            .font(.caption2.monospacedDigit())
                                    }
                                    Slider(
                                        value: Binding(
                                            get: { Double(vm.settings.jpegQuality) },
                                            set: { vm.settings.jpegQuality = Int($0) }
                                        ),
                                        in: 50...100,
                                        step: 2,
                                        onEditingChanged: { editing in
                                            if !editing {
                                                vm.syncPreviewsToCurrentSettings()
                                            }
                                        }
                                    )
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
