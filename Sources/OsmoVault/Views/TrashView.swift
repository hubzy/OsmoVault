import SwiftUI

struct TrashView: View {
    @EnvironmentObject var appModel: AppModel
    @State private var deletedAssets: [Asset] = []

    var body: some View {
        VStack {
            if deletedAssets.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "trash").font(.largeTitle).foregroundStyle(.secondary)
                    Text("回收站是空的").font(.title3)
                }
            } else {
                List {
                    ForEach(deletedAssets) { a in
                        HStack {
                            Text(a.fileName)
                            Spacer()
                            Button("恢复") { restore(a) }
                        }
                    }
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        deletedAssets = (try? appModel.database.readDeletedAssets()) ?? []
    }
    private func restore(_ a: Asset) {
        try? appModel.database.setDeleted(id: a.id ?? 0, deleted: false)
        reload()
        appModel.reloadAssets()
    }
}

