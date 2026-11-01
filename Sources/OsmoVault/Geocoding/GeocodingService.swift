import Foundation
import CoreLocation

@MainActor
final class GeocodingService: ObservableObject {
    static let shared = GeocodingService()
    private let geocoder = CLGeocoder()
    private var cache: [String: String] = [:]
    private var inFlight: Set<String> = []

    /// 为素材解析地名并写库；已有地名的跳过
    func resolve(for asset: Asset, database: AppDatabase) {
        guard let lat = asset.latitude, let lon = asset.longitude,
              asset.placeName == nil, asset.id != nil else { return }
        let key = String(format: "%.3f,%.3f", lat, lon)
        if let name = cache[key] {
            save(name, for: asset, database: database)
            return
        }
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        let loc = CLLocation(latitude: lat, longitude: lon)
        geocoder.reverseGeocodeLocation(loc) { [weak self] placemarks, _ in
            Task { @MainActor in
                guard let self else { return }
                self.inFlight.remove(key)
                var name: String?
                if let p = placemarks?.first {
                    let province = p.administrativeArea ?? ""
                    let city = (p.locality ?? p.subAdministrativeArea ?? "").replacingOccurrences(of: "市", with: "")
                    if !province.isEmpty || !city.isEmpty {
                        name = city.isEmpty || province.contains(city) ? province : province + "·" + city
                    }
                }
                if let name {
                    self.cache[key] = name
                    self.save(name, for: asset, database: database)
                }
            }
        }
    }

    private func save(_ name: String, for asset: Asset, database: AppDatabase) {
        try? database.setPlaceName(id: asset.id ?? 0, name: name)
    }
}

