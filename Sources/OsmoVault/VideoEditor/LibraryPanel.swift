import AppKit
import FCCore
import FCEngine
import FCMedia
import SwiftUI
import UniformTypeIdentifiers

enum LibraryTab: String, CaseIterable {
    case media, audio, title, text, transition, filter

    var title: String {
        switch self {
        case .media: String(localized: "素材")
        case .audio: String(localized: "音频")
        case .title: String(localized: "文字")
        case .text: String(localized: "字幕")
        case .transition: String(localized: "转场")
        case .filter: String(localized: "滤镜")
        }
    }

    var icon: String {
        switch self {
        case .media: "photo.on.rectangle"
        case .audio: "music.note"
        case .title: "textformat"
        case .text: "captions.bubble"
        case .transition: "square.split.diagonal"
        case .filter: "camera.filters"
        }
    }
}

/// 左侧素材库：素材 / 音频 / 字幕 / 转场 / 滤镜。
struct LibraryPanel: View {
    @Bindable var model: EditorModel
    @State private var tab: LibraryTab = UserDefaults.standard.string(forKey: "debug.libraryTab").flatMap(LibraryTab.init(rawValue:)) ?? .media

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(LibraryTab.allCases, id: \.self) { t in
                    Button {
                        tab = t
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: t.icon).latinSymbol().font(.system(size: 15))
                            Text(t.title).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .foregroundStyle(tab == t ? Theme.accent : Theme.secondary)
                        .background(RoundedRectangle(cornerRadius: 6).fill(tab == t ? Theme.raised : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            Divider().overlay(Theme.border)
            Group {
                switch tab {
                case .media: MediaTab(model: model)
                case .audio: AudioTab(model: model)
                case .title: TextTab(model: model)
                case .text: SubtitlePanel(model: model)
                case .transition: TransitionTab(model: model)
                case .filter: FilterTab(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Theme.panel)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
    }
}

// MARK: - 素材（OsmoVault 资源池）

/// 素材页 = OsmoVault 图库的窗口，**纯选择工具**：不带评分 / 收藏等管理功能，
/// 只负责"找到 → 选中 → 入轨"。时间组织对齐图库：按月分组 + 月份刻度尺跳转。
private struct MediaTab: View {
    @Bindable var model: EditorModel
    @EnvironmentObject private var appModel: AppModel

    @State private var searchText = ""
    /// 显式管理搜索框焦点：列表 / 标尺区域点击时主动放弃第一响应者，
    /// 否则 AppKit 不会在点到空白处时自动取消，搜索框会一直停在聚焦态。
    @FocusState private var searchFocused: Bool
    @State private var filter: PoolFilter = .all
    /// 刻度尺当前高亮的月份，滚动列表时跟随更新
    @State private var activeMonthID: String?
    /// 双向滚动绑定（图库同款）：设置它 → 滚到该月；手动滚动 → 它自动更新（刻度高亮跟着走）
    @State private var scrolledMonthID: String?

    // MARK: 分组缓存（图库同款）
    /// body 里现算「筛选 + 按月分组」的话，几千条素材每次重绘都是几十毫秒，
    /// 滚动列表 / 点卡片预览都会触发重绘 → 整个分组重算 → 滚动卡顿。
    /// 改按 (素材版本, 筛选, 搜索) 缓存进 @State
    @State private var sections: [PoolMonth] = []
    @State private var undatedAssets: [Asset] = []
    private var cacheKey: String { "\(appModel.assetsVersion)|\(filter)|\(searchText)" }

    // MARK: 批次渲染（图库同款机制）
    /// 只先渲染前几个月，触底追加下一批。刻度尺跳转的关键配套：
    /// 点击远处月份前先 ensureRendered 把批次补到它——目标不在 ForEach 里的话
    /// scrollTo / scrollPosition 根本无处可去，这正是之前"点了没反应"的根因
    @State private var monthLimit = 3
    @State private var growing = false
    private let batchSize = 3
    private var hasMoreMonths: Bool { monthLimit < sections.count }

    var body: some View {
        VStack(spacing: 8) {
            // 搜索 + 分类筛选 + 导入（单行，导入是外部文件入口，收在筛选右边）
            HStack(spacing: 6) {
                TextField("搜索素材 / 地点", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($searchFocused)
                    // Esc 也退出编辑态（macOS 标准行为），双保险
                    .onExitCommand { searchFocused = false }
                Picker("", selection: $filter) {
                    ForEach(PoolFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 62)
                .help("按类型筛选")
                Button {
                    model.importPanel(addToTimeline: false)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.text)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.raised))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border, lineWidth: 1))
                .help("导入不在资源池里的视频 / 音频文件")
            }
            if sections.isEmpty && undatedAssets.isEmpty {
                Spacer()
                Text(appModel.assets.isEmpty
                     ? "资源池还没有素材。\n先在「素材库」页导入并扫描。"
                     : "没有符合搜索 / 筛选的素材。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.tertiary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    VStack(spacing: 0) {
                        PoolRulerStrip(months: sections, activeMonthID: activeMonthID) { id in
                            // 目标月份不在已渲染范围时先把批次补到它，否则滚动指令无处可去
                            ensureRendered(id)
                            // 双向绑定：设置 scrolledMonthID → ScrollView 滚到该月
                            scrolledMonthID = id
                            activeMonthID = id
                            jump(proxy, to: id)
                        }
                        Divider().overlay(Theme.border)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                                ForEach(Array(sections.prefix(monthLimit))) { m in
                                    Section {
                                        ForEach(m.days) { day in
                                            dayRow(day)
                                        }
                                    } header: {
                                        monthHeader(m)
                                            .id(m.id)
                                    }
                                }
                                // 触底占位：它被实例化就说明快滚到底了，再追加下一批
                                if hasMoreMonths {
                                    loadMoreFooter
                                }
                                if !undatedAssets.isEmpty && !hasMoreMonths {
                                    Section {
                                        LazyVGrid(columns: Self.columns, spacing: 10) {
                                            ForEach(undatedAssets) { asset in
                                                poolCell(asset)
                                            }
                                        }
                                    } header: {
                                        HStack(spacing: 6) {
                                            Text("未记录时间").font(.system(size: 12, weight: .semibold))
                                            Text("\(undatedAssets.count) 个").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                                            Spacer()
                                        }
                                        .padding(.vertical, 4)
                                        .background(Theme.panel)
                                        .id("undated")
                                    }
                                }
                            }
                            .padding(10)
                        }
                        .scrollPosition(id: $scrolledMonthID, anchor: .top)
                        .onChange(of: scrolledMonthID) { _, newID in
                            if let newID { activeMonthID = newID }
                        }
                    }
                    // 点列表 / 标尺任意空白处都放弃搜索框焦点（搜索行是兄弟视图，点它自身不受影响）
                    .onTapGesture { searchFocused = false }
                }
            }
        }
        .padding(10)
        // 素材版本 / 筛选 / 搜索变化才重新分组，结果缓存进 @State，body 不现算
        .onChange(of: cacheKey, initial: true) { _, _ in recompute() }
    }

    // MARK: 批次渲染（图库同款）

    /// 触底提示 + 追加触发器。用 onAppear 而不是监听滚动偏移：
    /// LazyVStack 提前一点点实例化它，正好在"快到边界"时把下一批接上，滚起来是连贯的
    private var loadMoreFooter: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("正在加载更多素材…")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .onAppear { loadMore() }
    }

    private func loadMore() {
        guard hasMoreMonths, !growing else { return }
        growing = true
        Task { @MainActor in
            // 稍等一下再追加：新一批会实例化几十个 cell，正在滚动的当帧直接加会掉帧
            try? await Task.sleep(nanoseconds: 120_000_000)
            monthLimit = min(sections.count, monthLimit + batchSize)
            growing = false
        }
    }

    /// 让指定月份进入已渲染范围（点刻度尺跳到远处时用）
    private func ensureRendered(_ monthID: String) {
        guard let idx = sections.firstIndex(where: { $0.id == monthID }) else { return }
        if idx + 1 > monthLimit {
            monthLimit = min(sections.count, idx + 1 + batchSize)
        }
    }

    /// 重新筛选 + 分组并退回第一批（图库 restore 同款：换集合就从头铺）
    private func recompute() {
        let pool = Self.filtered(appModel.assets, search: searchText, filter: filter)
        sections = Self.group(pool)
        undatedAssets = pool.filter { $0.recordedAt == nil }
        monthLimit = min(batchSize, sections.count)
        if let first = sections.first {
            scrolledMonthID = first.id
            activeMonthID = first.id
        }
    }

    /// 定位到指定月份。批次刚补上时目标 cell 往往还没实体化，
    /// 单次 scrollTo 会落空，所以多补几次保证最终停在正确位置（图库同款）
    private func jump(_ proxy: ScrollViewProxy, to id: String) {
        proxy.scrollTo(id, anchor: .top)
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { proxy.scrollTo(id, anchor: .top) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { proxy.scrollTo(id, anchor: .top) }
    }


    // MARK: 分组渲染

    private func monthHeader(_ m: PoolMonth) -> some View {
        HStack(spacing: 6) {
            Text(m.title).font(.system(size: 12, weight: .semibold))
            Text("\(m.count) 个 · \(Self.humanDuration(m.seconds))")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
            Spacer()
        }
        .padding(.vertical, 4)
        .background(Theme.panel)
    }

    private func dayRow(_ day: PoolDay) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(day.title).font(.system(size: 11, weight: .semibold))
                Text("\(day.items.count) 个").font(.system(size: 9)).foregroundStyle(Theme.tertiary)
                Spacer()
            }
            LazyVGrid(columns: Self.columns, spacing: 10) {
                ForEach(day.items) { asset in
                    poolCell(asset)
                }
            }
        }
    }

    private func poolCell(_ asset: Asset) -> some View {
        let url = URL(fileURLWithPath: asset.playbackPath ?? asset.filePath)
        let ref = SourcePreviewRef(url: url, name: asset.fileName, isPlayable: asset.playbackPath != nil)
        return PoolCell(asset: asset, isPreviewing: model.sourcePreview == ref) {
            // 单击 = 在主预览区预览（再点同卡片退出），不碰时间线
            model.sourcePreview = model.sourcePreview == ref ? nil : ref
        } onAdd: {
            Task { await model.importVaultAssets([asset]) }
        }
    }

    // MARK: 分组计算（格式化器建一次，别在分组循环里反复 new）

    /// 卡片尺寸恒定（宽 110–150pt）：拉宽素材栏 → 列数增加，卡片本身不跟着拉伸
    private static let columns = [GridItem(.adaptive(minimum: 110, maximum: 150), spacing: 8)]

    private static func filtered(_ assets: [Asset], search: String, filter: PoolFilter) -> [Asset] {
        var list = assets
        if !search.isEmpty {
            let q = search.lowercased()
            list = list.filter {
                $0.fileName.lowercased().contains(q)
                || ($0.placeName?.lowercased().contains(q) ?? false)
            }
        }
        switch filter {
        case .all: break
        case .video: list = list.filter { $0.kind == .video }
        case .photo: list = list.filter { $0.kind == .photo }
        case .live: list = list.filter { $0.kind == .livePhoto }
        case .favorite: list = list.filter { $0.isFavorite }
        }
        return list
    }

    private static let monthID = Self.makeFormatter("yyyy-MM")
    private static let dayID = Self.makeFormatter("yyyy-MM-dd")
    private static let monthTitle = Self.makeFormatter("yyyy年M月")
    private static let dayTitle: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 EEEE"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        return f
    }

    /// 按月分组，返回时最新月份在前；isFirstOfYear 用于刻度尺上标年份
    private static func group(_ assets: [Asset]) -> [PoolMonth] {
        let cal = Calendar.current
        let dated = assets.compactMap { asset -> (Asset, Date)? in
            guard let t = asset.recordedAt else { return nil }
            return (asset, t)
        }
        guard !dated.isEmpty else { return [] }
        let byMonth = Dictionary(grouping: dated) { monthID.string(from: $0.1) }
        var result: [PoolMonth] = []
        var seenYears = Set<Int>()
        for key in byMonth.keys.sorted() {
            guard let pairs = byMonth[key], let sample = pairs.first?.1 else { continue }
            let year = cal.component(.year, from: sample)
            let isFirstOfYear = !seenYears.contains(year)
            seenYears.insert(year)
            let byDay = Dictionary(grouping: pairs) { dayID.string(from: $0.1) }
            let days = byDay.keys.sorted().map { dayKey in
                let items = (byDay[dayKey] ?? []).map(\.0)
                    .sorted { ($0.recordedAt ?? .distantPast) < ($1.recordedAt ?? .distantPast) }
                return PoolDay(id: dayKey,
                               title: dayTitle.string(from: items.first?.recordedAt ?? sample),
                               items: items)
            }
            result.append(PoolMonth(
                id: key,
                title: monthTitle.string(from: sample),
                year: year,
                month: cal.component(.month, from: sample),
                isFirstOfYear: isFirstOfYear,
                days: days,
                count: pairs.count
            ))
        }
        return result.reversed()
    }

    static func humanDuration(_ s: Double) -> String {
        let t = Int(max(s, 0).rounded())
        let m = (t % 3600) / 60, sec = t % 60
        if m > 0 { return "\(m) 分 \(sec) 秒" }
        return "\(sec) 秒"
    }
}

