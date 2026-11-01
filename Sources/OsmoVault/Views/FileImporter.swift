import SwiftUI
import AppKit

struct FileImporter: NSViewRepresentable {
    @Binding var isPresented: Bool
    @Binding var bgmURL: URL?

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            if isPresented {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowedContentTypes = [.audio]
                panel.begin { resp in
                    if resp == .OK { bgmURL = panel.url }
                    isPresented = false
                }
            }
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

