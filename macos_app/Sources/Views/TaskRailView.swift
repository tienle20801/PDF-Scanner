import SwiftUI

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
