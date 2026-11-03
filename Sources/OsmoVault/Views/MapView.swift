import SwiftUI
import MapKit
import AppKit

/// 地图页。
///
/// 八千个素材直接铺标记会把 MapKit 拖到卡死，所以做了两件事：
/// 1. 按当前视野做**网格聚类**：只渲染视野内的点，邻近的点合成一个「N 个素材」的聚合点。
///    聚类结果缓存在 @State 里，只在相机停止移动或素材库版本号变化时重算，
///    body 重绘（hover、选中变化等）不会碰它。渲染量从 8000 降到 400 以内。
/// 2. 标记本身用 `Annotation` 包一个 Button：点击行为完全由我们控制。
///    （试过 `Marker` + `Map(selection:)`，macOS 上点击不触发选中，点了没反应）
struct MapView: View {
    /// 只含带 GPS 的素材（由 AppModel 缓存过滤后传入）
    let assets: [Asset]
    /// 素材库版本号，变了才重算聚类
    let version: UInt64
    @Binding var selectedAssetID: Int64?

    @State private var cameraPosition: MapCameraPosition
    @State private var clusters: [Cluster] = []
    /// 上一次真正重算聚类时用的视野 / 素材库版本，用于跳过无意义的重复重算
    @State private var lastBuiltRegion: MKCoordinateRegion?
    @State private var lastBuiltVersion: UInt64 = 0
    /// 聚合点要显示的缩略图（素材 id → 图）。在地图外面加载好，标注视图里只画静态图
    @State private var pinImages: [Int64: NSImage] = [:]
    /// 加载失败的素材 id：不要每次重算都重试一遍
    @State private var failedPinIDs: Set<Int64> = []
    @State private var visibleRegion: MKCoordinateRegion
    /// 已渲染的点数，显示在左上角信息条里
    @State private var renderedCount = 0
    /// 相机停下后的重算用这个做防抖：惯性滑动结束时常会连发几次 `onEnd`，
    /// 每次都重算会让边缘标签跟着镜头收尾一跳一跳的。这里存最近一次的重算任务，
    /// 新回调进来就取消上一个，保证只重算真正停稳后的最后一次视野。
    /// 任务闭包只捕获 `region` 值、不捕获 `self`，所以不会和 @State 形成引用环。
    @State private var rebuildTask: Task<Void, Never>?

