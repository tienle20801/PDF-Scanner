import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
                        Stepper("", value: $model.startIndex, in: 1...9999)
                            .labelsHidden()
                    }
                }
            }
            .onChange(of: model.startIndex) { _, newValue in
                if newValue < 1 { model.startIndex = 1 }
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

        let ruleModel = PairNamingRuleModel(pattern: initialPattern, startIndex: max(1, initialStartIndex))
        let hosting = NSHostingView(rootView: PairNamingAccessoryView(model: ruleModel))
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        panel.accessoryView = hosting
        panel.isAccessoryViewDisclosed = true

        guard panel.runModal() == .OK, let dir = panel.url else {
            return nil
        }
        return (dir, ruleModel.pattern, max(1, ruleModel.startIndex))
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
