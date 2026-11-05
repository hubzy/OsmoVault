import SwiftUI
import AppKit

enum SidebarItem: Hashable {
    case library
    case map
    case quickCut
    case videoEditor
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
    /// 回收站内的素材数（assets 不含已删除的，由外部统计后传入）
    var trashCount: Int = 0
    /// 智能相册 id → 数量。由外部（AppModel）算好缓存后传进来：
    /// 13 个相册各 filter 一遍 8000 条，放在这里算就是每次 body 13 万次判断
    var albumCounts: [String: Int] = [:]
    /// 拍摄地聚合结果（省组 + 无省平铺项）。由 AppModel 算好缓存后传入
    var placeGroups: [SidebarPlaceGroup] = []
    /// 已展开的省份。默认全收起，侧边栏才不因几十个城市变得冗长
    @State private var expandedProvinces: Set<String> = []

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
                        row(icon: "folder", title: folderName(item.path), count: item.count,
                            empty: item.count == 0)
                            .help(sourceHelp(item))
                            .tag(SidebarItem.source(item.path))
                            .contextMenu {
                                Button {
                                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: item.path)
                                } label: {
                                    Label("在访达中显示", systemImage: "folder")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    onRemoveSource?(item.path)
                                } label: {
                                    Label("从库中移除（不删原文件）", systemImage: "folder.badge.minus")
                                }
                            }
                    }
                }
            }

            Section("智能相册") {
                ForEach(albums, id: \.album.id) { item in
                    row(icon: item.album.systemImage, title: item.album.name, count: item.count,
                        empty: item.count == 0, iconTint: item.album.tint)
                        // 空相册用语义色弱化但仍可点（禁止 .disabled(true)），方便先建规则后拍素材
                        .tag(SidebarItem.smartAlbum(item.album.id))
                }
            }

            if !placeGroups.isEmpty {
                Section("拍摄地") {
                    ForEach(placeGroups) { group in
                        if let province = group.province {
                            // 有省层级的城市：折叠展示，省行只做标题不参与选择
                            DisclosureGroup(isExpanded: expandedBinding(for: province)) {
                                ForEach(group.cities, id: \.city) { city in
                                    row(icon: "mappin.and.ellipse", title: city.city,
                                        count: city.count, empty: city.count == 0)
                                        .tag(SidebarItem.place(city.city))
                                }
                            } label: {
                                // macOS 的 DisclosureGroup 只有箭头可点，加整行点击一起切换展开
                                row(icon: "mappin.and.ellipse", title: province,
                                    count: group.total)
                                    .contentShape(Rectangle())
                                    .onTapGesture { toggleProvince(province) }
                            }
                        } else if let city = group.cities.first {
                            // 直辖市 / 海外：本身没有省份层级，直接平铺
                            row(icon: "mappin.and.ellipse", title: city.city,
                                count: group.total)
                                .tag(SidebarItem.place(city.city))
                        }
                    }
                }
            }

            Section("工具") {
                row(icon: "scissors", title: "一键出片")
                    .tag(SidebarItem.quickCut)
                // 完整剪辑台（移植自 FrameCut）：分割 / 变速 / 调色 / 字幕 / 音乐 / 导出
                row(icon: "film.stack", title: "剪辑台")
                    .tag(SidebarItem.videoEditor)
                // 同一段视频被从两个路径导入后没法区分，这里集中处理
                row(icon: "doc.on.doc", title: "重复素材", count: duplicateCount,
                    empty: duplicateCount == 0)
                    .tag(SidebarItem.duplicates)
                row(icon: "trash", title: "回收站", count: trashCount,
                    empty: trashCount == 0)
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

    /// 省份折叠状态绑定：展开集不存在则收起。视图刷新（换页/数据变）不丢展开状态
    private func expandedBinding(for province: String) -> Binding<Bool> {
        Binding(
            get: { expandedProvinces.contains(province) },
            set: { isOn in
                if isOn {
                    expandedProvinces.insert(province)
                } else {
                    expandedProvinces.remove(province)
                }
            }
        )
    }

    /// 点击省行整行切换折叠
    private func toggleProvince(_ province: String) {
        if expandedProvinces.contains(province) {
            expandedProvinces.remove(province)
        } else {
            expandedProvinces.insert(province)
        }
    }

    private func sourceHelp(_ item: (path: String, count: Int)) -> String {
        var lines = [item.path, "\(item.count) 个素材"]
        if let at = lastImportedAt?(item.path) {
            lines.append("最近导入 \(at.formatted(date: .numeric, time: .shortened))")
        }
        return lines.joined(separator: "\n")
    }

    /// 空集合用语义色（.secondary / .primary）表达，不再用 .opacity 整体压暗：
    /// 整体透明度会连带把「选中行白字」也压成灰白，对比度直接不达标。
    /// 只给图标与计数上色，标题保持动态色（选中时由 List 自动切成白字）。
    /// iconTint 给颜色标签相册上色（macOS 规范：标签圆点带色）；空相册仍回退灰色
    private func row(icon: String, title: String, count: Int? = nil,
                     empty: Bool = false, iconTint: Color? = nil) -> some View {
        HStack(spacing: 6) {
            Label {
                Text(title).lineLimit(1)
            } icon: {
                Image(systemName: icon)
                    .modifier(EmptyEmphasis(empty: empty, tint: iconTint))
            }
            Spacer(minLength: 4)
            if let count {
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .modifier(EmptyEmphasis(empty: empty))
            }
        }
        // 整行可点：不加 contentShape 时只有文字那一小条能响应点击，右侧空白点了没反应
        .contentShape(Rectangle())
    }
}

/// .primary / .secondary 是层级形状样式，会跟随 List 选中行的前景色自适应，
/// 不会像 Color.primary 那样把选中行白字覆盖成深色。
/// 传了 tint（颜色标签相册）时始终显示 tint 色：空相册用半透明弱化但保留色彩（
/// 之前把空相册整个降成灰色，用户以为是"没上色"），选中行也保持彩色=访达一致
private struct EmptyEmphasis: ViewModifier {
    let empty: Bool
    var tint: Color? = nil

    func body(content: Content) -> some View {
        if let tint {
            content.foregroundStyle(empty ? tint.opacity(0.45) : tint)
        } else if empty {
            content.foregroundStyle(.secondary)
        } else {
            content.foregroundStyle(.primary)
        }
    }
}
