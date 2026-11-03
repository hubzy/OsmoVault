import Foundation
import CoreServices

/// 递归监听已导入的文件夹（含所有子目录）。
///
/// 用 FSEvents 而不是 `DispatchSource`：后者只能监听单个目录、不递归，
/// 而无人机/相机的素材往往在 `DCIM/DJI_001/` 这种子目录里。
///
/// 一次拷贝几百张照片会连续抛几千个事件，所以这里做两级合并：
/// ① FSEvents 自带的 latency ② 事件安静下来后 2s 再回调一次。
final class FolderWatcher {
    private let queue = DispatchQueue(label: "OsmoVault.FolderWatcher")
    private var stream: FSEventStreamRef?
    private var watching: [String] = []
    private var pending: DispatchWorkItem?
    private let onChange: () -> Void

    /// 防抖窗口：拷贝/导出通常持续几秒，等落盘安静下来再扫，避免边拷边扫
    private let debounce: TimeInterval = 2.0

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit {
        // 这里不能走 stop() 的 queue.sync：deinit 有可能已经在同一条队列上
        pending?.cancel()
        teardown()
    }

    /// 更新监听目录。和当前一致时不动，避免每次导入都重开一条流
    func update(roots: [String]) {
        let next = roots.filter { !$0.isEmpty }
        queue.sync {
            guard next != watching else { return }
            watching = next
            restart()
        }
    }

    func stop() {
        queue.sync {
            pending?.cancel()
            pending = nil
            watching = []
            teardown()
        }
    }

    // MARK: - FSEvents

    private func teardown() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func restart() {
        teardown()
        guard !watching.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info, count > 0 else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.handle(count: count, paths: paths, flags: flags)
        }

        // FileEvents：要拿到"哪个文件变了"才能过滤掉缩略图/数据库这类无关写入
        // IgnoreSelf：程序自己挪文件（回收站、导出）不触发，避免自己扫自己
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents)
            | UInt32(kFSEventStreamCreateFlagIgnoreSelf)
            | UInt32(kFSEventStreamCreateFlagNoDefer)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            watching as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounce,
            flags
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    /// 注意：这个回调由 FSEvents 投递到 `queue` 上，所以碰 `pending` 是安全的
    private func handle(count: Int,
                        paths: UnsafeMutableRawPointer,
                        flags: UnsafePointer<FSEventStreamEventFlags>) {
        let list = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
        var shouldScan = false

        for i in 0..<count {
            let flag = flags[i]
            // 事件丢了（目录被整体移动、外接盘重挂）时只能整目录重扫
            if flag & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
                || flag & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
                shouldScan = true
                break
            }
            guard flag & UInt32(kFSEventStreamEventFlagItemIsFile) != 0,
                  flag & UInt32(kFSEventStreamEventFlagItemRemoved) == 0 else { continue }
            if Self.isMedia(String(cString: list[i])) {
                shouldScan = true
                break
            }
        }

        guard shouldScan else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.stream != nil else { return }
            self.onChange()
        }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private static func isMedia(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        return MediaScanner.imageExtensions.contains(ext)
            || MediaScanner.videoExtensions.contains(ext)
    }
}
