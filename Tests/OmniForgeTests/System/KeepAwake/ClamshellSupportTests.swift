import XCTest
@testable import OmniForge

final class ClamshellSupportTests: XCTestCase {
    func test_usernameValidationMatrix() {
        XCTAssertTrue(ClamshellSupport.isValidUsername("seam"))
        XCTAssertTrue(ClamshellSupport.isValidUsername("user_name-01.test"))
        XCTAssertFalse(ClamshellSupport.isValidUsername(""))
        XCTAssertFalse(ClamshellSupport.isValidUsername("seam;rm"))
        XCTAssertFalse(ClamshellSupport.isValidUsername("seam root"))
        XCTAssertFalse(ClamshellSupport.isValidUsername("seam\n"))
        XCTAssertFalse(ClamshellSupport.isValidUsername("../seam"))
    }

    func test_uidTextValidation() {
        let uid: uid_t = 501
        XCTAssertTrue(ClamshellSupport.isValidUIDText("501", expected: uid))
        XCTAssertFalse(ClamshellSupport.isValidUIDText("0501", expected: uid))
        XCTAssertFalse(ClamshellSupport.isValidUIDText("502", expected: uid))
        XCTAssertFalse(ClamshellSupport.isValidUIDText("-501", expected: uid))
    }

    func test_sudoersPathAndExactRule() {
        XCTAssertEqual(ClamshellSupport.sudoersPath(uid: 501), "/etc/sudoers.d/omniforge-clamshell-501")
        XCTAssertEqual(ClamshellSupport.sudoersCandidatePath(uid: 501), "/etc/sudoers.d/omniforge-clamshell-501.candidate")
        // 改名后必须同时识别历史前缀，以便清理老版本残留的孤儿 sudoers。
        let known = ClamshellSupport.allKnownSudoersPaths(uid: 501)
        XCTAssertEqual(known, [
            "/etc/sudoers.d/omniforge-clamshell-501",
            "/etc/sudoers.d/omniforge-clamshell-501.candidate",
            "/etc/sudoers.d/inputlock-clamshell-501",
            "/etc/sudoers.d/inputlock-clamshell-501.candidate",
        ])
        let rule = ClamshellSupport.sudoersRuleText(username: "seam")
        XCTAssertEqual(
            rule,
            "seam ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0\n"
        )
        XCTAssertTrue(ClamshellSupport.isExactSudoersContent(rule, username: "seam"))
        XCTAssertFalse(ClamshellSupport.isExactSudoersContent(rule + "extra\n", username: "seam"))
        XCTAssertFalse(ClamshellSupport.isExactSudoersContent(
            "seam ALL=(root) NOPASSWD: /usr/bin/pmset\n",
            username: "seam"
        ))
        XCTAssertFalse(ClamshellSupport.isExactSudoersContent(
            "seam ALL=(root) NOPASSWD: ALL\n",
            username: "seam"
        ))
    }

    func test_parseSleepDisabled() {
        XCTAssertEqual(ClamshellSupport.parseSleepDisabled(from: " SleepDisabled\t1\n"), 1)
        XCTAssertEqual(ClamshellSupport.parseSleepDisabled(from: "SleepDisabled 0"), 0)
        XCTAssertNil(ClamshellSupport.parseSleepDisabled(from: "SleepDisabled yes"))
        XCTAssertNil(ClamshellSupport.parseSleepDisabled(from: "no key here"))
    }

    func test_recoveryDecisionTable() {
        // prepared + 0 → delete
        XCTAssertEqual(
            ClamshellSupport.recoveryAction(phase: .prepared, actualSleepDisabled: 0, recordValid: true, restoreTargetIsZero: true),
            .deleteRecord
        )
        // prepared + 1 → restore（即使 changedByInputLock=false 的语义由调用方保证 recordValid）
        XCTAssertEqual(
            ClamshellSupport.recoveryAction(phase: .prepared, actualSleepDisabled: 1, recordValid: true, restoreTargetIsZero: true),
            .restoreToZero
        )
        XCTAssertEqual(
            ClamshellSupport.recoveryAction(phase: .enabled, actualSleepDisabled: 0, recordValid: true, restoreTargetIsZero: true),
            .deleteRecord
        )
        XCTAssertEqual(
            ClamshellSupport.recoveryAction(phase: .enabled, actualSleepDisabled: 1, recordValid: true, restoreTargetIsZero: true),
            .restoreToZero
        )
        XCTAssertEqual(
            ClamshellSupport.recoveryAction(phase: .restoring, actualSleepDisabled: 0, recordValid: true, restoreTargetIsZero: true),
            .deleteRecord
        )
        XCTAssertEqual(
            ClamshellSupport.recoveryAction(phase: .restoring, actualSleepDisabled: 1, recordValid: true, restoreTargetIsZero: true),
            .restoreToZero
        )
        // 无合法记录 + 实际 1 → conflict，不能写 0
        XCTAssertEqual(
            ClamshellSupport.recoveryAction(phase: nil, actualSleepDisabled: 1, recordValid: true, restoreTargetIsZero: true),
            .conflict(reason: "SleepDisabled is 1 without a matching recovery record")
        )
        XCTAssertEqual(
            ClamshellSupport.recoveryAction(phase: .prepared, actualSleepDisabled: 1, recordValid: false, restoreTargetIsZero: true),
            .refuse(reason: "recovery record failed validation")
        )
    }

    func test_preparedRecordRequiresRestoreTargetZero() {
        let record = ClamshellRecoveryRecord.makePrepared(
            userName: "seam",
            uid: 501,
            operationID: "op-1"
        )
        XCTAssertEqual(record.phase, .prepared)
        XCTAssertEqual(record.restoreTargetSleepDisabled, 0)
        XCTAssertFalse(record.changedByInputLock)
        if case .success = record.validate(expectedUID: 501, expectedUserName: "seam") {
            // ok
        } else {
            XCTFail("expected prepared record validation success")
        }
    }

    func test_osascriptAdministratorArguments_usesDoubleQuotedShellAndPreservesPrintfSingleQuotes() {
        let script = ClamshellSupport.installAuthorizationShellScript(username: "seam", uid: 501)
        let args = ClamshellSupport.osascriptAdministratorArguments(shellScript: script)
        XCTAssertEqual(args.count, 2)
        XCTAssertEqual(args[0], "-e")
        let apple = args[1]
        XCTAssertTrue(apple.hasPrefix("do shell script \""), apple)
        XCTAssertTrue(apple.hasSuffix("\" with administrator privileges"), apple)
        // 单引号包装会被 printf '%s\n' 截断，产生 \'s 语法错误；禁止该模式。
        XCTAssertFalse(apple.hasPrefix("do shell script '"), apple)
        XCTAssertFalse(apple.contains("'\\''"), "must not use shell-style single-quote splicing inside AppleScript")
        // shell 正文中的 printf 单引号字面量应原样保留在双引号 AppleScript 字符串内。
        XCTAssertTrue(apple.contains("printf '%s\\n'") || apple.contains("printf '%s\\\\n'"), apple)
    }
}
