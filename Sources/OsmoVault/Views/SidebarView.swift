import SwiftUI

struct SidebarView: View {
    enum Section: String, Hashable {
        case library = "资料库", timeline = "时间轴", map = "地图", quickCut = "一键出片", smartAlbums = "智能相册", trash = "回收站"
    }
    @Binding var selection: Section?

    var body: some View {
        List(selection: $selection) {
            Label("资料库", systemImage: "square.grid.2x2").tag(Section.library)
            Label("时间轴", systemImage: "clock").tag(Section.timeline)
            Label("地图", systemImage: "map").tag(Section.map)
            Label("一键出片", systemImage: "scissors").tag(Section.quickCut)
            Label("智能相册", systemImage: "rectangle.stack.badge.plus").tag(Section.smartAlbums)
            Label("回收站", systemImage: "trash").tag(Section.trash)
        }
        .listStyle(.sidebar)
        .navigationTitle("OsmoVault")
    }
}

