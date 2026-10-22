import Foundation
import XCTest
import libzstd
@testable import OmniForge

/// DSH 采集器：未压缩/多帧压缩解析、重复扫描幂等、torn tail 重读、fork 继承过滤与回填通知。
final class DshUsageCollectorTests: XCTestCase {
    private var sessionsDir: URL!
    private var store: FakeUsageStore!
    private var watcher: FakeDirectoryWatcher!
    private var scheduler: FakeRepeatingScheduler!
    private var collector: DshUsageCollector!
    private var backfillStates: [Bool] = []

    override func setUpWithError() throws {
        sessionsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DshUsageCollectorTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        store = FakeUsageStore()
        watcher = FakeDirectoryWatcher()
        scheduler = FakeRepeatingScheduler()
        collector = DshUsageCollector(
            store: store,
            sessionsDirectory: sessionsDir,
            scheduler: scheduler,
            watcher: watcher
        )
        backfillStates = []
        collector.onBackfillStateChange = { [weak self] value in
            self?.backfillStates.append(value)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sessionsDir)
    }

    // MARK: - 未压缩 JSONL

    func test_uncompressedSession_parsesUsageSessionsAndModels() throws {
        let file = try writeSessionLog(
            project: "proj",
            session: "session-a",
            fileName: "session.jsonl",
            content: [
                sessionHeaderLine(sessionID: "session-a"),
                userLine(turn: 1, seq: 2, time: 1_792_205_211_000),
                assistantLine(id: "m-1", turn: 1, seq: 3, time: 1_792_205_215_000, input: 100, output: 20),
                userLine(turn: 2, seq: 4, time: 1_792_205_220_000),
                assistantLine(id: "m-2", turn: 2, seq: 5, time: 1_792_205_225_000, input: 200, output: 30),
            ].joined(separator: "\n")
        )
        XCTAssertNotNil(file)

        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }

