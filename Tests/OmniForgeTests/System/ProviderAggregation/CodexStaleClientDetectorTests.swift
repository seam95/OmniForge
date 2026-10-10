import XCTest
@testable import OmniForge
import CryptoKit

/// Codex 陈旧客户端检测：目录代指纹记录、非我方目录不判、启动早于当前代的 daemon 判陈旧、
/// 启动晚于当前代的 daemon 不陈旧、历史上限 32。
final class CodexStaleClientDetectorTests: XCTestCase {
    private var tmpDir: URL!
    private var historyURL: URL!
    private var catalogURL: URL!
    private var detector: StubDetector!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexStaleClientDetectorTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        historyURL = tmpDir.appendingPathComponent("codex-catalog-history.json")
        catalogURL = tmpDir.appendingPathComponent("cc-switch-model-catalog.json")
        detector = StubDetector(historyURL: historyURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func writeCatalog(_ content: String) throws {
        try Data(content.utf8).write(to: catalogURL)
    }

    /// 目录字节的 SHA256 十六进制（与检测器口径一致）。
    private func fingerprint(of content: String) -> String {
        Data(SHA256.hash(data: Data(content.utf8))).map { String(format: "%02x", $0) }.joined()
    }

    /// 伪 ps 行：etime 00:10 = 10 秒前启动（早于任何刚记录的代）。
    private func appServerProcess(startedBeforeGeneration: Bool, isManagedDaemon: Bool) -> String {
        let etime = startedBeforeGeneration ? "00:10" : "00:00"
        let command = isManagedDaemon ? "codex app-server --managed-daemon" : "codex app-server"
        return "  1234 \(etime) \(command)"
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
}

/// 测试子类：`stubProcesses` 承载伪 ps 输出（主类不持有该属性）。
private final class StubDetector: CodexStaleClientDetector {
    var stubProcesses: [String] = []
    override func probeProcesses() async -> String? {
        stubProcesses.joined(separator: "\n")
    }
}
