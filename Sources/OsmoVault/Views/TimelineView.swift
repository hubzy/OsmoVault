import SwiftUI

struct TimelineView: View {
    let assets: [Asset]
    @Binding var selectedAsset: Asset?
    var onRate: (Int64, Int) -> Void = { _, _ in }
    var onColor: (Int64, Int) -> Void = { _, _ in }

    private var grouped: [(month: String, items: [Asset])] {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy年M月"
        let dict = Dictionary(grouping: assets) { a -> String in
            guard let t = a.recordedAt else { return "未知时间" }
            return fmt.string(from: t)
        }
        return dict.keys.sorted(by: >).map { ($0, dict[$0]!) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(grouped, id: \.month) { group in
                    Section {
                        AssetGridView(assets: group.items, selectedAsset: $selectedAsset,
                                      onRate: onRate, onColor: onColor)
                    } header: {
                        Text(group.month).font(.title3).bold()
                    }
                }
            }
            .padding(16)
        }
    }
}