        XCTAssertEqual(store.totalTokens(), 350)
        XCTAssertEqual(store.conversations(), 2, "每个 turn 首条消息计一次会话")
        XCTAssertEqual(store.bucketsByKey.keys.filter { $0.provider == .dsh }.map(\.model).first, "deepseek-v4.1-flash")
        pumpUntil { self.backfillStates.count == 2 }
        XCTAssertEqual(backfillStates, [true, false], "首次扫描为回填")
    }

    func test_secondScan_isIdempotent() throws {
        _ = try writeSessionLog(
            project: "proj",
            session: "session-a",
            fileName: "session.jsonl",
            content: [
                sessionHeaderLine(sessionID: "session-a"),
                assistantLine(id: "m-1", turn: 1, seq: 3, time: 1_792_205_215_000, input: 100, output: 20),
            ].joined(separator: "\n")
        )
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 120)

        // 文件内容变化触发重扫（mtime/size 变化），事件级去重保证不重复计。
        let url = try sessionURL(project: "proj", session: "session-a")
        let handle = try FileHandle(forWritingTo: url.appendingPathComponent("session.jsonl"))
        try handle.seekToEnd()
        try handle.write(Data("\n".utf8))
        try handle.close()

        watcher.simulateChange()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 2 }
        XCTAssertEqual(store.totalTokens(), 120, "重复扫描不得重复计费")
        XCTAssertEqual(store.conversations(), 1)
    }

    // MARK: - zstd 多帧与 torn tail

    func test_zstdMultiFrame_incrementalAndTornTail() throws {
        let firstLine = assistantLine(id: "m-1", turn: 1, seq: 3, time: 1_792_205_215_000, input: 100, output: 20)
        let secondLine = assistantLine(id: "m-2", turn: 1, seq: 12, time: 1_792_205_225_000, input: 200, output: 30)
        let directory = try sessionURL(project: "proj", session: "session-b")
        let file = directory.appendingPathComponent("session.v4.jsonl.zstd")
        var data = Data()
        data.append(zstdFrame(sessionHeaderLine(sessionID: "session-b") + "\n"))
        data.append(zstdFrame(firstLine + "\n"))
        try data.write(to: file)

        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 120)

        // 追加第二个完整帧：新增用量计入。
        var appended = zstdFrame(secondLine + "\n")
        let half = appended.count / 2
        let tail = appended.subdata(in: half..<appended.count)
        appended = appended.subdata(in: 0..<half)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(appended)
        try handle.close()
        watcher.simulateChange()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 2 }
        XCTAssertEqual(store.totalTokens(), 120, "torn 尾帧不消费，不产生新计数")

        // 补齐剩余半帧：完整帧解压后新事件计入。
        let handle2 = try FileHandle(forWritingTo: file)
        try handle2.seekToEnd()
        try handle2.write(tail)
        try handle2.close()
        watcher.simulateChange()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 3 }
        XCTAssertEqual(store.totalTokens(), 350)
    }

    // MARK: - fork 继承过滤

    func test_forkSeedLengthSkipsInheritedEvents() throws {
        var lines: [String] = []
        lines.append(sessionHeaderLine(sessionID: "session-child", seedLength: 5))
        // seq < 5：父会话复制事件，必须跳过。
        lines.append(assistantLine(id: "m-parent", turn: 1, seq: 3, time: 1_792_205_215_000, input: 999, output: 999))
        // seq >= 5：子会话自己的事件，计入。
        lines.append(assistantLine(id: "m-child", turn: 2, seq: 10, time: 1_792_205_225_000, input: 10, output: 5))
        _ = try writeSessionLog(
            project: "proj",
            session: "session-child",
            fileName: "session.jsonl",
            content: lines.joined(separator: "\n")
        )
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 15, "继承前缀不得重复计费")
    }

    func test_taggedEndSeedBoundarySkipsInheritedEvents() throws {
        var lines: [String] = []
        lines.append(sessionHeaderLine(sessionID: "session-child", isSeeded: true))
        lines.append(assistantLine(id: "m-parent", turn: 1, seq: 3, time: 1_792_205_215_000, input: 999, output: 999))
        lines.append("{\"type\":\"session/end-seed\",\"seq\":8,\"time\":1792205216000,\"data\":{\"inherited\":true}}")
        lines.append(assistantLine(id: "m-child", turn: 2, seq: 9, time: 1_792_205_225_000, input: 10, output: 5))
        _ = try writeSessionLog(
            project: "proj",
            session: "session-child",
            fileName: "session.jsonl",
            content: lines.joined(separator: "\n")
        )
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount == 1 }
        XCTAssertEqual(store.totalTokens(), 15)
    }

    // MARK: - 工具

    private func pumpUntil(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "pumpUntil timed out")
    }

    private func sessionURL(project: String, session: String) throws -> URL {
        let directory = sessionsDir
            .appendingPathComponent(project, isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    private func writeSessionLog(
        project: String,
        session: String,
        fileName: String,
        content: String
    ) throws -> URL {
        let directory = try sessionURL(project: project, session: session)
        let url = directory.appendingPathComponent(fileName)
        try Data(content.utf8).write(to: url)
        return url
    }

    private func sessionHeaderLine(
        sessionID: String,
        seedLength: Int? = nil,
        isSeeded: Bool? = nil
    ) -> String {
        var fields: [String] = [
            "\"type\":\"session\"",
            "\"id\":\"\(sessionID)\"",
            "\"createdAt\":1792205211000",
            "\"cwd\":\"/tmp/proj\"",
        ]
        if let seedLength { fields.append("\"seedLength\":\(seedLength)") }
        if let isSeeded { fields.append("\"isSeeded\":\(isSeeded)") }
        return "{" + fields.joined(separator: ",") + "}"
    }

    private func userLine(turn: Int, seq: Int, time: Int) -> String {
        "{\"type\":\"user/message\",\"seq\":\(seq),\"time\":\(time),\"data\":{\"turn\":\(turn)}}"
    }

    private func assistantLine(
        id: String,
        turn: Int,
        seq: Int,
        time: Int,
        input: Int,
        output: Int,
        model: String = "deepseek-v4.1-flash"
    ) -> String {
        """
        {"type":"assistant/message","seq":\(seq),"time":\(time),"data":{"turn":\(turn),"step":1,        "message":{"id":"\(id)","source":{"provider":"deepseek-account","model":"\(model)"}},        "usage":{"inputTokens":\(input),"outputTokens":\(output),"cacheReadTokens":0}}}
        """
    }

    /// libzstd 压缩一个独立 frame（模拟 DSH 每次 flush 追加一帧）。
    private func zstdFrame(_ text: String) -> Data {
        let input = Data(text.utf8)
        let bound = ZSTD_compressBound(input.count)
        var output = [UInt8](repeating: 0, count: bound)
        let written: Int = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                Int(ZSTD_compress(
                    destination.baseAddress,
                    destination.count,
                    source.baseAddress,
                    source.count,
                    3
                ))
            }
        }
        guard ZSTD_isError(written) == 0, written > 0 else {
            XCTFail("zstd compress failed")
            return Data()
        }
        return Data(output[0..<written])
    }
}
