import SwiftUI
import AppKit
import MapKit
import CoreLocation

/// 手动补定位的对象：单条素材（详情面板里点「编辑」），
/// 或一批素材（当前列表里缺定位的那些，用来批量补全）
enum LocationEditTarget: Identifiable {
    case single(Asset)
    case batch([Asset])

    var id: String {
        switch self {
        case .single(let a): return "single-\(a.id ?? 0)"
        case .batch(let list): return "batch-\(list.count)-\(list.first?.id ?? 0)"
        }
    }

    var assets: [Asset] {
        switch self {
        case .single(let a): return [a]
        case .batch(let list): return list
        }
    }

    var ids: [Int64] { assets.compactMap(\.id) }

    var isBatch: Bool {
        if case .batch = self { return true }
        return false
    }

    /// 单条编辑时用它做初值；批量没有"已有坐标"的概念
    var initialCoordinate: CLLocationCoordinate2D? {
        guard case .single(let a) = self, let lat = a.latitude, let lon = a.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var initialPlaceName: String? {
        guard case .single(let a) = self else { return nil }
        return a.placeName
    }

    /// 是否至少有一条已经有定位（决定要不要给「清除定位」按钮）
    var hasExistingLocation: Bool { assets.contains { $0.latitude != nil } }
}

/// 补定位面板：地图上点一下落点，或直接填经纬度 / 搜地名。
///
/// 没有 GPS 的素材（无人机老固件、手机截图、网络上存的图）在地图页和「拍摄地」里
/// 都找不到，这里让用户可以手动补一个坐标，单个或一批都行
struct LocationEditorSheet: View {
    let target: LocationEditTarget
    /// 应用：坐标 + 地名（地名可为空，交给 AppModel 反查）
    var onApply: (CLLocationCoordinate2D, String?) -> Void
    /// 清除已有定位
    var onClear: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var coordinate: CLLocationCoordinate2D?
    @State private var camera: MapCameraPosition
    @State private var latText: String
    @State private var lonText: String
    @State private var placeText: String
    @State private var searchText = ""
    @State private var busy = false
    @State private var hint: String?
    /// 只有批量清除才需要二次确认
    @State private var confirmClear = false
    /// 地图图层：0 标准 / 1 卫星 / 2 混合。找山川、建筑、楼栋时卫星图更直观
    @State private var mapStyleIndex = 0

    /// 没有任何已知坐标时的落点：先给一个能看到全国的范围
    private static let fallbackCenter = CLLocationCoordinate2D(latitude: 34.5, longitude: 105.0)

    /// 弹窗和地图都按屏幕大小走：小屏不会被窗口裁掉，大屏给足选点面积。
    /// 原来固定 520×240 的地图实在太小，点选和辨别位置都很费劲
    private static var sheetWidth: CGFloat {
        let w = NSScreen.main?.visibleFrame.width ?? 1440
        return min(max(w * 0.6, 780), 1000)
    }

    private static var mapHeight: CGFloat {
        let h = NSScreen.main?.visibleFrame.height ?? 900
        return min(max(h * 0.45, 340), 460)
    }

