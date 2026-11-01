import Foundation

/// 智能相册：按规则动态过滤素材，不用手动往里拖片子
struct SmartAlbum: Identifiable, Hashable {
    let id: String
    let name: String
    let systemImage: String
    private let match: (Asset) -> Bool

    init(id: String, name: String, systemImage: String, match: @escaping (Asset) -> Bool) {
        self.id = id
        self.name = name
        self.systemImage = systemImage
        self.match = match
    }

    func contains(_ asset: Asset) -> Bool { match(asset) }
    func filter(_ assets: [Asset]) -> [Asset] { assets.filter(match) }

    static func == (lhs: SmartAlbum, rhs: SmartAlbum) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static func builtin(now: Date = Date()) -> [SmartAlbum] {
        let day: TimeInterval = 24 * 3600
        return [
            SmartAlbum(id: "kindVideo", name: "视频", systemImage: "video") { $0.kind == .video },
            SmartAlbum(id: "kindPhoto", name: "照片", systemImage: "photo") { $0.kind == .photo },
            SmartAlbum(id: "kindLive", name: "实况照片", systemImage: "livephoto") { $0.kind == .livePhoto },
            SmartAlbum(id: "favorite", name: "收藏", systemImage: "heart.fill") { $0.isFavorite },
            SmartAlbum(id: "topRated", name: "高评分", systemImage: "star.fill") { $0.rating >= 4 },
            SmartAlbum(id: "unrated", name: "待评级", systemImage: "star") { $0.rating == 0 },
            SmartAlbum(id: "recent7", name: "最近 7 天", systemImage: "calendar.badge.clock") {
                guard let t = $0.recordedAt else { return false }
                return t > now.addingTimeInterval(-7 * day)
            },
            SmartAlbum(id: "recent30", name: "最近 30 天", systemImage: "calendar") {
                guard let t = $0.recordedAt else { return false }
                return t > now.addingTimeInterval(-30 * day)
            },
            SmartAlbum(id: "portrait", name: "竖屏素材", systemImage: "rectangle.portrait") {
                $0.height > $0.width && $0.width > 0
            },
            SmartAlbum(id: "uhd", name: "4K 及以上", systemImage: "4k.tv") {
                max($0.width, $0.height) >= 3840
            },
            SmartAlbum(id: "highFps", name: "高帧率", systemImage: "speedometer") { $0.frameRate >= 50 },
            SmartAlbum(id: "geotagged", name: "带 GPS", systemImage: "mappin.circle") { $0.latitude != nil },
            SmartAlbum(id: "labelRed", name: "红色标签", systemImage: "circle.fill") { $0.colorLabel == 1 },
            SmartAlbum(id: "labelOrange", name: "橙色标签", systemImage: "circle.fill") { $0.colorLabel == 2 },
            SmartAlbum(id: "labelGreen", name: "绿色标签", systemImage: "circle.fill") { $0.colorLabel == 3 },
            SmartAlbum(id: "labelBlue", name: "蓝色标签", systemImage: "circle.fill") { $0.colorLabel == 4 },
        ]
    }

    static func find(id: String) -> SmartAlbum? {
        builtin().first { $0.id == id }
    }
}