private enum PoolFilter: String, CaseIterable {
    case all, video, photo, live, favorite

    var title: String {
        switch self {
        case .all: "全部"
        case .video: "视频"
        case .photo: "照片"
        case .live: "实况"
        case .favorite: "收藏"
        }
    }
}

/// 一个月的分组
private struct PoolMonth: Identifiable {
    let id: String        // "2026-05"
    let title: String     // "2026年5月"
    let year: Int         // 刻度尺上首月标年份
    let month: Int        // 刻度尺标签
    let isFirstOfYear: Bool
    let days: [PoolDay]
    let count: Int
    var seconds: Double { days.reduce(0) { $0 + $1.items.reduce(0) { $0 + $1.durationSeconds } } }
}

// MARK: 刻度尺（图库 RulerStrip 同款移植）

/// 时间刻度尺：横向一排月份柱（高度 = 该月素材数占比，年份标在首月上方、跨年有分隔线），
/// 点一下跳到该月，**滚轮 / 触控板横滑左右平移**，底部细进度条指明还能往哪边滚。
///
/// 不用横向 `ScrollView`（图库踩过的坑）：SwiftUI 横向 ScrollView 不认鼠标滚轮
/// （事件穿透到下面的纵向列表），且 scrollTo 在两端不夹取、内容会钻出边界。
/// 位置完全由 offset 控制，`clamped()` 是唯一的边界来源。
private struct PoolRulerStrip: View {
    let months: [PoolMonth]
    let activeMonthID: String?
    let onPick: (String) -> Void

