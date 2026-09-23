import XCTest
@testable import OmniForge

final class RightClickActionExecutorTests: XCTestCase {
    private var tempDirectory: URL!
    private var executor: RightClickActionExecutor!
    private var revealedURLs: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniForgeRightClickTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        
        revealedURLs.removeAll()
        executor = RightClickActionExecutor(
            fileManager: .default,
            pasteboard: .general,
            workspace: .shared,
            fileRevealer: { [weak self] urls in
                self?.revealedURLs.append(contentsOf: urls)
            }
        )
    }

    override func tearDownWithError() throws {
        if let temp = tempDirectory, FileManager.default.fileExists(atPath: temp.path) {
            try? FileManager.default.removeItem(at: temp)
        }
        try super.tearDownWithError()
    }

    // MARK: - 1. 新建文件测试

    func test_createUniqueEmptyFile_createsFileAndIncrementsOnCollision() throws {
        // 第一次创建：未命名.txt
        let file1 = try executor.createUniqueEmptyFile(in: tempDirectory, fileExtension: "txt")
        XCTAssertEqual(file1.lastPathComponent, "未命名.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file1.path))
        let attrs1 = try FileManager.default.attributesOfItem(atPath: file1.path)
        XCTAssertEqual(attrs1[.size] as? Int, 0)
        XCTAssertEqual(revealedURLs.last, file1)

        // 第二次创建：未命名 2.txt
        let file2 = try executor.createUniqueEmptyFile(in: tempDirectory, fileExtension: ".txt") // 测试带点前缀
        XCTAssertEqual(file2.lastPathComponent, "未命名 2.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file2.path))

        // 第三次创建：未命名 3.txt
        let file3 = try executor.createUniqueEmptyFile(in: tempDirectory, fileExtension: "txt")
        XCTAssertEqual(file3.lastPathComponent, "未命名 3.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file3.path))
    }

    // MARK: - 2. 路径转义与格式化测试

    func test_escapeForShell_handlesSpecialCharactersSafely() {
        // 普通安全路径不需要额外引号
        XCTAssertEqual(RightClickActionExecutor.escapeForShell("/Users/seam/Documents/file.txt"), "/Users/seam/Documents/file.txt")
        
        // 含空格
        XCTAssertEqual(RightClickActionExecutor.escapeForShell("/Users/seam/My Projects/app.swift"), "'/Users/seam/My Projects/app.swift'")
        
        // 含单引号
        XCTAssertEqual(RightClickActionExecutor.escapeForShell("/Users/seam/It's a test.md"), "'/Users/seam/It'\\''s a test.md'")
    }

    func test_formatPaths_supportsAllFormats() {
        let url1 = URL(fileURLWithPath: "/tmp/foo.txt")
        let url2 = URL(fileURLWithPath: "/tmp/bar baz.txt")

        let posix = executor.formatPaths([url1, url2], format: .posix)
        XCTAssertEqual(posix, "/tmp/foo.txt\n/tmp/bar baz.txt")

        let escaped = executor.formatPaths([url1, url2], format: .shellEscaped)
        XCTAssertEqual(escaped, "/tmp/foo.txt\n'/tmp/bar baz.txt'")

        let fileNames = executor.formatPaths([url1, url2], format: .fileName)
        XCTAssertEqual(fileNames, "foo.txt\nbar baz.txt")
    }

    // MARK: - 3. 移动 / 复制防冲测试

    func test_resolveNonConflictingDestinationURL_incrementsCorrectly() throws {
        let targetDir = tempDirectory.appendingPathComponent("DestDir")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let source = tempDirectory.appendingPathComponent("report.pdf")
        FileManager.default.createFile(atPath: source.path, contents: "test".data(using: .utf8))

        // 目标目录尚无此文件，应保持原名
        let dest1 = executor.resolveNonConflictingDestinationURL(sourceURL: source, targetDirectoryURL: targetDir)
        XCTAssertEqual(dest1.lastPathComponent, "report.pdf")

        // 在目标目录下创建 report.pdf 制造冲突
        FileManager.default.createFile(atPath: dest1.path, contents: Data())
        let dest2 = executor.resolveNonConflictingDestinationURL(sourceURL: source, targetDirectoryURL: targetDir)
        XCTAssertEqual(dest2.lastPathComponent, "report (1).pdf")

        // 再次制造冲突
        FileManager.default.createFile(atPath: dest2.path, contents: Data())
        let dest3 = executor.resolveNonConflictingDestinationURL(sourceURL: source, targetDirectoryURL: targetDir)
        XCTAssertEqual(dest3.lastPathComponent, "report (2).pdf")
    }

    func test_moveFiles_movesAndPreventsCollision() throws {
        let targetDir = tempDirectory.appendingPathComponent("DestDir")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let fileA = tempDirectory.appendingPathComponent("sample.txt")
        FileManager.default.createFile(atPath: fileA.path, contents: "dataA".data(using: .utf8))

        // 先把一个 sample.txt 放入 targetDir
        FileManager.default.createFile(atPath: targetDir.appendingPathComponent("sample.txt").path, contents: "existing".data(using: .utf8))

        // 移动 fileA 到 targetDir
        let moved = try executor.moveFiles([fileA], to: targetDir)
        XCTAssertEqual(moved.count, 1)
        XCTAssertEqual(moved.first?.lastPathComponent, "sample (1).txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.first!.path))
    }

    // MARK: - 5. 隐藏文件可见性测试

    func test_toggleHiddenFiles_flipsFalseToTrueAndRelaunchesFinder() {
        let preferences = StubFinderPreferenceStore()
        let relauncher = StubFinderRelauncher()
        let executor = RightClickActionExecutor(preferences: preferences, relauncher: relauncher)

        // 未写入时按隐藏处理
        XCTAssertNil(preferences.stored[RightClickActionExecutor.showAllFilesPreferenceKey])

        let nowVisible = executor.toggleHiddenFiles()

        XCTAssertTrue(nowVisible)
        XCTAssertEqual(preferences.stored["AppleShowAllFiles"], true)
        XCTAssertEqual(relauncher.relaunchCount, 1)
    }

    func test_toggleHiddenFiles_flipsTrueToFalse() {
        let preferences = StubFinderPreferenceStore()
        preferences.stored["AppleShowAllFiles"] = true
        let relauncher = StubFinderRelauncher()
        let executor = RightClickActionExecutor(preferences: preferences, relauncher: relauncher)

        let nowVisible = executor.toggleHiddenFiles()

        XCTAssertFalse(nowVisible)
        XCTAssertEqual(preferences.stored["AppleShowAllFiles"], false)
        XCTAssertEqual(relauncher.relaunchCount, 1)
    }

    func test_toggleHiddenFiles_writesFinderDomainWithAppleShowAllFilesKey() {
        let preferences = StubFinderPreferenceStore()
        let executor = RightClickActionExecutor(preferences: preferences, relauncher: StubFinderRelauncher())

        _ = executor.toggleHiddenFiles()

        XCTAssertEqual(preferences.recordedWrites.count, 1)
        let write = preferences.recordedWrites[0]
        XCTAssertEqual(write.key, "AppleShowAllFiles")
        XCTAssertEqual(write.domain, "com.apple.finder")
        XCTAssertEqual(write.value, true)
    }

    func test_toggleHiddenFiles_doesNotRelaunchWhenWriteFails() {
        let preferences = StubFinderPreferenceStore()
        preferences.stored["AppleShowAllFiles"] = false
        preferences.writeSucceeds = false
        let relauncher = StubFinderRelauncher()
        let executor = RightClickActionExecutor(preferences: preferences, relauncher: relauncher)

        let nowVisible = executor.toggleHiddenFiles()

        // 写失败时保持原值，且不重启访达
        XCTAssertFalse(nowVisible)
        XCTAssertEqual(relauncher.relaunchCount, 0)
    }
}

// MARK: - 测试替身

private final class StubFinderPreferenceStore: FinderPreferenceStore {
    var stored: [String: Bool] = [:]
    var writeSucceeds = true
    private(set) var recordedWrites: [(key: String, domain: String, value: Bool)] = []

    func bool(forKey key: String, inApplicationDomain domain: String) -> Bool? {
        stored[key]
    }

    @discardableResult
    func set(_ value: Bool, forKey key: String, inApplicationDomain domain: String) -> Bool {
        recordedWrites.append((key, domain, value))
        guard writeSucceeds else { return false }
        stored[key] = value
        return true
    }
}

private final class StubFinderRelauncher: FinderRelauncher {
    private(set) var relaunchCount = 0

    func relaunchFinder() {
        relaunchCount += 1
    }
}
