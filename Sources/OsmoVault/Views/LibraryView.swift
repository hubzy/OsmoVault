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
    var emptyHint: String?

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
    }

    private func recompute() {
        let built = buildSections()
        sections = built
        undated = assets.filter { $0.recordedAt == nil }
        summaryText = makeSummary()
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
                             onVisible: onVisible)
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

    /// 与列表滚动位置双向绑定的原始值，滚动过程中可能短暂回写 nil
    @State private var scrolledMonthID: String?
    /// 实际用于高亮的月份，只接受非 nil，避免滚动时高亮闪烁
    @State private var activeMonthID: String?
    /// 已经为哪个 anchorKey 恢复过位置。切到别的集合时 anchorKey 变了，要重新恢复
    @State private var restoredKey = ""
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ruler { id in
                    // 重复点同一月也要重新定位：用户可能已经手动滚到别处了
                    scrolledMonthID = id
                    activeMonthID = id
                    jump(proxy, to: id)
                }
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                        ForEach(months) { month in
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
                                                      onVisible: onVisible, embedded: true)
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

                        if !undated.isEmpty {
                            Section {
                                AssetGridView(assets: undated, selectedAssetID: $selectedAssetID,
                                              onRate: onRate, onDelete: onDelete,
                                              onToggleFavorite: onToggleFavorite,
                                              onVisible: onVisible, embedded: true)
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

    // MARK: - 滚动位置记忆

    /// 回到上次看到的月份。以月份（日期）为锚点，宽度变化也不会错位
    private func restore(_ proxy: ScrollViewProxy) {
        guard !months.isEmpty, restoredKey != anchorKey else { return }
        restoredKey = anchorKey
        guard let saved = UserDefaults.standard.string(forKey: anchorKey),
              months.contains(where: { $0.id == saved }) else { return }
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
    /// LazyVStack 里第一帧目标 cell 往往还没实体化，单次 scrollTo 会落空，
    /// 所以在下一帧和 0.1s 后各补一次，最终一定停在正确位置。
    private func jump(_ proxy: ScrollViewProxy, to id: String) {
        proxy.scrollTo(id, anchor: .top)
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { proxy.scrollTo(id, anchor: .top) }
    }

    private func ruler(onPick: @escaping (String) -> Void) -> some View {
        let peak = Double(months.map(\.count).max() ?? 1)
        return ScrollViewReader { rulerProxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // 零尺寸的桥接视图：把滚轮的垂直分量转成刻度尺的左右平移
                ZStack(alignment: .bottom) {
                    RulerWheelBridge().frame(width: 0, height: 0)
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(Array(months.enumerated()), id: \.element.id) { index, month in
                            // 跨年份只插一条细分隔线作方位参考。年份不再占一个刻度位，
                            // 否则 1 月会被年份标签顶掉（之前 1 月显示成 "2026"，看着像统计漏了）
                            if index > 0, months[index - 1].year != month.year {
                                yearDivider
                            }
                            monthTick(month: month, peak: peak) { onPick(month.id) }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
            .frame(height: 58)
            // 年份浮在刻度尺左上角，跟随当前所处的月份，不挤占月份标签的位置
            .overlay(alignment: .topLeading) { yearBadge }
            // 手动滚动列表时，刻度尺上的当前月也要跟着滚进可视范围
            .onChange(of: activeMonthID) { _, newID in
                guard let newID else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    rulerProxy.scrollTo(Self.rulerID(newID), anchor: .center)
                }
            }
        }
    }

    /// 左上角年份：显示当前所处月份所属的年份
    @ViewBuilder
    private var yearBadge: some View {
        if let year = currentYear {
            HStack(spacing: 3) {
                Image(systemName: "calendar").font(.system(size: 9))
                Text("\(year)")
                    .font(.caption2)
                    .bold()
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(.background.opacity(0.9)))
            .padding(.leading, 12)
            .padding(.top, 3)
        }
    }

    private var currentYear: Int? {
        if let id = activeMonthID, let m = months.first(where: { $0.id == id }) { return m.year }
        return months.first?.year
    }

    /// 跨年份的分隔线：只是一条细线，不占月份刻度位
    private var yearDivider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.35))
            .frame(width: 1, height: 26)
            .padding(.horizontal, 3)
    }

    /// 刻度尺上的月份柱：高度 = 该月素材数占比，标签固定 "N月"
    private func monthTick(month: TimelineMonth, peak: Double, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            VStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(month.id == activeMonthID ? Color.accentColor : Color.accentColor.opacity(0.28))
                    .frame(height: max(3, CGFloat(Double(month.count) / max(peak, 1)) * 24))
                Text("\(month.month)月")
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(month.id == activeMonthID ? .primary : .secondary)
            }
            .frame(width: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(month.title) · \(month.count) 个素材")
        .id(Self.rulerID(month.id))
    }

    /// 刻度尺里的 id 单独加前缀，避免和列表里的月份 id 撞车
    private static func rulerID(_ monthID: String) -> String { "ruler-\(monthID)" }
}
