import SwiftUI
import AppKit

enum SidebarItem: Hashable {
    case library
    case map
    case quickCut
    case trash
    case duplicates
    case smartAlbum(String)
    case place(String)
    case source(String)   // 某个来源文件夹下的素材
}

struct SidebarView: View {
    @Binding var selection: SidebarItem?
    let assets: [Asset]
    /// 所有导入过的文件夹及其素材数。不传则不显示「导入来源」分组
    var sources: [(path: String, count: Int)] = []
    /// 某个来源最近一次导入的时间，用于提示
    var lastImportedAt: ((String) -> Date?)?
    /// 右键来源 → 从库中移除
    var onRemoveSource: ((String) -> Void)?
    var duplicateCount: Int = 0
    /// 智能相册 id → 数量。由外部（AppModel）算好缓存后传进来：
    /// 13 个相册各 filter 一遍 8000 条，放在这里算就是每次 body 13 万次判断
    var albumCounts: [String: Int] = [:]
    /// 拍摄地 → 数量，同上
    var placeCounts: [(name: String, count: Int)] = []

    private var albums: [(album: SmartAlbum, count: Int)] {
        SmartAlbum.builtin().map { ($0, albumCounts[$0.id] ?? 0) }
    }

    var body: some View {
        List(selection: $selection) {
            Section("图库") {
                // 资料库与时间轴已合并成一页，网格/时间轴切换在页面顶部
                row(icon: "square.grid.2x2", title: "图库", count: assets.count)
                    .tag(SidebarItem.library)
                row(icon: "map", title: "地图")
                    .tag(SidebarItem.map)
            }

            if !sources.isEmpty {
                Section("导入来源") {
                    ForEach(sources, id: \.path) { item in
                        row(icon: "folder", title: folderName(item.path), count: item.count)
                            .opacity(item.count == 0 ? 0.45 : 1)
                            .help(sourceHelp(item))
                            .tag(SidebarItem.source(item.path))
                            .contextMenu {
                                Button("在访达中显示") {
                                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: item.path)
                                }
                                Divider()
                                Button("从库中移除（不删原文件）", role: .destructive) {
                                    onRemoveSource?(item.path)
                                }
                            }
                    }
                }
            }

            Section("智能相册") {
                ForEach(albums, id: \.album.id) { item in
                    row(icon: item.album.systemImage, title: item.album.name, count: item.count)
                        // 空相册淡化但仍可点，方便先建规则后拍素材
                        .opacity(item.count == 0 ? 0.4 : 1)
                        .tag(SidebarItem.smartAlbum(item.album.id))
                }
            }

            if !placeCounts.isEmpty {
                Section("拍摄地") {
                    ForEach(placeCounts, id: \.name) { place in
                        row(icon: "mappin.and.ellipse", title: place.name, count: place.count)
                            .tag(SidebarItem.place(place.name))
                    }
                }
            }

            Section("工具") {
                row(icon: "scissors", title: "一键出片")
                    .tag(SidebarItem.quickCut)
                // 同一段视频被从两个路径导入后没法区分，这里集中处理
                row(icon: "doc.on.doc", title: "重复素材", count: duplicateCount)
                    .opacity(duplicateCount == 0 ? 0.45 : 1)
                    .tag(SidebarItem.duplicates)
                row(icon: "trash", title: "回收站")
                    .tag(SidebarItem.trash)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("OsmoVault")
        .frame(minWidth: 190)
    }

    private func folderName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private func sourceHelp(_ item: (path: String, count: Int)) -> String {
        var lines = [item.path, "\(item.count) 个素材"]
        if let at = lastImportedAt?(item.path) {
            lines.append("最近导入 \(at.formatted(date: .numeric, time: .shortened))")
        }
        return lines.joined(separator: "\n")
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
