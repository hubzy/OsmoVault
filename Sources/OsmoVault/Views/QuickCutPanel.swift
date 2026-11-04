import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - 拖放载荷

extension UTType {
    /// App 内素材拖放专用类型：避免和系统文本/文件的拖放混在一起
    static let osmoVaultAsset = UTType(exportedAs: "com.osmovault.asset")
    /// 时间轴片段（换序用）拖放类型
    static let osmoVaultClip = UTType(exportedAs: "com.osmovault.clip")
}

/// 素材池 → 时间轴的拖放载荷：带多个素材 id（支持多选拖拽），
/// 只带 id、落地时再查素材，即使拖拽过程中库刷新过 id 也仍然有效
struct DraggedAssets: Codable, Transferable {
    let ids: [Int64]
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .osmoVaultAsset)
    }
}

/// 时间轴内拖动片段换序的载荷：只带片段自身的 UUID
struct DraggedSegment: Codable, Transferable {
    let id: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .osmoVaultClip)
    }
}

// MARK: - 字号 / 尺寸规范
//
// 布局与字号沿剪映 / FrameCut（github.com/lidedongsn/frame-cut，MIT）的编辑器规范：
//   顶栏 44pt · 工具条 36pt · 检查条 40pt
//   区域间以 1px 分隔线分区，区内水平边距 12；工具条按钮 28×26
//   字号五档：13 标题 / 12 正文按钮 / 11 说明·时间 / 10 微标签 / 9 徽章（等宽数字一律 monospacedDigit）
//   提示用顶部胶囊 toast（6s 自动消失），不再常驻状态行

private extension Font {
    /// 顶栏标题
    static var qcTitle: Font { .system(size: 13, weight: .semibold) }
    /// 正文 / 按钮文字
    static var qcBody: Font { .system(size: 12) }
    /// 说明文字 / 时间码
    static var qcCaption: Font { .system(size: 11) }
    static var qcCaptionMono: Font { .system(size: 11).monospacedDigit() }
    /// 面板小标题
    static var qcSection: Font { .system(size: 11, weight: .semibold) }
    /// 微标签 / 路径
    static var qcMicro: Font { .system(size: 10) }
}

/// 一键出片页（剪映式布局，规格参照 FrameCut）：
///   顶栏 44：标题 · 提示 · 导出（主操作，⌘↩）
///   主区：素材池（可拖宽，搜索 / 收藏 / 高评分筛选，与图库数据库打通）｜预览 + 播放条 + 设置行
///   时间线工具条 36：撤销 · 分割 ⌘B · 删除 ⌘⌫ · 清空 · 时间码 · 缩放 · 适应 ⌘0
///   时间轴 70：剪映式纯缩略图片段卡（拖入插入 / 拖动换序 / 边缘拖拽修剪 / 变速徽章 / 转场标记 / 播放头）
///   检查条 40：选中片段微调起止、变速、换序、移除
///
/// 「预览即所得」：预览画面来自 `QuickCutService.prepare` 的 composition，
/// 导出走同一条 prepare + 导出会话，转场 / 画幅 / BGM / 变速效果所见即所得。
///
/// 拖放实现要点（曾表现为「拖得进去但时间轴不显示」的修复）：
/// onDrag 时把内容**同步**记进 `liveDrag`，onDrop 直接同步消费；
/// NSItemProvider 的异步 `loadDataRepresentation` 只留作跨窗口 / 兜底路径。
struct QuickCutPanel: View {
    @EnvironmentObject var appModel: AppModel

    @StateObject private var preview = QuickCutPreviewController()

    /// 素材池勾选（剪映式：点击即勾选/取消，拖已勾选卡片会带走全部已勾选素材）
    @State private var pickedIDs: Set<Int64> = []
    @State private var segments: [CutSegment] = []
    /// 时间轴上选中的片段（点选后在检查条里微调；选中态也用于显示修剪把手）
    @State private var selectedSegmentID: UUID?
    /// 程序性滚动定位：拖入落地 / 跳段后让时间轴滚到该片段（点击选中不触发）
    @State private var pendingScrollID: UUID?

    // MARK: 拖拽状态（同步消费，见顶部注释）

    enum LiveDrag {
        case assets([Int64])
        case segment(UUID)
    }

    @State private var liveDrag: LiveDrag?
    /// 拖拽悬停在时间轴上时的插入位置（nil = 未悬停）；== segments.count 表示追加到末尾
    @State private var dropTargetIndex: Int?

    /// 修剪（拖拽片段边缘）中：手势开始时的起止快照
    @State private var trimBase: (index: Int, start: Double, end: Double)?

    // MARK: 撤销 / 重做 / 自动刷新

    @State private var undoStack: [[CutSegment]] = []
    @State private var redoStack: [[CutSegment]] = []
    @State private var autoRefreshTask: Task<Void, Never>?

    // MARK: 素材池（与图库打通）

    enum PoolFilter: Hashable, CaseIterable {
        case all, favorites, highRated
        var label: String {
            switch self {
            case .all: return "全部"
            case .favorites: return "收藏"
            case .highRated: return "高评分"
            }
        }
    }

    @State private var poolFilter: PoolFilter = .all
    @State private var searchText = ""

    // MARK: 出片 / 导出状态

    @State private var isExporting = false
    @State private var status: String?
    @State private var outputURL: URL?
    @State private var bgmURL: URL?
    @State private var showBGMImporter = false
    @State private var progressValue: Double = 0
    @State private var transitionSeconds: Double = 0
    @State private var confirmClearSegments = false
    @State private var aspect: QuickCutConfig.Aspect = .original
    @State private var clipSeconds: Double = 6

    /// 上一次构建成功的预览时间线；配置变化后 computed 的 `previewDirty` 变 true，自动刷新接管
    @State private var prepared: PreparedTimeline?
    @State private var builtSignature: Signature?
    @State private var isPreparingPreview = false
    @State private var previewError: String?

    /// 时间线缩放（每秒像素数）。记在 UserDefaults，下次进页面保持
    @AppStorage("quickCut.pointsPerSecond") private var pointsPerSecond: Double = 30
    /// 时间轴可视宽度（zoomToFit 用），由时间轴区的 GeometryReader 回写
    @State private var timelineViewport: CGFloat = 0

    private var poolColumns: [GridItem] { [GridItem(.adaptive(minimum: 88), spacing: 8)] }

    // MARK: 时间轴几何参数

    private let timelineLeadingPad: CGFloat = 12
    private let clipSpacing: CGFloat = 6
    /// 剪映式片段卡：纯缩略图 + 浮层徽章（序号 / 时长 / 变速）
    private let clipHeight: CGFloat = 58
    private let timelineRowHeight: CGFloat = 70
    private var clipVPad: CGFloat { (timelineRowHeight - clipHeight) / 2 }

