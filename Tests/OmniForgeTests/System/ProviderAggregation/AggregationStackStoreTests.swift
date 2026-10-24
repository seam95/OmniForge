import XCTest
@testable import OmniForge

/// 聚合名单持久化：缺失当空栈、损坏隔离（不 throw）、原子往返、建中间目录、0600 权限。
final class AggregationStackStoreTests: XCTestCase {
    private var tmpDir: URL!
    private var stackURL: URL!
    private var store: AggregationStackStore!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AggregationStackStoreTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        stackURL = tmpDir.appendingPathComponent("stack.json")
        store = AggregationStackStore(stackURL: stackURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func test_load_returnsEmptyStackWhenFileMissing() {
        XCTAssertEqual(store.load(), AggregationStack())
    }

    func test_load_quarantinesCorruptFileAndReturnsEmptyStack() throws {
        try Data("not json".utf8).write(to: stackURL)
        XCTAssertEqual(store.load(), AggregationStack())
        XCTAssertTrue(FileManager.default.fileExists(atPath: stackURL.path) == false)
        let quarantined = try FileManager.default.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil)
        XCTAssertTrue(quarantined.contains { $0.lastPathComponent.hasPrefix("stack.json.corrupt-") })
    }

    func test_save_thenLoad_roundTrips() throws {
        let stack = AggregationStack(claudeCode: .init(enabled: true, members: ["kimi"], keys: ["kimi": "kimi"]))
        try store.save(stack)
        XCTAssertEqual(store.load(), stack)
    }

    func test_save_createsIntermediateDirectories() throws {
        let nested = AggregationStackStore(stackURL: tmpDir.appendingPathComponent("a/b/stack.json"))
        try nested.save(AggregationStack(codex: .init(members: ["x"], keys: ["x": "x"])))
        XCTAssertEqual(nested.load().toolStack(.codex).members, ["x"])
    }

    func test_savedFileIsNotWorldReadable() throws {
        try store.save(AggregationStack())
        let attrs = try FileManager.default.attributesOfItem(atPath: stackURL.path)
        XCTAssertEqual(attrs[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
    }
}

// MARK: - Desktop 后向兼容

extension AggregationStackStoreTests {
    /// 存量 stack.json 只有 claudeCode/codex 两键（Desktop 接入前的全部存量）：
    /// 解码不失败，claudeDesktop 取默认空栈。
    func test_load_legacyTwoToolJSONDecodesWithEmptyDesktopStack() throws {
        let legacyJSON = """
        {"claudeCode":{"enabled":true,"members":["kimi"],"keys":{"kimi":"kimi"}},"codex":{"enabled":false,"members":[],"keys":{}}}
        """
        try Data(legacyJSON.utf8).write(to: stackURL)
        let stack = store.load()
        XCTAssertEqual(stack.claudeCode.members, ["kimi"])
        XCTAssertTrue(stack.claudeCode.enabled)
        XCTAssertEqual(stack.claudeDesktop, AggregationStack.ToolStack())
    }

    /// 新格式三键往返不丢 Desktop 栈。
    func test_save_thenLoad_roundTripsDesktopStack() throws {
        let stack = AggregationStack(
            claudeDesktop: .init(enabled: true, members: ["glm"], keys: ["glm": "glm"])
        )
        try store.save(stack)
        XCTAssertEqual(store.load(), stack)
    }
}
