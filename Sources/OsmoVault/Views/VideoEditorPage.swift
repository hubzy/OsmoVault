import SwiftUI
import FCCore

/// 剪辑台页：OsmoVault 侧边栏的一整页。
///
/// 素材管理是"食材仓"，这页是"灶台"——剪辑能力整体移植自 FrameCut（MIT），
/// 编辑器本体（EditorView：预览 / 时间线 / 检查器）直接复用，
/// 工程生命周期由 VideoEditorSession 管理，素材来源是 OsmoVault 图库。
struct VideoEditorPage: View {
    @EnvironmentObject var appModel: AppModel

    var body: some View {
        let session = appModel.videoEditor
        ZStack {
            Theme.window.ignoresSafeArea()
            if let editor = session.editor {
                EditorView(model: editor)
                    .id(editor.packageURL)
            } else {
                EditorStartScreen(session: session)
            }
        }
        // 主题色跟随系统原生外观（浅色 / 深色自动切换，见 Theme）
        .environment(session)
        .onAppear {
            // 进页即用：没有打开的工程就自动新建一个，素材池就在编辑器左栏
            session.ensureProject()
        }
    }
}

/// 起始屏：只在手动关闭工程后出现（进页默认自动新建工程）。
/// 列出最近工程，也能直接新建。
private struct EditorStartScreen: View {
    let session: VideoEditorSession

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "film.stack")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)
            Text("剪辑台")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("素材池在编辑器左栏：点卡片或双击即可上时间线。\n支持分割、变速、调色、字幕、配乐与人声避让。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
            Button {
                session.newProject()
            } label: {
                Label("新建剪辑工程", systemImage: "plus")
                    .padding(.horizontal, 18).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)

            if !session.recent.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("最近工程")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.tertiary)
                    ForEach(session.recent.prefix(6), id: \.self) { url in
                        Button {
                            session.openRecent(url)
                        } label: {
                            HStack {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(Theme.tertiary)
                                Text(url.deletingPathExtension().lastPathComponent)
                                Spacer()
                                Text(url.lastPathComponent)
                                    .foregroundStyle(Theme.tertiary)
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raised))
                    }
                }
                .frame(maxWidth: 360)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
