import Foundation
import CoreLocation

@MainActor
final class GeocodingService {
    static let shared = GeocodingService()

    private let geocoder = CLGeocoder()
    private var cache: [String: String] = [:]
    private var failures: Set<String> = []

    /// 反查地名。相同坐标（3 位小数 ≈ 100m）命中缓存；失败过的坐标不再重试。
    /// 调用方负责串行 + 间隔调用，CLGeocoder 对并发请求很敏感。
    func placeName(latitude: Double, longitude: Double) async -> String? {
        let key = String(format: "%.3f,%.3f", latitude, longitude)
        if let cached = cache[key] { return cached }
        if failures.contains(key) { return nil }

        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(
                CLLocation(latitude: latitude, longitude: longitude)
            )
            guard let p = placemarks.first else {
                failures.insert(key)
                return nil
            }
            let province = p.administrativeArea ?? ""
            let city = (p.locality ?? p.subAdministrativeArea ?? "").replacingOccurrences(of: "市", with: "")
            guard !province.isEmpty || !city.isEmpty else {
                failures.insert(key)
                return nil
            }
            let name = city.isEmpty || province.contains(city) ? province : province + "·" + city
            cache[key] = name
            return name
        } catch {
            failures.insert(key)
            return nil
        }
    }
}
