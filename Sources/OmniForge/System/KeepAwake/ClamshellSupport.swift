import Foundation

// MARK: - Capability / Recovery

enum ClamshellCapability: Equatable {
    case checking
    case unsupported(reason: String)
    case needsAuthorization
    case ready
    case conflict(reason: String)
    case invalidAuthorization(reason: String)
}

enum ClamshellRecoveryPhase: String, Codable, Equatable {
    case prepared
    case enabled
    case restoring
}

/// 统一恢复动作：删除记录 / 恢复 SleepDisabled 到 0。
enum ClamshellRecoveryAction: Equatable {
    case deleteRecord
    case restoreToZero
    case conflict(reason: String)
    case refuse(reason: String)
}

enum ClamshellSupport {
    static let schemaVersion = 1
    static let expectedBundleIdentifier = "app.omniforge"
    static let usernamePattern = #"^[A-Za-z0-9._-]+$"#

    /// 历史版本（改名前）使用过的 bundle id，用于清理老版本残留的 sudoers 与用户数据。
    static let legacyBundleIdentifiers: [String] = ["app.inputlock"]

    /// `/etc/sudoers.d/omniforge-clamshell-<uid>`
    static func sudoersPath(uid: uid_t) -> String {
        "/etc/sudoers.d/omniforge-clamshell-\(uid)"
    }

    /// 候选文件名含 `.`，会被 sudoers `@includedir` 忽略（验证前不生效）。
    static func sudoersCandidatePath(uid: uid_t) -> String {
        "/etc/sudoers.d/omniforge-clamshell-\(uid).candidate"
    }

    /// 所有需要在清理阶段考虑的 sudoers 路径（含历史 `inputlock-` 前缀，用于删除老版本残留的孤儿规则）。
    /// 仅用于读取/清理，新安装只走 [`sudoersPath`] 与 [`sudoersCandidatePath`]。
    static func allKnownSudoersPaths(uid: uid_t) -> [String] {
        [
            sudoersPath(uid: uid),
            sudoersCandidatePath(uid: uid),
            "/etc/sudoers.d/inputlock-clamshell-\(uid)",
            "/etc/sudoers.d/inputlock-clamshell-\(uid).candidate",
        ]
    }

    /// 文件名含 `.` 时 includedir 忽略（SPEC 6.2）。
    static func isSudoersCandidateNameIgnoredByIncludeDir(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.contains(".")
    }

    /// 规则正文必须逐字匹配；无通配、无 shell、仅两条精确 pmset。
    static func sudoersRuleText(username: String) -> String {
        "\(username) ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0\n"
    }

    /// 固定管理员安装脚本；唯一动态值为已校验 username 与十进制 uid。
    /// 使用 candidate + visudo + `/bin/ln` no-clobber（无 -f）。
    /// 注意：成功 ln 后**保留候选**，供 Controller 后验；后验成功再 finalize 删候选。
    static func installAuthorizationShellScript(username: String, uid: uid_t) -> String {
        precondition(isValidUsername(username))
        let uidText = String(uid)
        precondition(isValidUIDText(uidText, expected: uid))
        let target = sudoersPath(uid: uid)
        let candidate = sudoersCandidatePath(uid: uid)
        // 规则正文不含 shell 转义；用 printf '%s\n' 写出真实换行。
        let ruleBody = sudoersRuleText(username: username)
            .trimmingCharacters(in: CharacterSet.newlines)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // macOS stat -f '%Mp%Lp' 输出 4 位八进制（如 0440）；期望值必须对齐。
        return """
        set -euo pipefail
        TARGET="\(target)"
        CANDIDATE="\(candidate)"
        RULE_BODY="\(ruleBody)"
        EXPECT_OWNER="root:wheel:0440"
        if [ -e "$TARGET" ]; then
          if [ -L "$TARGET" ]; then exit 20; fi
          if [ ! -f "$TARGET" ]; then exit 21; fi
          OWNER=$(/usr/bin/stat -f '%Su:%Sg:%Mp%Lp' "$TARGET")
          BODY=$(/bin/cat "$TARGET")
          EXPECT_BODY=$(/usr/bin/printf '%s\\n' "$RULE_BODY")
          if [ "$OWNER" = "$EXPECT_OWNER" ] && [ "$BODY" = "$EXPECT_BODY" ]; then
            exit 0
          fi
          exit 22
        fi
        if [ -e "$CANDIDATE" ]; then /bin/rm -f "$CANDIDATE"; fi
        /usr/bin/printf '%s\\n' "$RULE_BODY" > "$CANDIDATE"
        /usr/sbin/chown root:wheel "$CANDIDATE"
        /bin/chmod 0440 "$CANDIDATE"
        /usr/sbin/visudo -c -f "$CANDIDATE"
        if ! /bin/ln "$CANDIDATE" "$TARGET"; then
          /bin/rm -f "$CANDIDATE"
          exit 23
        fi
        # 保留候选硬链接，供后验失败时 inode 安全回滚；成功后由 finalize 删除。
        """
    }