    /// 内容横向偏移，取值恒在 [visible - content, 0]
    @State private var offset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var visibleWidth: CGFloat = 0
    /// 每个月份刻度在**内容坐标系**里的位置，用来把当前月滚进可视区
    /// （不靠"38pt 一列 + 分隔线"推算，实测坐标永远不会算错）
    @State private var tickRects: [String: CGRect] = [:]
    /// 上一次自动跟随过的月份，同一个月份不重复动
    @State private var followedID: String?
    /// 首次布局已完成。首次不自动跟随，否则正序标尺会被拉到最新月（最右端），
    /// 把最早的 2025 挤出可视区，看起来像方向没改
    @State private var didInitialLayout = false

    private let tickWidth: CGFloat = 38
    private let spacing: CGFloat = 3
    private let sideInset: CGFloat = 14
    private static let height: CGFloat = 74
    private static let space = "poolRulerContent"

    private var peak: Double { Double(months.map(\.count).max() ?? 1) }
    private var scrollable: Bool { contentWidth > visibleWidth + 0.5 }

    var body: some View {
        GeometryReader { geo in
            let visible = geo.size.width
            content
                .offset(x: offset)
                // 先给内容套一层"可视区大小"的框再裁掉溢出部分：
                // 框的坐标原点就是可视区左边缘，offset 为 0 时正好贴着左边
                .frame(width: visible, height: geo.size.height, alignment: .leading)
                .clipped()
                .overlay(alignment: .bottom) { scrollIndicator(visible: visible) }
                // 滚轮 → 横向位移，夹取只在这里发生
                .overlay {
                    RulerWheelRelay { delta in
                        offset = clamped(offset + delta, visible: visible)
                    }
                }
                .onAppear {
                    visibleWidth = visible
                    offset = clamped(offset, visible: visible)
                }
                .onChange(of: visible) { _, w in
                    visibleWidth = w
                    offset = clamped(offset, visible: w)
                }
                .onPreferenceChange(PoolRulerContentWidthKey.self) { width in
                    guard width > 0 else { return }
                    contentWidth = width
                    offset = clamped(offset, visible: visible)
                }
                .onPreferenceChange(PoolRulerTickRectsKey.self) { rects in
                    guard !rects.isEmpty else { return }
                    tickRects = rects
                    // 首次布局停在 offset 0（内容最左＝最早月 2025），让用户一眼看到
                    // 「2025 在左、2026 在右」；之后窗口尺寸/数据变化才继续跟随
                    guard didInitialLayout else {
                        didInitialLayout = true
                        return
                    }
                    followActive(animated: false)
                }
                .onChange(of: activeMonthID) { _, _ in followActive(animated: true) }
        }
        .frame(height: Self.height)
        .background(Theme.panel)
    }

