import AppKit
import XCTest
@testable import OmniForge

/// 固定 AppUninstaller 的安全规则 —— 这些保证扫描结果绝不含路径穿越、嵌套重复或越界路径。
final class AppUninstallerSafetyTests: XCTestCase {

    private let bundleID = "com.maker.editor"

    // MARK: matchesBundleScopedName

    func test_matchesBundleScopedName_exactMatch() {
        XCTAssertTrue(AppUninstaller.matchesBundleScopedName(bundleID, bundleID: bundleID))
    }

    func test_matchesBundleScopedName_prefixChild() {
        XCTAssertTrue(AppUninstaller.matchesBundleScopedName("com.maker.editor.helper", bundleID: bundleID))
    }

    func test_matchesBundleScopedName_suffixParent() {
        XCTAssertTrue(AppUninstaller.matchesBundleScopedName("group.com.maker.editor", bundleID: bundleID))
    }

    func test_matchesBundleScopedName_middleContained() {
        XCTAssertTrue(AppUninstaller.matchesBundleScopedName("systemgroup.com.maker.editor.cache", bundleID: bundleID))
    }

    func test_matchesBundleScopedName_unrelatedReturnsFalse() {
        XCTAssertFalse(AppUninstaller.matchesBundleScopedName("com.other.app", bundleID: bundleID))
        // 仅前缀字符串相同但非点边界 —— com.maker.editorX 不应匹配
        XCTAssertFalse(AppUninstaller.matchesBundleScopedName("com.maker.editorX", bundleID: bundleID))
    }

    // MARK: dedupe

    func test_dedupe_removesExactDuplicates() {
        let url = URL(fileURLWithPath: "/tmp/abc")
        let input = [(url, AppUninstaller.Category.support),
                     (url, AppUninstaller.Category.support)]
        let result = AppUninstaller.dedupe(input)
        XCTAssertEqual(result.count, 1)
    }

