import XCTest
@testable import OmniForge

/// 固定 CleanerSupport 的每条安全规则 —— 这些是清理器"绝不误伤活跃 app"承诺的核心。
final class CleanerSupportTests: XCTestCase {

    // MARK: looksLikeBundleID

    func test_looksLikeBundleID_acceptsReverseDNS() {
        XCTAssertTrue(CleanerSupport.looksLikeBundleID("com.maker.editor"))
        XCTAssertTrue(CleanerSupport.looksLikeBundleID("org.example.app.helper"))
    }

    func test_looksLikeBundleID_rejectsTooFewComponents() {
        XCTAssertFalse(CleanerSupport.looksLikeBundleID("com.maker"))
        XCTAssertFalse(CleanerSupport.looksLikeBundleID("maker"))
    }

    func test_looksLikeBundleID_rejectsInvalidCharacters() {
        XCTAssertFalse(CleanerSupport.looksLikeBundleID("com.maker.app helper"))   // 空格
        XCTAssertFalse(CleanerSupport.looksLikeBundleID("com.maker.app/path"))     // 斜杠
        XCTAssertFalse(CleanerSupport.looksLikeBundleID("com..maker"))             // 空段
    }

    // MARK: bundleIDCandidate

    func test_bundleIDCandidate_stripsKnownWrappersAndSuffixes() {
        XCTAssertEqual(CleanerSupport.bundleIDCandidate(fromEntryName: "com.maker.editor.plist"), "com.maker.editor")
        XCTAssertEqual(CleanerSupport.bundleIDCandidate(fromEntryName: "com.maker.editor.savedState"), "com.maker.editor")
        XCTAssertEqual(CleanerSupport.bundleIDCandidate(fromEntryName: "com.maker.editor.binarycookies"), "com.maker.editor")
        XCTAssertEqual(CleanerSupport.bundleIDCandidate(fromEntryName: "group.com.maker.editor"), "com.maker.editor")
        XCTAssertEqual(CleanerSupport.bundleIDCandidate(fromEntryName: "systemgroup.com.maker.editor"), "com.maker.editor")
    }

    func test_bundleIDCandidate_rejectsPlainVendorFolder() {
        XCTAssertNil(CleanerSupport.bundleIDCandidate(fromEntryName: "MakerEditor"))
        XCTAssertNil(CleanerSupport.bundleIDCandidate(fromEntryName: "MyApp"))
    }

    func test_bundleIDCandidate_rejectsUUIDNames() {
        XCTAssertNil(CleanerSupport.bundleIDCandidate(fromEntryName: "com.maker.AAAA1111-2222-3333-4444-555555555555"))
    }

    // MARK: containsUUIDComponent

    func test_containsUUIDComponent_detectsCanonicalUUID() {
        XCTAssertTrue(CleanerSupport.containsUUIDComponent("11111111-2222-3333-4444-555555555555"))
        XCTAssertTrue(CleanerSupport.containsUUIDComponent("prefix-11111111-2222-3333-4444-555555555555-suffix"))
    }

    func test_containsUUIDComponent_rejectsNonUUID() {
        XCTAssertFalse(CleanerSupport.containsUUIDComponent("com.maker.editor"))
        XCTAssertFalse(CleanerSupport.containsUUIDComponent("1111-2222"))
    }

    // MARK: isProtectedBundleID

    func test_isProtectedBundleID_protectsAppleAndSelf() {
        XCTAssertTrue(CleanerSupport.isProtectedBundleID("com.apple.Safari"))         // .com.apple.
        XCTAssertTrue(CleanerSupport.isProtectedBundleID("com.apple.something.helper")) // 深层 .com.apple.
        XCTAssertTrue(CleanerSupport.isProtectedBundleID("app.omniforge.helper"))    // 本 app（新名）
        XCTAssertTrue(CleanerSupport.isProtectedBundleID("app.inputlock.helper"))    // 本 app（历史名，老版本残留数据仍受保护）
    }

    func test_isProtectedBundleID_requiresDotBoundary() {
        // com.appleFinder 不是 com.apple 域（无点边界），不算受保护
        XCTAssertFalse(CleanerSupport.isProtectedBundleID("com.appleFinder"))
    }

    func test_isProtectedBundleID_protectsSharedInfrastructure() {
        XCTAssertTrue(CleanerSupport.isProtectedBundleID("org.sparkle-project.Sparkle"))
        XCTAssertTrue(CleanerSupport.isProtectedBundleID("io.sentry"))
    }

    func test_isProtectedBundleID_allowsOrdinaryThirdParty() {
        XCTAssertFalse(CleanerSupport.isProtectedBundleID("com.maker.editor"))
    }

    // MARK: isOwned

    func test_isOwned_exactMatch() {
        let installed: Set<String> = ["com.maker.editor"]
        XCTAssertTrue(CleanerSupport.isOwned(candidate: "com.maker.editor", byInstalled: installed))
    }

