import SwiftUI

/// 图库页：按拍摄时间分组的时间轴，顶部统一显示总量统计。
/// 智能相册 / 拍摄地 / 导入来源等筛选结果也复用这一页，标题与数量随之变化。
struct LibraryView: View {
    var title: String = "图库"
    let assets: [Asset]
    /// 素材集合版本。分组、排序、统计都是 O(n log n)，放在 body 里会被
    /// 每次重绘重算（8000 条时一次就是几十毫秒），改成按版本缓存
    var version: UInt64 = 0
    @Binding var selectedAssetID: Int64?
    var onRate: (Int64, Int) -> Void = { _, _ in }
    var onDelete: ((Int64) -> Void)?
    var onToggleFavorite: ((Int64) -> Void)?
    /// 卡片滚进可视区时回调，用于按需生成缩略图
    var onVisible: ((Int64) -> Void)?
    /// 只有「补定位」页才提供批量补定位入口，其他页面不放这个按钮
    var isLocationPage = false
    /// 批量补定位：把**用户勾选**的那些素材交给调用方
    var onAssignLocation: (([Asset]) -> Void)?
    /// 多选后的批量操作：普通页是「移入回收站」，由调用方决定具体动作
    var onDeleteSelected: (([Asset]) -> Void)?
    var emptyHint: String?

    /// 「补定位」页的多选状态。素材补完后会从本页消失，勾选集合跟着清理
    @State private var selectionMode = false
    @State private var checkedIDs: Set<Int64> = []

    @State private var sections: [TimelineMonth] = []
    @State private var undated: [Asset] = []
    @State private var summaryText = ""

    /// 版本 + 数量 + 首条 id：切换筛选时 version 不变但内容变了，也要触发重算
    private var cacheKey: String {
        "\(version)|\(assets.count)|\(assets.first?.id ?? -1)"
    }

    /// 滚动位置的记忆键：图库 / 各相册 / 各来源各记一份，互不干扰
    private var scrollAnchorKey: String { "timeline.scroll.\(title)" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onChange(of: cacheKey, initial: true) { _, _ in recompute() }
        // 切到别的集合时清掉多选，避免勾选状态被 SwiftUI 复用带到其他页面
        .onChange(of: title) { _, _ in
            selectionMode = false
            checkedIDs.removeAll()
        }
    }

    private func recompute() {
        let built = buildSections()
        sections = built
        undated = assets.filter { $0.recordedAt == nil }
        summaryText = makeSummary()
        // 补完定位的素材已经从这一页消失，勾选集合同步收敛，不会越攒越多
        let valid = Set(assets.compactMap(\.id))
        checkedIDs.formIntersection(valid)
    }

