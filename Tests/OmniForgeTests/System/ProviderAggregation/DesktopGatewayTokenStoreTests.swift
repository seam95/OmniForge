import XCTest
@testable import OmniForge

/// Desktop 网关 token：首次生成（ccs- 前缀 + UUID）、幂等（已存在原样返回）、0600 权限、
/// 空白文件视为缺失重新生成。
final class DesktopGatewayTokenStoreTests: XCTestCase {
    private var tmpDir: URL!
    private var tokenURL: URL!
    private var store: DesktopGatewayTokenStore!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesktopGatewayTokenStoreTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        tokenURL = tmpDir.appendingPathComponent("desktop-gateway-token")
        store = DesktopGatewayTokenStore(tokenURL: tokenURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func test_loadOrCreate_generatesCCSPrefixedToken() throws {
        let token = try store.loadOrCreate()
        XCTAssertTrue(token.hasPrefix(DesktopGatewayTokenStore.tokenPrefix), "token 应带 ccs- 前缀：\(token)")
        XCTAssertGreaterThan(token.count, DesktopGatewayTokenStore.tokenPrefix.count)
    }

    func test_loadOrCreate_isIdempotent() throws {
        let first = try store.loadOrCreate()
        let second = try store.loadOrCreate()
        XCTAssertEqual(first, second, "已存在的 token 必须原样返回，不得换新")
    }

    func test_savedTokenIsNotWorldReadable() throws {
        _ = try store.loadOrCreate()
        let attrs = try FileManager.default.attributesOfItem(atPath: tokenURL.path)
        XCTAssertEqual(attrs[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
    }

    func test_load_returnsNilWhenMissingOrBlank() throws {
        XCTAssertNil(try store.load())
        try Data("   \n".utf8).write(to: tokenURL)
        XCTAssertNil(try store.load(), "空白文件视为缺失")
        // 空白后 loadOrCreate 重新生成。
        let token = try store.loadOrCreate()
        XCTAssertTrue(token.hasPrefix(DesktopGatewayTokenStore.tokenPrefix))
    }
}