    // MARK: - 主体

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ResizableSplit(key: "quickCut.poolWidth", defaultValue: 320,
                           range: 240...520, side: .leading, minOther: 460,
                           leading: { poolColumn },
                           trailing: { centerColumn })
                .frame(maxHeight: .infinity)
            timelineToolbar
            if segments.isEmpty {
                emptyTimeline
                    .onDrop(of: Self.dropTypes, isTargeted: Binding(
                        get: { dropTargetIndex != nil },
                        set: { on in
                            if on { dropTargetIndex = 0 }
                            else if dropTargetIndex == 0 { dropTargetIndex = nil }
                        }
                    )) { providers in
                        dropFromProviders(providers, insertAt: 0)
                    }
                    .padding(.horizontal, 12)
            } else {
                timelineStrip
            }
            clipInspector
        }
        .frame(minWidth: 940)
        .background(FileImporter(isPresented: $showBGMImporter, bgmURL: $bgmURL))
        // 顶部胶囊 toast：6 秒自动消失，可手动关
        .overlay(alignment: .top) {
            if let msg = status {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(msg).font(.qcBody).lineLimit(2)
                    Button {
                        status = nil
                    } label: {
                        Image(systemName: "xmark").font(.qcMicro).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                .padding(.top, 50)
                .task(id: msg) {
                    try? await Task.sleep(for: .seconds(6))
                    if !Task.isCancelled, status == msg { withAnimation { status = nil } }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: status)
        .onDisappear {
            preview.unload()
            autoRefreshTask?.cancel()
        }
        // 设置 / 片段变化 → 防抖后自动重建预览（0.9s 内连续调整只触发一次）
        .onChange(of: configSignature) { _, _ in
            scheduleAutoRefresh()
        }
        // 手调过的起止时间不可一键重建，清空前必须确认
        .confirmationDialog("清空时间轴？", isPresented: $confirmClearSegments) {
            Button("清空 \(segments.count) 段", role: .destructive) {
                pushUndo()
                withAnimation(.easeInOut(duration: 0.22)) {
                    segments.removeAll()
                }
                selectedSegmentID = nil
                clearPreview()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("可用 ⌘Z 撤销这次清空。清空后需要重新拖入素材或「自动出片」")
        }
    }

    // MARK: - 顶栏（44）

    private var topBar: some View {
        HStack(spacing: 12) {
            Text("一键出片").font(.qcTitle)
            Text("拖素材到时间轴 · 空格播放 · ⌘B 分割 · ⌘Z 撤销")
                .font(.qcCaption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer()
            if isExporting {
                ProgressView().controlSize(.small)
                Text(String(format: "%.0f%%", progressValue * 100))
                    .font(.qcCaptionMono).foregroundStyle(.secondary)
            }
            Button {
                exportAll()
            } label: {
                Label(isExporting ? "导出中…" : "导出", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(segments.isEmpty || isExporting)
            .keyboardShortcut(.return, modifiers: .command)
            .help(previewDirty ? "⌘↩ 按当前最新设置导出（预览还在等待自动刷新）" : "⌘↩ 按当前预览效果导出到「影片」目录")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color.primary.opacity(0.03))
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - 素材池（左列，与图库数据库打通）

    private var poolColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 自动出片 + 每段秒数
            HStack(spacing: 8) {
                Button {
                    autoBuild()
                } label: {
                    Label("自动出片", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(poolAssets.isEmpty)
                .help("按已勾选素材（未勾选则当前筛选结果）自动生成时间轴")

                Stepper(value: $clipSeconds, in: 1...60, step: 1) {
                    Text("每段 \(Int(clipSeconds))s").font(.qcCaptionMono)
                }
                .frame(width: 104)
                .help("自动出片时每个素材取的长度（从素材 20% 处开始取，跳过开头废镜头）")
                Spacer(minLength: 0)
            }

            // 搜索 + 筛选（连的是图库的评分 / 收藏数据）
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.qcMicro).foregroundStyle(.secondary)
                    TextField("搜索文件名 / 地点", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.qcCaption)
                }
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.1)))

                Picker("筛选", selection: $poolFilter) {
                    ForEach(PoolFilter.allCases, id: \.self) { f in
                        Text(f.label).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 168)
                .help("全部视频 / 图库里收藏的 / 图库里评分 ≥ 4 的")
            }

            // 标题行 + 勾选状态
            HStack(spacing: 6) {
                Text(pickedIDs.isEmpty
                     ? "素材池 · \(poolAssets.count) 个视频"
                     : "素材池 · 已选 \(pickedIDs.count)/\(poolAssets.count)")
                    .font(.qcSection).foregroundStyle(.secondary)
                Spacer()
                if !pickedIDs.isEmpty {
                    Button("全不选") { pickedIDs.removeAll() }
                        .font(.qcCaption).buttonStyle(.plain)
                        .help("清除素材池里的全部勾选")
                }
            }

            if poolAssets.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: videoAssets.isEmpty ? "video.slash" : "magnifyingglass")
                        .font(.system(size: 24)).foregroundStyle(.tertiary)
                    Text(videoAssets.isEmpty ? "库里还没有视频素材" : "没有符合条件的素材")
                        .font(.qcCaption).foregroundStyle(.secondary)
                    if videoAssets.isEmpty {
                        Text("先去「图库」页导入文件夹，视频会出现在这里").font(.qcMicro).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: poolColumns, spacing: 8) {
                        ForEach(poolAssets) { asset in
                            poolCell(asset)
                        }
                    }
                    .padding(.vertical, 2)
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func poolCell(_ asset: Asset) -> some View {
        let id = asset.id ?? 0
        return PoolCell(
            asset: asset,
            picked: pickedIDs.contains(id),
            onTogglePick: {
                if pickedIDs.contains(id) { pickedIDs.remove(id) } else { pickedIDs.insert(id) }
            },
            onAppend: { insertAssetIDs([id], at: segments.count) },
            beginDrag: {
                let payload = dragPayload(for: id)
                // 同步记录：onDrop 落地时零等待直接消费，不依赖异步粘贴板回调
                liveDrag = .assets(payload.ids)
                let provider = NSItemProvider()
                provider.registerDataRepresentation(
                    forTypeIdentifier: UTType.osmoVaultAsset.identifier, visibility: .all
                ) { completion in
                    completion(try? JSONEncoder().encode(payload), nil)
                    return nil
                }
                return provider
            }
        )
    }

    /// 拖某个卡片时带走的内容：拖「已勾选」的卡片 = 按素材池顺序带走全部已勾选；
    /// 否则只拖这一个素材
    private func dragPayload(for id: Int64) -> DraggedAssets {
        if pickedIDs.contains(id), !pickedIDs.isEmpty {
            let ordered = poolAssets.compactMap { a -> Int64? in
                let aid = a.id ?? 0
                return pickedIDs.contains(aid) ? aid : nil
            }
            return DraggedAssets(ids: ordered)
        }
        return DraggedAssets(ids: [id])
    }

    // MARK: - 中列：预览 + 播放条 + 设置行

    private var centerColumn: some View {
        VStack(spacing: 0) {
            videoStage
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)
            playerBar
            settingsRow
        }
    }

    private var videoStage: some View {
        ZStack {
            Vault.shape(Vault.R.container)
                .fill(Color.gray.opacity(0.07))
            Vault.shape(Vault.R.container)
                .strokeBorder(Color.gray.opacity(0.18), lineWidth: 1)
                .allowsHitTesting(false)   // 必修：1px 装饰描边不参与命中

            if segments.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text("把素材拖到下方时间轴，这里就能预览拼接效果")
                        .font(.qcCaption).foregroundStyle(.secondary)
                }
            } else if isPreparingPreview {
                ProgressView("正在生成预览…").controlSize(.small)
            } else if let t = prepared, preview.isReady {
                QuickCutPlayerStage(player: preview.player)
                    .clipShape(Vault.shape(Vault.R.container))
                    .aspectRatio(t.renderRatio, contentMode: .fit)
                    .padding(2)
            } else if let err = previewError {
                VStack(spacing: 6) {
                    Text("预览生成失败").font(.qcCaption)
                    Text(err).font(.qcMicro).foregroundStyle(.secondary).lineLimit(2)
                    Button("重试", action: refreshPreview).controlSize(.small)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "play.rectangle.on.rectangle").foregroundStyle(.tertiary)
                    Text("正在准备预览，或点「刷新」查看拼接效果")
                        .font(.qcCaption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 170)
        .contentShape(Vault.shape(Vault.R.container))
    }

    /// 播放条（36）：刷新 · 播放/暂停（空格）· 从头 · 静音 · 时间码 · 进度
    private var playerBar: some View {
        HStack(spacing: 4) {
            Button {
                refreshPreview()
            } label: {
                Label(previewError == nil && prepared == nil ? "生成预览" : "刷新",
                      systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!previewDirty && prepared != nil)

            // 播放/暂停带空格快捷键（剪映习惯）：必须用原生 Button 才能注册 key equivalent
            Button {
                preview.togglePlay()
            } label: {
                Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13))
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!preview.isReady)
            .keyboardShortcut(.space, modifiers: [])
            .help(preview.isReady ? "播放 / 暂停（空格）" : "生成预览后可播放（空格）")
            .accessibilityLabel(Text("播放 / 暂停"))

            ToolButton("从头播放", systemImage: "backward.end.fill",
                       enabled: preview.isReady) { preview.playFromStart() }
            ToolButton(preview.isMuted ? "取消静音" : "静音",
                       systemImage: preview.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                       enabled: preview.isReady) { preview.toggleMute() }

            Spacer(minLength: 8)
            Text(Self.timeText(preview.currentTime)).font(.qcCaptionMono)
            Slider(
                value: Binding(
                    get: { preview.currentTime },
                    set: { preview.currentTime = $0 }
                ),
                in: 0...max(preview.duration, 0.1)
            ) { editing in
                preview.isScrubbing = editing
                // 松手才真正 seek，拖动过程中不打断播放
                if !editing { preview.seek(to: preview.currentTime) }
            }
            .frame(width: 150)
            .disabled(!preview.isReady || preview.duration <= 0)
            Text(Self.timeText(preview.duration)).font(.qcCaptionMono)

            if previewDirty {
                Label("设置已改", systemImage: "exclamationmark.triangle.fill")
                    .font(.qcMicro).foregroundStyle(.orange)
                    .help("调整会自动应用；也可以点「刷新」立即应用")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// 设置行（40）：画幅 · 转场 · 背景音乐
    private var settingsRow: some View {
        HStack(spacing: 12) {
            Picker("画幅", selection: $aspect) {
                ForEach(QuickCutConfig.Aspect.allCases) { a in
                    Text(a.rawValue).tag(a)
                }
            }
            .frame(width: 92)
            .controlSize(.small)
            .help("导出画幅；「原始」跟随第一段素材")

            HStack(spacing: 4) {
                Text("转场").font(.qcCaption)
                Slider(value: $transitionSeconds, in: 0...2, step: 0.1).frame(width: 70)
                Text(transitionSeconds == 0 ? "硬切" : String(format: "%.1fs", transitionSeconds))
                    .font(.qcCaptionMono)
                    .frame(width: 38, alignment: .leading)
            }
            .help("相邻片段之间的交叉溶解时长")

            Toggle("背景音乐", isOn: Binding(
                get: { bgmURL != nil },
                set: { on in if !on { bgmURL = nil } }
            ))
            .controlSize(.small)
            Button(bgmURL == nil ? "选择音乐…" : bgmURL!.lastPathComponent) {
                showBGMImporter = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(bgmURL != nil)
            .lineLimit(1)
            .frame(maxWidth: 110)
            if bgmURL != nil {
                Button {
                    bgmURL = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("移除所选音乐")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - 时间线工具条（36）

    private var timelineToolbar: some View {
        HStack(spacing: 4) {
            Button { undo() } label: { toolIcon("arrow.uturn.backward") }
                .buttonStyle(.plain).disabled(undoStack.isEmpty)
                .keyboardShortcut("z", modifiers: .command)
                .help("撤销（⌘Z）：加入 / 移除 / 换序 / 分割 / 修剪 / 变速 / 清空 / 自动出片")
            Button { redo() } label: { toolIcon("arrow.uturn.forward") }
                .buttonStyle(.plain).disabled(redoStack.isEmpty)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help("重做（⇧⌘Z）")

            toolDivider

            Button { splitAtPlayhead() } label: { toolIcon("scissors") }
                .buttonStyle(.plain)
                .disabled(!canSplit)
                .keyboardShortcut("b", modifiers: .command)
                .help("在播放头处分割所在片段（⌘B）")
            Button { removeSelectedSegment() } label: { toolIcon("trash") }
                .buttonStyle(.plain)
                .disabled(selectedIndex == nil)
                .keyboardShortcut(.delete, modifiers: .command)
                .help("移除选中的片段（⌘⌫）")
            ToolButton("清空时间轴", systemImage: "trash.slash",
                       enabled: !segments.isEmpty) { confirmClearSegments = true }

            Spacer()
            Text("\(Self.timeText(preview.currentTime)) / \(Self.timeText(totalSeconds))")
                .font(.qcCaptionMono).foregroundStyle(.secondary)
            Spacer()

            // 时间线缩放（剪映 / FrameCut 式：对数滑条 8–120 px/s）
            Image(systemName: "minus.magnifyingglass").font(.qcMicro).foregroundStyle(.tertiary)
            Slider(value: Binding(
                get: { log(pointsPerSecond) },
                set: { pointsPerSecond = min(max(exp($0), 8), 120) }
            ), in: log(8)...log(120))
                .frame(width: 110)
                .controlSize(.mini)
                .help("缩放时间线（当前 \(Int(pointsPerSecond)) 像素/秒）")
            Image(systemName: "plus.magnifyingglass").font(.qcMicro).foregroundStyle(.tertiary)
            Button { zoomToFit() } label: { toolIcon("arrow.left.and.right.square") }
                .buttonStyle(.plain)
                .disabled(segments.isEmpty)
                .keyboardShortcut("0", modifiers: .command)
                .help("缩放以适应窗口（⌘0）")
            if outputURL != nil, !isExporting {
                ToolButton("在访达中显示导出文件", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL!])
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color.primary.opacity(0.03))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func toolIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13))
            .frame(width: 28, height: 26)
            .contentShape(Rectangle())
    }

    private var toolDivider: some View {
        Divider().frame(height: 16).padding(.horizontal, 6)
    }

    // MARK: - 时间轴

    /// 时间轴接收的拖放类型：素材（新增）和片段（换序）
    private static let dropTypes: [UTType] = [.osmoVaultAsset, .osmoVaultClip]

    private var timelineStrip: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: clipSpacing) {
                        ForEach(Array(segments.enumerated()), id: \.element.id) { index, seg in
                            clipCard(seg, at: index)
                                .id(seg.id)
                        }
                        // 尾部追加落点：拖到空白处也接得住
                        Color.clear
                            .frame(width: 140, height: clipHeight)
                            .contentShape(Rectangle())
                            .onDrop(of: Self.dropTypes, isTargeted: dropZoneBinding(segments.count)) { providers in
                                dropFromProviders(providers, insertAt: segments.count)
                            }
                    }
                    .padding(.horizontal, timelineLeadingPad)
                    .padding(.vertical, clipVPad)
                    // 内容坐标系里的浮层：插入指示条 / 转场标记 / 播放头。
                    // 放在滚动内容里而不是外层 ZStack，滚动时它们和片段保持对齐。
                    .overlay(alignment: .topLeading) {
                        ZStack(alignment: .topLeading) {
                            if transitionSeconds > 0, dropTargetIndex == nil, segments.count > 1 {
                                ForEach(1..<segments.count, id: \.self) { junction in
                                    transitionMarker(at: junction)
                                }
                            }
                            if let idx = dropTargetIndex {
                                insertionBar(at: idx)
                            }
                            if let px = playheadX {
                                playheadView(x: px)
                            }
                        }
                        .allowsHitTesting(false)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(dropTargetIndex != nil ? Color.accentColor.opacity(0.08) : Color.gray.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(dropTargetIndex != nil ? Color.accentColor.opacity(0.7) : Color.clear,
                                      lineWidth: 1.5)
                        .allowsHitTesting(false)
                )
                .animation(.easeInOut(duration: 0.15), value: dropTargetIndex)
                // 播放跟随：播放头进入新片段时，滚到该片段开头（播放头保持在视野内）
                .onChange(of: playheadSegmentIndex) { _, new in
                    guard preview.isPlaying, let new, segments.indices.contains(new) else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(segments[new].id, anchor: .leading)
                    }
                }
                // 程序性定位：拖入落地 / 跳段后滚到目标片段
                .onChange(of: pendingScrollID) { _, new in
                    guard let new else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                    pendingScrollID = nil
                }
                // 整体兜底接收：拖到间隙 / 滚动条区域也追加（内层目标命中优先）
                .onDrop(of: Self.dropTypes, isTargeted: dropZoneBinding(segments.count)) { providers in
                    dropFromProviders(providers, insertAt: segments.count)
                }
            }
            .onAppear { timelineViewport = geo.size.width }
            .onChange(of: geo.size.width) { _, w in timelineViewport = w }
        }
        .frame(height: timelineRowHeight)
        .padding(.horizontal, 12)
    }

    /// 空时间轴的落点提示（拖拽悬停时文案 + 高亮变化，落地即见反馈）
    private var emptyTimeline: some View {
        let targeted = dropTargetIndex != nil
        return VStack(spacing: 6) {
            Image(systemName: targeted ? "arrow.down.to.line.compact" : "film.stack")
                .font(.system(size: 20)).foregroundStyle(targeted ? Color.accentColor : Color.secondary)
            Text(targeted
                 ? "松手，素材会加到这里"
                 : "把左侧素材池的素材拖到这里\n点击卡片右上角 +、双击卡片或「自动出片」也能快速加入")
                .font(.qcCaption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: timelineRowHeight + 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(targeted ? Color.accentColor.opacity(0.10) : Color.gray.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(targeted ? Color.accentColor : Color.gray.opacity(0.35),
                              style: StrokeStyle(lineWidth: targeted ? 1.5 : 1, dash: [4, 3]))
        )
        .animation(.easeInOut(duration: 0.15), value: dropTargetIndex != nil)
    }

    /// 时间轴上的一个片段卡（剪映式）：宽度≈时长×缩放，纯缩略图 + 浮层徽章。
    /// 点选微调、双击跳预览、拖动换序、选中后左右边缘出现**修剪把手**（拖拽直接改起止）。
    private func clipCard(_ seg: CutSegment, at index: Int) -> some View {
        let selected = selectedSegmentID == seg.id
        let w = clipWidth(seg)
        return Group {
            if let a = appModel.asset(id: seg.assetID) {
                AsyncThumbView(asset: a)
            } else {
                Color.gray.opacity(0.15)
            }
        }
        .frame(width: w - 4, height: clipHeight - 4)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        // 序号徽章（左上）
        .overlay(alignment: .topLeading) {
            Text("\(index + 1)")
                .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                .padding(3)
        }
        // 时长徽章（右下）
        .overlay(alignment: .bottomTrailing) {
            VaultBadge(horizontal: 4, vertical: 1) {
                Text(String(format: "%.1fs", seg.duration))
            }
            .padding(3)
        }
        // 变速徽章（左下，非 1x 才显示）
        .overlay(alignment: .bottomLeading) {
            if abs(seg.speed - 1) > 0.01 {
                VaultBadge(horizontal: 4, vertical: 1) {
                    Text(String(format: "%.2g×", seg.speed))
                }
                .padding(3)
            }
        }
        .padding(2)
        .frame(width: w, height: clipHeight)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.gray.opacity(selected ? 0.16 : 0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.gray.opacity(0.22),
                              lineWidth: selected ? 2 : 1)
                .allowsHitTesting(false)
        )
        // 修剪把手：选中后出现在左右边缘（剪映式拖拽修剪）
        .overlay(alignment: .leading) {
            TrimHandle(visible: selected,
                       onDrag: { dx in trimEdge(.leading, index: index, dx: dx) },
                       onEnded: { trimBase = nil })
                .frame(height: clipHeight)
        }
        .overlay(alignment: .trailing) {
            TrimHandle(visible: selected,
                       onDrag: { dx in trimEdge(.trailing, index: index, dx: dx) },
                       onEnded: { trimBase = nil })
                .frame(height: clipHeight)
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        // 双击 = 选中并在预览中跳到此片段（先声明 count:2，单击才不会被抢先消费）
        .onTapGesture(count: 2) {
            selectedSegmentID = seg.id
            jumpToSegment(index)
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) { selectedSegmentID = seg.id }
        }
        // 时间轴内拖片段换序：同步记录 + 粘贴板双通道
        .onDrag {
            liveDrag = .segment(seg.id)
            let provider = NSItemProvider()
            provider.suggestedName = seg.fileName
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.osmoVaultClip.identifier, visibility: .all
            ) { completion in
                completion(try? JSONEncoder().encode(DraggedSegment(id: seg.id)), nil)
                return nil
            }
            return provider
        }
        // 落点：素材 = 插到这个片段之前；片段 = 换到这个位置
        .onDrop(of: Self.dropTypes, isTargeted: dropZoneBinding(index)) { providers in
            dropFromProviders(providers, insertAt: index)
        }
        .contextMenu {
            Button("预览中跳到此片段") { selectedSegmentID = seg.id; jumpToSegment(index) }
                .disabled(!canJumpToSegment(index))
            Divider()
            Button("左移一格") { selectedSegmentID = seg.id; move(index, by: -1) }
                .disabled(index == 0)
            Button("右移一格") { selectedSegmentID = seg.id; move(index, by: 1) }
                .disabled(index == segments.count - 1)
            Divider()
            Button("移除片段", role: .destructive) { removeSegment(at: index) }
        }
        .help("\(seg.fileName) · \(String(format: "%.1fs", seg.duration))\(abs(seg.speed - 1) > 0.01 ? String(format: " · %.2g×", seg.speed) : "")（点击选中；选中后拖左右边缘修剪；双击跳转预览；拖动换序）")
    }

    /// 每个落点的悬停态绑定：进入 → 记录插入位置（驱动指示条），离开 → 清除
    private func dropZoneBinding(_ index: Int) -> Binding<Bool> {
        Binding(
            get: { dropTargetIndex == index },
            set: { on in
                if on { dropTargetIndex = index }
                else if dropTargetIndex == index { dropTargetIndex = nil }
            }
        )
    }

    // MARK: 时间轴浮层（内容坐标系）

    /// 第 junction 个接缝的 x 坐标（0 号接缝 = 最左端，segments.count 号 = 追加位置）
    private func junctionX(_ junction: Int) -> CGFloat {
        var x = timelineLeadingPad
        for i in 0..<min(junction, segments.count) {
            x += clipWidth(segments[i]) + clipSpacing
        }
        return x - clipSpacing / 2
    }

    /// 插入位置指示条（剪映式）：拖拽悬停时显示竖线 + 顶部圆点
    private func insertionBar(at idx: Int) -> some View {
        VStack(spacing: 2) {
            Circle().fill(Color.accentColor).frame(width: 9, height: 9)
            Capsule().fill(Color.accentColor).frame(width: 3)
        }
        .frame(height: timelineRowHeight, alignment: .top)
        .offset(x: max(junctionX(idx) - 4, 2))
        .allowsHitTesting(false)
        .shadow(color: Color.accentColor.opacity(0.45), radius: 3)
    }

    /// 接缝处的转场标记（设置了转场时长才出现）
    private func transitionMarker(at junction: Int) -> some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 15, height: 15)
            .background(Circle().fill(Color.accentColor.opacity(0.9)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1))
            .offset(x: junctionX(junction) - 7, y: (timelineRowHeight - 15) / 2)
            .allowsHitTesting(false)
            .help("交叉溶解转场 \(String(format: "%.1fs", transitionSeconds))")
    }

    /// 播放头：时间气泡 + 红线，跟预览进度落在对应片段内按比例定位
    private func playheadView(x: CGFloat) -> some View {
        VStack(spacing: 1) {
            Text(Self.timeText(preview.currentTime))
                .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.red))
                .fixedSize()
            Rectangle().fill(Color.red).frame(width: 1.5)
        }
        .frame(height: timelineRowHeight, alignment: .top)
        .offset(x: x - 14)
        .allowsHitTesting(false)
    }

    // MARK: - 检查条（选中片段微调，40）

    /// 选中片段的检查条（时间轴正下方）
    @ViewBuilder
    private var clipInspector: some View {
        if let index = selectedIndex, segments.indices.contains(index) {
            let seg = segments[index]
            let srcDur = appModel.asset(id: seg.assetID)?.durationSeconds ?? seg.end
            HStack(spacing: 8) {
                Text("片段 \(index + 1)").font(.qcCaptionMono).foregroundStyle(.secondary)
                Text(seg.fileName)
                    .font(.qcCaption).lineLimit(1).frame(maxWidth: 150, alignment: .leading)
                    .help(seg.fileName)
                Text("起").font(.qcMicro).foregroundStyle(.secondary)
                TextField("", value: Binding(
                    get: { segments[index].start },
                    set: { setTrim(index, start: $0) }
                ), format: .number)
                    .frame(width: 46).controlSize(.mini).multilineTextAlignment(.center)
                    .help("片段起点（秒），范围 0 ~ \(String(format: "%.1f", srcDur))")
                Text("止").font(.qcMicro).foregroundStyle(.secondary)
                TextField("", value: Binding(
                    get: { segments[index].end },
                    set: { setTrim(index, end: $0) }
                ), format: .number)
                    .frame(width: 46).controlSize(.mini).multilineTextAlignment(.center)
                    .help("片段终点（秒），范围 0 ~ \(String(format: "%.1f", srcDur))")
                Stepper(value: Binding(
                    get: { segments[index].speed },
                    set: { pushUndo(); segments[index].speed = min(max($0, 0.25), 4) }
                ), in: 0.25...4, step: 0.25) {
                    Text(String(format: "%.2g×", seg.speed)).font(.qcCaptionMono)
                }
                .frame(width: 74)
                .help("变速 0.25×–4×（预览保持原调；导出音频随速变调）")

                Divider().frame(height: 14)

                VaultIconButton("预览中跳到此片段", systemImage: "arrow.right.to.line", symbolSize: 12, hit: 24,
                                isDisabled: !canJumpToSegment(index)) {
                    jumpToSegment(index)
                }
                VaultIconButton("左移", systemImage: "arrow.left", symbolSize: 12, hit: 24,
                                isDisabled: index == 0) { move(index, by: -1) }
                VaultIconButton("右移", systemImage: "arrow.right", symbolSize: 12, hit: 24,
                                isDisabled: index == segments.count - 1) { move(index, by: 1) }
                // 移除带 ⌘⌫ 快捷键：用原生 Button 才能可靠注册 key equivalent
                Button {
                    removeSegment(at: index)
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 13))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.delete, modifiers: .command)
                .help("移除片段（⌘⌫）")

                Spacer()
                Text(String(format: "用时 %.1fs · 源 %.1f–%.1fs", seg.duration, seg.start, seg.end))
                    .font(.qcMicro).monospacedDigit().foregroundStyle(.tertiary)
            }
            .frame(height: 40)
            .padding(.horizontal, 12)
        } else {
            HStack(spacing: 6) {
                Text("点时间轴上的片段，这里可以微调起止 / 变速、换序、移除；选中后拖片段左右边缘可直接修剪；双击片段在预览中跳转")
                    .font(.qcMicro).foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(height: 40)
            .padding(.horizontal, 12)
        }
    }

    /// 起止时间钳制：保证 0 ≤ start < end ≤ 素材全长，且片段不短于 0.3s
    private func setTrim(_ index: Int, start: Double?) {
        guard segments.indices.contains(index) else { return }
        let srcDur = appModel.asset(id: segments[index].assetID)?.durationSeconds ?? segments[index].end
        let v = min(max(start ?? 0, 0), srcDur)
        segments[index].start = v
        if segments[index].end - v < 0.3 {
            segments[index].end = min(v + 0.3, srcDur)
        }
        segments[index].start = min(segments[index].start, max(segments[index].end - 0.3, 0))
    }

    private func setTrim(_ index: Int, end: Double?) {
        guard segments.indices.contains(index) else { return }
        let srcDur = appModel.asset(id: segments[index].assetID)?.durationSeconds ?? segments[index].end
        let v = min(max(end ?? 0, 0), srcDur)
        segments[index].end = v
        if v - segments[index].start < 0.3 {
            segments[index].start = max(v - 0.3, 0)
        }
    }

    /// 拖拽修剪把手：dx（点）→ 源秒数（÷ 每秒像素 × 变速），从手势起点快照累加
    private func trimEdge(_ edge: TrimHandle.Edge, index: Int, dx: CGFloat) {
        guard segments.indices.contains(index) else { return }
        if trimBase == nil {
            pushUndo()
            trimBase = (index, segments[index].start, segments[index].end)
        }
        guard let base = trimBase, base.index == index else { return }
        let seg = segments[index]
        let dSource = Double(dx) / pointsPerSecond * min(max(seg.speed, 0.25), 4)
        if edge == .leading {
            setTrim(index, start: base.start + dSource)
        } else {
            setTrim(index, end: base.end + dSource)
        }
    }

    /// 片段宽度：时长 × 缩放（每秒像素数），下限 48 保证可见
    private func clipWidth(_ seg: CutSegment) -> CGFloat {
        max(seg.duration * pointsPerSecond, 48)
    }

    /// 选中片段的下标（selectedSegmentID 有效时才有值）
    private var selectedIndex: Int? {
        guard let id = selectedSegmentID else { return nil }
        return segments.firstIndex { $0.id == id }
    }

    /// 每个片段在时间轴上的起点（秒）。优先用 prepare 出的 segmentStarts（含转场偏移），
    /// 未生成预览时按原始时长累积（valid = false 表示只是估算）
    private var segmentStartsOnTimeline: (starts: [Double], valid: Bool)? {
        guard !segments.isEmpty else { return nil }
        if let p = prepared, !previewDirty, preview.isReady,
           p.segmentStarts.count == segments.count {
            return (p.segmentStarts.map { max(CMTimeGetSeconds($0), 0) }, true)
        }
        var acc = 0.0
        var starts: [Double] = []
        for seg in segments {
            starts.append(acc)
            acc += seg.duration
        }
        return (starts, false)
    }

    /// 播放头当前落在哪个片段（播放跟随滚动 / 分割用）
    private var playheadSegmentIndex: Int? {
        guard let (starts, valid) = segmentStartsOnTimeline else { return nil }
        let t = valid ? preview.currentTime : 0
        var idx = 0
        for (i, s) in starts.enumerated() where t >= s - 0.05 { idx = i }
        return idx
    }

    /// 播放头 x 坐标（时间轴内容坐标系）：按各片段实际宽度累加 + 段内比例定位
    private var playheadX: CGFloat? {
        guard let (starts, valid) = segmentStartsOnTimeline,
              let idx = playheadSegmentIndex, segments.indices.contains(idx) else { return nil }
        let t = valid ? preview.currentTime : 0
        let local = max(min((t - starts[idx]) / max(segments[idx].duration, 0.1), 1), 0)

        var x = timelineLeadingPad
        for i in 0..<idx { x += clipWidth(segments[i]) + clipSpacing }
        x += local * clipWidth(segments[idx])
        return x
    }

    /// 分割可用：预览已构建且播放头落在某个片段内部
    private var canSplit: Bool {
        guard let (starts, valid) = segmentStartsOnTimeline, valid,
              let idx = playheadSegmentIndex, segments.indices.contains(idx) else { return false }
        let local = preview.currentTime - starts[idx]
        return local > 0.15 && local < segments[idx].duration - 0.15
    }

    // MARK: - 拖放落地

    /// 时间轴统一落点：优先消费 onDrag 同步记录的内容（零等待、必达）；
    /// 本地状态缺失（跨窗口拖入等）时退回 NSItemProvider 异步路径兜底。
    private func dropFromProviders(_ providers: [NSItemProvider], insertAt: Int) -> Bool {
        dropTargetIndex = nil
        if let drag = liveDrag {
            liveDrag = nil
            switch drag {
            case .assets(let ids):
                insertAssetIDs(ids, at: insertAt)
            case .segment(let id):
                moveSegment(id, to: insertAt)
            }
            return true
        }
        return handleTimelineDrop(providers, insertAt: insertAt)
    }

    /// 粘贴板异步兜底：按载荷类型分流——素材插到 insertAt，片段换到 insertAt
    private func handleTimelineDrop(_ providers: [NSItemProvider], insertAt: Int) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.osmoVaultAsset.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.osmoVaultClip.identifier)
        }) else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.osmoVaultClip.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.osmoVaultClip.identifier) { data, _ in
                guard let data,
                      let payload = try? JSONDecoder().decode(DraggedSegment.self, from: data) else { return }
                DispatchQueue.main.async { moveSegment(payload.id, to: insertAt) }
            }
            return true
        }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.osmoVaultAsset.identifier) { data, _ in
            guard let data,
                  let payload = try? JSONDecoder().decode(DraggedAssets.self, from: data) else { return }
            DispatchQueue.main.async { insertAssetIDs(payload.ids, at: insertAt) }
        }
        return true
    }

    // MARK: - 撤销 / 重做

    private func pushUndo() {
        undoStack.append(segments)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(segments)
        withAnimation(.easeInOut(duration: 0.22)) { segments = prev }
        restoreSelection()
        refreshPreview()
        status = "已撤销（⇧⌘Z 可重做）"
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(segments)
        withAnimation(.easeInOut(duration: 0.22)) { segments = next }
        restoreSelection()
        refreshPreview()
        status = "已重做"
    }

    private func restoreSelection() {
        if let id = selectedSegmentID, segments.contains(where: { $0.id == id }) { return }
        selectedSegmentID = segments.last?.id
    }

    // MARK: - 逻辑

    private func makeConfig() -> QuickCutConfig {
        var cfg = QuickCutConfig()
        cfg.transitionDuration = transitionSeconds
        cfg.aspect = aspect
        if let bgm = bgmURL { cfg.includeBGM = true; cfg.bgmPath = bgm.path }
        return cfg
    }

    /// 按「每段秒数」从一个素材生成默认片段：从 20% 处开始取，跳过无人机起飞/开机的废镜头
    private func makeSegment(from a: Asset) -> CutSegment {
        let dur = min(clipSeconds, max(a.durationSeconds, 0.5))
        let start = min(a.durationSeconds * 0.2, max(a.durationSeconds - dur, 0))
        return CutSegment(assetID: a.id ?? 0, sourcePath: a.filePath, fileName: a.fileName,
                          start: start, end: start + dur)
    }

    /// 素材落地：插到指定位置（剪映允许同一素材多次入轨，可裁出不同段落），落地后立即刷新预览
    private func insertAssetIDs(_ ids: [Int64], at index: Int) {
        guard !ids.isEmpty else { return }
        var inserted: [CutSegment] = []
        let insertIndex = min(max(index, 0), segments.count)
        for id in ids {
            guard let a = appModel.asset(id: id) else { continue }
            guard a.kind == .video else { continue }
            inserted.append(makeSegment(from: a))
        }
        guard !inserted.isEmpty else {
            status = "拖入的素材不是视频（照片 / 实况照片暂不能进时间轴）"
            return
        }
        pushUndo()
        withAnimation(.easeInOut(duration: 0.22)) {
            segments.insert(contentsOf: inserted, at: insertIndex)
        }
        selectedSegmentID = inserted.first?.id   // 选中第一个落地的片段，方便继续微调
        pendingScrollID = inserted.first?.id     // 时间轴滚到落地位置
        status = "已加入 \(inserted.count) 段（按拖入顺序从左往右排列）"
        previewError = nil
        refreshPreview()
    }

    /// 时间轴内拖片段换序：把 id 片段挪到「第 toIndex 个位置」上（toIndex == count 表示挪到末尾）
    private func moveSegment(_ id: UUID, to toIndex: Int) {
        guard let from = segments.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(toIndex, 0), segments.count)
        guard from != clamped else { return }
        pushUndo()
        let seg = segments.remove(at: from)
        // 从前面挪到后面时，目标下标在移除后前移一位
        let target = min(max(from < clamped ? clamped - 1 : clamped, 0), segments.count)
        withAnimation(.easeInOut(duration: 0.22)) {
            segments.insert(seg, at: target)
        }
        selectedSegmentID = id
        status = "已调整片段顺序"
        refreshPreview()
    }

    private func removeSegment(at index: Int) {
        guard segments.indices.contains(index) else { return }
        pushUndo()
        let removed = segments.remove(at: index)
        if segments.isEmpty {
            clearPreview()
        }
        if selectedSegmentID == removed.id {
            selectedSegmentID = segments.indices.contains(index) ? segments[index].id : segments.last?.id
        }
        status = "已移除「\(removed.fileName)」（⌘Z 可撤销）"
    }

    private func removeSelectedSegment() {
        guard let index = selectedIndex else { return }
        removeSegment(at: index)
    }

    /// ⌘B：在播放头处把所在片段一分为二（FrameCut 同款交互）
    private func splitAtPlayhead() {
        guard let (starts, valid) = segmentStartsOnTimeline, valid,
              let idx = playheadSegmentIndex, segments.indices.contains(idx) else { return }
        let seg = segments[idx]
        let local = preview.currentTime - starts[idx]
        guard local > 0.15, local < seg.duration - 0.15 else {
            status = "播放头要落在片段中间才能分割"
            return
        }
        // 时间轴秒 → 源素材秒（除以变速）
        let sourceSplit = seg.start + local * min(max(seg.speed, 0.25), 4)
        pushUndo()
        var left = seg
        left.end = sourceSplit
        var right = seg
        right.id = UUID()
        right.start = sourceSplit
        withAnimation(.easeInOut(duration: 0.22)) {
            segments.replaceSubrange(idx...idx, with: [left, right])
        }
        selectedSegmentID = right.id   // 选中后半段，最贴近「分割后继续处理右侧」的习惯
        status = "已分割片段 \(idx + 1)（⌘Z 可撤销）"
    }

    private func autoBuild() {
        let pool = poolAssets
        guard !pool.isEmpty else { status = "当前筛选下没有可用素材"; return }
        pushUndo()
        withAnimation(.easeInOut(duration: 0.25)) {
            segments = pool.prefix(40).map { makeSegment(from: $0) }
        }
        selectedSegmentID = segments.first?.id
        status = "已生成 \(segments.count) 段（「每段秒数」控制单片长度，可再逐个微调）"
        previewError = nil
        refreshPreview()
    }

    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard segments.indices.contains(target) else { return }
        pushUndo()
        withAnimation(.easeInOut(duration: 0.2)) {
            segments.swapAt(index, target)
        }
        refreshPreview()
    }

    private func jumpToSegment(_ index: Int) {
        guard let t = prepared, !previewDirty, t.segmentStarts.indices.contains(index) else { return }
        pendingScrollID = segments[index].id   // 时间轴滚到该片段，预览画面同步跳转
        preview.seek(to: CMTimeGetSeconds(t.segmentStarts[index]))
    }

    /// 缩放以适应窗口：总时长铺满可视宽度
    private func zoomToFit() {
        guard totalSeconds > 0, timelineViewport > 0 else { return }
        let pps = (timelineViewport - 2 * timelineLeadingPad - 8) / totalSeconds
        withAnimation(.easeInOut(duration: 0.2)) {
            pointsPerSecond = min(max(pps, 8), 120)
        }
    }

    /// 按当前时间轴与设置重建预览时间线（与导出共用 prepare，效果一定一致）。
    /// 重建时保留播放位置：调转场/微调起止不会把播放进度打回 0。
    private func refreshPreview() {
        guard !segments.isEmpty else { clearPreview(); return }
        isPreparingPreview = true
        previewError = nil
        let resumeAt = preview.currentTime
        // 先取签名：构建过程中用户再改设置时，dirty 不会被误清掉
        let signature = configSignature
        Task { @MainActor in
            defer { isPreparingPreview = false }
            do {
                let timeline = try QuickCutService.prepare(segments: segments, config: makeConfig())
                guard !Task.isCancelled else { return }
                prepared = timeline
                builtSignature = signature
                preview.load(timeline)
                if resumeAt > 0.1 {
                    preview.seek(to: min(resumeAt, max(CMTimeGetSeconds(timeline.total) - 0.05, 0)))
                }
                // 构建期间又有新改动 → 排一轮防抖刷新，别丢掉
                if previewDirty { scheduleAutoRefresh() }
            } catch {
                previewError = error.localizedDescription
                preview.unload()
            }
        }
    }

    /// 设置 / 片段变化后 0.9s 防抖自动刷新预览（连续微调只触发一次重建）
    private func scheduleAutoRefresh() {
        autoRefreshTask?.cancel()
        guard !segments.isEmpty else { return }
        autoRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, previewDirty, !segments.isEmpty, !isPreparingPreview else { return }
            refreshPreview()
        }
    }

    private func clearPreview() {
        preview.unload()
        prepared = nil
        builtSignature = nil
    }

    private func exportAll() {
        isExporting = true
        status = "开始导出…"
        outputURL = nil
        progressValue = 0
        Task {
            do {
                let out = QuickCutService.defaultOutputURL()
                try await QuickCutService.export(segments: segments, config: makeConfig(), to: out) { p in
                    Task { @MainActor in progressValue = p }
                }
                outputURL = out
                status = "已导出「\(out.lastPathComponent)」到「影片/OsmoVault 出片」"
            } catch {
                status = "导出失败：\(error.localizedDescription)"
            }
            isExporting = false
        }
    }

    // MARK: - 数据

    /// 出片只接视频；照片/实况进不了时间线（要做成片段得先转码，暂不支持）
    private var videoAssets: [Asset] {
        appModel.assets
            .filter { $0.kind == .video }
            .sorted { ($0.recordedAt ?? .distantPast) < ($1.recordedAt ?? .distantPast) }
    }

    /// 素材池 = 图库视频 × 筛选（全部 / 收藏 / 评分 ≥ 4）× 搜索（文件名 / 地点），
    /// 排序按拍摄时间——与图库页的评级 / 收藏数据完全打通
    private var poolAssets: [Asset] {
        var list = videoAssets
        switch poolFilter {
        case .all: break
        case .favorites: list = list.filter(\.isFavorite)
        case .highRated: list = list.filter { $0.rating >= 4 }
        }
        if !searchText.isEmpty {
            let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
            if !q.isEmpty {
                list = list.filter {
                    $0.fileName.lowercased().contains(q)
                        || ($0.placeName ?? "").lowercased().contains(q)
                }
            }
        }
        return list
    }

    private var totalSeconds: Double {
        guard !segments.isEmpty else { return 0 }
        let raw = segments.reduce(0) { $0 + $1.duration }
        let overlap = segments.count > 1 ? transitionSeconds * Double(segments.count - 1) : 0
        return max(raw - overlap, 0)
    }

    /// 当前配置的签名：任何会影响时间线的设置都在这里，变了就说明预览过期
    private var configSignature: Signature {
        Signature(segments: segments, transition: transitionSeconds, aspect: aspect, bgmPath: bgmURL?.path)
    }

    private var previewDirty: Bool { builtSignature != configSignature }

    private func canJumpToSegment(_ index: Int) -> Bool {
        guard let t = prepared, !previewDirty, preview.isReady else { return false }
        return t.segmentStarts.indices.contains(index)
    }

    // MARK: - 配置签名

    private struct Signature: Equatable {
        let segments: [CutSegment]
        let transition: Double
        let aspect: QuickCutConfig.Aspect
        let bgmPath: String?
    }

    static func timeText(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}

