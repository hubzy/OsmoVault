import SwiftUI
import AppKit

enum SidebarItem: Hashable {
    case library
    case timeline
    case map
    case quickCut
    case trash
    case smartAlbum(String)
    case place(String)
}

struct SidebarView: View {
    @Binding var selection: SidebarItem?
    let assets: [Asset]

    /// 只在素材或选中变化时才重算，避免 hover 之类的操作触发整条侧边栏重排
    private var albums: [(album: SmartAlbum, count: Int)] {
        SmartAlbum.builtin().map { ($0, $0.filter(assets).count) }
    }

    private var places: [(name: String, count: Int)] {
        let grouped = Dictionary(grouping: assets.compactMap(\.placeName), by: { $0 })
        return grouped.map { ($0.key, $0.value.count) }.sorted { $0.count > $1.count }
    }

    var body: some View {
        List(selection: $selection) {
            Section("图库") {
                row(icon: "square.grid.2x2", title: "资料库", count: assets.count)
                    .tag(SidebarItem.library)
                row(icon: "clock", title: "时间轴")
                    .tag(SidebarItem.timeline)
                row(icon: "map", title: "地图")
                    .tag(SidebarItem.map)
            }

            Section("智能相册") {
                ForEach(albums, id: \.album.id) { item in
                    row(icon: item.album.systemImage, title: item.album.name, count: item.count)
                        // 空相册淡化但仍可点，方便先建规则后拍素材
                        .opacity(item.count == 0 ? 0.4 : 1)
                        .tag(SidebarItem.smartAlbum(item.album.id))
                }
            }

            if !places.isEmpty {
                Section("拍摄地") {
                    ForEach(places, id: \.name) { place in
                        row(icon: "mappin.and.ellipse", title: place.name, count: place.count)
                            .tag(SidebarItem.place(place.name))
                    }
                }
            }

            Section("工具") {
                row(icon: "scissors", title: "一键出片")
                    .tag(SidebarItem.quickCut)
                row(icon: "trash", title: "回收站")
                    .tag(SidebarItem.trash)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("OsmoVault")
        .frame(minWidth: 190)
    }

    private func row(icon: String, title: String, count: Int? = nil) -> some View {
        HStack(spacing: 6) {
            Label(title, systemImage: icon)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let count {
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        // 整行可点：不加 contentShape 时只有文字那一小条能响应点击，右侧空白点了没反应
        .contentShape(Rectangle())
    }
}

/// 侧边栏顶部：显示当前库的来源文件夹，点击可在访达中打开
struct SidebarHeaderView: View {
    /// 最近导入的在前；为空表示还没导入过
    let roots: [String]
    let assetCount: Int

    @State private var rootIndex = 0

    private var currentPath: String? {
        guard !roots.isEmpty else { return nil }
        return roots[min(rootIndex, roots.count - 1)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let path = currentPath {
                HStack(spacing: 4) {
                    Button {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "folder.fill").foregroundStyle(.secondary)
                            Text(abbreviate(path))
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)   // 路径中段省略，保留头尾更有信息量
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(path)\n点击在访达中打开")

                    // 导入过多个文件夹时给个菜单切换显示哪一个
                    if roots.count > 1 {
                        Menu {
                            ForEach(Array(roots.enumerated()), id: \.offset) { index, root in
                                Button {
                                    rootIndex = index
                                } label: {
                                    if index == min(rootIndex, roots.count - 1) {
                                        Image(systemName: "checkmark")
                                    }
                                    Text(abbreviate(root))
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 16)
                        .help("共 \(roots.count) 个来源文件夹")
                    }
                }

                Text("\(assetCount) 个素材")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text("尚未导入文件夹").font(.caption).foregroundStyle(.secondary)
                }
                Text("点击工具栏 + 导入").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // 来源数量变化后索引可能越界，自动归位
        .onChange(of: roots.count) { _, count in
            if rootIndex > count - 1 { rootIndex = 0 }
        }
    }

    /// 家目录缩写为 ~，长路径靠 truncationMode(.middle) 省略
    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
