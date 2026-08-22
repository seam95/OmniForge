import Foundation

// MARK: - 目录监听协议

/// 目录变更监听边界 — 采集器与 DispatchSource 解耦（测试注入替身）。
/// 只负责「发信号」，解析由采集器在自有串行队列执行（信号与解析分离，参考 02）。
protocol DirectoryWatching: AnyObject {
    func startWatching(url: URL, onChange: @escaping () -> Void)
    func stopWatching()
}

// MARK: - DispatchSource 实现

/// 用 `DispatchSourceFileSystemObject` 监听 Claude 日志目录（及其一级子目录，
/// 即各项目 slug 目录）的写入/变更事件；5 分钟定时兜底由采集器负责。
///
/// 说明：目录级监听只对「直接子条目」的变化生效——新建/删除会话文件会触发，
/// 而向已有文件追加内容不触发，这正是需要定时兜底的场景（SPEC 5.6）。
final class DispatchSourceDirectoryWatcher: DirectoryWatching {
    /// path → source（fd 由源持有，取消时关闭）。
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var onChange: (() -> Void)?
    private var rootURL: URL?

    func startWatching(url: URL, onChange: @escaping () -> Void) {
        stopWatching()
        self.onChange = onChange
        self.rootURL = url
        attach(url)
        for child in Self.childDirectories(of: url) {
            attach(child)
        }
    }

    func stopWatching() {
        for source in sources.values {
            source.cancel()
        }
        sources.removeAll()
        onChange = nil
        rootURL = nil
    }

    private func attach(_ url: URL) {
        let path = url.path
        guard sources[path] == nil else { return }
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            self?.handleEvent(at: url)
        }
        source.setCancelHandler {
            close(descriptor)
        }
        sources[path] = source
        source.resume()
    }

    private func handleEvent(at url: URL) {
        // 新项目目录出现时补挂一级子目录监听（监听本身就运行在全局队列，安全）。
        if url == rootURL {
            guard let root = rootURL else { return }
            for child in Self.childDirectories(of: root) {
                attach(child)
            }
        }
        onChange?()
    }

    private static func childDirectories(of url: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }
}
