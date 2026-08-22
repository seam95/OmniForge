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
    /// 事件处理器运行在全局队列（.utility），可能与新目录触发「动态 attach」并发；
    /// 生命周期与字典读写必须持锁（#09 评审 H5：并发变异可崩溃、stop 后残留 source）。
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var onChange: (() -> Void)?
    private var rootURL: URL?
    private let lock = NSLock()

    func startWatching(url: URL, onChange: @escaping () -> Void) {
        stopWatching()
        lock.lock()
        self.onChange = onChange
        self.rootURL = url
        lock.unlock()
        attach(url)
        for child in Self.childDirectories(of: url) {
            attach(child)
        }
    }

    func stopWatching() {
        lock.lock()
        let active = Array(sources.values)
        sources.removeAll()
        onChange = nil
        rootURL = nil
        lock.unlock()
        // cancel 放在锁外：cancel handler 关闭 fd，不触碰本对象状态，避免锁内回调风险。
        for source in active {
            source.cancel()
        }
    }

    private func attach(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        // stop 之后到达的事件处理器不得再挂新 source。
        guard rootURL != nil else { return }
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
        lock.lock()
        let isRoot = url == rootURL
        let root = rootURL
        let handler = onChange
        lock.unlock()
        // 新项目目录出现时补挂一级子目录监听。
        if isRoot, let root {
            for child in Self.childDirectories(of: root) {
                attach(child)
            }
        }
        handler?()
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