    // MARK: - 顶部：标题 + 总量统计 + 视图切换

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2).bold()
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(summaryText)
            }
            Spacer(minLength: 0)

            // 多选入口每个页面都有：先「选择」进入多选，勾完再批量处理。
            // 批量动作因页而异——补定位页是「补定位」，普通页是「移入回收站」
            if !assets.isEmpty {
                selectionToolbar
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func toggleCheck(_ id: Int64) {
        if checkedIDs.contains(id) {
            checkedIDs.remove(id)
        } else {
            checkedIDs.insert(id)
        }
    }

    @ViewBuilder
    private var selectionToolbar: some View {
        Button(selectionMode ? "完成" : "选择") {
            selectionMode.toggle()
            if !selectionMode { checkedIDs.removeAll() }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(selectionMode ? "退出多选" : "进入多选，勾选要处理的素材")

        if selectionMode {
            Button(checkedIDs.count == assets.count ? "取消全选" : "全选") {
                if checkedIDs.count == assets.count {
                    checkedIDs.removeAll()
                } else {
                    checkedIDs = Set(assets.compactMap(\.id))
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            Text("已选 \(checkedIDs.count) / \(assets.count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            // 主操作：补定位页额外有「补定位」，所有页面都有「移入回收站」
            if isLocationPage, let onAssign = onAssignLocation {
                Button {
                    let picked = assets.filter { checkedIDs.contains($0.id ?? -1) }
                    guard !picked.isEmpty else { return }
                    onAssign(picked)
                } label: {
                    Label("补定位 已选 \(checkedIDs.count)", systemImage: "mappin.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(checkedIDs.isEmpty)
                .help("只给勾中的 \(checkedIDs.count) 个素材标同一个位置")
            }
            if let onDeleteSelected {
                Button {
                    let picked = assets.filter { checkedIDs.contains($0.id ?? -1) }
                    guard !picked.isEmpty else { return }
                    onDeleteSelected(picked)
                } label: {
                    Label("移入回收站 已选 \(checkedIDs.count)", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(checkedIDs.isEmpty)
                .help("把勾中的 \(checkedIDs.count) 个素材移入回收站")
            }
        }
    }

    /// 数量 + 时间跨度 + 总时长，一行说清楚当前集合有多大
    private func makeSummary() -> String {
        let seconds = assets.reduce(0) { $0 + $1.durationSeconds }
        var parts = ["\(assets.count) 个素材"]
        let span = spanText
        if span != "暂无时间信息" { parts.append(span) }
        parts.append("总时长 \(Self.humanDuration(seconds))")
        return parts.joined(separator: " · ")
    }

    private var spanText: String {
        // 只要最小值和最大值，不需要排序（原来 sort 一遍 8000 个 Date 纯属浪费）
        var min: Date?
        var max: Date?
        for a in assets {
            guard let t = a.recordedAt else { continue }
            if min == nil || t < min! { min = t }
            if max == nil || t > max! { max = t }
        }
        guard let first = min, let last = max else { return "暂无时间信息" }
        let fmt = Self.isoFormatter
        let a = fmt.string(from: first), b = fmt.string(from: last)
        return a == b ? a : "\(a) – \(b)"
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        if assets.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "film.stack").font(.largeTitle).foregroundStyle(.secondary)
                Text(emptyHint ?? "还没有素材").font(.title3)
                if emptyHint == nil {
                    Text("点击右上角导入文件夹开始建库").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            timelineContent
        }
    }

    @ViewBuilder
    private var timelineContent: some View {
        // 分组结果缓存在 @State 里，不在这里现算
        let months = sections
        let noDate = undated

        if months.isEmpty && noDate.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "clock").font(.largeTitle).foregroundStyle(.secondary)
                Text("还没有带拍摄时间的素材").font(.title3)
                Text("导入后会在时间轴上按拍摄日期自动排布").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            TimelineScroller(months: months, undated: noDate,
                             anchorKey: scrollAnchorKey,
                             selectedAssetID: $selectedAssetID,
                             onRate: onRate, onDelete: onDelete,
                             onToggleFavorite: onToggleFavorite,
                             onVisible: onVisible,
                             selectionMode: selectionMode,
                             checkedIDs: checkedIDs,
                             onToggleCheck: toggleCheck)
        }
    }

    /// 固定时间正序：2026年 → 1月 → 2月 往后排
    private func buildSections() -> [TimelineMonth] {
        let cal = Calendar.current
        let dated = assets.compactMap { asset -> (Asset, Date)? in
            guard let t = asset.recordedAt else { return nil }
            return (asset, t)
        }
        guard !dated.isEmpty else { return [] }

        let byMonth = Dictionary(grouping: dated) { Self.monthID.string(from: $0.1) }
        var result: [TimelineMonth] = []
        result.reserveCapacity(byMonth.count)

        for (key, pairs) in byMonth {
            guard let sample = pairs.first?.1 else { continue }
            let byDay = Dictionary(grouping: pairs) { Self.dayID.string(from: $0.1) }
            let days = byDay.map { dayKey, dayPairs -> TimelineDay in
                let items = dayPairs.map(\.0)
                    .sorted { ($0.recordedAt ?? .distantPast) < ($1.recordedAt ?? .distantPast) }
                return TimelineDay(id: dayKey, title: Self.dayTitle.string(from: dayPairs[0].1), items: items)
            }
            .sorted { $0.id < $1.id }

            result.append(TimelineMonth(
                id: key,
                title: Self.monthTitle.string(from: sample),
                year: cal.component(.year, from: sample),
                month: cal.component(.month, from: sample),
                days: days,
                count: pairs.count,
                seconds: pairs.reduce(0) { $0 + $1.0.durationSeconds }
            ))
        }

        result.sort { $0.id < $1.id }
        return result
    }

    // MARK: - 复用的格式化器（DateFormatter 创建开销不小，别在分组循环里反复 new）

    private static let isoFormatter = makeFormatter("yyyy/M/d")
    private static let monthID = makeFormatter("yyyy-MM")
    private static let dayID = makeFormatter("yyyy-MM-dd")
    private static let monthTitle = makeFormatter("yyyy年M月")
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

    static func humanDuration(_ s: Double) -> String {
        let t = Int(max(s, 0).rounded())
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        if h > 0 { return "\(h) 时 \(m) 分" }
        if m > 0 { return "\(m) 分 \(sec) 秒" }
        return "\(sec) 秒"
    }
}

// MARK: - 时间轴的分组模型

/// 一天一组的素材
private struct TimelineDay: Identifiable {
    let id: String          // "2026-05-12"
    let title: String       // "5月12日 星期一"
    let items: [Asset]
    var seconds: Double { items.reduce(0) { $0 + $1.durationSeconds } }
}

/// 一个月的分区，含刻度尺标签与统计
private struct TimelineMonth: Identifiable {
    let id: String          // "2026-05"
    let title: String       // "2026年5月"
    let year: Int           // 刻度尺上插入年份标记用
    let month: Int          // 刻度尺标签："5月"
    let days: [TimelineDay]
    let count: Int
    let seconds: Double
}

/// 刻度尺 + 可滚动的分组列表。months 由外层算好传进来，这里不再重复计算
private struct TimelineScroller: View {
    let months: [TimelineMonth]
    let undated: [Asset]
    /// 滚动位置的记忆键。窗口宽度一变，按像素记的偏移就对不上了，
    /// 所以记的是**月份 id（日期）**而不是偏移量
    let anchorKey: String
    @Binding var selectedAssetID: Int64?
    var onRate: (Int64, Int) -> Void
    var onDelete: ((Int64) -> Void)?
    var onToggleFavorite: ((Int64) -> Void)?
    var onVisible: ((Int64) -> Void)?
    /// 「补定位」页多选：透传给卡片，选择模式下点卡片只勾选
    var selectionMode = false
    var checkedIDs: Set<Int64> = []
    var onToggleCheck: ((Int64) -> Void)?

    /// 与列表滚动位置双向绑定的原始值，滚动过程中可能短暂回写 nil
    @State private var scrolledMonthID: String?
    /// 实际用于高亮的月份，只接受非 nil，避免滚动时高亮闪烁
    @State private var activeMonthID: String?
    /// 已经为哪个 anchorKey 恢复过位置。切到别的集合时 anchorKey 变了，要重新恢复
    @State private var restoredKey = ""
    @State private var saveTask: Task<Void, Never>?

    /// 分批渲染：一次只铺这么几个月，滚到底部再追加下一批。
    /// 之前 27 个月一次性铺开：即便 LazyVStack 只实例化可视区的 cell，
    /// 每个月的 Section + 每天的 LazyVGrid 结构、加上 SwiftUI 的预取，
    /// 启动那一刻就会铺出好几屏卡片（实测 151 个 cell 全部发起了取图请求），
    /// 七千多条素材时会明显拖慢首屏和滚动。
    @State private var monthLimit = 3
    @State private var growing = false
    private let batchSize = 3

    private var hasMoreMonths: Bool { monthLimit < months.count }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ruler { id in
                    // 点的是一个还没铺开的月份时，先把批次补到它，否则 scrollTo 无处可去
                    ensureRendered(id)
                    // 重复点同一月也要重新定位：用户可能已经手动滚到别处了
                    scrolledMonthID = id
                    activeMonthID = id
                    jump(proxy, to: id)
                }
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                        ForEach(Array(months.prefix(monthLimit))) { month in
                            Section {
                                ForEach(month.days) { day in
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack(spacing: 6) {
                                            Text(day.title).font(.subheadline).bold()
                                            Text("\(day.items.count) 个 · \(LibraryView.humanDuration(day.seconds))")
                                                .font(.caption2).foregroundStyle(.secondary)
                                            Spacer()
                                        }
                                        AssetGridView(assets: day.items, selectedAssetID: $selectedAssetID,
                                                      onRate: onRate, onDelete: onDelete,
                                                      onToggleFavorite: onToggleFavorite,
                                                      onVisible: onVisible,
                                                      selectionMode: selectionMode,
                                                      checkedIDs: checkedIDs,
                                                      onToggleCheck: onToggleCheck,
                                                      embedded: true)
                                    }
                                }
                            } header: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(month.title).font(.title3).bold()
                                    Text("\(month.count) 个素材").font(.caption).foregroundStyle(.secondary)
                                    Text("时长 \(LibraryView.humanDuration(month.seconds))")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(.vertical, 6)
                                // 吸顶的 header 必须不透明，否则下面的卡片会透上来
                                .background(.background)
                                .id(month.id)
                            }
                        }

                        // 触底占位：它被实例化就说明快滚到底了，再追加下一批
                        if hasMoreMonths {
                            loadMoreFooter
                        }

                        if !undated.isEmpty && !hasMoreMonths {
                            Section {
                                AssetGridView(assets: undated, selectedAssetID: $selectedAssetID,
                                              onRate: onRate, onDelete: onDelete,
                                              onToggleFavorite: onToggleFavorite,
                                              onVisible: onVisible,
                                              selectionMode: selectionMode,
                                              checkedIDs: checkedIDs,
                                              onToggleCheck: onToggleCheck,
                                              embedded: true)
                            } header: {
                                HStack(spacing: 8) {
                                    Text("未知拍摄时间").font(.title3).bold()
                                    Text("\(undated.count) 个素材").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(.vertical, 6)
                                .background(.background)
                            }
                        }
                    }
                    .padding(16)
                }
                // 双向绑定：设置它 → 滚到该月；手动滚动 → 它自动更新（刻度尺高亮跟着走）
                .scrollPosition(id: $scrolledMonthID, anchor: .top)
                .onChange(of: scrolledMonthID) { _, newID in
                    if let newID { activeMonthID = newID }
                }
            }
            // 分组是外层算完才给过来的，可能比本视图晚一帧，所以几处都试。
            // anchorKey 变化（切到别的集合）也要重新恢复一次
            .onAppear { restore(proxy) }
            .onChange(of: anchorKey, initial: true) { _, _ in restore(proxy) }
            .onChange(of: months.count) { _, _ in restore(proxy) }
        }
        .onChange(of: activeMonthID) { _, newID in saveAnchor(newID) }
    }

    // MARK: - 分批渲染

    /// 触底提示 + 追加触发器。用 onAppear 而不是监听滚动偏移：
    /// LazyVStack 提前一点点实例化它，正好在"快到边界"时把下一批接上，滚起来是连贯的
    private var loadMoreFooter: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("正在加载更多素材…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .onAppear { loadMore() }
    }

    private func loadMore() {
        guard hasMoreMonths, !growing else { return }
        growing = true
        Task { @MainActor in
            // 稍等一下再追加：新一批会实例化几十个 cell，正在滚动的当帧直接加会掉帧
            try? await Task.sleep(nanoseconds: 120_000_000)
            monthLimit = min(months.count, monthLimit + batchSize)
            growing = false
        }
    }

    /// 让指定月份进入已渲染范围（点刻度尺跳到远处时用）
    private func ensureRendered(_ monthID: String) {
        guard let idx = months.firstIndex(where: { $0.id == monthID }) else { return }
        if idx + 1 > monthLimit {
            monthLimit = min(months.count, idx + 1 + batchSize)
        }
    }

    // MARK: - 滚动位置记忆

    /// 回到上次看到的月份。以月份（日期）为锚点，宽度变化也不会错位
    private func restore(_ proxy: ScrollViewProxy) {
        guard !months.isEmpty, restoredKey != anchorKey else { return }
        restoredKey = anchorKey
        // 换了集合（切相册 / 来源）就退回一批重新开始铺
        monthLimit = min(batchSize, months.count)
        guard let saved = UserDefaults.standard.string(forKey: anchorKey),
              let idx = months.firstIndex(where: { $0.id == saved }) else { return }
        // 目标月份还没渲染出来，scrollTo 会落空：先把批次补到它
        if idx + 1 > monthLimit {
            monthLimit = min(months.count, idx + 1 + batchSize)
        }
        scrolledMonthID = saved
        activeMonthID = saved
        jump(proxy, to: saved)
    }

    /// 滚动停下来才落盘，免得快速拖动时狂写 UserDefaults
    private func saveAnchor(_ id: String?) {
        saveTask?.cancel()
        let key = anchorKey
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            if let id {
                UserDefaults.standard.set(id, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// 定位到指定月份。
    /// LazyVStack 里第一帧目标 cell 往往还没实体化（刚补批次时更是如此），
    /// 单次 scrollTo 会落空，所以在下一帧、0.1s、0.25s 各补一次，最终一定停在正确位置。
    private func jump(_ proxy: ScrollViewProxy, to id: String) {
        proxy.scrollTo(id, anchor: .top)
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { proxy.scrollTo(id, anchor: .top) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { proxy.scrollTo(id, anchor: .top) }
    }

    private func ruler(onPick: @escaping (String) -> Void) -> some View {
        RulerStrip(months: months, activeMonthID: activeMonthID, onPick: onPick)
    }
}

// MARK: - 刻度尺

/// 时间刻度尺：横向一排月份柱，点一下跳到该月，滚轮左右平移。
///
/// 这里**不用 `ScrollView`**，位置是自己算的 `offset`：
/// 1. SwiftUI 横向 `ScrollView` + `scrollTo(anchor: .center)` 在两端不夹取，
///    内容会被推到边界之外——表现就是刻度尺左边钻到导航栏底下，
///    再往回滚又被手动滚动的夹取挡住，于是"滚不到头也滚不回来"；
/// 2. 滚轮又走另一套（直接改 `NSScrollView` 的 origin），两套状态互相覆盖。
/// 现在只有一个 offset 真相，`clamped()` 是唯一的边界来源，越界不可能发生。
private struct RulerStrip: View {
    let months: [TimelineMonth]
    let activeMonthID: String?
    let onPick: (String) -> Void

    /// 内容横向偏移，取值恒在 [visible - content, 0]
    @State private var offset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var visibleWidth: CGFloat = 0
    /// 每个月份刻度在**内容坐标系**里的位置。用来把当前月滚进可视区——
    /// 不想靠"38pt 一列 + 分隔线"去推算，实测坐标永远不会算错
    @State private var tickRects: [String: CGRect] = [:]
    /// 上一次自动跟随过的月份，同一个月份不重复动
    @State private var followedID: String?

    private let tickWidth: CGFloat = 38
    private let spacing: CGFloat = 3
    private let sideInset: CGFloat = 14
    private static let height: CGFloat = 74
    private static let space = "ruler-content"

    private var peak: Double { Double(months.map(\.count).max() ?? 1) }
    private var scrollable: Bool { contentWidth > visibleWidth + 0.5 }

    var body: some View {
        GeometryReader { geo in
            let visible = geo.size.width
            content
                .offset(x: offset)
                // 先给内容套一层"可视区大小"的框再裁掉溢出的部分：
                // 框的坐标原点就是可视区左边缘，offset 为 0 时正好贴着左边
                .frame(width: visible, height: geo.size.height, alignment: .leading)
                .clipped()
                .overlay(alignment: .bottom) { scrollIndicator(visible: visible) }
                // 滚轮 → 横向位移。夹取只在这里发生
                .overlay {
                    RulerWheelRelay { delta in
                        offset = clamped(offset + delta, visible: visible)
                    }
                }
                .onAppear {
                    visibleWidth = visible
                    offset = clamped(offset, visible: visible)
                }
                .onChange(of: visible) { _, newValue in
                    visibleWidth = newValue
                    offset = clamped(offset, visible: newValue)
                }
                .onPreferenceChange(RulerContentWidthKey.self) { width in
                    guard width > 0 else { return }
                    contentWidth = width
                    offset = clamped(offset, visible: visible)
                }
                .onPreferenceChange(RulerTickRectsKey.self) { rects in
                    guard !rects.isEmpty else { return }
                    tickRects = rects
                    followActive(animated: false)
                }
                .onChange(of: activeMonthID) { _, _ in followActive(animated: true) }
        }
        .frame(height: Self.height)
    }

    // MARK: - 内容

    private var content: some View {
        HStack(alignment: .bottom, spacing: spacing) {
            ForEach(Array(months.enumerated()), id: \.element.id) { index, month in
                // 跨年份插一条细分隔线作方位参考。年份**不占独立刻度位**，
                // 否则 1 月会被年份标签顶掉（之前 1 月显示成 "2026"，看着像统计漏了）
                if index > 0, months[index - 1].year != month.year {
                    yearDivider
                }
                monthTick(month: month,
                          isYearStart: index == 0 || months[index - 1].year != month.year)
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
                Color.clear.preference(key: RulerContentWidthKey.self, value: inner.size.width)
            }
        )
    }

    /// 跨年份的分隔线：只是一条细线，不占月份刻度位
    private var yearDivider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.35))
            .frame(width: 1, height: 40)
            .padding(.horizontal, 3)
    }

    /// 刻度尺上的月份柱：高度 = 该月素材数占比，标签固定 "N月"
    private func monthTick(month: TimelineMonth, isYearStart: Bool) -> some View {
        Button {
            onPick(month.id)
        } label: {
            VStack(spacing: 2) {
                // 年份行：每年首月在自己这一列的**上方**标出年份，其余月份留同样高度占位。
                // 占位保证了所有年份标签在同一条水平线上、柱子底部也仍然对齐
                yearRow(month: month, isYearStart: isYearStart)
                RoundedRectangle(cornerRadius: 2)
                    .fill(month.id == activeMonthID ? Color.accentColor : Color.accentColor.opacity(0.28))
                    // 柱子区域固定高度 + 底部对齐：月份高低不同也不会把年份顶得歪歪扭扭
                    .frame(height: max(3, CGFloat(Double(month.count) / max(peak, 1)) * 24))
                    .frame(height: 24, alignment: .bottom)
                Text("\(month.month)月")
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(month.id == activeMonthID ? .primary : .secondary)
            }
            .frame(width: tickWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(month.title) · \(month.count) 个素材")
        .background(
            GeometryReader { g in
                Color.clear.preference(
                    key: RulerTickRectsKey.self,
                    value: [month.id: g.frame(in: .named(Self.space))]
                )
            }
        )
    }

    /// 年份标签：贴在该年首月的左上角；非首月用等高空视图占位
    @ViewBuilder
    private func yearRow(month: TimelineMonth, isYearStart: Bool) -> some View {
        if isYearStart {
            Text("\(month.year)")
                .font(.caption2)
                .bold()
                .monospacedDigit()
                .foregroundStyle(month.id == activeMonthID ? .primary : .secondary)
                .frame(width: tickWidth, alignment: .leading)
                .frame(height: 14, alignment: .bottom)
        } else {
            Color.clear.frame(width: tickWidth, height: 14)
        }
    }

    // MARK: - 位置

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
    /// （以前越界滚动时既看不到头也看不到尾，很容易以为滚完了）
    @ViewBuilder
    private func scrollIndicator(visible: CGFloat) -> some View {
        if scrollable, visible > 0 {
            let barWidth = max(28, visible * visible / contentWidth)
            let minOffset = visible - contentWidth
            let progress = minOffset < 0 ? min(1, max(0, offset / minOffset)) : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.32))
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
private struct RulerContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 每个月刻度在内容坐标系里的位置
private struct RulerTickRectsKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
