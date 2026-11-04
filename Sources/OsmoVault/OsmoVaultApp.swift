import SwiftUI
import FCCore
import FCEngine

@main
struct OsmoVaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appModel = AppModel()

    init() {
        // FrameCut 引擎：用户导入的 .cube LUT 库（全局共享，进剪辑台前加载）
        UserLUTLibrary.shared.load()
    }

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environmentObject(appModel)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .commands {
            SidebarCommands()
            // 剪辑台命令：只在工程打开时可用（快速入口，快捷键与编辑器内一致）
            CommandMenu("剪辑") {
                let editor = appModel.videoEditor.editor
                Button("撤销") { editor?.store.undo() }
                    .keyboardShortcut("z").disabled(editor?.store.canUndo != true)
                Button("重做") { editor?.store.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(editor?.store.canRedo != true)
                Divider()
                Button("分割") { editor?.splitAtPlayhead() }
                    .keyboardShortcut("b").disabled(editor == nil)
                Button("删除所选") { editor?.deleteSelection() }
                    .disabled(editor?.selection == nil)
                Divider()
                Button("放大时间线") { editor?.zoom(by: 1.4) }
                    .keyboardShortcut("=").disabled(editor == nil)
                Button("缩小时间线") { editor?.zoom(by: 1 / 1.4) }
                    .keyboardShortcut("-").disabled(editor == nil)
                Button("时间线适应窗口") { editor?.zoomToFit() }
                    .keyboardShortcut("0").disabled(editor == nil)
                Divider()
                Button("导出…") { editor?.showExport = true }
                    .keyboardShortcut("e").disabled(editor == nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 退出前保存剪辑工程（编辑器平时 2 秒防抖自动保存，这里是最后一道兜底）
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            // AppDelegate 拿不到 AppModel（@main Scene 结构限制），通过共享窗口找 RootView 的环境不现实。
            // 改用通知：AppModel 订阅后保存。见 AppModel.applicationWillTerminateFlow
            NotificationCenter.default.post(name: .osmoVaultWillTerminate, object: nil)
        }
    }
}

extension Notification.Name {
    static let osmoVaultWillTerminate = Notification.Name("OsmoVaultWillTerminate")
}
