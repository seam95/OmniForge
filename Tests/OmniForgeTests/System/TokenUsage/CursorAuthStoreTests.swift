import Foundation
import XCTest
@testable import OmniForge

/// Cursor 凭证读取：state.vscdb（SQLite ItemTable）+ cli-config.json 的
/// userId 标准化、`WorkosCursorSessionToken=<userId>%3A%3A<jwt>` cookie 拼装。
/// 隐私红线：accessToken 只在内存中使用，读后不落盘副本（SPEC 2.6；参考 08/cursor-config.js:29-158）。
final class CursorAuthStoreTests: XCTestCase {
    private var root: URL!
    private var stateDB: URL!
    private var cliConfig: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CursorAuthStoreTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        stateDB = root.appendingPathComponent("state.vscdb")
        cliConfig = root.appendingPathComponent("cli-config.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// 用 sqlite3 CLI 构造最小 state.vscdb（ItemTable + cursorAuth/accessToken）。
    private func writeStateDB(accessToken: String) throws {
        let sql = """
        CREATE TABLE ItemTable (key TEXT, value TEXT);
        INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '\(accessToken)');
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [stateDB.path, sql]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "sqlite3 建库成功")
    }

    private func writeCLIConfig(authId: String) throws {
        let json = try JSONSerialization.data(withJSONObject: ["authInfo": ["authId": authId]])
        try json.write(to: cliConfig)
    }

    private func makeReader() -> CursorVSCDBCredentialReader {
        CursorVSCDBCredentialReader(stateDBPath: stateDB, cliConfigPath: cliConfig)
    }

    // MARK: - 路径解析

    func test_defaultPaths_pointAtCursorAppSupportAndCliConfig() {
        let reader = CursorVSCDBCredentialReader()
        XCTAssertEqual(
            reader.stateDBPath.path,
            FileManager.default.homeDirectoryForCurrentUser.path
                + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        )
        XCTAssertEqual(
            reader.cliConfigPath.path,
            FileManager.default.homeDirectoryForCurrentUser.path + "/.cursor/cli-config.json"
        )
        XCTAssertTrue(reader.usesDefaultPaths)
    }

    // MARK: - subject 标准化（参考 cursor-config.js:101-124）

    func test_subject_normalizer_nativeAuth0StripsPrefix() {
        XCTAssertEqual(CursorSubjectNormalizer.normalize("auth0|user_abc123"), "user_abc123")
        XCTAssertEqual(CursorSubjectNormalizer.normalize("google-oauth2|user_9"), "user_9", "任何带 user_ 前缀的 subject 都先走原生规则")
    }

    func test_subject_normalizer_workosBridgingKeepsVerbatim() {
        XCTAssertEqual(CursorSubjectNormalizer.normalize("google-oauth2|123456789"), "google-oauth2|123456789")
        XCTAssertEqual(CursorSubjectNormalizer.normalize("github|octocat"), "github|octocat")
        XCTAssertEqual(CursorSubjectNormalizer.normalize("oidc|subj-42"), "oidc|subj-42")
        XCTAssertEqual(CursorSubjectNormalizer.normalize("auth0|other"), "auth0|other", "auth0 也在白名单（WorkOS 桥接）")
    }

    func test_subject_normalizer_rejectsUnknownSubjects() {
        XCTAssertNil(CursorSubjectNormalizer.normalize("system:admin"))
        XCTAssertNil(CursorSubjectNormalizer.normalize(""))
        XCTAssertNil(CursorSubjectNormalizer.normalize(nil))
        XCTAssertNil(CursorSubjectNormalizer.normalize("auth0|user_x|extra"), "含额外管道不为 bridge 格式")
    }

    func test_subject_normalizer_fromJWT_readsSubClaim() throws {
        let jwt = makeJWT(sub: "auth0|user_xyz", exp: 2_000_000_000)
        XCTAssertEqual(CursorSubjectNormalizer.fromJWT(jwt), "user_xyz")
        XCTAssertEqual(
            CursorSubjectNormalizer.fromJWT(makeJWT(sub: "github|octocat")),
            "github|octocat"
        )
        XCTAssertNil(CursorSubjectNormalizer.fromJWT("not-a-jwt"), "非 JWT → nil")
        XCTAssertNil(CursorSubjectNormalizer.fromJWT(nil))
    }

    // MARK: - cookie 拼装（WorkosCursorSessionToken=<userId>%3A%3A<jwt>）

    func test_cookie_isExactEncodeFormat() {
        let cookie = CursorSessionCookieBuilder.cookie(userId: "user_abc", jwt: "jwt.payload.sig")
        XCTAssertEqual(cookie, "WorkosCursorSessionToken=user_abc%3A%3Ajwt.payload.sig")
    }

    func test_cookie_keepsJwtPlusSignsAndDotsVerbatim() {
        let jwt = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJhdXRoMHx1c2VyX2FiYyJ9.sig+x"
        let cookie = CursorSessionCookieBuilder.cookie(userId: "user_abc", jwt: jwt)
        XCTAssertEqual(cookie, "WorkosCursorSessionToken=user_abc%3A%3AeyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJhdXRoMHx1c2VyX2FiYyJ9.sig+x")
    }

    // MARK: - readBundle（SQLite + cli-config，读后不落盘副本）

    func test_readBundle_readsJwtFromSqliteAndAuthIdFromCliConfig() throws {
        try writeStateDB(accessToken: "jwt-abcdefgh-123")
        try writeCLIConfig(authId: "auth0|user_abc")
        let bundle = try XCTUnwrap(makeReader().readBundle())
        XCTAssertEqual(bundle.jwt, "jwt-abcdefgh-123")
        XCTAssertEqual(bundle.userId, "user_abc")
        XCTAssertEqual(bundle.sessionCookie, "WorkosCursorSessionToken=user_abc%3A%3Ajwt-abcdefgh-123")
    }

    func test_readBundle_fallsBackToJwtSubWhenCliConfigAbsent() throws {
        try writeStateDB(accessToken: makeJWT(sub: "auth0|user_def"))
        let bundle = try XCTUnwrap(makeReader().readBundle())
        XCTAssertEqual(bundle.userId, "user_def", "cli-config.json 缺失 → JWT sub 兜底")
        XCTAssertEqual(bundle.sessionCookie, "WorkosCursorSessionToken=user_def%3A%3A\(makeJWT(sub: "auth0|user_def"))")
    }

    func test_readBundle_cliConfigWinsOverJwtSub() throws {
        let jwt = makeJWT(sub: "auth0|user_from_jwt")
        try writeStateDB(accessToken: jwt)
        try writeCLIConfig(authId: "google-oauth2|123")
        let bundle = try XCTUnwrap(makeReader().readBundle())
        XCTAssertEqual(bundle.userId, "google-oauth2|123", "cli-config authId 优先")
    }

    func test_readBundle_returnsNilWhenStateDbMissing() throws {
        XCTAssertNil(try makeReader().readBundle(), "无 state.vscdb → 未配置")
    }

    func test_readBundle_returnsNilWhenAccessTokenMissingOrTooShort() throws {
        try writeStateDB(accessToken: "short")
        XCTAssertNil(try makeReader().readBundle(), "JWT 长度过短 → nil（参考长度阈 10）")
    }

    func test_readBundle_returnsNilWhenNullOrInvalidAuthId() throws {
        try writeStateDB(accessToken: makeJWT(sub: "system:admin"))
        XCTAssertNil(try makeReader().readBundle(), "未知 subject → nil")
    }

    // MARK: - 工具

    /// 最小三段式 JWT（payload 仅 sub/exp）。
    private func makeJWT(sub: String, exp: Double = 2_000_000_000) -> String {
        let header = "eyJhbGciOiJSUzI1NiJ9"
        let payload = Data("{\"sub\":\"\(sub)\",\"exp\":\(exp)}".utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(header).\(payload).sig"
    }
}
