import Foundation

// MARK: - 数据模型

/// 一条素材的人工标注。写在素材旁边的 `文件名.ext.xmp` 伴生文件里，是标注的**真源**；
/// `vault.sqlite` 只是可随时重建的索引——换机、删库重扫后，标注从这里恢复。
struct SidecarAnnotation: Sendable, Equatable {
    var latitude: Double?
    var longitude: Double?
    var placeName: String?
    /// 用户显式清除了定位。必须保留这个「否定标记」：
    /// 单纯删掉 xmp 会让扫描回落到文件内原生 GPS，刚清掉的坐标又冒回来
    var locationCleared = false
    var rating: Int?
    var colorLabel: Int?
    var isFavorite: Bool?
    /// 身份校验：伴生文件被挪动、或走只读卷镜像目录时用来确认还是同一条素材
    var fileHash: String?
    var fileName: String?

    var hasContent: Bool {
        latitude != nil || longitude != nil || placeName != nil || locationCleared
            || rating != nil || colorLabel != nil || isFavorite != nil
    }
}

// MARK: - 服务

/// XMP sidecar 的读写与合并。
///
/// 命名规则（写）：`DJI_0012.MP4` → `DJI_0012.MP4.xmp`（完整文件名 + 后缀），
/// 不用 Lightroom 那种 `DJI_0012.xmp`——实况照片的 HEIC/MOV、无人机的 MP4/SRT
/// 都共享 basename，裸 basename 会串数据。
/// 读取时兼容 `DJI_0012.xmp`（外部工具写的），但自己从不写这种。
///
/// GPS 用标准 `exif:` 命名空间的度分秒格式，Lightroom / exiftool / digiKam 都认；
/// 地名、评分等私货放自定义 `ov:` 命名空间，别的软件会忽略、不冲突。
///
/// 只读外接盘写不进素材目录时，退到库目录的镜像
/// `~/Library/Application Support/OsmoVault/sidecars/<fileHash>.xmp`，
/// 按指纹匹配——素材被改名、挪目录、换卷都还能对上。
enum SidecarService {

    /// 一次写盘请求。值类型快照，从 @MainActor 传到后台线程
    struct WriteRequest: Sendable {
        var filePath: String
        var fileHash: String
        var fileName: String
        var latitude: Double?
        var longitude: Double?
        var placeName: String?
        var rating: Int
        var colorLabel: Int
        var isFavorite: Bool
        /// 本次操作就是「清除定位」→ 写显式否定标记
        var forceCleared = false
    }

    // MARK: - 路径

