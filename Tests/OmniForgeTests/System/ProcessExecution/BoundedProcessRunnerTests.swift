import XCTest
@testable import OmniForge

/// 有界进程执行边界（审查 R05）：并发排空防等待环、截断标志、超时回收、取消。
final class BoundedProcessRunnerTests: XCTestCase {
    private let zsh = URL(fileURLWithPath: "/bin/zsh")

    /// 两路同时写入超过管道容量（64KB）的输出：不发生等待环死锁，内容完整、未截断。
    func test_runBlocking_largeBidirectionalOutputDoesNotDeadlock() throws {
        // 每路约 280KB（20000 行 × ~14B），远超单路管道容量。
        let script = "for i in $(seq 1 20000); do echo \"out-$i\"; echo \"err-$i\" 1>&2; done"
        let started = Date()

        let result = try XCTUnwrap(BoundedProcessRunner.runBlocking(
            executable: zsh,
            arguments: ["-c", script]
        ))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.truncated, "默认上限内不得标记截断")
        XCTAssertTrue(result.stdout.contains("out-1\n"), "stdout 首行完整")
        XCTAssertTrue(result.stdout.contains("out-20000"), "stdout 尾行完整（排空到 EOF）")
        XCTAssertTrue(result.stderr.contains("err-1\n"), "stderr 首行完整")
        XCTAssertTrue(result.stderr.contains("err-20000"), "stderr 尾行完整")
        XCTAssertLessThan(Date().timeIntervalSince(started), 15, "不得死锁卡死")
    }

    /// 超时：到点 SIGKILL 回收，不无限期占用调用方。
    func test_runBlocking_timeoutKillsAndReturns() {
        let started = Date()
        let result = BoundedProcessRunner.runBlocking(
            executable: zsh,
            arguments: ["-c", "sleep 30"],
            options: .init(timeout: 0.3)
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.exitCode, 9, "SIGKILL 信号退出（terminationStatus 为信号数）")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "超时后必须快速返回")
    }

    /// 输出上限：达上限后丢弃式排空并标记截断，输出长度受限于上限。
    func test_runBlocking_truncatesAndFlags() throws {
        let result = try XCTUnwrap(BoundedProcessRunner.runBlocking(
            executable: zsh,
            arguments: ["-c", "seq 1 100000"],
            options: .init(timeout: 10, maxOutputBytesPerStream: 4096)
        ))

        XCTAssertTrue(result.truncated, "超上限必须显式标记")
        XCTAssertLessThanOrEqual(result.stdout.utf8.count, 4096, "缓冲不超上限")
    }

    /// 启动失败：同步版返回 nil、异步版抛错。
    func test_launchFailure() async {
        XCTAssertNil(BoundedProcessRunner.runBlocking(
            executable: URL(fileURLWithPath: "/nonexistent/binary-\(UUID().uuidString)"),
            arguments: []
        ))
        do {
            _ = try await BoundedProcessRunner.run(
                executable: URL(fileURLWithPath: "/nonexistent/binary-\(UUID().uuidString)"),
                arguments: []
            )
            XCTFail("启动失败必须抛错")
        } catch {
            // 预期路径
        }
    }

    /// 异步版正常路径与 Unicode 输出。
    func test_run_asyncCapturesUnicodeOutput() async throws {
        let result = try await BoundedProcessRunner.run(
            executable: zsh,
            arguments: ["-c", "echo 中文-✓-output; echo 错误-✓ 1>&2"]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.truncated)
        XCTAssertTrue(result.stdout.contains("中文-✓-output"))
        XCTAssertTrue(result.stderr.contains("错误-✓"))
    }

    /// 取消：外层 Task 取消时终止子进程并抛 CancellationError。
    func test_run_cancellationKillsAndThrows() async {
        let task = Task {
            try await BoundedProcessRunner.run(
                executable: zsh,
                arguments: ["-c", "sleep 30"],
                options: .init(timeout: 30)
            )
        }
        // 等子进程真正跑起来再取消。
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()

        let started = Date()
        do {
            _ = try await task.value
            XCTFail("取消后必须抛 CancellationError")
        } catch is CancellationError {
            // 预期
        } catch {
            XCTFail("期望 CancellationError，实际 \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "取消后必须快速收尾")
    }
}