    /// 后验成功后删除候选硬链接名（目标保留）。
    static func finalizeAuthorizationShellScript(uid: uid_t) -> String {
        let candidate = sudoersCandidatePath(uid: uid)
        return """
        set -euo pipefail
        CANDIDATE="\(candidate)"
        if [ -e "$CANDIDATE" ]; then /bin/rm -f "$CANDIDATE"; fi
        """
    }

    /// 后验失败回滚：仅当 target 与 candidate inode 相同且正文/owner/mode 精确匹配时删 target，再删 candidate。
    static func rollbackAuthorizationShellScript(username: String, uid: uid_t) -> String {
        precondition(isValidUsername(username))
        let target = sudoersPath(uid: uid)
        let candidate = sudoersCandidatePath(uid: uid)
        let ruleBody = sudoersRuleText(username: username)
            .trimmingCharacters(in: CharacterSet.newlines)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        set -euo pipefail
        TARGET="\(target)"
        CANDIDATE="\(candidate)"
        RULE_BODY="\(ruleBody)"
        EXPECT_OWNER="root:wheel:0440"
        EXPECT_BODY=$(/usr/bin/printf '%s\\n' "$RULE_BODY")
        # ROLLBACK: only delete target when same inode as candidate and exact content/owner/mode.
        if [ -e "$TARGET" ] && [ -e "$CANDIDATE" ]; then
          T_INODE=$(/usr/bin/stat -f '%i' "$TARGET")
          C_INODE=$(/usr/bin/stat -f '%i' "$CANDIDATE")
          if [ "$T_INODE" = "$C_INODE" ]; then
            if [ ! -L "$TARGET" ] && [ -f "$TARGET" ]; then
              OWNER=$(/usr/bin/stat -f '%Su:%Sg:%Mp%Lp' "$TARGET")
              BODY=$(/bin/cat "$TARGET")
              if [ "$OWNER" = "$EXPECT_OWNER" ] && [ "$BODY" = "$EXPECT_BODY" ]; then
                /bin/rm -f "$TARGET"
              fi
            fi
          fi
        fi
        if [ -e "$CANDIDATE" ]; then /bin/rm -f "$CANDIDATE"; fi
        """
    }

    /// 固定管理员移除脚本；仅删除精确匹配的当前 UID 规则。
    static func removeAuthorizationShellScript(username: String, uid: uid_t) -> String {
        precondition(isValidUsername(username))
        let uidText = String(uid)
        precondition(isValidUIDText(uidText, expected: uid))
        let target = sudoersPath(uid: uid)
        let ruleBody = sudoersRuleText(username: username)
            .trimmingCharacters(in: CharacterSet.newlines)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        set -euo pipefail
        TARGET="\(target)"
        RULE_BODY="\(ruleBody)"
        EXPECT_BODY=$(/usr/bin/printf '%s\\n' "$RULE_BODY")
        if [ ! -e "$TARGET" ]; then exit 0; fi
        if [ -L "$TARGET" ]; then exit 30; fi
        if [ ! -f "$TARGET" ]; then exit 31; fi
        OWNER=$(/usr/bin/stat -f '%Su:%Sg:%Mp%Lp' "$TARGET")
        BODY=$(/bin/cat "$TARGET")
        if [ "$OWNER" != "root:wheel:0440" ] || [ "$BODY" != "$EXPECT_BODY" ]; then
          exit 32
        fi
        /bin/rm -f "$TARGET"
        """
    }

    /// 将 shell 脚本包装为 osascript do shell script 参数（测试可断言片段）。
    /// 必须用双引号包裹 shell 正文：安装脚本含 `printf '%s\n'` 等单引号字面量，
    /// 若用单引号包裹会被截断，触发 AppleScript -2741（找到 `\'s`）。
    static func osascriptAdministratorArguments(shellScript: String) -> [String] {
        let escaped = shellScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
        return ["-e", appleScript]
    }

    static func isValidUsername(_ username: String) -> Bool {
        username.range(of: usernamePattern, options: .regularExpression) != nil
    }

    static func isValidUIDText(_ text: String, expected: uid_t) -> Bool {
        guard let value = UInt32(text), value == expected else { return false }
        // 拒绝前导零等非规范文本（"0" 除外）。
        if text.count > 1 && text.hasPrefix("0") { return false }
        return String(expected) == text
    }

