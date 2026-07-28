import Foundation

// MARK: - Protocol

protocol PortProbing {
    /// 以当前用户权限采集端口占用列表。
    func probe() throws -> [PortEntry]
}

enum PortProbeError: Error, Equatable {
    case lsofMissing
    case lsofFailed(exitCode: Int32, stderr: String)
}

// MARK: - Production probe

final class PortProbe: PortProbing {
    static let defaultArguments = ["-nP", "-iTCP", "-iUDP"]

    private let runner: (_ arguments: [String]) throws -> (stdout: String, exitCode: Int32, stderr: String)

    init(
        runner: @escaping (_ arguments: [String]) throws -> (stdout: String, exitCode: Int32, stderr: String)
            = PortProbe.runLsof
    ) {
        self.runner = runner
    }

    func probe() throws -> [PortEntry] {
        let result = try runner(Self.defaultArguments)
        guard result.exitCode == 0 else {
            // lsof 无匹配时也可能非零；空 stdout 视为空列表
            if result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if result.exitCode == 1 {
                    return []
                }
                throw PortProbeError.lsofFailed(exitCode: result.exitCode, stderr: result.stderr)
            }
            // 有输出时仍尝试解析（部分环境非零但仍有行）
            return Self.parse(stdout: result.stdout)
        }
        return Self.parse(stdout: result.stdout)
    }

    // MARK: Pure parse

    /// 解析 `lsof -nP -iTCP -iUDP` 的 stdout；异常行静默跳过。
    static func parse(stdout: String) -> [PortEntry] {
        var entries: [PortEntry] = []
        for rawLine in stdout.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if let entry = parseLine(line) {
                entries.append(entry)
            }
        }
        return entries
    }

    /// 单行解析；header / 畸形行返回 nil。
    static func parseLine(_ line: String) -> PortEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 表头
        if trimmed.hasPrefix("COMMAND") { return nil }

        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        // COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME…
        guard tokens.count >= 9 else { return nil }

        let command = tokens[0].replacingOccurrences(of: "\\x20", with: " ")
        guard let pid = Int32(tokens[1]), pid >= 0 else { return nil }

        guard let typeIndex = tokens.firstIndex(where: { $0 == "IPv4" || $0 == "IPv6" }) else {
            return nil
        }
        guard let nodeIndex = tokens[typeIndex...].firstIndex(where: { $0 == "TCP" || $0 == "UDP" }) else {
            return nil
        }
        guard nodeIndex + 1 < tokens.count else { return nil }

        let isIPv6 = tokens[typeIndex] == "IPv6"
        let isTCP = tokens[nodeIndex] == "TCP"
        let proto: PortEntry.Proto
        switch (isTCP, isIPv6) {
        case (true, false): proto = .tcp
        case (true, true): proto = .tcp6
        case (false, false): proto = .udp
        case (false, true): proto = .udp6
        }

        let nameTokens = Array(tokens[(nodeIndex + 1)...])
        guard let parsedName = parseNameField(nameTokens, isTCP: isTCP) else { return nil }

        return PortEntry(
            proto: proto,
            localIP: parsedName.localIP,
            localPort: parsedName.localPort,
            remoteIP: parsedName.remoteIP,
            remotePort: parsedName.remotePort,
            state: parsedName.state,
            pid: pid,
            command: command
        )
    }

    // MARK: NAME field

    private struct NameParts {
        let localIP: String
        let localPort: Int
        let remoteIP: String?
        let remotePort: Int?
        let state: String?
    }

    /// NAME：`local` / `local->remote`，可选尾部 `(STATE)`。
    private static func parseNameField(_ tokens: [String], isTCP: Bool) -> NameParts? {
        guard !tokens.isEmpty else { return nil }

        var working = tokens
        var state: String?
        // 末尾 `(LISTEN)` / `(ESTABLISHED)` 等
        if let last = working.last,
           last.hasPrefix("("),
           last.hasSuffix(")"),
           last.count >= 3
        {
            state = String(last.dropFirst().dropLast())
            working.removeLast()
        }

        let nameBody = working.joined(separator: " ")
        guard !nameBody.isEmpty else { return nil }

        let localRaw: String
        let remoteRaw: String?
        if let arrow = nameBody.range(of: "->") {
            localRaw = String(nameBody[..<arrow.lowerBound])
            remoteRaw = String(nameBody[arrow.upperBound...])
        } else {
            localRaw = nameBody
            remoteRaw = nil
        }

        guard let local = parseEndpoint(localRaw) else { return nil }
        let remote = remoteRaw.flatMap { parseEndpoint($0) }

        // UDP 无状态；TCP 保留解析到的状态（可能为 nil，如异常行）
        let resolvedState: String? = isTCP ? state : nil

        return NameParts(
            localIP: local.ip,
            localPort: local.port ?? 0,
            remoteIP: remote?.ip,
            remotePort: remote?.port,
            state: resolvedState
        )
    }

    /// 解析 `ip:port`、`*:port`、`*:*`、`[ipv6]:port`。
    private static func parseEndpoint(_ raw: String) -> (ip: String, port: Int?)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // [IPv6]:port
        if s.hasPrefix("["),
           let close = s.firstIndex(of: "]")
        {
            let ip = String(s[s.index(after: s.startIndex)..<close])
            let after = s[s.index(after: close)...]
            if after.hasPrefix(":") {
                let portPart = String(after.dropFirst())
                if portPart == "*" {
                    return (ip, nil)
                }
                guard let port = Int(portPart), port >= 0, port <= 65535 else { return nil }
                return (ip, port)
            }
            return (ip, nil)
        }

        // IPv4 / * ：取最后一个 ':' 分隔端口（IPv6 无括号时不在此路径期望）
        if let colon = s.lastIndex(of: ":") {
            let ip = String(s[..<colon])
            let portPart = String(s[s.index(after: colon)...])
            if portPart == "*" {
                return (ip.isEmpty ? "*" : ip, nil)
            }
            guard let port = Int(portPart), port >= 0, port <= 65535 else { return nil }
            return (ip.isEmpty ? "*" : ip, port)
        }

        return (s, nil)
    }

    // MARK: Live runner

    private static func runLsof(arguments: [String]) throws -> (stdout: String, exitCode: Int32, stderr: String) {
        let process = Process()
        let lsofURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        if FileManager.default.isExecutableFile(atPath: lsofURL.path) {
            process.executableURL = lsofURL
        } else if let path = which("lsof") {
            process.executableURL = URL(fileURLWithPath: path)
        } else {
            throw PortProbeError.lsofMissing
        }
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        return (stdout, process.terminationStatus, stderr)
    }

    private static func which(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (path?.isEmpty == false) ? path : nil
        } catch {
            return nil
        }
    }
}
