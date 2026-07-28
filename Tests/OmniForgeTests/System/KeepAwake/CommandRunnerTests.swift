import XCTest
@testable import OmniForge

final class CommandRunnerTests: XCTestCase {
    func test_processCommandRunner_separatesStdoutStderrAndStatus() async throws {
        let runner = ProcessCommandRunner()
        // 使用 /bin/sh -c 以外的直接可执行文件：/usr/bin/printf 与 /bin/echo
        // 验证 argv 不经 shell 展开：把带空格参数作为单一 argv。
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello world", "special$chars"]
        )
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertTrue(result.standardOutput.contains("hello world"))
        XCTAssertTrue(result.standardOutput.contains("special$chars"))
        XCTAssertEqual(result.standardError, "")
    }

    func test_processCommandRunner_capturesNonZeroStatusAndStderr() async throws {
        let runner = ProcessCommandRunner()
        // ls 不存在的路径：非 0 status，stderr 非空
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/ls"),
            arguments: ["/path/that/does/not/exist-\(UUID().uuidString)"]
        )
        XCTAssertNotEqual(result.terminationStatus, 0)
        XCTAssertFalse(result.standardError.isEmpty)
    }

    func test_processCommandRunner_launchFailureIsExplicit() async {
        let runner = ProcessCommandRunner()
        do {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/this/executable/does/not/exist-\(UUID().uuidString)"),
                arguments: []
            )
            XCTFail("expected launch failure")
        } catch let error as CommandRunnerError {
            if case .launchFailed = error {
                // expected
            } else {
                XCTFail("unexpected CommandRunnerError: \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func test_fakeCommandRunner_recordsCallSequence() async throws {
        let fake = FakeCommandRunner()
        fake.results = [
            CommandResult(terminationStatus: 0, standardOutput: "ok", standardError: ""),
            CommandResult(terminationStatus: 1, standardOutput: "", standardError: "no"),
        ]
        let exe = URL(fileURLWithPath: "/usr/bin/pmset")
        _ = try await fake.run(executable: exe, arguments: ["disablesleep", "1"])
        _ = try await fake.run(executable: exe, arguments: ["disablesleep", "0"])
        XCTAssertEqual(fake.calls.count, 2)
        XCTAssertEqual(fake.calls[0].arguments, ["disablesleep", "1"])
        XCTAssertEqual(fake.calls[1].arguments, ["disablesleep", "0"])
    }

    func test_argvWithSpacesRemainsSingleArgument() async throws {
        // 通过 python3 打印最后一个 argv，验证空格参数不被 shell 拆分。
        let runner = ProcessCommandRunner()
        let script = "import sys; print(repr(sys.argv[-1]))"
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", script, "one two three"]
        )
        XCTAssertEqual(result.terminationStatus, 0)
        // 作为单一 argv 传入时，repr 应为 'one two three'
        XCTAssertTrue(
            result.standardOutput.contains("'one two three'")
                || result.standardOutput.contains("\"one two three\""),
            "expected single argv with spaces, got: \(result.standardOutput)"
        )
    }
}
