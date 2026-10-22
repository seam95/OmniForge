import Foundation
import XCTest
@testable import OmniForge

/// Oh My Pi 采集器：复用 Pi 格式解析、递归扫描子代理文件（同目录内独立 session 文件）、
/// OMP 的 model 键 / reasoningTokens 拼写、增量游标与测试进程守卫。
final class OmpUsageCollectorTests: XCTestCase {
    private var root: URL!
    private var sessionsDir: URL!
    private var store: FakeUsageStore!
    private var watcher: FakeDirectoryWatcher!
    private var scheduler: FakeRepeatingScheduler!
    private var collector: OmpUsageCollector!

    private let parentSessionID = "019f4a9e-2371-7000-ad7d-d32c511b23b3"
    private let parentFileName = "2026-07-10T06-01-45-585Z_019f4a9e-2371-7000-ad7d-d32c511b23b3.jsonl"
    private let subagentSessionID = "019f4aa1-366d-7000-9452-4eb4826bb9b2"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmpUsageCollectorTests_\(UUID().uuidString)", isDirectory: true)
        sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        store = FakeUsageStore()
        watcher = FakeDirectoryWatcher()
        scheduler = FakeRepeatingScheduler()
        collector = OmpUsageCollector(
            store: store,
            sessionsDirectory: sessionsDir,
            scheduler: scheduler,
            watcher: watcher
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 回填：主会话 + 子代理

    func test_backfill_parentAndSubagentFiles_areIndependentSessions() throws {
        let project = "--Users-seam-proj--"
        _ = try writeFile(project: project, fileName: parentFileName, lines: [
            titleLine(),
            sessionLine(id: parentSessionID),
            modelChangeLine(model: "deepseek/deepseek-v4-flash"),
            messageLine(
                id: "p1",
                usage: ["input": 100, "output": 50, "cacheRead": 10, "cacheWrite": 5, "reasoningTokens": 20]
            ),
        ])
        // 子代理文件：主会话同名目录内，带自己的 session 头，是完整 session。
        _ = try writeNestedFile(
            project: project,
            parentDirectory: "2026-07-10T06-01-45-585Z_019f4a9e-2371-7000-ad7d-d32c511b23b3",
            fileName: "CodeReviewer.jsonl",
            lines: [
                sessionLine(id: subagentSessionID, timestamp: "2026-07-10T06:02:00.000Z"),
                messageLine(
                    id: "s1",
                    usage: ["input": 30, "output": 10, "reasoningTokens": 2],
                    timestamp: "2026-07-10T06:02:10.000Z",
                    model: "claude-opus-5",
                    provider: "anthropic"
                ),
            ]
        )

        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }

        XCTAssertEqual(store.conversations(), 2, "主会话与子代理文件各算 1 个会话")
        XCTAssertEqual(store.totalTokens(), 190, "父 150 + 子 40（reasoning 是 output 子集，不重复计）")
        let byModel = Dictionary(uniqueKeysWithValues: store.bucketsByKey.values
            .filter { $0.key.provider == .omp }
            .map { ($0.key.model, $0.usage) })
        XCTAssertEqual(byModel.count, 2)
        let parentUsage = try XCTUnwrap(byModel["deepseek/deepseek-v4-flash"], "OMP model_change 用 model 键");
        XCTAssertEqual(parentUsage.inputTokens, 100)
        XCTAssertEqual(parentUsage.cachedInputTokens, 10)
        XCTAssertEqual(parentUsage.cacheCreationInputTokens, 5)
        XCTAssertEqual(parentUsage.outputTokens, 30, "output 拆掉 reasoningTokens：50 - 20")
        XCTAssertEqual(parentUsage.reasoningOutputTokens, 20)
        XCTAssertEqual(parentUsage.totalTokens, 150)
        let subagentUsage = try XCTUnwrap(byModel["claude-opus-5"], "子代理无 model_change 时回退消息模型");
        XCTAssertEqual(subagentUsage.outputTokens, 8)
        XCTAssertEqual(subagentUsage.totalTokens, 40)
        XCTAssertEqual(store.seenKeys.count, 4, "2 条消息 + 2 个会话 marker")
    }

    func test_incrementalAppendToSubagentFile_usesPersistedModel() throws {
        let project = "--Users-seam-proj--"
        let subagent = try writeNestedFile(
            project: project,
            parentDirectory: "2026-07-10T06-01-45-585Z_019f4a9e-2371-7000-ad7d-d32c511b23b3",
            fileName: "CodeReviewer.jsonl",
            lines: [
                sessionLine(id: subagentSessionID),
                modelChangeLine(model: "deepseek/deepseek-v4-flash"),
                messageLine(id: "s1", usage: ["input": 100, "output": 10]),
            ]
        )
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 110)

