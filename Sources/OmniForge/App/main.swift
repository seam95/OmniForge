import AppKit

// main.swift — AppKit 入口点
// 注册 UserDefaults 默认值（在任何 Manager 初始化之前），然后启动运行循环。
// AppDelegate 标记为 @MainActor，需要通过 MainActor.assumeIsolated 在入口处进入主线程隔离。

Defaults.register()

do {
    switch try SingleInstanceCoordinator().acquire() {
    case let .primary(lease):
        let delegate = MainActor.assumeIsolated { AppDelegate(instanceLease: lease) }
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    case .secondary:
        exit(EXIT_SUCCESS)
    }
} catch {
    FileHandle.standardError.write(Data("OmniForge 无法取得单实例锁：\(error)\n".utf8))
    exit(EXIT_FAILURE)
}