    private static var mirrorDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask).first!
        return base.appendingPathComponent("OsmoVault/sidecars", isDirectory: true)
    }

    private static func mirrorURL(for fileHash: String) -> URL {
        let safe = fileHash.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "unknown"
        return mirrorDirectory.appendingPathComponent(safe + ".xmp")
    }

    /// 候选路径，按优先级排列：自己写的完整名 → 外部工具的 basename → 只读卷镜像
    static func candidates(for mediaURL: URL, fileHash: String) -> [URL] {
        let fullName = URL(fileURLWithPath: mediaURL.path + ".xmp")
        let baseName = mediaURL.deletingLastPathComponent()
            .appendingPathComponent((mediaURL.lastPathComponent as NSString).deletingPathExtension + ".xmp")
        if fullName.path == baseName.path {
            return [fullName, mirrorURL(for: fileHash)]
        }
        return [fullName, baseName, mirrorURL(for: fileHash)]
    }

    static func exists(for mediaURL: URL, fileHash: String) -> Bool {
        candidates(for: mediaURL, fileHash: fileHash)
            .contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - 读

    static func read(for mediaURL: URL, fileHash: String) -> SidecarAnnotation? {
        for url in candidates(for: mediaURL, fileHash: fileHash) {
            guard let data = try? Data(contentsOf: url), !data.isEmpty,
                  let ann = parse(data) else { continue }
            // 镜像目录按指纹归档：记录的指纹对不上就别用（素材可能被替换过）
            if url.path.hasPrefix(mirrorDirectory.path),
               let recorded = ann.fileHash, recorded != fileHash { continue }
            return ann
        }
        return nil
    }

    // MARK: - 写

    /// 优先写素材同目录；卷只读/没权限时退到镜像目录。
    /// 返回 false 表示两处都没写成（比如外接盘整个被拔了）。
    @discardableResult
    static func write(_ ann: SidecarAnnotation, for mediaURL: URL, fileHash: String) -> Bool {
        let payload = Data(serialize(ann).utf8)
        let primary = URL(fileURLWithPath: mediaURL.path + ".xmp")
        if atomicWrite(payload, to: primary) {
            // 同目录写成功后清掉旧镜像，避免两处内容打架
            try? FileManager.default.removeItem(at: mirrorURL(for: fileHash))
            return true
        }
        return atomicWrite(payload, to: mirrorURL(for: fileHash))
    }

    /// 批量「读现有 xmp → 合并当前状态 → 写回」。
    /// 读-改-写很关键：只改评分时不能丢掉已有的定位与否定标记。
    /// 返回写失败的条数。
    @discardableResult
    static func apply(_ requests: [WriteRequest]) -> Int {
        var failures = 0
        for r in requests {
            let url = URL(fileURLWithPath: r.filePath)
            var ann = read(for: url, fileHash: r.fileHash) ?? SidecarAnnotation()
            ann.fileName = r.fileName
            ann.fileHash = r.fileHash

            if r.forceCleared {
                ann.latitude = nil
                ann.longitude = nil
                ann.placeName = nil
                ann.locationCleared = true
            } else if let lat = r.latitude, let lon = r.longitude {
                ann.latitude = lat
                ann.longitude = lon
                ann.locationCleared = false
                if let p = r.placeName { ann.placeName = p }
            } else if let p = r.placeName {
                ann.placeName = p
                // 没有坐标时不动 locationCleared：
                // 之前清过的保持清除，本来就没有的保持没有
            }
            ann.rating = r.rating
            ann.colorLabel = r.colorLabel
            ann.isFavorite = r.isFavorite

            if !ann.hasContent { continue }
            if !write(ann, for: url, fileHash: r.fileHash) { failures += 1 }
        }
        return failures
    }

    private static func atomicWrite(_ data: Data, to url: URL) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - 序列化

    private static func serialize(_ ann: SidecarAnnotation) -> String {
        var attrs: [(String, String)] = []
        if ann.locationCleared {
            attrs.append(("ov:LocationCleared", "1"))
        } else if let lat = ann.latitude, let lon = ann.longitude {
            attrs.append(("exif:GPSLatitude", GPSDMS.format(lat, isLatitude: true)))
            attrs.append(("exif:GPSLongitude", GPSDMS.format(lon, isLatitude: false)))
        }
        if let p = ann.placeName, !p.isEmpty { attrs.append(("ov:PlaceName", p)) }
        if let r = ann.rating { attrs.append(("ov:Rating", String(r))) }
        if let c = ann.colorLabel { attrs.append(("ov:ColorLabel", String(c))) }
        if let f = ann.isFavorite { attrs.append(("ov:Favorite", f ? "1" : "0")) }
        if let h = ann.fileHash { attrs.append(("ov:FileHash", h)) }
        if let n = ann.fileName { attrs.append(("ov:FileName", n)) }

        let body = attrs.map { "\($0.0)=\"\(escape($0.1))\"" }
            .joined(separator: "\n    ")
        return """
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="OsmoVault 1.0">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
                xmlns:exif="http://ns.adobe.com/exif/1.0/"
                xmlns:ov="http://ns.osmovault.app/1.0/"
                \(body)/>
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    // MARK: - 解析

    private static func parse(_ data: Data) -> SidecarAnnotation? {
        let delegate = XMPDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), !delegate.values.isEmpty else { return nil }

        var ann = SidecarAnnotation()
        if let latText = delegate.values["exif:GPSLatitude"],
           let lonText = delegate.values["exif:GPSLongitude"],
           let lat = GPSDMS.parse(latText), let lon = GPSDMS.parse(lonText) {
            ann.latitude = lat
            ann.longitude = lon
        }
        ann.locationCleared = delegate.values["ov:LocationCleared"] == "1"
        if let p = delegate.values["ov:PlaceName"], !p.isEmpty { ann.placeName = p }
        ann.rating = delegate.values["ov:Rating"].flatMap(Int.init)
        ann.colorLabel = delegate.values["ov:ColorLabel"].flatMap(Int.init)
        if let f = delegate.values["ov:Favorite"] { ann.isFavorite = f == "1" }
        ann.fileHash = delegate.values["ov:FileHash"]
        ann.fileName = delegate.values["ov:FileName"]
        return ann.hasContent ? ann : nil
    }

    /// SAX 收集 `rdf:Description` 上的属性。关闭命名空间处理，
    /// 这样 elementName / 属性 key 都保留 `exif:` 这类前缀，直接按键取值最稳
    private final class XMPDelegate: NSObject, XMLParserDelegate {
        var values: [String: String] = [:]

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            guard elementName == "rdf:Description" || elementName == "Description" else { return }
            for (key, value) in attributeDict {
                values[key] = value
            }
        }
    }
}

// MARK: - GPS 度分秒

/// XMP 标准的 GPS 写法是 `"31,13.824000N"`（度,十进制分+半球），
/// 不是十进制小数——写了别的软件读不出来
private enum GPSDMS {
    static func format(_ value: Double, isLatitude: Bool) -> String {
        let ref = value >= 0 ? (isLatitude ? "N" : "E") : (isLatitude ? "S" : "W")
        let abs = Swift.abs(value)
        let deg = Int(abs)
        let minutes = (abs - Double(deg)) * 60
        return String(format: "%d,%.6f%@", deg, minutes, ref)
    }

    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return nil }
        let sign: Double
        switch last {
        case "N", "n", "E", "e": sign = 1
        case "S", "s", "W", "w": sign = -1
        default:
            // 兼容外部工具直接写十进制小数的情况
            return Double(trimmed)
        }
        let parts = String(trimmed.dropLast())
            .split(separator: ",")
            .map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 2, let deg = parts[0], let min = parts[1] else { return nil }
        let sec = parts.count >= 3 ? (parts[2] ?? 0) : 0
        return sign * (deg + min / 60 + sec / 3600)
    }
}