    // MARK: 内容

    private var content: some View {
        // 刻度尺按时间正序（旧→新，左→右）排布：2025 在左、2026 在右，
        // 每月也是 1 月→12 月递增——符合"时间轴越往右越新"的直觉。
        // sections 本身是最新在前的倒序（供素材列表用），这里单独反一下只影响标尺显示，
        // 不影响列表与跳转（跳转按 id 定位，与顺序无关）。
        let ordered = Array(months.reversed())
        return HStack(alignment: .bottom, spacing: spacing) {
            ForEach(Array(ordered.enumerated()), id: \.element.id) { index, month in
                // 跨年份插一条细分隔线作方位参考。年份**不占独立刻度位**，
                // 否则 1 月会被年份标签顶掉（显示成 "2026"，看着像统计漏了）
                if index > 0, ordered[index - 1].year != month.year {
                    yearDivider
                }
                monthTick(month: month,
                          isYearStart: index == 0 || ordered[index - 1].year != month.year)
            }
        }
        .padding(.horizontal, sideInset)
        .padding(.top, 6)
        .padding(.bottom, 8)
        // 宽度由内容自己决定，不受外层可视区大小影响，否则列数一多就被压缩
        .fixedSize()
        .coordinateSpace(name: Self.space)
        .background(
            GeometryReader { inner in
                Color.clear.preference(key: PoolRulerContentWidthKey.self, value: inner.size.width)
            }
        )
    }

