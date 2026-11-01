import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var assets: [Asset] = []
    @Published var isScanning = false
    @Published var scanProgress: ScanProgress?

    let database: AppDatabase

    init() {
        self.database = (try? AppDatabase.open()) ?? AppDatabase.inMemory()
        reloadAssets()
    }

    func reloadAssets() {
        assets = (try? database.readAssets()) ?? []
    }

    func scanFolder(_ url: URL) {
        guard !isScanning else { return }
        isScanning = true
        Task {
            let scanner = MediaScanner(database: database)
            for await progress in scanner.scan(folder: url) {
                scanProgress = progress
                if case .finished = progress.state {
                    isScanning = false
                    reloadAssets()
                    // 扫描完成后异步解析地名
                    for a in assets where a.placeName == nil {
                        GeocodingService.shared.resolve(for: a, database: database)
                    }
                    reloadAssets()
                }
            }
        }
    }
}

struct ScanProgress: Equatable {
    enum State: Equatable {
        case discovering
        case importing(indexed: Int, total: Int?)
        case finished(newAssets: Int, duplicates: Int)
    }
    let state: State
    let currentFile: String?
}

