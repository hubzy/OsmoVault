import SwiftUI
import AVFoundation

struct AssetGridView: View {
    let assets: [Asset]
    @Binding var selectedAssetID: Int64?
    var onRate: (Int64, Int) -> Void = { _, _ in }
    var onDelete: ((Int64) -> Void)?
    var onToggleFavorite: ((Int64) -> Void)?
    /// 卡片滚进可视区时回调。缩略图改成按需生成后，靠它把"当前看到哪"传给 AppModel
    var onVisible: ((Int64) -> Void)?
    /// 「补定位」页的多选：进入选择模式后点卡片 = 勾选，不再打开详情
    var selectionMode = false
    var checkedIDs: Set<Int64> = []
    var onToggleCheck: ((Int64) -> Void)?
    /// 右键「补定位」。回调传当前卡片 id；多选模式下由调用方决定作用于勾选集还是单条
    var onLocate: ((Int64) -> Void)?
    /// 多选右键已勾选卡片时的批量「移到回收站」：由外层统一弹二次确认并执行。
    /// 勾选集归 LibraryView 管，这里只发一个「请求批量删除」的信号
    var onDeleteChecked: (() -> Void)? = nil
    /// 只有「补定位」页置 true：右键菜单里才出现「补定位 已选 N 条」批量项。
    /// 其他页面（图库/来源/地点…）右键只对症当前这条，避免点了"批量"实际只改一条
    var canBatchLocate = false
    var emptyHint: String?
    /// 嵌入别的滚动容器（比如时间轴）时置 true：不再套自己的 ScrollView，避免双层滚动
    var embedded = false
    /// 多选右键已勾选卡片时的批量评分 / 批量收藏：勾选集由 LibraryView 组装，这里只传目标值
    var onRateChecked: ((Int) -> Void)? = nil
    var onSetFavoriteChecked: ((Bool) -> Void)? = nil
    /// 整个勾选集（不是当前网格这一天/这一月的分组）：
    /// 批量项的「已选 N」和「全部已收藏 / 全部已定位」判断都得以它为准
    var checkedAssets: [Asset] = []
    /// 右键菜单里的多选控制：退出多选 / 全选。顶部不再放「选择 / 完成」按钮
    var onExitSelection: (() -> Void)? = nil
    var onToggleSelectAll: (() -> Void)? = nil
    /// 整个页面的素材数（不是本分组），用来判断「全选 / 取消全选」
    var totalCount: Int = 0
    // 竖屏素材用更窄的最小宽度，让同屏能排下更多卡片
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 200), spacing: 14)] }

    var body: some View {
        Group {
            if embedded {
                LazyVGrid(columns: columns, spacing: 16) { cells }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) { cells }
                        .padding(16)
                }
                .overlay {
                    if assets.isEmpty { emptyState }
                }
            }
        }
    }

    @ViewBuilder
    private var cells: some View {
        ForEach(assets) { asset in
            let id = asset.id ?? 0
            AssetCell(asset: asset,
                      isSelected: selectedAssetID == asset.id,
                      checked: selectionMode && checkedIDs.contains(id),
                      selectionMode: selectionMode,
                      onRate: { onRate(id, $0) },
                      onToggleFavorite: onToggleFavorite == nil ? nil : { onToggleFavorite?(id) })
                .contentShape(Rectangle())
                .onTapGesture {
                    if selectionMode {
                        onToggleCheck?(id)
                    } else {
                        selectedAssetID = asset.id
                    }
                }
                // LazyVGrid 只实例化可视区的 cell，所以这里天然就是"滚到才生成"
                .onAppear { if let id = asset.id { onVisible?(id) } }
                .contextMenu {
                    // 多选入口整个搬进右键：第一次「选中」自动进入多选，
                    // 顶部不再需要「选择 / 完成 / 批量」按钮。
                    // 右键已勾选卡片 = 对整个勾选集操作（补定位 / 收藏 / 评分 / 删除统一走这条）；
                    // 右键未勾选的卡片或没进多选 = 只作用这一条
                    let batchForChecked = selectionMode && checkedIDs.contains(id) && !checkedAssets.isEmpty
                    let count = checkedAssets.count

                    Button(checkedIDs.contains(id) ? "取消选中" : "多选") { onToggleCheck?(id) }
                    if selectionMode {
                        Divider()
                        Button(totalCount > 0 && checkedIDs.count >= totalCount ? "取消全选" : "全选") {
                            onToggleSelectAll?()
                        }
                        Button("退出多选") { onExitSelection?() }
                        Divider()
                    }
                    if onLocate != nil {
                        // 只给一条补定位入口，避免菜单里同时冒出两个「补定位」。
                        // 有定位显示「修改定位」，没有显示「补定位」（定位不准时从这里改）
                        if batchForChecked && canBatchLocate {
                            let allLocated = checkedAssets.allSatisfy { $0.latitude != nil }
                            Button {
                                onLocate?(id)
                            } label: {
                                Label(allLocated ? "修改定位 · 已选 \(count) 条"
                                      : "补定位 · 已选 \(count) 条",
                                      systemImage: "mappin.circle")
                            }
                        } else {
                            Button {
                                onLocate?(id)
                            } label: {
                                Label(asset.latitude == nil ? "补定位…" : "修改定位…",
                                      systemImage: "mappin.circle")
                            }
                        }
                    }
                    if batchForChecked, let onSetFavoriteChecked {
                        // 勾选集里可能有的已收藏有的没收藏：统一设成一个值，
                        // 全已收藏才给「取消收藏」，否则给「收藏」
                        let allFavorite = checkedAssets.allSatisfy { $0.isFavorite }
                        Button(allFavorite ? "取消收藏 已选 \(count)" : "收藏 已选 \(count)") {
                            onSetFavoriteChecked(!allFavorite)
                        }
                    } else {
                        Button(asset.isFavorite ? "取消收藏" : "收藏") {
                            onToggleFavorite?(id)
                        }
                    }
                    // 评分键盘等价路径：网格里的星标是 onTapGesture，不可聚焦
                    if batchForChecked, let onRateChecked {
                        Menu("评分 已选 \(count)") {
                            ForEach(0...5, id: \.self) { r in
                                Button(r == 0 ? "清除评分" : "\(r) 星") { onRateChecked(r) }
                            }
                        }
                    } else {
                        Menu("评分") {
                            ForEach(0...5, id: \.self) { r in
                                Button(r == 0 ? "清除评分" : "\(r) 星") { onRate(id, r) }
                            }
                        }
                    }
                    if batchForChecked, let onDeleteChecked {
                        Button("移到回收站 已选 \(count)") { onDeleteChecked() }
                    } else {
                        Button("移到回收站") { onDelete?(id) }
                    }
                }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack").font(.largeTitle).foregroundStyle(.secondary)
            Text(emptyHint ?? "还没有素材").font(.title3)
            if emptyHint == nil {
                Text("点击右上角导入文件夹开始建库").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

/// 独立出来的异步缩略图视图：出片面板等地方也能复用
struct AsyncThumbView: View {
    let asset: Asset
    @State private var thumb: NSImage?
    /// 缩略图属于哪条素材。切换筛选/来源后 cell 会被复用到另一条素材上，
    /// 只判 `thumb == nil` 会把上一条的图留着不发新的请求
    @State private var loadedID: Int64?

    var body: some View {
        // 同样是弹性骨架 + overlay，避免 .fill 的固有宽高比撑破外框
        Color.clear
            .overlay {
                Group {
                    if let thumb {
                        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.18))
                            .overlay { Image(systemName: "film").foregroundStyle(.tertiary) }
                    }
                }
            }
            .clipped()
            .task(id: asset.id) {
                guard loadedID != asset.id else { return }
                // 先用已生成好的缓存顶上（不触发解码）：地图聚合点缩放后重建视图时，
                // 不会闪一下灰块再弹回图片——那就是用户看到的"标签抖动"
                let cached = ThumbnailStore.shared.cachedThumbnail(for: asset)
                thumb = cached
                if cached != nil {
                    loadedID = asset.id
                    return
                }
                let loaded = await ThumbnailStore.shared.thumbnail(for: asset)
                guard !Task.isCancelled else { return }
                loadedID = asset.id
                thumb = loaded
            }
    }
}

struct AssetCell: View {
    let asset: Asset
    let isSelected: Bool
    /// 「补定位」页的多选状态
    var checked = false
    var selectionMode = false
    var onRate: (Int) -> Void = { _ in }
    var onToggleFavorite: (() -> Void)?

    /// hover 状态放在 cell 内部：放在父视图上会让每次移动鼠标都刷新整屏卡片
    @State private var isHovered = false
    @State private var previewOn = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var thumb: NSImage?
    /// 缩略图属于哪条素材。LazyVStack 会复用 cell，切换筛选后可能拿另一条素材
    /// 填到同一个位置上，只判 `thumb == nil` 会一直显示上一条的图
    @State private var loadedID: Int64?
    /// 正在取图的请求：cell 滚走/复用后要能取消，避免解出来的图贴到别的素材上
    @State private var thumbTask: Task<Void, Never>?

    /// 媒体区统一高度：横竖屏在同一行内等高显示，竖屏按比例变窄
    private var mediaHeight: CGFloat { 150 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            mediaArea
            infoArea
        }
        .contentShape(Rectangle())
        .accessibilityValue(Text(checked ? "已勾选" : ""))
        .onHover { hovering in
            isHovered = hovering
            hoverTask?.cancel()
            // 多选时不跑 hover 预览：勾选过程不该冒出一堆播放器 / 声音
            guard !selectionMode else {
                previewOn = false
                return
            }
            if hovering {
                // 悬停 0.4s 才起播：鼠标扫过一排卡片时不会瞬间创建一堆 AVPlayer
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled else { return }
                    previewOn = true
                }
            } else {
                previewOn = false
            }
        }
        .onDisappear { hoverTask?.cancel() }
    }

    private var mediaArea: some View {
        ZStack(alignment: .bottomTrailing) {
            // 尺寸骨架必须是弹性的 Color.clear：
            // .fill 的图片带固有宽高比，直接放进 ZStack 会把卡片撑得比列宽还宽，
            // 列间距和四周 padding 会被吃掉。overlay 内容不参与尺寸计算，只负责画面。
            Color.clear
                .overlay {
                    ZStack {
                        if let thumb {
                            Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle()
                                .fill(Color.gray.opacity(0.18))
                                .overlay { Image(systemName: "film").font(.largeTitle).foregroundStyle(.tertiary) }
                        }
                        // 缩略图垫底 + 播放器叠加：首帧解码前不闪黑。
                        // 实况照片播它的动态部分；纯照片不起播；多选时一律不预览
                        if previewOn, !selectionMode, let playPath = asset.playbackPath {
                            HoverPreviewPlayer(url: URL(fileURLWithPath: playPath))
                        }
                        if checked {
                            Color.accentColor.opacity(0.18)
                        }
                    }
                }
                .frame(height: mediaHeight)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(Vault.shape(Vault.R.media))
                // 单选 = 仅 2pt accent 描边、无填充；
                // 勾选 = 0.18 accent 填充 + 右上角徽章，不画 accent 描边。两者可叠加
                .overlay(
                    Vault.shape(Vault.R.media)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                )

            // 照片没有时长，改标类型；视频标时长。
            // 实况照片：类型已由左上角的 LIVE 徽章表达，右下角不再重复图标——
            // 只在实际有真实时长时才补一个时长角标（当前扫描不探测实况视频时长，
            // durationSeconds 恒为 0，所以右下角角标整体不出现）
            if asset.kind == .livePhoto {
                if asset.durationSeconds > 0 {
                    VaultBadge {
                        Text(Self.durationText(asset.durationSeconds))
                    }
                    .padding(6)
                }
            } else {
                VaultBadge {
                    HStack(spacing: 4) {
                        if asset.kind == .photo {
                            Image(systemName: "photo")
                                .font(.caption2)
                                .help("照片")
                        }
                        if asset.durationSeconds > 0 {
                            Text(Self.durationText(asset.durationSeconds))
                        }
                    }
                }
                .padding(6)
            }
        }
        .overlay(alignment: .topTrailing) {
            if selectionMode {
                // 勾选框：整张卡片都是点击热区，这里只负责显示状态
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(checked ? Color.accentColor : .white)
                    .shadow(radius: 2)
                    .padding(6)
            } else if asset.isFavorite || (isHovered && onToggleFavorite != nil) {
                Button {
                    onToggleFavorite?()
                } label: {
                    Image(systemName: asset.isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(asset.isFavorite ? .pink : .white)
                        .shadow(radius: 2)
                }
                .buttonStyle(.plain)
                // hover-only：不套 VaultIconButton、不加 .help（否则 8000 个 cell 全进 VO / Tab 顺序）。
                // 常驻等价入口已在 contextMenu 的「收藏」里
                .accessibilityHidden(true)
                .padding(6)
            }
        }
        .overlay(alignment: .topLeading) {
            // 实况照片按规范在左上角标 LIVE；视频/实况悬停起播才显示播放指示，
            // 纯照片没有可播内容（playbackPath 为 nil），hover 不出现 play 图标
            if asset.kind == .livePhoto {
                LiveBadge(compact: true)
                    .padding(5)
            } else if isHovered && previewOn, asset.kind.isPlayable {
                Image(systemName: "play.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .padding(6)
            }
        }
        // cell 被复用到另一条素材时先清掉旧图，等它真的出现在屏幕上再去取
        .task(id: asset.id) {
            thumb = nil
            loadedID = nil
            previewOn = false
            hoverTask?.cancel()
        }
        // 懒加载的关键：`LazyVGrid` 会在可视区上下各预实例化好几屏 cell，
        // 以前在 `.task` 里直接解码，等于每次启动/滚动都白解几十上百张看不到的图。
        // 这里按"是否真的滚进可视区"来触发，滚出去的 cell 不再发请求。
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            if visible { loadThumbIfNeeded() }
        }
    }

    /// 取缩略图（内存 → 磁盘 → 现解码）。已经拿过同一张就直接返回
    private func loadThumbIfNeeded() {
        guard loadedID != asset.id else { return }
        let target = asset
        thumbTask?.cancel()
        thumbTask = Task { @MainActor in
            let loaded = await ThumbnailStore.shared.thumbnail(for: target)
            guard !Task.isCancelled else { return }
            loadedID = target.id
            thumb = loaded
        }
    }

    private var infoArea: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if asset.colorLabel > 0 {
                    Circle().fill(ColorLabelControl.colors[asset.colorLabel] ?? .clear)
                        .frame(width: 8, height: 8)
                }
                Text(asset.fileName).font(.footnote).lineLimit(1)
            }
            HStack(spacing: 6) {
                if let t = asset.recordedAt {
                    Text(t, style: .date).font(.caption2).foregroundStyle(.secondary)
                }
                if asset.latitude != nil {
                    Image(systemName: "mappin").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                CompactRatingControl(rating: asset.rating, onChange: onRate)
                    .controlSize(.mini)
            }
        }
    }

    static func durationText(_ s: Double) -> String {
        let total = Int(s.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
