import XCTest
@testable import OmniForge
import CryptoKit

/// Codex 陈旧客户端检测：目录代指纹记录、非我方目录不判、启动早于当前代的 daemon 判陈旧、
/// 启动晚于当前代的 daemon 不陈旧、历史上限 32、登录代次、ack 抑制、进程表不可得降级。
final class CodexStaleClientDetectorTests: XCTestCase {
    private var tmpDir: URL!
    private var historyURL: URL!
    private var catalogURL: URL!
    private var authURL: URL!
    private var detector: StubDetector!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexStaleClientDetectorTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        historyURL = tmpDir.appendingPathComponent("codex-catalog-history.json")
        catalogURL = tmpDir.appendingPathComponent("omniforge-stack-catalog.json")
        authURL = tmpDir.appendingPathComponent("auth.json")
        detector = StubDetector(historyURL: historyURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func writeCatalog(_ content: String) throws {
        try Data(content.utf8).write(to: catalogURL)
    }

    private func writeAuth(_ account: String) throws {
        try Data("{\"tokens\":{\"account_id\":\"\(account)\"}}".utf8).write(to: authURL)
    }

    /// 目录字节的 SHA256 十六进制（与检测器口径一致）。
    private func fingerprint(of content: String) -> String {
        Data(SHA256.hash(data: Data(content.utf8))).map { String(format: "%02x", $0) }.joined()
    }

    /// 伪 ps 行：etime 00:10 = 10 秒前启动（早于任何刚记录的代）。
    private func appServerProcess(startedBeforeGeneration: Bool, isManagedDaemon: Bool) -> String {
        appServerProcess(elapsed: startedBeforeGeneration ? "00:10" : "00:00", isManagedDaemon: isManagedDaemon)
    }

    /// 伪 ps 行：app-server，etime 直接给（需要「落在两代之间」的启动时刻时用）。
    private func appServerProcess(elapsed: String, isManagedDaemon: Bool = false) -> String {
        let command = isManagedDaemon ? "codex app-server --managed-daemon" : "codex app-server"
        return "  1234 \(elapsed) \(command)"
    }

    func test_observe_recordsGenerationWithCatalogFingerprint() throws {
        try writeCatalog("v1")
        detector.observe(catalogURL: catalogURL, catalogIsOurs: true)
        XCTAssertEqual(try detector.loadHistory().last?.fingerprint, fingerprint(of: "v1"))
    }

    func test_observe_recordsNoneFingerprintWhenCatalogIsNotOurs() throws {
        detector.observe(catalogURL: catalogURL, catalogIsOurs: false)
        XCTAssertEqual(try detector.loadHistory().last?.fingerprint, "none")
    }

    func test_staleClients_nilWhenCatalogIsNotOurs() async throws {
        detector.observe(catalogURL: catalogURL, catalogIsOurs: false)
        let stale = await detector.staleClients(catalogURL: catalogURL, catalogIsOurs: false)
        XCTAssertNil(stale)
    }

    func test_staleClients_detectsDaemonStartedBeforeCurrentGeneration() async throws {
        try writeCatalog("v1")
        detector.observe(catalogURL: catalogURL, catalogIsOurs: true)
        try await Task.sleep(nanoseconds: 50_000_000)
        try writeCatalog("v2")
        detector.observe(catalogURL: catalogURL, catalogIsOurs: true)
        detector.stubProcesses = [appServerProcess(startedBeforeGeneration: true, isManagedDaemon: true)]
        let stale = await detector.staleClients(catalogURL: catalogURL, catalogIsOurs: true)
        XCTAssertEqual(stale, CodexStaleClients(daemon: true, others: false))
    }

    func test_staleClients_freshDaemonIsNotStale() async throws {
        try writeCatalog("v1")
        detector.observe(catalogURL: catalogURL, catalogIsOurs: true)
        detector.stubProcesses = [appServerProcess(startedBeforeGeneration: false, isManagedDaemon: true)]
        let stale = await detector.staleClients(catalogURL: catalogURL, catalogIsOurs: true)
        XCTAssertEqual(stale, CodexStaleClients(daemon: false, others: false))
    }

    func test_historyIsCappedAtLimit() throws {
        for index in 0..<40 {
            try writeCatalog("v\(index)")
            detector.observe(catalogURL: catalogURL, catalogIsOurs: true)
        }
        XCTAssertEqual(try detector.loadHistory().count, CodexStaleClientDetector.historyLimit)
    }

    func test_observeLogin_recordsAuthFingerprintGeneration() throws {
        try writeAuth("account-a")
        detector.observeLogin(authURL: authURL)
        XCTAssertEqual(
            try detector.loadLoginHistory().last?.fingerprint,
            fingerprint(of: "{\"tokens\":{\"account_id\":\"account-a\"}}")
        )
        // 指纹没变不记新代（对齐 cc-switch `record_history`：否则「从没变过」会被当成切换过）。
        detector.observeLogin(authURL: authURL)
        XCTAssertEqual(try detector.loadLoginHistory().count, 1)
        // auth.json 缺失 → 记 "none"。
        try FileManager.default.removeItem(at: authURL)
        detector.observeLogin(authURL: authURL)
        XCTAssertEqual(try detector.loadLoginHistory().last?.fingerprint, "none")
    }

    func test_loginHistoryIsCappedAtLimit() throws {
        for index in 0..<40 {
            try writeAuth("account-\(index)")
            detector.observeLogin(authURL: authURL)
        }
        XCTAssertEqual(try detector.loadLoginHistory().count, CodexStaleClientDetector.historyLimit)
    }

    func test_staleClients_suppressedWhenCurrentGenerationMatchesAck() async throws {
        try writeCatalog("v1")
        detector.observe(catalogURL: catalogURL, catalogIsOurs: true)
        detector.stubProcesses = [appServerProcess(startedBeforeGeneration: true, isManagedDaemon: true)]
        // 未确认 → 报 daemon 陈旧。
        var stale = await staleNow()
        XCTAssertEqual(stale, CodexStaleClients(daemon: true, others: false, loginChanged: false, unverified: false))
        // 关掉横幅 = 写当前指纹 → 同一份不再报。
        detector.acknowledge(catalogURL: catalogURL, authURL: authURL)
        stale = await staleNow()
        XCTAssertEqual(stale, CodexStaleClients(daemon: false, others: false, loginChanged: false, unverified: false))
        // 指纹再变才重现。
        try await Task.sleep(nanoseconds: 50_000_000)
        try writeCatalog("v2")
        detector.observe(catalogURL: catalogURL, catalogIsOurs: true)
        stale = await staleNow()
        XCTAssertEqual(stale, CodexStaleClients(daemon: true, others: false, loginChanged: false, unverified: false))
    }

    func test_staleClients_reportsLoginChange() async throws {
        try writeCatalog("v1")
        detector.observe(catalogURL: catalogURL, catalogIsOurs: true)
        try writeAuth("account-a")
        detector.observeLogin(authURL: authURL)
        // 启动晚于目录代：目录不陈旧；登录只观察过一次 → 不算切号。
        detector.stubProcesses = [appServerProcess(elapsed: "00:00")]
        var stale = await staleNow()
        XCTAssertEqual(
            stale,
            CodexStaleClients(daemon: false, others: false, loginChanged: false, unverified: false),
            "首次观察登录不是切号"
        )
        // 登录 A→B：进程启动于两代之间 → 缓存着旧账号（目录没变，others 不报）。
        try await Task.sleep(nanoseconds: 4_200_000_000)
        try writeAuth("account-b")
        detector.observeLogin(authURL: authURL)
        detector.stubProcesses = [appServerProcess(elapsed: "00:03")]
        stale = await staleNow()
        XCTAssertEqual(stale, CodexStaleClients(daemon: false, others: false, loginChanged: true, unverified: false))
        // ack 后指纹未变 → 不报。
        detector.acknowledge(catalogURL: catalogURL, authURL: authURL)
        stale = await staleNow()
        XCTAssertEqual(stale, CodexStaleClients(daemon: false, others: false, loginChanged: false, unverified: false))
    }

    func test_unverified_setWhenProcessTableUnavailable() async throws {
        try writeCatalog("v1")
        detector.observe(catalogURL: catalogURL, catalogIsOurs: true)
        // 进程表不可得 → 置位；没确认过（无 ack）→ 不猜有没有客户端开着。
        detector.stubProcesses = nil
        var stale = await staleNow()
        XCTAssertEqual(stale, CodexStaleClients(daemon: false, others: false, loginChanged: false, unverified: true))
        // 进程表拿得到（哪怕没有 app-server 进程）→ 不置位。
        detector.stubProcesses = []
        stale = await staleNow()
        XCTAssertEqual(stale, CodexStaleClients(daemon: false, others: false, loginChanged: false, unverified: false))
        // 降级路径：确认后目录变了 → others 只表示「变了」，不知是否开着。
        detector.acknowledge(catalogURL: catalogURL, authURL: authURL)
        try writeCatalog("v2")
        detector.observe(catalogURL: catalogURL, catalogIsOurs: true)
        detector.stubProcesses = nil
        stale = await staleNow()
        XCTAssertEqual(stale, CodexStaleClients(daemon: false, others: true, loginChanged: false, unverified: true))
    }

    /// 老负载（只有 daemon/others 两个键）缺键不抛——合成 `Codable` 会抛 `keyNotFound`。
    func test_codexStaleClients_decodesPayloadMissingNewFields() throws {
        let payload = Data(#"{"daemon":true,"others":false}"#.utf8)
        let decoded = try JSONDecoder().decode(CodexStaleClients.self, from: payload)
        XCTAssertEqual(decoded, CodexStaleClients(daemon: true, others: false, loginChanged: false, unverified: false))
    }

    /// 当前检测结果（`await` 不能写在 XCTAssert 的 autoclosure 里，先取出来）。
    private func staleNow() async -> CodexStaleClients? {
        await detector.staleClients(catalogURL: catalogURL, catalogIsOurs: true)
    }
}

/// 测试子类：`stubProcesses` 承载伪 ps 输出（nil = 进程表不可得）。
private final class StubDetector: CodexStaleClientDetector {
    var stubProcesses: [String]? = []
    override func probeProcesses() async -> String? {
        stubProcesses?.joined(separator: "\n")
    }
}
