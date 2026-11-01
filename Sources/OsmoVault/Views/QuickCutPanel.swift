import SwiftUI
import AppKit

struct QuickCutPanel: View {
    @EnvironmentObject var appModel: AppModel

    /// 素材池里勾选的素材；为空表示"用全部"
    @State private var pickedIDs: Set<Int64> = []
    @State private var segments: [CutSegment] = []
    @State private var isExporting = false
    @State private var status: String?
    @State private var outputURL: URL?
    @State private var bgmURL: URL?
    @State private var showBGMImporter = false
    @State private var showPool = true
    @State private var progressValue: Double = 0
    @State private var transitionSeconds: Double = 0
    @State private var aspect: QuickCutConfig.Aspect = .original
    @State private var clipSeconds: Double = 6
    @State private var onlyHighRated = false

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 108), spacing: 10)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            autoBar
            poolSection
            segmentSection
            optionsRow
            exportBar
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minWidth: 520)
        .background(FileImporter(isPresented: $showBGMImporter, bgmURL: $bgmURL))
    }

    // MARK: - 分区

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("一键出片").font(.title2).bold()
            Text("勾选素材 → 自动出片 → 微调片段 → 导出。默认按拍摄时间排序拼接。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var autoBar: some View {
        HStack(spacing: 12) {
            Button {
                autoBuild()
            } label: {
                Label("自动出片", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .disabled(poolAssets.isEmpty)

            Stepper(value: $clipSeconds, in: 1...60, step: 1) {
                Text("每段 \(Int(clipSeconds))s").font(.caption).monospacedDigit()
            }
            .frame(width: 140)

            Toggle("只用高评分(≥4)", isOn: $onlyHighRated)
                .font(.caption)

            Spacer()
            Button("清空片段") { segments.removeAll() }
                .disabled(segments.isEmpty)
        }
    }

    private var poolSection: some View {
        DisclosureGroup(isExpanded: $showPool) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(videoAssets) { asset in
                        poolCell(asset)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(height: 176)
        } label: {
            HStack(spacing: 6) {
                Text("素材池").font(.headline)
                Text(pickedIDs.isEmpty ? "（未勾选 = 用全部 \(videoAssets.count) 个）" : "（已选 \(pickedIDs.count) 个）")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !pickedIDs.isEmpty {
                    Button("取消勾选") { pickedIDs.removeAll() }.font(.caption)
                }
            }
        }
    }

    private func poolCell(_ asset: Asset) -> some View {
        let id = asset.id ?? 0
        let picked = pickedIDs.contains(id)
        return Button {
            if picked { pickedIDs.remove(id) } else { pickedIDs.insert(id) }
        } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    AsyncThumbView(asset: asset)
                        .frame(height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    if asset.rating >= 4 {
                        Image(systemName: "star.fill")
                            .font(.caption2).foregroundStyle(.yellow)
                            .padding(3)
                    }
                }
                Text(asset.fileName)
                    .font(.caption2).lineLimit(1)
                Text(String(format: "%.0fs", asset.durationSeconds))
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(picked ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    private var segmentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("片段顺序").font(.headline)
                Text("\(segments.count) 段 · 总长 \(Self.timeText(totalSeconds))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
            }
            if segments.isEmpty {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.08))
                    .frame(height: 90)
                    .overlay {
                        Text("点「自动出片」一键生成，或在素材池里勾选后重新生成")
                            .font(.caption).foregroundStyle(.secondary)
                    }
            } else {
                List {
                    ForEach($segments) { $seg in
                        segmentRow($seg)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 120, maxHeight: 260)
            }
        }
    }

    private func segmentRow(_ seg: Binding<CutSegment>) -> some View {
        let index = segments.firstIndex { $0.id == seg.wrappedValue.id } ?? 0
        return HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(seg.wrappedValue.fileName).font(.caption).lineLimit(1)
                HStack(spacing: 6) {
                    Text("起").font(.caption2).foregroundStyle(.secondary)
                    TextField("", value: seg.start, format: .number)
                        .frame(width: 54).controlSize(.small)
                    Text("止").font(.caption2).foregroundStyle(.secondary)
                    TextField("", value: seg.end, format: .number)
                        .frame(width: 54).controlSize(.small)
                    Text(String(format: "%.1fs", seg.wrappedValue.duration))
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }
                .buttonStyle(.borderless).disabled(index == 0)
            Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }
                .buttonStyle(.borderless).disabled(index == segments.count - 1)
            Button { segments.remove(at: index) } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless)
        }
    }

    private var optionsRow: some View {
        HStack(spacing: 16) {
            Picker("画幅", selection: $aspect) {
                ForEach(QuickCutConfig.Aspect.allCases) { a in
                    Text(a.rawValue).tag(a)
                }
            }
            .frame(width: 160)
            HStack(spacing: 6) {
                Text("转场").font(.caption)
                Slider(value: $transitionSeconds, in: 0...2, step: 0.1).frame(width: 120)
                Text(transitionSeconds == 0 ? "硬切" : String(format: "%.1fs 溶解", transitionSeconds))
                    .font(.caption).monospacedDigit().frame(width: 70, alignment: .leading)
            }
            Toggle("背景音乐", isOn: Binding(
                get: { bgmURL != nil },
                set: { on in if !on { bgmURL = nil } }
            ))
            .font(.caption)
            Button(bgmURL == nil ? "选择音乐" : (bgmURL?.lastPathComponent ?? "")) {
                showBGMImporter = true
            }
            .controlSize(.small)
            .disabled(bgmURL != nil)
            Spacer()
        }
    }

    private var exportBar: some View {
        HStack(spacing: 10) {
            Button {
                exportAll()
            } label: {
                if isExporting { ProgressView().controlSize(.small) }
                Text(isExporting ? "导出中…" : "导出 mp4")
            }
            .buttonStyle(.borderedProminent)
            .disabled(segments.isEmpty || isExporting)

            if isExporting {
                ProgressView(value: progressValue).frame(width: 140)
                Text(String(format: "%.0f%%", progressValue * 100))
                    .font(.caption).monospacedDigit()
            }
            if let s = status {
                Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let out = outputURL, !isExporting {
                Button("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                }
                .controlSize(.small)
            }
            Spacer()
        }
    }

    // MARK: - 逻辑

    /// 出片只接视频；照片/实况进不了时间线（要做成片段得先转码，暂不支持）
    private var videoAssets: [Asset] {
        appModel.assets.filter { $0.kind == .video }
    }

    private var poolAssets: [Asset] {
        let base = pickedIDs.isEmpty
            ? videoAssets
            : videoAssets.filter { pickedIDs.contains($0.id ?? 0) }
        let filtered = onlyHighRated ? base.filter { $0.rating >= 4 } : base
        return filtered.sorted { ($0.recordedAt ?? .distantPast) < ($1.recordedAt ?? .distantPast) }
    }

    private var totalSeconds: Double {
        guard !segments.isEmpty else { return 0 }
        let raw = segments.reduce(0) { $0 + $1.duration }
        let overlap = segments.count > 1 ? transitionSeconds * Double(segments.count - 1) : 0
        return max(raw - overlap, 0)
    }

    private func autoBuild() {
        let pool = poolAssets
        guard !pool.isEmpty else { status = "没有可用素材"; return }
        segments = pool.prefix(40).map { a in
            let dur = min(clipSeconds, max(a.durationSeconds, 0.5))
            // 从 20% 处开始取，跳过无人机起飞/开机的废镜头
            let start = min(a.durationSeconds * 0.2, max(a.durationSeconds - dur, 0))
            return CutSegment(assetID: a.id ?? 0, sourcePath: a.filePath, fileName: a.fileName,
                              start: start, end: start + dur)
        }
        status = "已生成 \(segments.count) 段"
    }

    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard segments.indices.contains(target) else { return }
        segments.swapAt(index, target)
    }

    private func exportAll() {
        isExporting = true
        status = nil
        outputURL = nil
        progressValue = 0
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
                outputURL = out
                status = "已导出：\(out.lastPathComponent)"
            } catch {
                status = "失败：\(error.localizedDescription)"
            }
            isExporting = false
        }
    }

    static func timeText(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}
