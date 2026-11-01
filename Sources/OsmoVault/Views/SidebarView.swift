import SwiftUI

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
