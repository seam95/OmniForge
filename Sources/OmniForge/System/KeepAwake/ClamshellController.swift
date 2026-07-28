import Foundation

/// 合盖系统控制边界：capability、授权安装/移除、精确 pmset 启停。
/// 自动化测试必须注入 FakeCommandRunner；不得真实写 sudoers / SleepDisabled。
protocol ClamshellControlling: AnyObject {
    func refreshCapability() async -> ClamshellCapability
    func readSleepDisabled() async throws -> Int
    func setSleepDisabled(_ value: Int, allowPasswordPrompt: Bool) async throws
    func installAuthorization() async throws
    func removeAuthorization() async throws
}

/// 只读/写 SleepDisabled、capability 与受限 sudoers 安装/移除的可测试实现。
/// 管理员事务仅通过 osascript + 固定脚本；自动化测试必须注入 FakeCommandRunner。
@MainActor
final class ClamshellController: ClamshellControlling {
    private let runner: CommandRunning
    private let userName: String
    private let uid: uid_t
    private var serial = false

    static let pmsetURL = URL(fileURLWithPath: "/usr/bin/pmset")
    static let sudoURL = URL(fileURLWithPath: "/usr/bin/sudo")
    static let osascriptURL = URL(fileURLWithPath: "/usr/bin/osascript")

    init(
        runner: CommandRunning,
        userName: String,
        uid: uid_t
    ) {
        self.runner = runner
        self.userName = userName
        self.uid = uid
    }

    func refreshCapability() async -> ClamshellCapability {
        guard ClamshellSupport.isValidUsername(userName) else {
            return .invalidAuthorization(reason: "invalid username")
        }

        // 两个只读 sudo -n -l 检查。
        do {
            let list1 = try await runner.run(
                executable: Self.sudoURL,
                arguments: ["-n", "-l", "/usr/bin/pmset", "disablesleep", "1"]
            )
            let list0 = try await runner.run(
                executable: Self.sudoURL,
                arguments: ["-n", "-l", "/usr/bin/pmset", "disablesleep", "0"]
            )
            let authorized = list1.terminationStatus == 0 && list0.terminationStatus == 0

            let sleepDisabled: Int?
            do {
                sleepDisabled = try await readSleepDisabled()
            } catch {
                return .unsupported(reason: "SleepDisabled unreadable")
            }

            guard let sleepDisabled else {
                return .unsupported(reason: "SleepDisabled unreadable")
            }

            if !authorized {
                return .needsAuthorization
            }
            if sleepDisabled == 1 {
                // 是否 conflict 由上层结合恢复记录判断；此处 ready 表示命令可用。
                return .ready
            }
            return .ready
        } catch {
            return .unsupported(reason: "capability probe failed")
        }
    }

    func readSleepDisabled() async throws -> Int {
        let result = try await runner.run(
            executable: Self.pmsetURL,
            arguments: ["-g"]
        )
        guard result.terminationStatus == 0 else {
            throw KeepAwakeError.clamshellStateUnverified(
                "pmset -g status \(result.terminationStatus)"
            )
        }
        guard let value = ClamshellSupport.parseSleepDisabled(from: result.standardOutput) else {
            throw KeepAwakeError.clamshellStateUnverified("SleepDisabled not parseable")
        }
        return value
    }

    func setSleepDisabled(_ value: Int, allowPasswordPrompt: Bool) async throws {
        guard value == 0 || value == 1 else {
            throw KeepAwakeError.clamshellUnsupported("SleepDisabled must be 0 or 1")
        }
        try await withSerial {
            // 仅允许精确 argv；禁止额外参数。
            let args: [String]
            if allowPasswordPrompt {
                // 无 -n：允许密码框（仅用户可见恢复流程）。
                args = ["/usr/bin/pmset", "disablesleep", String(value)]
            } else {
                args = ["-n", "/usr/bin/pmset", "disablesleep", String(value)]
            }
            let result = try await runner.run(executable: Self.sudoURL, arguments: args)
            guard result.terminationStatus == 0 else {
                if result.standardError.lowercased().contains("cancel")
                    || result.terminationStatus == 1 && result.standardError.isEmpty {
                    throw KeepAwakeError.administratorAuthorizationCancelled
                }
                throw KeepAwakeError.administratorCommandFailed(
                    command: "pmset disablesleep \(value)",
                    status: result.terminationStatus,
                    output: result.standardError
                )
            }
            // 命令成功后必须确认实际状态。
            let actual = try await readSleepDisabled()
            guard actual == value else {
                throw KeepAwakeError.clamshellStateUnverified(
                    "expected SleepDisabled=\(value), actual=\(actual)"
                )
            }
        }
    }