    func test_dedupe_dropsNestedPaths() {
        // 父目录在前 → 子目录应被丢弃
        let parent = URL(fileURLWithPath: "/tmp/app")
        let child = URL(fileURLWithPath: "/tmp/app/inner")
        let input = [(parent, AppUninstaller.Category.support),
                     (child, AppUninstaller.Category.support)]
        let result = AppUninstaller.dedupe(input)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.0, parent)
    }

    func test_dedupe_keepsSiblings() {
        let a = URL(fileURLWithPath: "/tmp/appA")
        let b = URL(fileURLWithPath: "/tmp/appB")
        let input = [(a, AppUninstaller.Category.support),
                     (b, AppUninstaller.Category.caches)]
        let result = AppUninstaller.dedupe(input)
        XCTAssertEqual(result.count, 2)
    }

    func test_dedupe_childFirstStillDedupesAgainstLaterParent() {
        // 顺序无关：子目录在前、父目录在后，子也应被父吸收
        let parent = URL(fileURLWithPath: "/tmp/app")
        let child = URL(fileURLWithPath: "/tmp/app/inner")
        let input = [(child, AppUninstaller.Category.support),
                     (parent, AppUninstaller.Category.support)]
        let result = AppUninstaller.dedupe(input)
        XCTAssertEqual(result.count, 1, "无论输入顺序，嵌套子路径都应被父吸收")
    }

    // MARK: scan 过滤其他在装应用的文件

    /// 构造卸载目标；bundleID 可覆盖，用于复现 Chrome / Chrome Canary 案例。
    private func uninstallTarget(bundleID: String,
                                 path: String = "/Applications/Google Chrome.app",
                                 name: String = "Google Chrome") -> AppUninstaller.Target {
        AppUninstaller.Target(
            name: name,
            bundleID: bundleID,
            url: URL(fileURLWithPath: path),
            icon: NSImage(size: NSSize(width: 16, height: 16))
        )
    }

    func test_scan_excludesFilesOwnedByOtherInstalledApps() {
        // 复现审计案例：卸载 Chrome 时，仍在安装的 Chrome Canary（com.google.Chrome.canary）
        // 的偏好、ByHost、Group Container、LaunchAgent 文件都以 "com.google.Chrome." 开头，
        // 会被前缀规则误当成 Chrome 的子资源。它们属于另一个应用，必须被排除。
        let lib = NSHomeDirectory() + "/Library"
        let target = uninstallTarget(bundleID: "com.google.Chrome")

        let preferences = URL(fileURLWithPath: "\(lib)/Preferences")
        let byHost = URL(fileURLWithPath: "\(lib)/Preferences/ByHost")
        let groupContainers = URL(fileURLWithPath: "\(lib)/Group Containers")
        let launchAgents = URL(fileURLWithPath: "\(lib)/LaunchAgents")

        let chromePlist = preferences.appendingPathComponent("com.google.Chrome.plist")
        let canaryPlist = preferences.appendingPathComponent("com.google.Chrome.canary.plist")
        let chromeByHost = byHost.appendingPathComponent("com.google.Chrome.abc123.plist")
        let canaryByHost = byHost.appendingPathComponent("com.google.Chrome.canary.def456.plist")
        let chromeGroup = groupContainers.appendingPathComponent("group.com.google.Chrome")
        let canaryGroup = groupContainers.appendingPathComponent("group.com.google.Chrome.canary")
        let chromeAgent = launchAgents.appendingPathComponent("com.google.Chrome.plist")
        let canaryAgent = launchAgents.appendingPathComponent("com.google.Chrome.canary.plist")

        let reader = UninstallerScanFakeReader(
            existing: [target.url, chromePlist],
            entriesByDirectory: [
                preferences: [chromePlist, canaryPlist],
                byHost: [chromeByHost, canaryByHost],
                groupContainers: [chromeGroup, canaryGroup],
                launchAgents: [chromeAgent, canaryAgent],
            ]
        )

        // 在装集合包含目标自身（扫描发生时 Chrome 仍在 /Applications）与 canary。
        let result = AppUninstaller.performScan(
            target: target,
            reader: reader,
            installedBundleIDs: { ["com.google.Chrome", "com.google.Chrome.canary"] }
        )

        let paths = result.items.map(\.url.standardizedFileURL.path)
        // Canary 的文件一律不得进入移除列表。
        XCTAssertFalse(paths.contains(canaryPlist.standardizedFileURL.path))
        XCTAssertFalse(paths.contains(canaryByHost.standardizedFileURL.path))
        XCTAssertFalse(paths.contains(canaryGroup.standardizedFileURL.path))
        XCTAssertFalse(paths.contains(canaryAgent.standardizedFileURL.path))
        // Chrome 自身的文件正常保留。
        XCTAssertTrue(paths.contains(target.url.standardizedFileURL.path))
        XCTAssertTrue(paths.contains(chromePlist.standardizedFileURL.path))
        XCTAssertTrue(paths.contains(chromeByHost.standardizedFileURL.path))
        XCTAssertTrue(paths.contains(chromeGroup.standardizedFileURL.path))
        XCTAssertTrue(paths.contains(chromeAgent.standardizedFileURL.path))
    }

    func test_scan_keepsTargetSubresourcesNotSeparatelyInstalled() {
        // 目标自身的子资源（如 Chrome 内嵌 helper，bundle id com.google.Chrome.helper）
        // 未单独安装时，不属于任何其他在装应用，仍应命中。
        let launchAgents = URL(fileURLWithPath: NSHomeDirectory() + "/Library/LaunchAgents")
        let helperAgent = launchAgents.appendingPathComponent("com.google.Chrome.helper.plist")
        let target = uninstallTarget(bundleID: "com.google.Chrome")
        let reader = UninstallerScanFakeReader(
            entriesByDirectory: [launchAgents: [helperAgent]]
        )

        let result = AppUninstaller.performScan(
            target: target,
            reader: reader,
            installedBundleIDs: { ["com.google.Chrome"] }
        )

        XCTAssertTrue(
            result.items.map(\.url.standardizedFileURL.path)
                .contains(helperAgent.standardizedFileURL.path)
        )
    }
}

/// 内存版文件读取器：只在布置的路径上应答，扫描测试不触碰真实磁盘。
private final class UninstallerScanFakeReader: UtilityFileReading {
    private let existing: Set<URL>
    private let entriesByDirectory: [URL: [URL]]

    init(existing: Set<URL> = [], entriesByDirectory: [URL: [URL]] = [:]) {
        self.existing = existing
        self.entriesByDirectory = entriesByDirectory
    }

    func fileExists(at url: URL) -> Bool {
        existing.contains(url) || entriesByDirectory[url] != nil
    }

    func isDirectory(at url: URL) throws -> Bool {
        entriesByDirectory[url] != nil
    }

    func directoryEntries(at url: URL) throws -> [URL] {
        entriesByDirectory[url] ?? []
    }

    func allocatedSize(at url: URL) throws -> Int64 {
        1
    }
}