    init(target: LocationEditTarget,
         onApply: @escaping (CLLocationCoordinate2D, String?) -> Void,
         onClear: (() -> Void)? = nil) {
        self.target = target
        self.onApply = onApply
        self.onClear = onClear
        let initial = target.initialCoordinate
        _coordinate = State(initialValue: initial)
        _camera = State(initialValue: Self.camera(for: initial))
        _latText = State(initialValue: initial.map { String(format: "%.6f", $0.latitude) } ?? "")
        _lonText = State(initialValue: initial.map { String(format: "%.6f", $0.longitude) } ?? "")
        _placeText = State(initialValue: target.initialPlaceName ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            mapPicker
            coordinateFields
            placeFields
            Divider()
            footer
        }
        .padding(16)
        .frame(width: Self.sheetWidth)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("清除定位？", isPresented: $confirmClear) {
            Button("清除 \(target.assets.count) 个素材的定位", role: .destructive) {
                onClear?()
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清除 \(target.assets.count) 个素材的定位信息，可在详情页重新补定位")
        }
    }

    // MARK: - 各部分

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(target.isBatch ? "批量补定位" : "补定位")
                .font(.headline)
            Text(target.isBatch
                 ? "只给勾选的 \(target.assets.count) 个素材标上同一个位置"
                 : target.assets.first?.fileName ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// 地图选点。用 MapReader 把点击位置换算成经纬度。
    /// 放大的地图上常驻缩放 / 图层 / 回到落点控件，选位置不用反复拖着找
    private var mapPicker: some View {
        MapReader { proxy in
            mapCanvas(proxy: proxy)
        }
    }

    @ViewBuilder
    private func mapCanvas(proxy: MapProxy) -> some View {
        let base = Map(position: $camera) {
            if let c = coordinate {
                Marker("选中的位置", coordinate: c)
                    .tint(.red)
            }
        }
        Group {
            switch mapStyleIndex {
            case 1: base.mapStyle(.imagery)
            case 2: base.mapStyle(.hybrid)
            default: base.mapStyle(.standard)
            }
        }
        .frame(height: Self.mapHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) { mapControls.padding(10) }
        .overlay(alignment: .bottomLeading) { coordinateBadge.padding(10) }
        .onTapGesture { point in
            guard let c = proxy.convert(point, from: .local) else { return }
            setCoordinate(c, moveCamera: false)
        }
    }

    /// 地图右上角：缩放、回到落点、切换图层
    private var mapControls: some View {
        VStack(spacing: 6) {
            controlButton("plus.magnifyingglass", "放大地图") { zoom(by: 0.5) }
            controlButton("minus.magnifyingglass", "缩小地图") { zoom(by: 2) }
            controlButton("scope", "回到选中的位置") { zoomToCoordinate() }
                .disabled(coordinate == nil)
            Menu {
                Button("标准地图") { mapStyleIndex = 0 }
                Button("卫星影像") { mapStyleIndex = 1 }
                Button("混合") { mapStyleIndex = 2 }
            } label: {
                Image(systemName: "square.2.layers.3d")
                    .frame(width: 20, height: 18)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("切换地图图层")
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func controlButton(_ icon: String, _ tip: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 20, height: 18)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(tip)
    }

    /// 左下角直接显示当前落点，不用抬头核对输入框
    @ViewBuilder
    private var coordinateBadge: some View {
        HStack(spacing: 6) {
            if let c = coordinate {
                Image(systemName: "mappin.circle.fill").foregroundStyle(.red)
                Text(String(format: "%.5f, %.5f", c.latitude, c.longitude))
                    .monospacedDigit()
            } else {
                Text("点击地图选点 · 滚轮 / 双指缩放")
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
    }

    private var coordinateFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                labeledField("纬度", text: $latText, prompt: "39.904200")
                labeledField("经度", text: $lonText, prompt: "116.407400")
            }
            .onChange(of: latText) { _, _ in syncFromText() }
            .onChange(of: lonText) { _, _ in syncFromText() }
            .onSubmit { zoomToCoordinate() }

            Text("纬度 -90~90，经度 -180~180；也可以把 \"39.9042,116.4074\" 整段粘进纬度框")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var placeFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("地名")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)
                TextField("留空会自动反查（需要联网）", text: $placeText)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 8) {
                Text("搜索")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)
                TextField("输入地名后回车，如「杭州西湖」", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                Button("搜索") { search() }
                    .disabled(searchText.trimmed.isEmpty || busy)
            }

            if busy {
                ProgressView().controlSize(.small)
            } else if let hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(hint.hasPrefix("没") ? .red : .secondary)
                    .lineLimit(2)
            }
        }
    }