    /// 跨年份的分隔线：只是一条细线，不占月份刻度位
    private var yearDivider: some View {
        Rectangle()
            .fill(Theme.tertiary.opacity(0.35))
            .frame(width: 1, height: 40)
            .padding(.horizontal, 3)
    }

    /// 刻度尺上的月份柱：柱高 = 该月素材数占比，标签固定 "N月"
    private func monthTick(month: PoolMonth, isYearStart: Bool) -> some View {
        Button {
            onPick(month.id)
        } label: {
            VStack(spacing: 2) {
                // 年份行：每年首月在自己这一列的**上方**标出年份，其余月份留等高占位，
                // 保证所有年份标签在同一条水平线上、柱子底部对齐
                yearRow(month: month, isYearStart: isYearStart)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(month.id == activeMonthID ? Theme.accent : Theme.accent.opacity(0.28))
                    // 柱子区域固定高度 + 底部对齐：月份高低不同也不会把年份顶得歪歪扭扭
                    .frame(height: max(3, CGFloat(Double(month.count) / max(peak, 1)) * 24))
                    .frame(height: 24, alignment: .bottom)
                Text("\(month.month)月")
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .foregroundStyle(month.id == activeMonthID ? Theme.text : Theme.secondary)
            }
            .frame(width: tickWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(month.title) · \(month.count) 个素材")
        .background(
            GeometryReader { g in
                Color.clear.preference(
                    key: PoolRulerTickRectsKey.self,
                    value: [month.id: g.frame(in: .named(Self.space))]
                )
            }
        )
    }

    /// 年份标签：贴在该年首月的左上角；非首月用等高空视图占位
    @ViewBuilder
    private func yearRow(month: PoolMonth, isYearStart: Bool) -> some View {
        if isYearStart {
            Text("\(month.year)")
                .font(.system(size: 10, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(month.id == activeMonthID ? Theme.text : Theme.secondary)
                .frame(width: tickWidth, alignment: .leading)
                .frame(height: 14, alignment: .bottom)
        } else {
            Color.clear.frame(width: tickWidth, height: 14)
        }
    }

    // MARK: 位置

    /// 唯一的边界来源：内容比可视区短就贴左（offset 只能是 0），
    /// 长了就夹在 [visible - content, 0]——两边都滚不到头以外的地方
    private func clamped(_ value: CGFloat, visible: CGFloat) -> CGFloat {
        guard visible > 0, contentWidth > visible else { return 0 }
        return min(0, max(value, visible - contentWidth))
    }

    /// 把当前月带进可视区。只在它真的出界时才动，尽量不打扰用户手动滚到的位置
    private func followActive(animated: Bool) {
        guard let id = activeMonthID, id != followedID else { return }
        guard let rect = tickRects[id], visibleWidth > 0 else { return }
        followedID = id

        let margin: CGFloat = 16
        let left = rect.minX + offset
        let right = rect.maxX + offset
        var target = offset
        if left < margin {
            target = offset + (margin - left)
        } else if right > visibleWidth - margin {
            target = offset - (right - (visibleWidth - margin))
        }
        target = clamped(target, visible: visibleWidth)
        guard abs(target - offset) > 0.5 else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { offset = target }
        } else {
            offset = target
        }
    }

    /// 底部一条细进度条：内容比可视区宽时才出现，明确告诉用户"还能往哪边滚"
    @ViewBuilder
    private func scrollIndicator(visible: CGFloat) -> some View {
        if scrollable, visible > 0 {
            let barWidth = max(28, visible * visible / contentWidth)
            let minOffset = visible - contentWidth
            let progress = minOffset < 0 ? min(1, max(0, offset / minOffset)) : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.tertiary.opacity(0.5))
                    .frame(width: barWidth, height: 2)
                    .offset(x: (visible - barWidth) * progress)
            }
            .frame(width: visible, alignment: .leading)
            .padding(.bottom, 1)
            .allowsHitTesting(false)
        }
    }
}

/// 刻度尺内容总宽度
private struct PoolRulerContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 每个月刻度在内容坐标系里的位置
private struct PoolRulerTickRectsKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 一天的分组
private struct PoolDay: Identifiable {
    let id: String        // "2026-05-12"
    let title: String     // "5月12日 星期一"
    let items: [Asset]
}

/// 资源池卡片：**纯选择**——缩略图 / 悬停静音预览 / LIVE / 时长 / 文件名，
/// 不带评分、收藏等管理功能，也不做多选。
/// 单击在主预览区预览该素材（再点退出）；入轨只有拖拽、+ 按钮、右键三个入口。
private struct PoolCell: View {
    let asset: Asset
    /// 该素材是否正显示在主预览区（用于高亮）
    let isPreviewing: Bool
    let onPreview: () -> Void
    let onAdd: () -> Void

