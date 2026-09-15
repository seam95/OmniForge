import Foundation

/// 结构化命令结果；stdout/stderr/status 分离。
struct CommandResult: Equatable {
    let terminationStatus: Int32
    let standardOutput: String
    let standardError: String
}

enum CommandRunnerError: Error, Equatable {
    case invalidExecutable(String)
    case launchFailed(String)
}

/// 可注入命令执行边界；只接受 executable URL + argv，不经 shell。
protocol CommandRunning: AnyObject {
    func run(executable: URL, arguments: [String]) async throws -> CommandResult
}

/// 基于 Process 的生产实现（经有界进程执行边界：并发排空、超时回收、协作取消）。
final class ProcessCommandRunner: CommandRunning {
    func run(executable: URL, arguments: [String]) async throws -> CommandResult {
        guard executable.isFileURL else {
            throw CommandRunnerError.invalidExecutable(executable.absoluteString)
        }
        do {
            let output = try await BoundedProcessRunner.run(executable: executable, arguments: arguments)
            return CommandResult(
                terminationStatus: output.exitCode,
                standardOutput: output.stdout,
                standardError: output.stderr
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CommandRunnerError.launchFailed(error.localizedDescription)
        }
    }
}
