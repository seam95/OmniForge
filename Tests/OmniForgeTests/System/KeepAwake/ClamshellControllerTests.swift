import XCTest
@testable import OmniForge

@MainActor
final class ClamshellControllerTests: XCTestCase {
    func test_readSleepDisabled_parsesPmsetOutput() async throws {
        let fake = FakeCommandRunner()
        fake.results = [
            CommandResult(terminationStatus: 0, standardOutput: "SleepDisabled\t0\n", standardError: "")
        ]
        let controller = ClamshellController(runner: fake, userName: "seam", uid: 501)
        let value = try await controller.readSleepDisabled()
        XCTAssertEqual(value, 0)
        XCTAssertEqual(fake.calls.first?.executable.path, "/usr/bin/pmset")
        XCTAssertEqual(fake.calls.first?.arguments, ["-g"])
    }

    func test_setSleepDisabled_usesExactSudoArgvAndConfirms() async throws {
        let fake = FakeCommandRunner()
        fake.results = [
            // sudo -n pmset disablesleep 1
            CommandResult(terminationStatus: 0, standardOutput: "", standardError: ""),
            // pmset -g confirm
            CommandResult(terminationStatus: 0, standardOutput: "SleepDisabled 1\n", standardError: ""),
        ]
        let controller = ClamshellController(runner: fake, userName: "seam", uid: 501)
        try await controller.setSleepDisabled(1, allowPasswordPrompt: false)
        XCTAssertEqual(fake.calls[0].executable.path, "/usr/bin/sudo")
        XCTAssertEqual(fake.calls[0].arguments, ["-n", "/usr/bin/pmset", "disablesleep", "1"])
        XCTAssertEqual(fake.calls[1].arguments, ["-g"])
    }