    @State private var hovering = false
    @State private var previewOn = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var thumb: NSImage?
    /// 缩略图属于哪条素材：LazyVGrid 复用 cell，防止旧图贴到别的素材上
    @State private var loadedID: Int64?

    private var durationText: String {
        guard asset.kind.isPlayable, asset.durationSeconds > 0 else { return "" }
        return AssetCell.durationText(asset.durationSeconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            mediaArea
            Text(asset.fileName)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(isPreviewing ? Theme.accent : (hovering ? Theme.accent.opacity(0.6) : .clear),
                    lineWidth: isPreviewing ? 2 : 1))
        // 命中区域铺满整张卡：画面骨架是 Color.clear，
        // 不加 contentShape 的话缩略图周围的留白点上去没有任何反应
        .contentShape(Rectangle())
        .onHover { h in
            hovering = h
            hoverTask?.cancel()
            if h {
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
        // 单击 = 主预览区预览（不入轨）；入轨只走拖拽、+ 按钮、右键
        .onTapGesture(perform: onPreview)
        .draggable(URL(fileURLWithPath: asset.filePath))
        .help(asset.fileName)
        .contextMenu {
            Button("添加到时间线末尾") { onAdd() }
        }
        // cell 被复用到另一条素材时先清旧图，等真正滚进可视区再取
        .task(id: asset.id) {
            thumb = nil
            loadedID = nil
            previewOn = false
            hoverTask?.cancel()
        }
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            if visible { loadThumbIfNeeded() }
        }
    }

    // MARK: 画面区

    private var mediaArea: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear
                .overlay {
                    ZStack {
                        if let thumb {
                            Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(Theme.raised)
                                .overlay {
                                    Image(systemName: asset.kind == .photo ? "photo" : "film")
                                        .font(.system(size: 20))
                                        .foregroundStyle(Theme.tertiary)
                                }
                        }
                        // 悬停预览：视频 / 实况照片播动态部分，静音循环
                        if previewOn, let playPath = asset.playbackPath {
                            HoverPreviewPlayer(url: URL(fileURLWithPath: playPath))
                        }
                    }
                }
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipped()
            if !durationText.isEmpty {
                VaultBadge { Text(durationText) }
                    .padding(5)
            }
        }
        .overlay(alignment: .topLeading) {
            if asset.kind == .livePhoto {
                LiveBadge(compact: true)
                    .padding(4)
            } else if previewOn, asset.kind.isPlayable {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .padding(5)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if hovering {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(Theme.accent, in: Circle())
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                }
                .buttonStyle(.plain)
                .help("追加到时间线末尾")
                .padding(5)
            }
        }
    }

    private func loadThumbIfNeeded() {
        guard loadedID != asset.id else { return }
        if let cached = ThumbnailStore.shared.cachedThumbnail(for: asset) {
            loadedID = asset.id
            thumb = cached
            return
        }
        let target = asset
        Task { @MainActor in
            let loaded = await ThumbnailStore.shared.thumbnail(for: target)
            guard !Task.isCancelled else { return }
            loadedID = target.id
            thumb = loaded
        }
    }
}

enum AssetDrag {
    static let prefix = "framecut-asset:"
    static func assetID(_ s: String) -> UUID? {
        guard s.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(s.dropFirst(prefix.count)))
    }
}

// MARK: - 音频

private struct AudioTab: View {
    @Bindable var model: EditorModel

    private var audioAssets: [MediaAsset] { model.project.assets.filter { $0.kind == .audio } }