// MARK: - 工具条按钮（FrameCut 规格：28×26 命中区）

private struct ToolButton: View {
    let help: String
    let systemImage: String
    var enabled = true
    let action: () -> Void

    init(_ help: String, systemImage: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.help = help
        self.systemImage = systemImage
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.45))
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

// MARK: - 片段修剪把手（剪映式：选中片段的左右边缘）

/// 选中态显示白色把手；拖拽把位移（点）回传给宿主，由宿主换算成源秒数。
/// 手势结束时通知宿主清理快照。
private struct TrimHandle: View {
    enum Edge { case leading, trailing }

    let visible: Bool
    let onDrag: (CGFloat) -> Void
    let onEnded: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white)
                .frame(width: 3, height: 24)
                .shadow(color: .black.opacity(0.4), radius: 1)
                .opacity(visible ? 1 : 0)
        }
        .frame(width: 12)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    onDrag(value.translation.width)
                }
                .onEnded { _ in onEnded() }
        )
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 素材池卡片

/// 素材池卡片：点击即勾选（勾选后拖动任一已勾选卡片 = 整组按顺序入轨，剪映习惯），
/// 悬浮出现 + 快速追加按钮，双击卡片也直接追加到时间轴末尾。
private struct PoolCell: View {
    let asset: Asset
    let picked: Bool
    let onTogglePick: () -> Void
    let onAppend: () -> Void
    /// 拖拽启动：由父视图同步记录 liveDrag 并构造 NSItemProvider
    let beginDrag: () -> NSItemProvider

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .bottomTrailing) {
                AsyncThumbView(asset: asset)
                    .frame(height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .topLeading) {
                        if asset.rating >= 4 {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9)).foregroundStyle(.yellow)
                                .padding(3)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if picked {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.white, Color.accentColor)
                                .padding(3)
                        }
                    }
                // 悬浮的快速追加（剪映素材库的 +）
                if hovering {
                    Button {
                        onAppend()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.accentColor))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("添加到时间轴末尾")
                }
            }
            Text(asset.fileName)
                .font(.qcMicro).lineLimit(1)
            Text(String(format: "%.0fs", asset.durationSeconds))
                .font(.qcMicro).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(picked ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        // 双击 = 追加到时间轴末尾；单击 = 勾选（先声明 count:2）
        .onTapGesture(count: 2) { onAppend() }
        .onTapGesture { onTogglePick() }
        // onDrag（AppKit 粘贴板）比 draggable + dropDestination 在 macOS 上可靠得多
        .onDrag { beginDrag() }
        .help("点击勾选（拖已勾选卡片会带走全部已勾选素材）；双击或右上角 + 直接加到时间轴末尾；拖到时间轴任意位置插入\(asset.placeName.map { "；拍摄地：\($0)" } ?? "")")
    }
}