        try append(
            messageLine(
                id: "s2",
                usage: ["input": 200, "output": 20],
                timestamp: "2026-07-10T06:05:00.000Z"
            ),
            to: subagent
        )
        watcher.simulateChange()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 2 }

        XCTAssertEqual(store.totalTokens(), 330, "增量续读 110 + 220")
        XCTAssertEqual(store.cursors[subagent.standardizedFileURL.path]?.model, "deepseek/deepseek-v4-flash")
        let ompBuckets = store.bucketsByKey.values.filter { $0.key.provider == .omp }
        XCTAssertEqual(ompBuckets.count, 1)
        XCTAssertEqual(ompBuckets.first?.key.model, "deepseek/deepseek-v4-flash")
        XCTAssertEqual(store.conversations(), 1)
    }

    func test_twoSubagentFiles_countSeparateSessions() throws {
        let project = "--Users-seam-proj--"
        for (index, agent) in ["CodeReviewer", "Advisor"].enumerated() {
            _ = try writeNestedFile(
                project: project,
                parentDirectory: "2026-07-10T06-01-45-585Z_019f4a9e-2371-7000-ad7d-d32c511b23b3",
                fileName: "\(agent).jsonl",
                lines: [
                    sessionLine(id: "session-\(index)"),
                    messageLine(
                        id: "\(agent)-m1",
                        usage: ["input": 10, "output": 2],
                        model: "deepseek-v4-flash"
                    ),
                ]
            )
        }
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }

        XCTAssertEqual(store.totalTokens(), 24)
        XCTAssertEqual(store.conversations(), 2)
    }

    // MARK: - 生命周期 / 保护

    func test_defaultSessionsDirectory_isOmpAgentSessions() {
        XCTAssertTrue(
            OmpUsageCollector.defaultSessionsDirectory.path.hasSuffix("/.omp/agent/sessions")
        )
        XCTAssertTrue(
            OmpUsageCollector.defaultSessionsDirectory.path != PiUsageCollector.defaultSessionsDirectory.path,
            "Pi 与 OMP 扫描根不同，避免重复计数"
        )
    }

    func test_start_inUnitTestProcess_doesNotScanRealUserDirectory() {
        let realCollector = OmpUsageCollector(store: store)
        realCollector.start()
        realCollector.waitForIdle()
        XCTAssertEqual(realCollector.scanCount, 0, "测试进程下默认目录采集器不启动扫描")
        XCTAssertTrue(store.cursors.isEmpty)
        realCollector.stop()
    }

    func test_stop_stopsWatcherAndTimer() {
        collector.start()
        collector.waitForIdle()
        collector.stop()
        XCTAssertFalse(watcher.isWatching)
        XCTAssertEqual(scheduler.activeScheduleCount, 0, "定时器被取消")
    }

    // MARK: - 工具

    private func pumpUntil(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "pumpUntil timed out")
    }

    @discardableResult
    private func writeFile(project: String, fileName: String, lines: [String]) throws -> URL {
        let directory = sessionsDir.appendingPathComponent(project, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try write(lines: lines, to: directory.appendingPathComponent(fileName))
    }

    @discardableResult
    private func writeNestedFile(
        project: String,
        parentDirectory: String,
        fileName: String,
        lines: [String]
    ) throws -> URL {
        let directory = sessionsDir
            .appendingPathComponent(project, isDirectory: true)
            .appendingPathComponent(parentDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try write(lines: lines, to: directory.appendingPathComponent(fileName))
    }

    @discardableResult
    private func write(lines: [String], to url: URL) throws -> URL {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    private func append(_ line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(Data((line + "\n").utf8))
        try handle.close()
    }

    private func jsonLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func titleLine() -> String {
        jsonLine(["type": "title", "v": 1, "title": "", "updatedAt": "2026-07-10T06:01:45.585Z"])
    }

    private func sessionLine(id: String, timestamp: String = "2026-07-10T06:01:45.585Z") -> String {
        jsonLine([
            "type": "session",
            "version": 3,
            "id": id,
            "timestamp": timestamp,
            "cwd": "/Users/seam/proj",
        ])
    }

    /// OMP 的 model_change 用 model 键（无 modelId、provider 可能为 null）。
    private func modelChangeLine(model: String) -> String {
        jsonLine([
            "type": "model_change",
            "id": UUID().uuidString,
            "parentId": NSNull(),
            "timestamp": "2026-07-10T06:01:45.593Z",
            "model": model,
            "provider": NSNull(),
        ])
    }

    private func messageLine(
        id: String? = nil,
        usage: [String: Any]? = nil,
        timestamp: String = "2026-07-10T06:04:15.332Z",
        model: String? = nil,
        provider: String? = nil
    ) -> String {
        var message: [String: Any] = ["role": "assistant"]
        var object: [String: Any] = ["type": "message"]
        if let id { object["id"] = id }
        object["timestamp"] = timestamp
        if let usage { message["usage"] = usage }
        if let model { message["model"] = model }
        if let provider { message["provider"] = provider }
        object["message"] = message
        return jsonLine(object)
    }
}
