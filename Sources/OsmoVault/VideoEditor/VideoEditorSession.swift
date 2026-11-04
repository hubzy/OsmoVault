import AppKit
import AVFoundation
import FCCore
import FCEngine
import FCMedia
import Observation
import UniformTypeIdentifiers

/// 剪辑会话：管理当前打开的剪辑工程（FrameCut 工程）。
///
/// OsmoVault 的定位是「食材仓 + 灶台」：素材管理（SQLite 图库）是本命，
/// 剪辑能力整体移植自开源项目 FrameCut（MIT）。这个类相当于原 FrameCut 的
/// AppModel，砍掉了工程启动页 / 文件面板那套独立 App 的壳，只保留：
/// 工程的创建 / 打开 / 关闭 + 最近工程 + OsmoVault 素材入轨的桥。
@Observable
@MainActor
final class VideoEditorSession {
    var editor: EditorModel?
    var recent: [URL] = RecentProjects().list()

    /// 工程文件统一放在应用支持目录，不弹保存面板——素材库形态的 App 里
    /// 工程是"随手开"的，不该用独立剪辑器的文件管理心智。
    static var projectsDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OsmoVault/Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var autoIndex = 1

    // MARK: 工程生命周期

    /// 新建并打开一个空工程（名字自动带序号，可在检查器里改）。
    @discardableResult
    func newProject() -> Bool {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        let base = formatter.string(from: Date())
        // 同一天第 N 个工程
        let existing = (try? FileManager.default.contentsOfDirectory(at: Self.projectsDirectory, includingPropertiesForKeys: nil)) ?? []
        let count = existing.filter { $0.pathExtension == ProjectFile.fileExtension }.count
        let name = "\(base) 剪辑 \(count + autoIndex)"
        autoIndex += 1
        let url = Self.projectsDirectory.appendingPathComponent("\(name).\(ProjectFile.fileExtension)")
        do {
            try ProjectFile.write(Project(name: name), to: url)
            open(url: url)
            return true
        } catch {
            return false
        }
    }

    func open(url: URL) {
        do {
            let project = try ProjectFile.read(from: url)
            if let editor {
                editor.close()
                Self.purgeCaches()
            }
            editor = EditorModel(project: project, packageURL: url)
            RecentProjects().add(url)
            recent = RecentProjects().list()
        } catch {
            Log.project.error("无法打开工程：\(error.localizedDescription, privacy: .public)")
            RecentProjects().remove(url)
            recent = RecentProjects().list()
        }
    }

    func openRecent(_ url: URL) { open(url: url) }

    /// 关闭当前工程（自动保存）。编辑页随之回到起始状态。
    func closeProject() {
        editor?.close()
        editor = nil
        recent = RecentProjects().list()
        Self.purgeCaches()
    }

    /// 确保有一个打开的工程：进入编辑页时调用，没有就自动新建。
    func ensureProject() {
        if editor == nil { newProject() }
    }

    /// 把「一键出片」排好的时间线原样送进剪辑台继续精修：
    /// 片段顺序、起止时间、变速、交叉溶解都保留，之后随便改（可撤销）。
    func openProject(fromSegments segments: [CutSegment], transitionDuration: Double) {
        guard !segments.isEmpty else { return }
        newProject()
        guard let editor else { return }
        Task { @MainActor in
            await editor.importVaultCutSegments(segments, transitionDuration: transitionDuration)
        }
    }

    /// 释放缩略图、波形、照片、滤镜与字幕的内存缓存（关闭工程或系统内存紧张时）。
    static func purgeCaches() {
        Log.cache.info("释放内存缓存")
        RenderCaches.purge()
        Task {
            await Thumbnails.shared.purge()
            await WaveformProvider.shared.purge()
        }
    }
}

// MARK: - OsmoVault 素材 → 剪辑工程 的桥