// MARK: - 预览播放控制器

/// 预览专用播放器：只管一条 composition 时间线（转场/画幅/BGM/变速都由 videoComposition 呈现），
/// 播完停在结尾等待用户从头/跳段，不需要倍速、逐帧那套。
@MainActor
final class QuickCutPreviewController: ObservableObject {
    let player = AVPlayer()

    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var isReady = false
    @Published var isMuted = false

    /// 拖动进度条时暂停时间回调回写，避免滑块跟手打架
    var isScrubbing = false

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        // 0.25s 回调一次即可：控制条不需要每秒重绘 10 次
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self, !self.isScrubbing else { return }
                self.currentTime = CMTimeGetSeconds(time)
            }
        }
    }

    /// 加载一条已构建好的时间线（与导出共用 `QuickCutService.prepare` 产物）
    func load(_ timeline: PreparedTimeline) {
        teardownItemObservers()
        player.rate = 0
        isReady = false
        isPlaying = false
        duration = 0
        currentTime = 0

        let item = AVPlayerItem(asset: timeline.composition)
        item.videoComposition = timeline.videoComposition
        item.audioMix = timeline.audioMix
        item.preferredForwardBufferDuration = 1
        // 预览里变速保持原调（导出管线暂不做原调保持）
        item.audioTimePitchAlgorithm = .spectral
        player.replaceCurrentItem(with: item)

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                guard item.status == .readyToPlay else { return }
                let d = CMTimeGetSeconds(item.duration)
                self.duration = d.isFinite ? d : 0
                self.isReady = true
            }
        }
        // 预览播完停在结尾，不循环
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = false
            }
        }
    }

    // MARK: - 播放控制

    func togglePlay() {
        guard isReady else { return }
        if player.rate == 0 {
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
    }

    func playFromStart() {
        guard isReady else { return }
        seek(to: 0)
        player.play()
        isPlaying = true
    }

    /// 拖动结束时调用：真正跳转
    func seek(to seconds: Double) {
        let t = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isScrubbing = false
                self.currentTime = max(seconds, 0)
            }
        }
    }

    func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    /// 卸载：页面消失时兜底停声，也释放旧时间线占用的资源
    func unload() {
        teardownItemObservers()
        player.rate = 0
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        isReady = false
        isMuted = false
        duration = 0
        currentTime = 0
    }

    private func teardownItemObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        if let o = endObserver {
            NotificationCenter.default.removeObserver(o)
            endObserver = nil
        }
    }

    deinit {
        if let o = timeObserver { player.removeTimeObserver(o) }
    }
}

// MARK: - 预览画面层

/// AVPlayerLayer 直接做 backing layer（与详情页同一思路，CommandLineTools 工具链下 AVKit 不可靠）
private struct QuickCutPlayerStage: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> QuickCutPlayerLayerView {
        let v = QuickCutPlayerLayerView(frame: .zero)
        v.player = player
        return v
    }

    func updateNSView(_ nsView: QuickCutPlayerLayerView, context: Context) {
        nsView.player = player
    }
}

private final class QuickCutPlayerLayerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let l = AVPlayerLayer()
        l.videoGravity = .resizeAspect
        // 画面外的信箱区透出容器淡灰底色，不硬编码黑色
        l.backgroundColor = nil
        layer = l
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    var player: AVPlayer? {
        get { (layer as? AVPlayerLayer)?.player }
        set { (layer as? AVPlayerLayer)?.player = newValue }
    }

    override func layout() {
        super.layout()
        (layer as? AVPlayerLayer)?.frame = bounds
    }
}