    init(assets: [Asset], version: UInt64, selectedAssetID: Binding<Int64?>) {
        self.assets = assets
        self.version = version
        self._selectedAssetID = selectedAssetID
        let fit = Self.fitRegion(for: assets)
        self._cameraPosition = State(initialValue: .region(fit))
        self._visibleRegion = State(initialValue: fit)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if assets.isEmpty {
                emptyState
            } else {
                map
                    .overlay(alignment: .topLeading) { infoBar }
                    .overlay(alignment: .bottomTrailing) { legend }
            }
        }
    }

    // MARK: - 地图

    private var map: some View {
        Map(position: $cameraPosition) {
            ForEach(clusters) { cluster in
                Annotation(cluster.title, coordinate: cluster.coordinate) {
                    Button {
                        select(cluster)
                    } label: {
                        pinView(cluster)
                    }
                    .buttonStyle(.plain)
                    // 标注内容不参与任何隐式动画：聚类变化时不让标签做淡入淡出
                    .transaction { $0.animation = nil }
                }
            }
        }
        .mapStyle(.standard)
        // 只在相机停下来之后重算：拖动/缩放过程中每帧都算会把主线程占满
        .onMapCameraChange(frequency: .onEnd) { context in
            apply(region: context.region)
        }
        .onAppear { rebuild(region: visibleRegion) }
        .onChange(of: version) { _, _ in rebuild(region: visibleRegion) }
    }

    /// 相机停下后的入口。
    ///
    /// **视野没变就什么都不做**：MapKit 在地图静止时也会反复回调 `onEnd`
    /// （它自己那点细微的镜头调整），以前每回调一次就把八千条素材重聚类一遍、
    /// 再把 `clusters` 整个换新，标注跟着重新布局一下 —— 表现就是标签轻微闪动，
    /// 而且按住拖动地图时反而正常（拖动中不会触发 `onEnd`）。
    ///
    /// 这里再套一层 120ms 防抖：惯性滑动收尾时 `onEnd` 可能连发，每次都按当时的
    /// 镜头重算会让边缘的标签跟着镜头一点点挪，松手后看着就是抖一下。防抖后只取
    /// 真正停稳后的最后一次视野来重算，一次到位。
    private func apply(region: MKCoordinateRegion) {
        rebuildTask?.cancel()
        rebuildTask = Task { [region] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { [region] in
                guard self.needsRebuild(region) else { return }
                self.visibleRegion = region
                self.rebuild(region: region)
            }
        }
    }

    /// 判断这次视野变化值不值得重算：
    /// 缩放比例变化不超过 5%、中心位移不超过当前视野的 3%，就沿用旧的聚合结果
    private func needsRebuild(_ region: MKCoordinateRegion) -> Bool {
        guard lastBuiltVersion == version, let last = lastBuiltRegion else { return true }
        let latSpan = max(last.span.latitudeDelta, 0.000001)
        let lonSpan = max(last.span.longitudeDelta, 0.000001)
        let ratio = region.span.latitudeDelta / latSpan
        if ratio < 0.95 || ratio > 1.05 { return true }
        let dLat = abs(region.center.latitude - last.center.latitude) / latSpan
        let dLon = abs(region.center.longitude - last.center.longitude) / lonSpan
        return dLat > 0.03 || dLon > 0.03
    }

    /// 点标记：单个素材直接选中，聚合点先放大到这一簇（放大后格子变小会自然散开）
    private func select(_ cluster: Cluster) {
        selectedAssetID = cluster.asset.id
        if cluster.count > 1 {
            cameraPosition = .region(cluster.focusRegion)
        }
    }

    /// 视野里的聚合点不多时才用缩略图卡片：一张 400px 缩略图解开就是 640KB，
    /// 几百个全铺开会吃掉几百 MB 内存。点多了自动退化成彩色圆点
    private static let detailedClusterLimit = 60

    private func pinView(_ cluster: Cluster) -> some View {
        let isSelected = cluster.asset.id == selectedAssetID
        let detailed = clusters.count <= Self.detailedClusterLimit
        let size: CGFloat = isSelected ? 54 : 44

        return ZStack(alignment: .bottomTrailing) {
            if detailed {
                VStack(spacing: 0) {
                    ZStack {
                        // 聚合点垫一层白卡在后面，做出"一叠照片"的效果
                        if cluster.count > 1 {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.white.opacity(0.9))
                                .frame(width: size - 8, height: size - 8)
                                .offset(x: 5, y: 5)
                        }
                        // 这里**只能是静态图**：缩略图在外面统一加载好，
                        // 标注视图里不再有任何 @State / 异步任务 / 阴影，
                        // 否则 MapKit 每次回收重建标注就会闪一下
                        if let image = pinImages[cluster.asset.id ?? -1] {
                            Image(nsImage: image)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fill)
                                .frame(width: size, height: size)
                                .clipped()
                        } else {
                            Rectangle()
                                .fill(Color(white: 0.93))
                                .frame(width: size, height: size)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(isSelected ? Color.accentColor : Color.white,
                                    lineWidth: isSelected ? 3 : 2)
                    )
                    // 指向真实坐标点的小尖角
                    Image(systemName: "arrowtriangle.down.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.white)
                        .offset(y: -4)
                }
            } else {
                ZStack {
                    if cluster.count == 1 {
                        Image(systemName: cluster.systemImage)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    } else {
                        Text("\(cluster.count)")
                            .font(.caption2).bold().monospacedDigit()
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: isSelected ? 30 : 24, height: isSelected ? 30 : 24)
                .background(Circle().fill(cluster.tint))
                .overlay(
                    Circle().stroke(isSelected ? Color.accentColor : Color.white.opacity(0.9),
                                    lineWidth: isSelected ? 2.5 : 1.5)
                )
            }

            // 多素材的聚合点右下角标数量
            if cluster.count > 1 {
                VaultBadge(vertical: 1, font: .caption2.bold().monospacedDigit()) {
                    Text("\(cluster.count)")
                }
                .offset(x: 4, y: 3)
            }
        }
        // 实况照片按规范在左上角标 LIVE
        .overlay(alignment: .topLeading) {
            if detailed && cluster.asset.kind == .livePhoto {
                LiveBadge(compact: true)
                    .offset(x: -4, y: -4)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - 标记缩略图（在地图外面加载）

    /// 给聚合点准备缩略图。做成字典塞进 `@State`，标注视图里就只剩一张现成的图：
    /// 之前是每个标注里挂一个 AsyncThumbView，自带 `@State thumb` 和 `.task`；
    /// 地图缩放时 MapKit 会把标注视图回收重建，任务跟着重启、`thumb` 先被清空，
    /// 于是整片标签一起闪一下。加载搬到外面后，重建多少次都只是画同一张内存里的图
    private func loadPinImages(for clusters: [Cluster]) {
        guard clusters.count <= Self.detailedClusterLimit else {
            if !pinImages.isEmpty { pinImages = [:] }
            return
        }

        // 只保留当前视野内的，避免越滚越多
        let ids = Set(clusters.map { $0.asset.id ?? -1 })
        var next = pinImages.filter { ids.contains($0.key) }

        var pending: [Asset] = []
        for cluster in clusters {
            let id = cluster.asset.id ?? -1
            if next[id] != nil { continue }
            // 加载失败过一次的别再反复排队，否则每次重算都会重新发一轮请求
            if failedPinIDs.contains(id) { continue }
            // 已生成过的直接同步取，不触发解码；没有的攒起来异步补
            if let cached = ThumbnailStore.shared.cachedThumbnail(for: cluster.asset) {
                next[id] = cached
            } else {
                pending.append(cluster.asset)
            }
        }
        if next.count != pinImages.count || !pending.isEmpty {
            pinImages = next
        }
        guard !pending.isEmpty else { return }

        // 补齐：一张一张来，每补一张只是把字典里那个位置填上，
        // 已经显示的标签完全不受影响
        let missing = pending
        Task { @MainActor in
            for asset in missing {
                guard let id = asset.id else { continue }
                guard let image = await ThumbnailStore.shared.thumbnail(for: asset) else {
                    failedPinIDs.insert(id)
                    continue
                }
                if pinImages[id] == nil { pinImages[id] = image }
            }
        }
    }

    // MARK: - 聚类

    /// 一个聚合点。只保留代表素材 + 计数 + 包围盒，不存整个数组（几千簇时内存差很多）
    private struct Cluster: Identifiable {
        let id: String
        let latitude: Double
        let longitude: Double
        let count: Int
        let asset: Asset
        let minLat: Double, maxLat: Double, minLon: Double, maxLon: Double

        var coordinate: CLLocationCoordinate2D {
            .init(latitude: latitude, longitude: longitude)
        }
        var title: String {
            count == 1 ? (asset.placeName ?? asset.fileName) : "\(count) 个素材"
        }
        var systemImage: String {
            if count > 1 { return "photo.stack.fill" }
            switch asset.kind {
            case .video: return "video.fill"
            case .livePhoto: return "livephoto"
            case .photo: return "photo.fill"
            }
        }
        var tint: Color {
            if count > 1 { return .orange }
            switch asset.kind {
            case .video: return .red
            case .livePhoto: return .pink
            case .photo: return .blue
            }
        }
        /// 放大到这一簇时用的视野
        var focusRegion: MKCoordinateRegion {
            let latDelta = max((maxLat - minLat) * 2.6, 0.0015)
            let lonDelta = max((maxLon - minLon) * 2.6, 0.0015)
            return MKCoordinateRegion(
                center: .init(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
                span: .init(latitudeDelta: latDelta, longitudeDelta: lonDelta))
        }
    }

    /// 网格聚类。网格尺寸跟着视野走：放大时格子变小，聚合点自然散开成单个标记。
    ///
    /// **关键：每个标记的坐标都是「钉死」的，平移时绝不会动。**
    /// - 单张素材：直接用地图的真实坐标，id 绑到素材本身。它本来就在那个点，平移地图时
    ///   它跟着地图平滑移动，重算聚类也不会改变它的坐标，所以永远不会抖。
    /// - 多张素材的格子：用「网格中心」坐标，id 绑到网格 key。网格是按地理空间固定的
    ///   （不是相对视野中心算的），同一缩放级别下平移地图不会改变任何一个格子的中心，
    ///   所以这些聚合点也钉死不动 —— 只有缩放时网格才会整体重排（那本来就发生在缩放结束后）。
    /// 旧实现用的是「格子内素材平均坐标」，平移会让边缘格子 membership 变化、平均坐标跟着挪，
    /// 于是已存在的标签被 MapKit 重新摆位，松手后就抖那么一下。现在不存在这个问题了。
    private func rebuild(region: MKCoordinateRegion) {
        guard !assets.isEmpty else { clusters = []; renderedCount = 0; return }

        // 视野外的一点也留着（10% 余量），否则刚平移完边缘会先空一块
        let latHalf = region.span.latitudeDelta / 2 * 1.1
        let lonHalf = region.span.longitudeDelta / 2 * 1.1
        let lat0 = region.center.latitude - latHalf, lat1 = region.center.latitude + latHalf
        let lon0 = region.center.longitude - lonHalf, lon1 = region.center.longitude + lonHalf

        // 20×20 个格子：最坏也就 400 个标记，MapKit 扛得住
        let cells = 20.0
        let cellLat = max(region.span.latitudeDelta / cells, 0.00002)
        let cellLon = max(region.span.longitudeDelta / cells, 0.00002)

        struct CellAgg {
            var gx = 0, gy = 0
            var count = 0
            var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
            var asset: Asset?
            var firstLat = 0.0, firstLon = 0.0   // 代表素材（单点时即真实坐标）
        }
        var buckets: [String: CellAgg] = [:]
        buckets.reserveCapacity(256)
        for asset in assets {
            guard let lat = asset.latitude, let lon = asset.longitude else { continue }
            guard lat >= lat0, lat <= lat1, lon >= lon0, lon <= lon1 else { continue }
            let gx = Int(floor(lat / cellLat))
            let gy = Int(floor(lon / cellLon))
            let key = "\(gx)|\(gy)"
            var b = buckets[key] ?? CellAgg()
            if b.asset == nil {
                b.asset = asset
                b.firstLat = lat
                b.firstLon = lon
            }
            b.gx = gx; b.gy = gy
            b.count += 1
            if lat < b.minLat { b.minLat = lat }
            if lat > b.maxLat { b.maxLat = lat }
            if lon < b.minLon { b.minLon = lon }
            if lon > b.maxLon { b.maxLon = lon }
            buckets[key] = b
        }

        var result: [Cluster] = []
        result.reserveCapacity(buckets.count)
        for (key, b) in buckets {
            guard let asset = b.asset else { continue }
            let isSingle = b.count == 1
            let coordLat: Double
            let coordLon: Double
            let id: String
            if isSingle {
                // 单张：真实坐标 + 绑素材 id，平移时钉死在原地
                coordLat = b.firstLat
                coordLon = b.firstLon
                id = "c-\(asset.id ?? -1)"
            } else {
                // 多张：网格中心坐标 + 绑网格 key，平移时格子中心不变，钉死不动
                coordLat = (Double(b.gx) + 0.5) * cellLat
                coordLon = (Double(b.gy) + 0.5) * cellLon
                id = "g-\(key)"
            }
            result.append(Cluster(id: id,
                                  latitude: coordLat,
                                  longitude: coordLon,
                                  count: b.count,
                                  asset: asset,
                                  minLat: b.minLat, maxLat: b.maxLat,
                                  minLon: b.minLon, maxLon: b.maxLon))
        }
        lastBuiltRegion = region
        lastBuiltVersion = version

        // 结果和上一次完全一样就别换数组：换一次 `clusters` 会让 MapKit 重新摆一遍标注，
        // 哪怕位置分毫未变也可能抖一下
        if !Self.sameClusters(result, clusters) {
            clusters = result
        }
        let count = result.reduce(0) { $0 + $1.count }
        if count != renderedCount { renderedCount = count }
        loadPinImages(for: result)
    }

    /// 两次聚类结果是否一模一样（id / 计数 / 位置都没变）
    private static func sameClusters(_ a: [Cluster], _ b: [Cluster]) -> Bool {
        guard a.count == b.count else { return false }
        let keyA = a.map { "\($0.id)/\($0.count)" }
        let keyB = b.map { "\($0.id)/\($0.count)" }
        guard keyA == keyB else { return false }
        for (x, y) in zip(a, b) {
            if abs(x.latitude - y.latitude) > 1e-9 || abs(x.longitude - y.longitude) > 1e-9 {
                return false
            }
        }
        return true
    }

    /// 全部素材的外接视野。相机初始位置和「显示全部」都用它
    private static func fitRegion(for assets: [Asset]) -> MKCoordinateRegion {
        var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
        var n = 0
        for a in assets {
            guard let lat = a.latitude, let lon = a.longitude else { continue }
            n += 1
            if lat < minLat { minLat = lat }
            if lat > maxLat { maxLat = lat }
            if lon < minLon { minLon = lon }
            if lon > maxLon { maxLon = lon }
        }
        guard n > 0 else {
            return MKCoordinateRegion(center: .init(latitude: 34.0, longitude: 108.0),
                                      span: .init(latitudeDelta: 40, longitudeDelta: 40))
        }
        if n == 1 {
            return MKCoordinateRegion(center: .init(latitude: minLat, longitude: minLon),
                                      span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05))
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.25, 0.01),
                                    longitudeDelta: max((maxLon - minLon) * 1.25, 0.01))
        return MKCoordinateRegion(center: center, span: span)
    }

    // MARK: - 辅助 UI

    private var infoBar: some View {
        // 改掉 .bar 语义：统一走 14pt continuous + regularMaterial 的玻璃外壳
        VaultGlassContainer {
            HStack(spacing: 10) {
                Image(systemName: "mappin.circle.fill").foregroundStyle(.red)
                Text("\(assets.count) 个带位置素材")
                    .font(.subheadline)
                Divider().frame(height: 12)
                Text("视野内 \(renderedCount) 个 · \(clusters.count) 个位置点")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    cameraPosition = .region(Self.fitRegion(for: assets))
                } label: {
                    Label("显示全部", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("缩放到全部素材")
            }
        }
        .padding(16)
    }

    private var legend: some View {
        VaultGlassContainer {
            HStack(spacing: 12) {
                legendDot(.red, "视频")
                legendDot(.pink, "实况")
                legendDot(.blue, "照片")
                legendDot(.orange, "多素材聚合")
            }
            .font(.caption2)
        }
        .padding(16)
    }

    private func legendDot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "map").font(.largeTitle).foregroundStyle(.secondary)
            Text("没有带 GPS 信息的素材").font(.title3)
            Text("DJI 无人机视频通常伴随 SRT 文件，重新扫描导入时即可自动提取坐标")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