    var body: some View {
        VStack(spacing: 10) {
            Button {
                model.importPanel(addToTimeline: false, audioOnly: true)
            } label: {
                Label("导入音频", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(PanelButtonStyle(prominent: true))
            RecordButton(model: model)
            if audioAssets.isEmpty {
                Spacer()
                Text("导入本地音频文件（mp3 / m4a / wav）\n作为配乐、旁白或音效\n时间重叠的音频会自动放到新的音频轨").multilineTextAlignment(.center).foregroundStyle(Theme.tertiary)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(audioAssets) { asset in
                            HStack(spacing: 10) {
                                Image(systemName: "music.note")
                                    .frame(width: 32, height: 32)
                                    .background(Theme.musicClip, in: RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(asset.name).font(.system(size: 12)).lineLimit(1)
                                    Text(asset.duration.displayString).font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.tertiary)
                                }
                                Spacer()
                                Button {
                                    let at = model.playhead
                                    model.store.perform { _ = $0.addMusic(assetID: asset.id, at: at) }
                                } label: {
                                    Image(systemName: "plus.circle.fill").font(.system(size: 18)).foregroundStyle(Theme.accent)
                                }
                                .buttonStyle(.plain)
                                .help("添加到播放头位置")
                            }
                            .padding(8)
                            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
                            .contextMenu {
                                Button("从素材库删除", role: .destructive) { model.removeAsset(asset) }
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .foregroundStyle(Theme.text)
    }
}

// MARK: - 转场

private struct TransitionTab: View {
    @Bindable var model: EditorModel
    @State private var duration = 0.5

    /// 当前要设置转场的交界：选中转场，或选中的片段（与前一片段之间）。
    private var targetClipID: UUID? {
        switch model.selection {
        case .transition(let id): return id
        case .video(let id):
            guard let i = model.project.mainTrack.firstIndex(where: { $0.id == id }), i > 0 else { return nil }
            return id
        default: return nil
        }
    }

    private var currentKind: TransitionKind? {
        targetClipID.flatMap { model.project.transitions[$0]?.kind }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(targetClipID == nil ? "在时间线上点击两个片段之间的 ◇ 选择位置" : "点击应用到所选位置")
                .font(.system(size: 11))
                .foregroundStyle(targetClipID == nil ? Theme.tertiary : Theme.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 8)], spacing: 8) {
                    tile(nil)
                    ForEach(TransitionKind.allCases, id: \.self) { tile($0) }
                }
            }
            LabeledSlider(title: "时长", value: $duration, range: 0.2...2, format: { String(format: String(localized: "%.1f 秒"), $0) })
            Button {
                model.store.perform { $0.applyTransitionToAll(FCCore.Transition(kind: currentKind ?? .dissolve, duration: Time(seconds: duration))) }
            } label: {
                Text("应用到全部（\(currentKind?.displayName ?? TransitionKind.dissolve.displayName)）").frame(maxWidth: .infinity)
            }
            .buttonStyle(PanelButtonStyle())
            .disabled(model.project.mainTrack.count < 2)
        }
        .padding(10)
    }

    private func tile(_ kind: TransitionKind?) -> some View {
        let selected = targetClipID != nil && currentKind == kind
        return Button {
            guard let id = targetClipID else { return }
            model.store.perform { $0.setTransition(kind.map { FCCore.Transition(kind: $0, duration: Time(seconds: duration)) }, before: id) }
            model.selection = .transition(id)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: kind.map(Self.icon) ?? "nosign")
                    .font(.system(size: 20))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Theme.accent : .clear, lineWidth: 2))
                Text(kind?.displayName ?? String(localized: "无")).font(.system(size: 11))
            }
            .foregroundStyle(targetClipID == nil ? Theme.tertiary : Theme.text)
        }
        .buttonStyle(.plain)
    }

    static func icon(_ kind: TransitionKind) -> String {
        switch kind {
        case .dissolve: "circle.lefthalf.filled"
        case .fadeBlack: "moon.fill"
        case .fadeWhite: "sun.max.fill"
        case .pushLeft: "arrow.left.square"
        case .pushRight: "arrow.right.square"
        case .pushUp: "arrow.up.square"
        case .pushDown: "arrow.down.square"
        case .slideLeft: "rectangle.righthalf.inset.filled.arrow.right"
        case .wipeLeft: "rectangle.split.2x1"
        case .zoom: "plus.magnifyingglass"
        case .blur: "drop.halffull"
        }
    }
}

// MARK: - 滤镜

private struct FilterTab: View {
    @Bindable var model: EditorModel
    @State private var source: CGImage?
    @State private var previews: [FilterPreset: CGImage] = [:]
    @State private var lutPreviews: [UUID: CGImage] = [:]
    @State private var luts: [UserLUTRef] = UserLUTLibrary.shared.all
    @State private var presets: [GradePreset] = GradePresets.store.presets
    @State private var presetPreviews: [UUID: CGImage] = [:]

