import SwiftUI

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
    let rulerLabel: String  // 刻度尺短标签：该年首月标年份，其余标月份
    let days: [TimelineDay]
    let count: Int
    let seconds: Double
}

struct TimelineView: View {
    let assets: [Asset]
    @Binding var selectedAssetID: Int64?
    var onRate: (Int64, Int) -> Void = { _, _ in }
    var onDelete: ((Int64) -> Void)?
    var onToggleFavorite: ((Int64) -> Void)?

    @State private var newestFirst = true

    var body: some View {
        // 分组只算一次再往下传：放在子视图里各自调用会重复计算好几遍
        let months = buildSections(newestFirst: newestFirst)
        let noDate = assets.filter { $0.recordedAt == nil }
        let total = assets.reduce(0) { $0 + $1.durationSeconds }
        let span = spanText

        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("时间轴").font(.title2).bold()
                    Text("\(assets.count) 个素材 · \(span) · 总时长 \(Self.humanDuration(total))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("排序", selection: $newestFirst) {
                    Text("最新在前").tag(true)
                    Text("最早在前").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

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
                                 selectedAssetID: $selectedAssetID,
                                 onRate: onRate, onDelete: onDelete,
                                 onToggleFavorite: onToggleFavorite)
            }
        }
    }

    private var spanText: String {
        let dates = assets.compactMap(\.recordedAt).sorted()
        guard let first = dates.first, let last = dates.last else { return "暂无时间信息" }
        let fmt = Self.isoFormatter
        let a = fmt.string(from: first), b = fmt.string(from: last)
        return a == b ? a : "\(a) – \(b)"
    }

    private func buildSections(newestFirst: Bool) -> [TimelineMonth] {
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
            .sorted { newestFirst ? $0.id > $1.id : $0.id < $1.id }

            let year = cal.component(.year, from: sample)
            let monthNum = cal.component(.month, from: sample)
            // 该年第一个月标年份，其余只标月份，避免刻度尺标签挤成一团
            let isFirstOfYear = !byMonth.keys.contains { $0.hasPrefix("\(year)-") && $0 < key }
            result.append(TimelineMonth(
                id: key,
                title: Self.monthTitle.string(from: sample),
                rulerLabel: isFirstOfYear ? "\(year)" : "\(monthNum)月",
                days: days,
                count: pairs.count,
                seconds: pairs.reduce(0) { $0 + $1.0.durationSeconds }
            ))
        }

        result.sort { newestFirst ? $0.id > $1.id : $0.id < $1.id }
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

/// 刻度尺 + 可滚动的分组列表。months 由外层算好传进来，这里不再重复计算
private struct TimelineScroller: View {
    let months: [TimelineMonth]
    let undated: [Asset]
    @Binding var selectedAssetID: Int64?
    var onRate: (Int64, Int) -> Void
    var onDelete: ((Int64) -> Void)?
    var onToggleFavorite: ((Int64) -> Void)?

    /// 与列表滚动位置双向绑定的原始值，滚动过程中可能短暂回写 nil
    @State private var scrolledMonthID: String?
    /// 实际用于高亮的月份，只接受非 nil，避免滚动时高亮闪烁
    @State private var activeMonthID: String?

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
                                            Text("\(day.items.count) 个 · \(TimelineView.humanDuration(day.seconds))")
                                                .font(.caption2).foregroundStyle(.secondary)
                                            Spacer()
                                        }
                                        AssetGridView(assets: day.items, selectedAssetID: $selectedAssetID,
                                                      onRate: onRate, onDelete: onDelete,
                                                      onToggleFavorite: onToggleFavorite, embedded: true)
                                    }
                                }
                            } header: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(month.title).font(.title3).bold()
                                    Text("\(month.count) 个素材").font(.caption).foregroundStyle(.secondary)
                                    Text("时长 \(TimelineView.humanDuration(month.seconds))")
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
                                              onToggleFavorite: onToggleFavorite, embedded: true)
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
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(months) { month in
                        Button {
                            onPick(month.id)
                        } label: {
                            VStack(spacing: 3) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(month.id == activeMonthID ? Color.accentColor : Color.accentColor.opacity(0.28))
                                    .frame(height: max(3, CGFloat(Double(month.count) / max(peak, 1)) * 28))
                                Text(month.rulerLabel)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .foregroundStyle(month.id == activeMonthID ? .primary : .secondary)
                            }
                            .frame(width: 46)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("\(month.title) · \(month.count) 个素材")
                        .id(Self.rulerID(month.id))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .frame(height: 56)
            // 手动滚动列表时，刻度尺上的当前月也要跟着滚进可视范围
            .onChange(of: activeMonthID) { _, newID in
                guard let newID else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    rulerProxy.scrollTo(Self.rulerID(newID), anchor: .center)
                }
            }
        }
    }

    /// 刻度尺里的 id 单独加前缀，避免和列表里的月份 id 撞车
    private static func rulerID(_ monthID: String) -> String { "ruler-\(monthID)" }
}
