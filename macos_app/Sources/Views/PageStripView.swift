import SwiftUI

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
                        } else if let scanError = item.scanError {
                            Label("Lỗi", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.red.opacity(0.14))
                                .cornerRadius(3)
                                .help(scanError)
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
