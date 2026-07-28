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

/// 基于 Process 的生产实现。
final class ProcessCommandRunner: CommandRunning {
    func run(executable: URL, arguments: [String]) async throws -> CommandResult {
        guard executable.isFileURL else {
            throw CommandRunnerError.invalidExecutable(executable.absoluteString)
        }

        return try await withCheckedThrowingContinuation { continuation in
            do {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                try process.run()
                process.waitUntilExit()

                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let result = CommandResult(
                    terminationStatus: process.terminationStatus,
                    standardOutput: String(data: outData, encoding: .utf8) ?? "",
                    standardError: String(data: errData, encoding: .utf8) ?? ""
                )
                continuation.resume(returning: result)
            } catch {
                continuation.resume(throwing: CommandRunnerError.launchFailed(error.localizedDescription))
            }
        }
    }
}