    func test_isOwned_prefixFamily_bothDirections() {
        // 已安装 com.maker.App 持有 com.maker.App.helper
        XCTAssertTrue(CleanerSupport.isOwned(candidate: "com.maker.App.helper",
                                             byInstalled: ["com.maker.app"]))
        // 已安装 com.maker.App.helper 仍让 com.maker 算作被持有
        XCTAssertTrue(CleanerSupport.isOwned(candidate: "com.maker",
                                             byInstalled: ["com.maker.app.helper"]))
    }

    func test_isOwned_caseInsensitive() {
        XCTAssertTrue(CleanerSupport.isOwned(candidate: "COM.MAKER.EDITOR",
                                             byInstalled: ["com.maker.editor"]))
    }

    func test_isOwned_unrelatedReturnsFalse() {
        XCTAssertFalse(CleanerSupport.isOwned(candidate: "com.other.app",
                                              byInstalled: ["com.maker.editor"]))
    }

    // MARK: sharesVendorNamespace

    func test_sharesVendorNamespace_siblingKeepsAlive() {
        // 已安装 com.maker.editor 让 com.maker.updater 保持活跃
        let installed: Set<String> = ["com.maker.editor"]
        XCTAssertTrue(CleanerSupport.sharesVendorNamespace(candidate: "com.maker.updater",
                                                           withInstalled: installed))
    }

    func test_sharesVendorNamespace_hostingNamespaceDoesNotCount() {
        // github 命名空间下互不相关的开发者，两段匹配无意义
        let installed: Set<String> = ["com.github.someone.app"]
        XCTAssertFalse(CleanerSupport.sharesVendorNamespace(candidate: "com.github.other.tool",
                                                            withInstalled: installed))
    }

    func test_sharesVendorNamespace_differentVendorReturnsFalse() {
        let installed: Set<String> = ["com.maker.editor"]
        XCTAssertFalse(CleanerSupport.sharesVendorNamespace(candidate: "com.other.helper",
                                                            withInstalled: installed))
    }

    // MARK: executablePaths

    func test_executablePaths_collectsAllReferencedPaths() {
        let plist: [String: Any] = [
            "Program": "/usr/local/bin/daemon",
            "ProgramArguments": ["/Applications/MyApp.app/Contents/MacOS/MyApp", "--flag"],
        ]
        let paths = CleanerSupport.executablePaths(inLaunchPlist: plist)
        XCTAssertEqual(paths, ["/usr/local/bin/daemon", "/Applications/MyApp.app/Contents/MacOS/MyApp"])
    }

    func test_executablePaths_relativeBundleProgramIgnored() {
        let plist: [String: Any] = ["BundleProgram": "Contents/MacOS/Helper"]
        XCTAssertTrue(CleanerSupport.executablePaths(inLaunchPlist: plist).isEmpty)
    }

    // MARK: launchPlistIsRemovableOrphan

    func test_launchPlistIsRemovableOrphan_allExecutablesGone() {
        let result = CleanerSupport.launchPlistIsRemovableOrphan(
            label: "com.maker.helper",
            executables: ["/gone/a", "/gone/b"],
            executableExists: { _ in false }
        )
        XCTAssertTrue(result)
    }

    func test_launchPlistIsRemovableOrphan_anyExecutablePresent_returnsFalse() {
        let result = CleanerSupport.launchPlistIsRemovableOrphan(
            label: "com.maker.helper",
            executables: ["/gone/a", "/present/b"],
            executableExists: { $0 == "/present/b" }
        )
        XCTAssertFalse(result)
    }

    func test_launchPlistIsRemovableOrphan_noExecutables_returnsFalse() {
        let result = CleanerSupport.launchPlistIsRemovableOrphan(
            label: "com.maker.helper",
            executables: [],
            executableExists: { _ in false }
        )
        XCTAssertFalse(result, "未命名可执行文件的 plist 无法判定，必须保留")
    }

    func test_launchPlistIsRemovableOrphan_appleLabelProtected() {
        let result = CleanerSupport.launchPlistIsRemovableOrphan(
            label: "com.apple.something",
            executables: ["/gone/a"],
            executableExists: { _ in false }
        )
        XCTAssertFalse(result, "Apple 自身 agent 必须被保护")
    }

    func test_launchPlistIsRemovableOrphan_externalVolumeCountsAsPresent() {
        // 外部卷上缺失的二进制是不确定的（卷可能只是未挂载），算作存在，plist 保留
        let result = CleanerSupport.launchPlistIsRemovableOrphan(
            label: "com.maker.helper",
            executables: ["/Volumes/External/tool"],
            executableExists: { path in path.hasPrefix("/Volumes/") || FileManager.default.fileExists(atPath: path) }
        )
        XCTAssertFalse(result)
    }
}