    /// 解析 `pmset -g` 输出中的 SleepDisabled，只接受可确认 0/1。
    static func parseSleepDisabled(from pmsetOutput: String) -> Int? {
        for line in pmsetOutput.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("SleepDisabled") else { continue }
            let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
            guard let last = parts.last, let value = Int(last), value == 0 || value == 1 else {
                return nil
            }
            return value
        }
        return nil
    }

    /// 校验规则正文是否为当前用户的精确双命令规则。
    static func isExactSudoersContent(_ content: String, username: String) -> Bool {
        content == sudoersRuleText(username: username)
    }

    /// 统一恢复决策表（启动/退出/卸载/脚本共用）。
    static func recoveryAction(
        phase: ClamshellRecoveryPhase?,
        actualSleepDisabled: Int?,
        recordValid: Bool,
        restoreTargetIsZero: Bool
    ) -> ClamshellRecoveryAction {
        guard recordValid else {
            return .refuse(reason: "recovery record failed validation")
        }
        guard restoreTargetIsZero else {
            return .refuse(reason: "unsupported restore target")
        }
        guard let phase else {
            if actualSleepDisabled == 1 {
                return .conflict(reason: "SleepDisabled is 1 without a matching recovery record")
            }
            return .refuse(reason: "no recovery record")
        }
        guard let actual = actualSleepDisabled, actual == 0 || actual == 1 else {
            return .refuse(reason: "SleepDisabled unreadable")
        }

        switch (phase, actual) {
        case (.prepared, 0), (.enabled, 0), (.restoring, 0):
            return .deleteRecord
        case (.prepared, 1), (.enabled, 1), (.restoring, 1):
            return .restoreToZero
        default:
            return .refuse(reason: "unhandled recovery combination")
        }
    }

    /// 启用前基线检查：已为 1 且无当前有效记录 → conflict。
    static func enableBaselineDecision(
        actualSleepDisabled: Int?,
        hasMatchingPreparedOrEnabledRecord: Bool
    ) -> ClamshellCapability {
        guard let actual = actualSleepDisabled else {
            return .unsupported(reason: "SleepDisabled unreadable")
        }
        if actual == 1 && !hasMatchingPreparedOrEnabledRecord {
            return .conflict(reason: "SleepDisabled already enabled by another owner")
        }
        if actual != 0 && actual != 1 {
            return .unsupported(reason: "SleepDisabled unreadable")
        }
        return .ready
    }
}

// MARK: - Recovery record model

struct ClamshellRecoveryRecord: Codable, Equatable {
    var schemaVersion: Int
    var requestedAt: Date
    var userName: String
    var uid: UInt32
    var bundleIdentifier: String
    var operationID: String
    var phase: ClamshellRecoveryPhase
    var previousSleepDisabled: Int
    var restoreTargetSleepDisabled: Int
    var changedByInputLock: Bool

    static func makePrepared(
        userName: String,
        uid: uid_t,
        operationID: String,
        requestedAt: Date = Date(),
        bundleIdentifier: String = ClamshellSupport.expectedBundleIdentifier
    ) -> ClamshellRecoveryRecord {
        ClamshellRecoveryRecord(
            schemaVersion: ClamshellSupport.schemaVersion,
            requestedAt: requestedAt,
            userName: userName,
            uid: UInt32(uid),
            bundleIdentifier: bundleIdentifier,
            operationID: operationID,
            phase: .prepared,
            previousSleepDisabled: 0,
            restoreTargetSleepDisabled: 0,
            changedByInputLock: false
        )
    }

    /// 完整校验：schema、身份、恢复目标。
    func validate(
        expectedUID: uid_t,
        expectedUserName: String,
        expectedBundleID: String = ClamshellSupport.expectedBundleIdentifier
    ) -> Result<Void, KeepAwakeError> {
        guard schemaVersion == ClamshellSupport.schemaVersion else {
            return .failure(.recoveryRecordReadFailed("unknown schemaVersion \(schemaVersion)"))
        }
        guard ClamshellSupport.isValidUsername(userName) else {
            return .failure(.recoveryRecordReadFailed("invalid userName"))
        }
        guard userName == expectedUserName else {
            return .failure(.recoveryRecordReadFailed("userName mismatch"))
        }
        guard uid == UInt32(expectedUID) else {
            return .failure(.recoveryRecordReadFailed("uid mismatch"))
        }
        guard bundleIdentifier == expectedBundleID else {
            return .failure(.recoveryRecordReadFailed("bundleIdentifier mismatch"))
        }
        guard restoreTargetSleepDisabled == 0 else {
            return .failure(.recoveryRecordReadFailed("unsupported restoreTargetSleepDisabled"))
        }
        guard previousSleepDisabled == 0 || previousSleepDisabled == 1 else {
            return .failure(.recoveryRecordReadFailed("invalid previousSleepDisabled"))
        }
        guard !operationID.isEmpty else {
            return .failure(.recoveryRecordReadFailed("empty operationID"))
        }
        return .success(())
    }
}
