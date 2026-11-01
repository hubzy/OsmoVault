import SwiftUI
import UniformTypeIdentifiers

struct QuickCutPanel: View {
    @EnvironmentObject var appModel: AppModel
    /// 选中的素材（作为初始片段池）
    let seedAssets: [Asset]
    @State private var segments: [CutSegment] = []
    @State private var isExporting = false
    @State private var status: String?
    @State private var useClipRange = false
    @State private var clipStart: Double = 0
    @State private var clipEnd: Double = 5
    @State private var bgmURL: URL?
    @State private var showBGMImporter = false
    @State private var progressValue: Double = 0
    @State private var transitionSeconds: Double = 0
    @State private var aspect: QuickCutConfig.Aspect = .original

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            assetList

            clipRangeRow

            bgmRow
            optionsRow

            if !segments.isEmpty {
                segmentList
            }

            exportBar
            Spacer()
        }
        .padding(16)
        .frame(minWidth: 480)
        .background(
            FileImporter(isPresented: $showBGMImporter, bgmURL: $bgmURL)
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("一键出片").font(.title2).bold()
            Text("从下方素材列表勾选片段，按顺序硬切拼接导出 mp4。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var assetList: some View {
        List {
            ForEach(seedAssets) { asset in
                assetRow(asset)
            }
        }
        .frame(minHeight: 160)
    }

    private func assetRow(_ asset: Asset) -> some View {
        HStack {
            Image(systemName: "film")
            VStack(alignment: .leading) {
                Text(asset.fileName).font(.footnote)
                Text(String(format: "%.1fs", asset.durationSeconds)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("加入") {
                let end = useClipRange ? min(clipEnd, asset.durationSeconds) : asset.durationSeconds
                segments.append(CutSegment(assetID: asset.id ?? 0, sourcePath: asset.filePath,
                                           fileName: asset.fileName,
                                           start: useClipRange ? clipStart : 0,
                                           end: end))
            }
            .buttonStyle(.bordered)
        }
    }

    private var clipRangeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("使用指定时间区间（秒）", isOn: $useClipRange)
            if useClipRange {
                HStack {
                    Text("起点")
                    TextField("0", value: $clipStart, format: .number).frame(width: 70)
                    Text("终点")
                    TextField("5", value: $clipEnd, format: .number).frame(width: 70)
                }
            }
        }
    }

    private var bgmRow: some View {
        HStack {
            Toggle("背景音乐（自动循环，音量 30%）", isOn: Binding(
                get: { bgmURL != nil },
                set: { on in if !on { bgmURL = nil } }
            ))
            Button(bgmURL == nil ? "选择音乐文件" : (bgmURL?.lastPathComponent ?? "")) {
                showBGMImporter = true
            }
            .disabled(bgmURL == nil)
        }
    }

    private var optionsRow: some View {
        HStack(spacing: 16) {
            Picker("画幅", selection: $aspect) {
                ForEach(QuickCutConfig.Aspect.allCases) { a in
                    Text(a.rawValue).tag(a)
                }
            }
            .frame(width: 180)
            HStack {
                Text("转场")
                Slider(value: $transitionSeconds, in: 0...2, step: 0.1).frame(width: 140)
                Text(transitionSeconds == 0 ? "硬切" : String(format: "%.1fs 溶解", transitionSeconds))
                    .font(.caption).monospacedDigit().frame(width: 80, alignment: .leading)
            }
        }
    }

    private var segmentList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("已选片段（按此顺序拼接）:").font(.headline)
            ForEach(Array(segments.enumerated()), id: \.element.id) { pair in
                let idx = pair.offset
                let seg = pair.element
                HStack {
                    Text("\(idx+1). \(seg.fileName) [\(seg.start, specifier: "%.1f")s - \(seg.end, specifier: "%.1f")s]")
                        .font(.caption)
                    Spacer()
                    Button {
                        if idx > 0 { segments.swapAt(idx, idx-1) }
                    } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderless)
                    Button {
                        _ = segments.remove(at: idx)
                    } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var exportBar: some View {
            HStack {
                Button {
                    exportAll()
                } label: {
                    if isExporting { ProgressView().controlSize(.small) }
                    Text(isExporting ? "导出中…" : "导出 mp4")
                }
                .disabled(segments.isEmpty || isExporting)
                if isExporting {
                    ProgressView(value: progressValue)
                        .frame(width: 160)
                    Text(String(format: "%.0f%%", progressValue * 100))
                        .font(.caption).monospacedDigit()
                }
                if let s = status { Text(s).font(.caption).foregroundStyle(.secondary) }
            }
    }

    private func exportAll() {
        isExporting = true
        status = nil
        Task {
            do {
                let out = QuickCutService.defaultOutputURL()
                var cfg = QuickCutConfig()
                cfg.transitionDuration = transitionSeconds
                cfg.aspect = aspect
                if let bgm = bgmURL { cfg.includeBGM = true; cfg.bgmPath = bgm.path }
                try await QuickCutService.export(segments: segments, config: cfg, to: out) { p in
                    Task { @MainActor in progressValue = p }
                }
                status = "已导出：\(out.path)"
            } catch {
                status = "失败：\(error.localizedDescription)"
            }
            isExporting = false
        }
    }
}