    func installAuthorization() async throws {
        guard ClamshellSupport.isValidUsername(userName) else {
            throw KeepAwakeError.clamshellUnsupported("invalid username")
        }
        try await withSerial {
            let script = ClamshellSupport.installAuthorizationShellScript(
                username: userName,
                uid: uid
            )
            // 固定脚本必须包含候选路径、visudo 与无 -f 的 ln。
            let candidate = ClamshellSupport.sudoersCandidatePath(uid: uid)
            precondition(ClamshellSupport.isSudoersCandidateNameIgnoredByIncludeDir(candidate))
            try await runAdministratorScript(script, commandLabel: "install-sudoers")
            // 后验：两个 sudo -n -l 必须成功；失败则 inode 安全回滚。
            let list1 = try await runner.run(
                executable: Self.sudoURL,
                arguments: ["-n", "-l", "/usr/bin/pmset", "disablesleep", "1"]
            )
            let list0 = try await runner.run(
                executable: Self.sudoURL,
                arguments: ["-n", "-l", "/usr/bin/pmset", "disablesleep", "0"]
            )
            guard list1.terminationStatus == 0, list0.terminationStatus == 0 else {
                let rollback = ClamshellSupport.rollbackAuthorizationShellScript(
                    username: userName,
                    uid: uid
                )
                // 回滚失败仍报告后验失败；不静默吞掉。
                try? await runAdministratorScript(rollback, commandLabel: "rollback-sudoers")
                throw KeepAwakeError.sudoersValidationFailed(
                    "post-install sudo -n -l failed (status1=\(list1.terminationStatus), status0=\(list0.terminationStatus))"
                )
            }
            // 后验成功：删除候选硬链接名。
            let finalize = ClamshellSupport.finalizeAuthorizationShellScript(uid: uid)
            try await runAdministratorScript(finalize, commandLabel: "finalize-sudoers")
        }
    }

    func removeAuthorization() async throws {
        guard ClamshellSupport.isValidUsername(userName) else {
            throw KeepAwakeError.clamshellUnsupported("invalid username")
        }
        try await withSerial {
            // 移除前必须确认 SleepDisabled 已为 0。
            let actual = try await readSleepDisabled()
            guard actual == 0 else {
                throw KeepAwakeError.authorizationRemovalFailed(
                    "SleepDisabled must be 0 before removing authorization (actual=\(actual))"
                )
            }
            let script = ClamshellSupport.removeAuthorizationShellScript(
                username: userName,
                uid: uid
            )
            try await runAdministratorScript(script, commandLabel: "remove-sudoers")
        }
    }

    private func runAdministratorScript(_ script: String, commandLabel: String) async throws {
        let args = ClamshellSupport.osascriptAdministratorArguments(shellScript: script)
        let result = try await runner.run(executable: Self.osascriptURL, arguments: args)
        guard result.terminationStatus == 0 else {
            let combined = (result.standardError + result.standardOutput).lowercased()
            if combined.contains("cancel") || combined.contains("user canceled") {
                throw KeepAwakeError.administratorAuthorizationCancelled
            }
            // 脚本约定退出码：20/21/22 目标冲突；23 ln no-clobber 失败；30/31/32 移除拒绝。
            if result.terminationStatus == 20
                || result.terminationStatus == 21
                || result.terminationStatus == 22
                || result.terminationStatus == 23
                || result.terminationStatus == 30
                || result.terminationStatus == 31
                || result.terminationStatus == 32 {
                throw KeepAwakeError.sudoersValidationFailed(
                    "\(commandLabel) refused: status=\(result.terminationStatus) \(result.standardError)"
                )
            }
            throw KeepAwakeError.administratorCommandFailed(
                command: commandLabel,
                status: result.terminationStatus,
                output: result.standardError
            )
        }
    }

    private func withSerial(_ body: () async throws -> Void) async throws {
        while serial {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        serial = true
        defer { serial = false }
        try await body()
    }
}