    private var clip: VideoClip? { model.selectedClip }
    private var sampleClip: VideoClip? { clip ?? model.project.mainTrack.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(clip == nil ? "先在时间线上选中一个片段" : "点击应用到所选片段")
                .font(.system(size: 11))
                .foregroundStyle(clip == nil ? Theme.tertiary : Theme.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 8)], spacing: 10) {
                        ForEach(FilterPreset.allCases, id: \.self) { preset in
                            tile(preset.displayName, image: previews[preset],
                                 selected: clip?.filter.lut == nil && clip?.filter.preset == preset) {
                                apply { $0.selectPreset(preset) }
                            }
                        }
                    }
                    HStack {
                        SectionTitle("我的预设")
                        Spacer()
                        Button("保存当前调色…") { savePreset() }
                            .buttonStyle(.plain).font(.system(size: 11))
                            .foregroundStyle(canSavePreset ? Theme.accent : Theme.tertiary)
                            .disabled(!canSavePreset)
                            .help("把所选片段的风格、调节、HSL 和效果存为预设，所有工程通用")
                    }
                    if presets.isEmpty {
                        Text("调好一个片段后点「保存当前调色」，下次一键套用。")
                            .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 8)], spacing: 10) {
                            ForEach(presets) { preset in
                                tile(preset.name, image: presetPreviews[preset.id], selected: clip?.filter == preset.filter) {
                                    apply { $0 = preset.filter }
                                }
                                .contextMenu {
                                    Button("重命名…") { renamePreset(preset) }
                                    Button("删除预设", role: .destructive) {
                                        try? GradePresets.store.delete(preset.id)
                                        presets = GradePresets.store.presets
                                    }
                                }
                            }
                        }
                    }
                    HStack {
                        SectionTitle("我的 LUT")
                        Spacer()
                        Button("导入 .cube…") { importLUT() }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
                    }
                    if luts.isEmpty {
                        Text("导入相机厂商或网上下载的 .cube 调色文件，所有工程通用。")
                            .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 8)], spacing: 10) {
                            ForEach(luts, id: \.id) { lut in
                                tile(lut.name, image: lutPreviews[lut.id], selected: clip?.filter.lut?.id == lut.id) {
                                    apply { $0.selectLUT(lut) }
                                }
                                .contextMenu {
                                    Button("从 LUT 库删除", role: .destructive) {
                                        UserLUTLibrary.shared.remove(lut.id)
                                        luts = UserLUTLibrary.shared.all
                                        model.scheduleRebuild()
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if let clip {
                LabeledSlider(title: "强度", value: model.clipBinding(clip.id, \.filter.intensity, default: 1), range: 0...1,
                              onEditing: model.coalesce)
                Button {
                    model.store.perform { $0.applyFilterToAll(clip.filter) }
                } label: {
                    Text("应用到全部片段").frame(maxWidth: .infinity)
                }
                .buttonStyle(PanelButtonStyle())
            }
        }
        .padding(10)
        .task(id: sampleClip?.id) { await loadPreviews() }
    }

    private func apply(_ change: @escaping (inout FilterSettings) -> Void) {
        guard let id = clip?.id else { return }
        model.store.perform { $0.updateMain(id: id) { change(&$0.filter) } }
    }

    private func tile(_ title: String, image: CGImage?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Rectangle().fill(Theme.raised)
                    .aspectRatio(1.4, contentMode: .fit)
                    .overlay {
                        if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Theme.accent : .clear, lineWidth: 2))
                Text(title).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(clip == nil ? Theme.tertiary : Theme.text)
        }
        .buttonStyle(.plain)
    }

    private var canSavePreset: Bool { !(clip?.filter.isIdentity ?? true) }

    private func askName(title: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = initial
        field.placeholderString = String(localized: "例如：海边清透、夜景电影感")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "保存"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func savePreset() {
        guard let filter = clip?.filter, let name = askName(title: String(localized: "保存调色预设"), initial: "") else { return }
        do {
            try GradePresets.store.save(name: name, filter: filter)
        } catch {
            model.errorMessage = String(localized: "预设保存失败：\(error.localizedDescription)")
        }
        presets = GradePresets.store.presets
        Task { await loadPreviews() }
    }

    private func renamePreset(_ preset: GradePreset) {
        guard let name = askName(title: String(localized: "重命名预设"), initial: preset.name) else { return }
        try? GradePresets.store.rename(preset.id, to: name)
        presets = GradePresets.store.presets
    }

    private func importLUT() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        guard panel.runModal() == .OK else { return }
        var failed: [String] = []
        var last: UserLUTRef?
        for url in panel.urls {
            do { last = try UserLUTLibrary.shared.importFile(url) } catch {
                failed.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        luts = UserLUTLibrary.shared.all
        if let last, clip != nil { apply { $0.selectLUT(last) } }
        if !failed.isEmpty { model.errorMessage = String(localized: "以下 LUT 无法导入：\n") + failed.joined(separator: "\n") }
        Task { await loadPreviews() }
    }

    private func loadPreviews() async {
        guard let clip = sampleClip, let asset = model.project.asset(id: clip.assetID) else {
            previews = [:]
            return
        }
        guard let base = await Thumbnails.shared.thumbnail(url: asset.url, time: clip.sourceIn + clip.sourceDuration / 2, maxHeight: 80, hdr: asset.hdr) else { return }
        var result: [FilterPreset: CGImage] = [:]
        for preset in FilterPreset.allCases {
            result[preset] = preset == .none ? base : FilterPreview.render(base, preset: preset)
        }
        previews = result
        var lutResult: [UUID: CGImage] = [:]
        for lut in UserLUTLibrary.shared.all {
            lutResult[lut.id] = FilterPreview.render(base, lut: lut)
        }
        lutPreviews = lutResult
        var presetResult: [UUID: CGImage] = [:]
        for preset in GradePresets.store.presets {
            presetResult[preset.id] = FilterPreview.render(base, settings: preset.filter)
        }
        presetPreviews = presetResult
    }
}