extension EditorModel {
    /// 「一键出片」的时间线 → 剪辑工程：逐段探测入轨，保留起止 / 变速 / 转场。
    func importVaultCutSegments(_ segments: [CutSegment], transitionDuration: Double) async {
        importing = true
        defer { importing = false }
        var failed: [String] = []
        // 先把所有源探测成 MediaAsset（按路径去重，同一素材多段只探测一次）
        var probed: [MediaAsset] = []
        for seg in segments {
            let url = URL(fileURLWithPath: seg.sourcePath)
            if let existing = probed.first(where: { $0.path == url.path }) ?? project.assets.first(where: { $0.path == url.path }) {
                if !probed.contains(where: { $0.id == existing.id }) { probed.append(existing) }
                continue
            }
            do { probed.append(try await FCMedia.MediaProbe.probe(url: url)) }
            catch { failed.append(seg.fileName) }
        }
        guard !probed.isEmpty else {
            if !failed.isEmpty { errorMessage = String(localized: "以下素材无法导入：\(failed.joined(separator: "、"))") }
            return
        }
        let segs = segments
        store.perform { p in
            p.addAssets(probed)
            for seg in segs {
                guard let asset = probed.first(where: { $0.path == URL(fileURLWithPath: seg.sourcePath).path }),
                      asset.kind != .audio else { continue }
                guard let clipID = p.appendToMain(assetID: asset.id) else { continue }
                p.updateMain(id: clipID) {
                    $0.sourceIn = Time(seconds: max(seg.start, 0))
                    $0.sourceOut = Time(seconds: max(seg.end, seg.start + 0.1))
                    $0.speed = min(max(seg.speed, EditLimits.speedRange.lowerBound), EditLimits.speedRange.upperBound)
                }
            }
            if transitionDuration > 0, p.mainTrack.count > 1 {
                p.applyTransitionToAll(Transition(kind: .dissolve, duration: Time(seconds: transitionDuration)))
            }
        }
        if !failed.isEmpty { notice = String(localized: "有 \(failed.count) 个片段的源文件无法读取，已跳过。") }
    }

    /// 暂停预览（切离剪辑页时兜底调用，避免"人走了声音还在"）。
    func pausePlayback() {
        if isPlaying { togglePlay() }
    }
    /// 把 OsmoVault 图库里的素材送进剪辑工程。
    ///
    /// 资源池卡片上的元数据（时长 / 尺寸 / 帧率）只够展示，入轨前统一走一次
    /// 引擎的媒体探测，拿到权威数据（含音轨、HDR 格式）——探测过一次后
    /// 工程里就留有 MediaAsset，同一素材再入轨不会重复探测。
    ///
    /// livePhoto 走它的动态视频（playbackPath），照片按图片素材处理。
    func importVaultAssets(_ assets: [Asset], addToTimeline: Bool = true) async {
        guard !assets.isEmpty else { return }
        importing = true
        defer { importing = false }
        var probed: [MediaAsset] = []
        var failed: [String] = []
        for asset in assets {
            // 实况照片：有动态部分就用动态部分（能剪、有声音）；没有就当静态图
            let path: String?
            switch asset.kind {
            case .video: path = asset.filePath
            case .livePhoto: path = asset.playbackPath ?? asset.filePath
            case .photo: path = asset.filePath
            }
            guard let path else { failed.append(asset.fileName); continue }
            let url = URL(fileURLWithPath: path)
            if let existing = project.assets.first(where: { $0.path == url.path }) {
                probed.append(existing)
                continue
            }
            do {
                probed.append(try await FCMedia.MediaProbe.probe(url: url))
            } catch {
                failed.append(asset.fileName)
            }
        }
        guard !probed.isEmpty else {
            if !failed.isEmpty { errorMessage = String(localized: "以下素材无法导入：\(failed.joined(separator: "、"))") }
            return
        }
        let wasHDR = project.colorMode == .hdr
        store.perform { p in
            p.addAssets(probed)
            guard addToTimeline else { return }
            for asset in probed {
                switch asset.kind {
                case .video, .image: p.appendToMain(assetID: asset.id)
                case .audio: p.addMusic(assetID: asset.id, at: .zero)
                }
            }
        }
        if !wasHDR, project.colorMode == .hdr {
            notice = String(localized: "检测到 HDR 素材，工程已切换为 HDR，预览与导出保留高光细节。")
        }
        if !failed.isEmpty {
            notice = String(localized: "已导入 \(probed.count) 个素材；以下文件无法读取：\(failed.joined(separator: "、"))")
        }
    }
}

// MARK: - 应用级共享设施（原 FrameCutApp.swift 里的两个单例搬到这里）

/// 应用共用的缩略图提供者，HDR 帧按成片同样的方式色调映射。
enum Thumbnails {
    static let shared = ThumbnailProvider(hdrToneMapper: { image, format in HDRThumbnail.toneMap(image, format: format) })
}

/// 应用共用的调色预设库。
@MainActor
enum GradePresets {
    static let store = GradePresetStore()
}
