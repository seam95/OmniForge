import XCTest
@testable import OmniForge

// 目录监听替身复用 Shared/TokenUsageUsageTestDoubles.swift 的 FakeDirectoryWatcher
// （brief 原稿自带同名私有替身，与测试 target 既有 internal 替身冲突，故复用）。

final class ScreenshotFolderWatcherTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        // /var 是 firmlink，resolvingSymlinksInPath 不解析；而 contentsOfDirectory 恒返回
        // /private/var 前缀的 URL。构造测试目录时直接对齐 /private 形态，
        // 否则断言比较与排除集路径匹配都会因前缀不一致而失败。
        var tempPath = FileManager.default.temporaryDirectory.path
        if tempPath.hasPrefix("/var/") { tempPath = "/private" + tempPath }
        dir = URL(fileURLWithPath: tempPath, isDirectory: true)
            .appendingPathComponent("watcher-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func makeImage(_ name: String) -> URL {
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data([0x89, 0x50]))
        return url
    }

    @MainActor
    func testIsCandidateExtensionAndTaggingRules() {
        let png = URL(fileURLWithPath: "/x/a.png")
        let txt = URL(fileURLWithPath: "/x/a.txt")
        XCTAssertTrue(ScreenshotFolderWatcher.isCandidate(png, desktopOnlyTagged: false))
        XCTAssertFalse(ScreenshotFolderWatcher.isCandidate(txt, desktopOnlyTagged: false))
        // desktopOnlyTagged 只在带标记时放行；测试环境无法给 /x/a.png 打标 → false
        XCTAssertFalse(ScreenshotFolderWatcher.isCandidate(png, desktopOnlyTagged: true))
    }

    @MainActor
    func testStartHangsPostLaunchFilesAndSetsBaseline() {
        let preExisting = makeImage("old.png")   // 基线前：不挂
        // 基线取在两次创建之间：早于基线的静默入 known，晚于基线的立即补挂。
        // （brief 原稿在两文件创建后才回拨 1 秒取基线，基线恒早于两者，old.png 会被误挂。）
        let watcher = ScreenshotFolderWatcher(launchDate: Date())
        let fresh = makeImage("new.png")          // 基线后创建：立即补挂
        var hung: [URL] = []
        watcher.start(folder: dir, desktopOnlyTagged: false, onNew: { hung.append($0) }, onChange: {})
        XCTAssertEqual(hung, [fresh])
        _ = preExisting
    }

    @MainActor
    func testEventScanPicksUpNewFileAfterDebounce() async throws {
        let fakeWatcher = FakeDirectoryWatcher()
        let watcher = ScreenshotFolderWatcher(
            watcher: fakeWatcher, debounceInterval: 0.05)
        var hung: [URL] = []
        watcher.start(folder: dir, desktopOnlyTagged: false, onNew: { hung.append($0) }, onChange: {})
        let late = makeImage("late.png")
        fakeWatcher.simulateChange()   // 模拟目录事件
        try await Task.sleep(nanoseconds: 300_000_000)  // 等防抖
        XCTAssertEqual(hung, [late])
    }

    @MainActor
    func testEventScanConsumesOwnWritesFromManager() async throws {
        let fakeWatcher = FakeDirectoryWatcher()
        let manager = ClotheslineManager.testable(userDefaults: UserDefaults(suiteName: "w-\(UUID().uuidString)")!)
        let watcher = ScreenshotFolderWatcher(watcher: fakeWatcher, debounceInterval: 0.05)
        // 排除集接线：扫描层通过消费者闭包询问 ClotheslineManager（brief 原稿漏接，恒不命中）。
        watcher.ownWriteConsumer = { manager.consumeOwnWrite($0) }
        var hung: [URL] = []
        let folder = dir.appendingPathComponent("f2", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        watcher.start(folder: folder, desktopOnlyTagged: false, onNew: { hung.append($0) }, onChange: {})
        let own = folder.appendingPathComponent("own.png")
        FileManager.default.createFile(atPath: own.path, contents: Data([1]))
        manager.noteOwnWrite(own.path)
        fakeWatcher.simulateChange()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(hung.isEmpty)   // 排除集命中：不挂
    }

    @MainActor
    func testStopDetaches() async throws {
        let fakeWatcher = FakeDirectoryWatcher()
        let watcher = ScreenshotFolderWatcher(watcher: fakeWatcher, debounceInterval: 0.05)
        watcher.start(folder: dir, desktopOnlyTagged: false, onNew: { _ in }, onChange: {})
        watcher.stop()
        XCTAssertFalse(fakeWatcher.isWatching)   // stopWatching 已解绑
    }
}
