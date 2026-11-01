import SwiftUI
import MapKit

struct MapView: View {
    let assets: [Asset]
    @Binding var selectedAssetID: Int64?

    private var geotagged: [Asset] {
        assets.filter { $0.latitude != nil && $0.longitude != nil }
    }
    private var pins: [Pin] {
        geotagged.map { Pin(asset: $0) }
    }

    struct Pin: Identifiable {
        let asset: Asset
        var id: Int64? { asset.id }
        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: asset.latitude ?? 0, longitude: asset.longitude ?? 0)
        }
    }

    var body: some View {
        if pins.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "map").font(.largeTitle).foregroundStyle(.secondary)
                Text("没有带 GPS 信息的素材").font(.title3)
                Text("DJI 无人机视频通常伴随 SRT 文件，重新扫描导入时即可自动提取坐标").font(.subheadline).foregroundStyle(.secondary)
            }
        } else {
            Map(initialPosition: .automatic) {
                ForEach(pins) { pin in
                    Annotation(pin.asset.fileName, coordinate: pin.coordinate) {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(.red)
                            .onTapGesture { selectedAssetID = pin.asset.id }
                    }
                }
            }
        }
    }
}

