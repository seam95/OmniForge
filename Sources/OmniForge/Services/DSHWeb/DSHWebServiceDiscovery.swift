import Foundation

/// 已确认正在监听的 DSH Web 实例。命令行用于停止前的二次身份核验。
struct DSHWebService: Identifiable, Equatable {
    let pid: Int32
    let port: UInt16
    let command: String

    var id: String { "\(pid):\(port)" }

    var address: String { "http://127.0.0.1:\(port)" }
}

/// 枚举当前用户实际监听的 DSH Web 服务。
protocol DSHWebServiceDiscovering: AnyObject {
    func discover() async throws -> [DSHWebService]
}

/// 向已核验的外部 DSH Web 进程发送信号。
protocol DSHWebServiceSignaling: AnyObject {
    @discardableResult
    func terminate(pid: Int32) -> Bool

    @discardableResult
    func forceTerminate(pid: Int32) -> Bool
}

/// 基于 lsof + ps 的生产发现器。
///
/// 先限定为 TCP LISTEN，再用完整命令行确认其确为 dsh 的 web profile，避免把普通 Node
/// 服务误显示或误终止。端口诊断已有稳定的 lsof 解析器，复用它可保持系统命令解析一致。
final class SystemDSHWebServiceDiscoverer: DSHWebServiceDiscovering {
    private let portProbe: PortProbing
    private let commandRunner: CommandRunning

    init(
        portProbe: PortProbing = PortProbe(),
        commandRunner: CommandRunning = ProcessCommandRunner()
    ) {
        self.portProbe = portProbe
        self.commandRunner = commandRunner
    }

    func discover() async throws -> [DSHWebService] {
        let listeners = try portProbe.probe().filter { entry in
            (entry.proto == .tcp || entry.proto == .tcp6)
                && entry.state?.uppercased() == "LISTEN"
                && entry.pid > 0
                && entry.localPort > 0
                && entry.localPort <= Int(UInt16.max)
        }

        let portsByPID = Dictionary(grouping: listeners, by: \.pid)
        var services: [DSHWebService] = []
        for pid in portsByPID.keys.sorted() {
            guard let command = try await commandLine(for: pid),
                  DSHWebServiceSupport.isDSHWebCommand(command),
                  let entries = portsByPID[pid]
            else {
                continue
            }
            for port in Set(entries.map { UInt16($0.localPort) }).sorted() {
                services.append(DSHWebService(pid: pid, port: port, command: command))
            }
        }
        return services.sorted { lhs, rhs in
            lhs.port == rhs.port ? lhs.pid < rhs.pid : lhs.port < rhs.port
        }
    }

    private func commandLine(for pid: Int32) async throws -> String? {
        let result = try await commandRunner.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-p", String(pid), "-o", "command="]
        )
        guard result.terminationStatus == 0 else { return nil }
        let command = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }
}

final class DarwinDSHWebServiceSignaler: DSHWebServiceSignaling {
    func terminate(pid: Int32) -> Bool {
        kill(pid_t(pid), SIGTERM) == 0
    }

    func forceTerminate(pid: Int32) -> Bool {
        kill(pid_t(pid), SIGKILL) == 0
    }
}

/// 不依赖系统调用的识别和比较辅助逻辑，便于回归测试。
enum DSHWebServiceSupport {
    static func isDSHWebCommand(_ command: String) -> Bool {
        let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let executableIndex = tokens.firstIndex(where: {
            $0.contains("@deepseek-ai/dsh") && $0.hasSuffix("/lib/bin.js")
        }) else {
            return false
        }

        let arguments = tokens.dropFirst(executableIndex + 1)
        if arguments.first == "web" {
            return true
        }
        return zip(arguments, arguments.dropFirst()).contains { pair in
            pair.0 == "--profile" && pair.1 == "web"
        }
    }

    static func isSameInstance(_ lhs: DSHWebService, _ rhs: DSHWebService) -> Bool {
        lhs.pid == rhs.pid && lhs.port == rhs.port && lhs.command == rhs.command
    }
}