    func test_setSleepDisabled_statusZeroButActualMismatch_fails() async {
        let fake = FakeCommandRunner()
        fake.results = [
            CommandResult(terminationStatus: 0, standardOutput: "", standardError: ""),
            CommandResult(terminationStatus: 0, standardOutput: "SleepDisabled 0\n", standardError: ""),
        ]
        let controller = ClamshellController(runner: fake, userName: "seam", uid: 501)
        do {
            try await controller.setSleepDisabled(1, allowPasswordPrompt: false)
            XCTFail("expected mismatch failure")
        } catch let error as KeepAwakeError {
            guard case .clamshellStateUnverified = error else {
                return XCTFail("unexpected \(error)")
            }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_refreshCapability_needsAuthorizationWhenSudoListFails() async {
        let fake = FakeCommandRunner()
        fake.results = [
            CommandResult(terminationStatus: 1, standardOutput: "", standardError: "not allowed"),
            CommandResult(terminationStatus: 1, standardOutput: "", standardError: "not allowed"),
            CommandResult(terminationStatus: 0, standardOutput: "SleepDisabled 0\n", standardError: ""),
        ]
        let controller = ClamshellController(runner: fake, userName: "seam", uid: 501)
        let cap = await controller.refreshCapability()
        XCTAssertEqual(cap, .needsAuthorization)
    }

    func test_installAuthorization_runsOsascriptWithFixedScriptFragments() async throws {
        let fake = FakeCommandRunner()
        fake.results = [
            // osascript install
            CommandResult(terminationStatus: 0, standardOutput: "", standardError: ""),
            // post sudo -n -l 1
            CommandResult(terminationStatus: 0, standardOutput: "", standardError: ""),
            // post sudo -n -l 0
            CommandResult(terminationStatus: 0, standardOutput: "", standardError: ""),
            // finalize remove candidate
            CommandResult(terminationStatus: 0, standardOutput: "", standardError: ""),
        ]
        let controller = ClamshellController(runner: fake, userName: "seam", uid: 501)
        try await controller.installAuthorization()

        XCTAssertEqual(fake.calls[0].executable.path, "/usr/bin/osascript")
        let joined = fake.calls[0].arguments.joined(separator: " ")
        XCTAssertTrue(joined.contains("omniforge-clamshell-501.candidate"), joined)
        XCTAssertTrue(joined.contains("visudo"), joined)
        XCTAssertTrue(joined.contains("/bin/ln"), joined)
        XCTAssertFalse(joined.contains("ln -f"), "must not force-link")
        XCTAssertTrue(joined.contains("disablesleep 1"), joined)
        XCTAssertTrue(joined.contains("disablesleep 0"), joined)
        XCTAssertEqual(fake.calls[1].arguments, ["-n", "-l", "/usr/bin/pmset", "disablesleep", "1"])
        XCTAssertEqual(fake.calls[2].arguments, ["-n", "-l", "/usr/bin/pmset", "disablesleep", "0"])
        XCTAssertEqual(fake.calls[3].executable.path, "/usr/bin/osascript")
    }

    func test_installAuthorization_postListFailure_mapsSudoersValidationFailed() async {
        let fake = FakeCommandRunner()
        fake.results = [
            CommandResult(terminationStatus: 0, standardOutput: "", standardError: ""),
            CommandResult(terminationStatus: 1, standardOutput: "", standardError: "not allowed"),
            CommandResult(terminationStatus: 1, standardOutput: "", standardError: "not allowed"),
            CommandResult(terminationStatus: 0, standardOutput: "", standardError: ""),
        ]
        let controller = ClamshellController(runner: fake, userName: "seam", uid: 501)
        do {
            try await controller.installAuthorization()
            XCTFail("expected failure")
        } catch let error as KeepAwakeError {
            guard case .sudoersValidationFailed = error else {
                return XCTFail("unexpected \(error)")
            }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_installAuthorization_adminCancel_mapsCancelled() async {
        let fake = FakeCommandRunner()
        fake.results = [
            CommandResult(terminationStatus: 1, standardOutput: "", standardError: "User canceled."),
        ]
        let controller = ClamshellController(runner: fake, userName: "seam", uid: 501)
        do {
            try await controller.installAuthorization()
            XCTFail("expected cancel")
        } catch let error as KeepAwakeError {
            XCTAssertEqual(error, .administratorAuthorizationCancelled)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_installAuthorization_targetConflictExitCode_mapsValidationFailed() async {
        let fake = FakeCommandRunner()
        fake.results = [
            CommandResult(terminationStatus: 22, standardOutput: "", standardError: "conflict"),
        ]
        let controller = ClamshellController(runner: fake, userName: "seam", uid: 501)
        do {
            try await controller.installAuthorization()
            XCTFail("expected conflict")
        } catch let error as KeepAwakeError {
            guard case .sudoersValidationFailed = error else {
                return XCTFail("unexpected \(error)")
            }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_removeAuthorization_requiresSleepDisabledZero() async {
        let fake = FakeCommandRunner()
        fake.results = [
            CommandResult(terminationStatus: 0, standardOutput: "SleepDisabled 1\n", standardError: ""),
        ]
        let controller = ClamshellController(runner: fake, userName: "seam", uid: 501)
        do {
            try await controller.removeAuthorization()
            XCTFail("expected refuse")
        } catch let error as KeepAwakeError {
            guard case .authorizationRemovalFailed = error else {
                return XCTFail("unexpected \(error)")
            }
        } catch {
            XCTFail("unexpected \(error)")
        }
        // 不应触发 osascript
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(fake.calls[0].executable.path, "/usr/bin/pmset")
    }

    func test_removeAuthorization_successSequence() async throws {
        let fake = FakeCommandRunner()
        fake.results = [
            CommandResult(terminationStatus: 0, standardOutput: "SleepDisabled 0\n", standardError: ""),
            CommandResult(terminationStatus: 0, standardOutput: "", standardError: ""),
        ]
        let controller = ClamshellController(runner: fake, userName: "seam", uid: 501)
        try await controller.removeAuthorization()
        XCTAssertEqual(fake.calls[0].arguments, ["-g"])
        XCTAssertEqual(fake.calls[1].executable.path, "/usr/bin/osascript")
        let joined = fake.calls[1].arguments.joined(separator: " ")
        XCTAssertTrue(joined.contains("omniforge-clamshell-501"), joined)
    }

    func test_candidatePath_isIgnoredByIncludeDir() {
        let path = ClamshellSupport.sudoersCandidatePath(uid: 501)
        XCTAssertTrue(ClamshellSupport.isSudoersCandidateNameIgnoredByIncludeDir(path))
        XCTAssertFalse(
            ClamshellSupport.isSudoersCandidateNameIgnoredByIncludeDir(
                ClamshellSupport.sudoersPath(uid: 501)
            )
        )
    }

    func test_installScript_containsNoClobberLnAndVisudo() {
        let script = ClamshellSupport.installAuthorizationShellScript(username: "seam", uid: 501)
        XCTAssertTrue(script.contains("/bin/ln \"$CANDIDATE\" \"$TARGET\""))
        XCTAssertFalse(script.contains("ln -f"))
        XCTAssertFalse(script.contains("mv "))
        XCTAssertTrue(script.contains("visudo -c -f"))
        XCTAssertTrue(script.contains("omniforge-clamshell-501.candidate"))
        XCTAssertTrue(script.contains("root:wheel"))
    }

    /// macOS `stat -f '%Mp%Lp'` 输出 4 位八进制（0440）；
    /// EXPECT_OWNER 必须与该格式精确匹配，否则 owner 比较恒 false，
    /// 会让 install no-op、rollback 和 remove 的 owner 守卫全部失效。
    func test_scripts_expectOwnerMatchesStatFormat() {
        let install = ClamshellSupport.installAuthorizationShellScript(username: "seam", uid: 501)
        let rollback = ClamshellSupport.rollbackAuthorizationShellScript(username: "seam", uid: 501)
        let remove = ClamshellSupport.removeAuthorizationShellScript(username: "seam", uid: 501)

        for (name, script) in [("install", install), ("rollback", rollback), ("remove", remove)] {
            XCTAssertTrue(
                script.contains("EXPECT_OWNER=\"root:wheel:0440\"")
                    || script.contains("\"root:wheel:0440\""),
                "\(name) must expect the 4-digit octal owner string produced by stat -f '%Mp%Lp'"
            )
            // 不得再用 3 位 440 形式比较，那永远匹配不上 stat 的 0440。
            XCTAssertFalse(
                script.contains("\"root:wheel:440\""),
                "\(name) must not compare against the 3-digit form that never matches stat output"
            )
        }
    }

    func test_installScript_writesRealNewlineNotLiteralEscapedN() {
        let script = ClamshellSupport.installAuthorizationShellScript(username: "seam", uid: 501)
        // RULE 必须是真实换行的精确规则，不能把尾部 \n 写成字面 \\n。
        let expectedRule = ClamshellSupport.sudoersRuleText(username: "seam")
        XCTAssertTrue(
            script.contains(expectedRule) || script.contains("printf '%s\\n'"),
            "script must materialize a real trailing newline for sudoers body"
        )
        // 禁止把规则正文里的换行错误地嵌成字面 \n 字符串比较体。
        XCTAssertFalse(
            script.contains("EXPECT_BODY=\"seam ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0\\n\""),
            "EXPECT_BODY must not store a double-escaped newline literal that never matches file body"
        )
    }

    func test_installScript_keepsCandidateUntilPostInstallValidation() {
        let script = ClamshellSupport.installAuthorizationShellScript(username: "seam", uid: 501)
        // ln 成功后不得立刻 rm 候选；候选应保留到后验成功（finalize）或失败回滚。
        guard let lnRange = script.range(of: "/bin/ln \"$CANDIDATE\" \"$TARGET\"") else {
            return XCTFail("missing no-clobber ln")
        }
        // ln 失败分支允许删候选；成功路径（ln 语句之后到脚本结束，不含 if ! 分支体）不得再 rm。
        // 结构：`if ! /bin/ln ...; then rm; exit 23; fi` 之后不应再有 rm candidate。
        let afterLnBlock = script[lnRange.lowerBound...]
        // 成功路径：if 分支结束后应保留候选注释，且没有第二次无条件 rm。
        XCTAssertTrue(
            afterLnBlock.contains("保留候选") || afterLnBlock.contains("finalize"),
            "success path should document retaining candidate for post-check"
        )
        // 统计 rm candidate：允许 1 次（写前清理 stale）+ 1 次（ln 失败分支）
        let rmCount = script.components(separatedBy: "/bin/rm -f \"$CANDIDATE\"").count - 1
        XCTAssertLessThanOrEqual(rmCount, 2, "install script should not eagerly delete candidate on success")

        let rollback = ClamshellSupport.rollbackAuthorizationShellScript(username: "seam", uid: 501)
        XCTAssertTrue(rollback.contains("stat -f '%i'"), "need inode compare for safe rollback")
        XCTAssertTrue(rollback.contains("ROLLBACK"), "need explicit rollback marker")

        let finalize = ClamshellSupport.finalizeAuthorizationShellScript(uid: 501)
        XCTAssertTrue(finalize.contains("/bin/rm -f \"$CANDIDATE\""))
    }

    func test_installScript_lnExistingTarget_exitsRecognizableCode() {
        let script = ClamshellSupport.installAuthorizationShellScript(username: "seam", uid: 501)
        // 目标并发出现时 ln 必须失败且使用可识别退出码，不得覆盖。
        XCTAssertTrue(
            script.contains("exit 23") || script.contains("exit 24"),
            "ln no-clobber failure should use a dedicated exit code"
        )
    }

    func test_installAuthorization_postListFailure_runsRollbackScript() async {
        let fake = FakeCommandRunner()
        fake.results = [
            // install osascript success (leaves candidate+target)
            CommandResult(terminationStatus: 0, standardOutput: "", standardError: ""),
            // post sudo -n -l 1 fail
            CommandResult(terminationStatus: 1, standardOutput: "", standardError: "not allowed"),
            // post sudo -n -l 0 fail
            CommandResult(terminationStatus: 1, standardOutput: "", standardError: "not allowed"),
            // rollback osascript
            CommandResult(terminationStatus: 0, standardOutput: "", standardError: ""),
        ]
        let controller = ClamshellController(runner: fake, userName: "seam", uid: 501)
        do {
            try await controller.installAuthorization()
            XCTFail("expected failure")
        } catch let error as KeepAwakeError {
            guard case .sudoersValidationFailed = error else {
                return XCTFail("unexpected \(error)")
            }
        } catch {
            XCTFail("unexpected \(error)")
        }
        // 至少：install + 两个 list + rollback
        XCTAssertGreaterThanOrEqual(fake.calls.count, 4)
        XCTAssertEqual(fake.calls[0].executable.path, "/usr/bin/osascript")
        XCTAssertEqual(fake.calls[3].executable.path, "/usr/bin/osascript")
        let rollbackJoined = fake.calls[3].arguments.joined(separator: " ")
        XCTAssertTrue(
            rollbackJoined.contains("omniforge-clamshell-501") || rollbackJoined.contains("ROLLBACK") || rollbackJoined.contains("stat"),
            rollbackJoined
        )
    }
}