    private var footer: some View {
        HStack {
            if target.hasExistingLocation {
                if target.isBatch {
                    // 批量清除影响面大，走二次确认；单条补定位是可逆的，不打断
                    Button("清除定位", role: .destructive) { confirmClear = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button("清除定位", role: .destructive) {
                        onClear?()
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("应用") { apply() }
                .keyboardShortcut(.defaultAction)
                .disabled(coordinate == nil)
        }
    }

    private func labeledField(_ title: String, text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - 逻辑

    private static func camera(for coordinate: CLLocationCoordinate2D?) -> MapCameraPosition {
        guard let c = coordinate else {
            return .region(MKCoordinateRegion(center: fallbackCenter,
                                              span: MKCoordinateSpan(latitudeDelta: 45, longitudeDelta: 45)))
        }
        return .region(MKCoordinateRegion(center: c,
                                          span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)))
    }

    private func setCoordinate(_ c: CLLocationCoordinate2D, moveCamera: Bool) {
        coordinate = c
        latText = String(format: "%.6f", c.latitude)
        lonText = String(format: "%.6f", c.longitude)
        hint = nil
        if moveCamera {
            // 搜地名命中时给一个城市尺度的视野，别一上来就贴到 8km 里
            camera = .region(MKCoordinateRegion(center: c,
                                                span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)))
        }
    }

    /// 输入框 → 坐标。纬度框里带了逗号就当成"一次粘贴了两个值"
    private func syncFromText() {
        let lat = latText.trimmed
        let lon = lonText.trimmed
        if lat.contains(",") || lat.contains("，") {
            let parts = lat.replacingOccurrences(of: "，", with: ",")
                .split(separator: ",")
                .map { String($0).trimmed }
            guard parts.count >= 2,
                  let x = Double(parts[0]), let y = Double(parts[1]),
                  (-90...90).contains(x), (-180...180).contains(y) else { return }
            latText = String(format: "%.6f", x)
            lonText = String(format: "%.6f", y)
            coordinate = CLLocationCoordinate2D(latitude: x, longitude: y)
            return
        }
        guard let x = Double(lat), let y = Double(lon),
              (-90...90).contains(x), (-180...180).contains(y) else { return }
        coordinate = CLLocationCoordinate2D(latitude: x, longitude: y)
    }

    private func zoomToCoordinate() {
        guard let c = coordinate else { return }
        camera = .region(MKCoordinateRegion(center: c,
                                            span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)))
    }

    /// 以当前视野中心按比例缩放。用 position binding 里的 region，
    /// 用户滚轮 / 拖拽之后按钮仍接着当前视野继续，不会突然跳回初始范围
    private func zoom(by factor: Double) {
        let current = camera.region ?? MKCoordinateRegion(
            center: coordinate ?? Self.fallbackCenter,
            span: MKCoordinateSpan(latitudeDelta: 45, longitudeDelta: 45))
        let span = MKCoordinateSpan(
            latitudeDelta: min(max(current.span.latitudeDelta * factor, 0.0015), 120),
            longitudeDelta: min(max(current.span.longitudeDelta * factor, 0.0015), 180))
        camera = .region(MKCoordinateRegion(center: current.center, span: span))
    }

    /// 地名 → 坐标（正向地理编码）。拿不到就提示一下，不影响手动填
    private func search() {
        let query = searchText.trimmed
        guard !query.isEmpty else { return }
        busy = true
        hint = nil
        let geocoder = CLGeocoder()
        geocoder.geocodeAddressString(query) { marks, error in
            DispatchQueue.main.async {
                busy = false
                guard let mark = marks?.first, let c = mark.location?.coordinate else {
                    hint = "没找到「\(query)」，可以手动在地图上点"
                    return
                }
                setCoordinate(c, moveCamera: true)
                let name = mark.locality ?? mark.name ?? query
                hint = "已定位：\(name)"
                if placeText.trimmed.isEmpty { placeText = name }
            }
        }
    }

    private func apply() {
        guard let c = coordinate else { return }
        let name = placeText.trimmed.isEmpty ? nil : placeText.trimmed
        onApply(c, name)
        dismiss()
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
