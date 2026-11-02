import SwiftUI
import MapKit

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
    @State private var visibleRegion: MKCoordinateRegion
    /// 已渲染的点数，显示在左上角信息条里
    @State private var renderedCount = 0

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
                    .help(cluster.title)
                }
            }
        }
        .mapStyle(.standard)
        // 只在相机停下来之后重算：拖动/缩放过程中每帧都算会把主线程占满
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
            rebuild(region: context.region)
        }
        .onAppear { rebuild(region: visibleRegion) }
        .onChange(of: version) { _, _ in rebuild(region: visibleRegion) }
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
                            RoundedRectangle(cornerRadius: 9)
                                .fill(Color.white.opacity(0.9))
                                .frame(width: size - 8, height: size - 8)
                                .offset(x: 5, y: 5)
                                .shadow(radius: 1)
                        }
                        AsyncThumbView(asset: cluster.asset)
                            .frame(width: size, height: size)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .overlay(
                                RoundedRectangle(cornerRadius: 9)
                                    .stroke(isSelected ? Color.accentColor : Color.white,
                                            lineWidth: isSelected ? 3 : 2)
                            )
                            .shadow(radius: 2)
                    }
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
                .shadow(radius: 1)
            }

            // 多素材的聚合点右下角标数量
            if cluster.count > 1 {
                Text("\(cluster.count)")
                    .font(.caption2).bold().monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.black.opacity(0.7)))
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
        .scaleEffect(isSelected ? 1.12 : 1.0)
        .contentShape(Rectangle())
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

    private struct Bucket {
        var count = 0
        var latSum = 0.0
        var lonSum = 0.0
        var minLat = 90.0, maxLat = -90.0
        var minLon = 180.0, maxLon = -180.0
        var asset: Asset?
    }

    /// 网格聚类。网格尺寸跟着视野走：放大时格子变小，聚合点自然散开成单个标记
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

        var buckets: [String: Bucket] = [:]
        buckets.reserveCapacity(256)
        for asset in assets {
            guard let lat = asset.latitude, let lon = asset.longitude else { continue }
            guard lat >= lat0, lat <= lat1, lon >= lon0, lon <= lon1 else { continue }
            let key = "\(Int(floor(lat / cellLat)))|\(Int(floor(lon / cellLon)))"
            var b = buckets[key] ?? Bucket()
            b.count += 1
            b.latSum += lat
            b.lonSum += lon
            if lat < b.minLat { b.minLat = lat }
            if lat > b.maxLat { b.maxLat = lat }
            if lon < b.minLon { b.minLon = lon }
            if lon > b.maxLon { b.maxLon = lon }
            if b.asset == nil { b.asset = asset }
            buckets[key] = b
        }

        var result: [Cluster] = []
        result.reserveCapacity(buckets.count)
        for b in buckets.values {
            guard let asset = b.asset else { continue }
            // id 用代表素材而不是网格 key：网格 key 随缩放级别整个换一遍，
            // 会让 MapKit 把所有标记销毁重建，视觉上就是缩放结束后标签集体闪一下/抖一下。
            // 代表素材 id 在同一缩放级别下是稳定的，没变的点视图原样保留
            result.append(Cluster(id: "c-\(asset.id ?? -1)",
                                  latitude: b.latSum / Double(b.count),
                                  longitude: b.lonSum / Double(b.count),
                                  count: b.count,
                                  asset: asset,
                                  minLat: b.minLat, maxLat: b.maxLat,
                                  minLon: b.minLon, maxLon: b.maxLon))
        }
        clusters = result
        renderedCount = result.reduce(0) { $0 + $1.count }
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
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar, in: RoundedRectangle(cornerRadius: 8))
        .padding(12)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendDot(.red, "视频")
            legendDot(.pink, "实况")
            legendDot(.blue, "照片")
            legendDot(.orange, "多素材聚合")
        }
        .font(.caption2)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar, in: RoundedRectangle(cornerRadius: 8))
        .padding(12)
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
