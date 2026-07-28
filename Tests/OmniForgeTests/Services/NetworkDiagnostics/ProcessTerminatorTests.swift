import Darwin
import XCTest
@testable import OmniForge

final class ProcessTerminatorTests: XCTestCase {

    private let ownPID: pid_t = 4242

    private func makeTerminator(
        killResult: Int32 = 0,
        errnoValue: Int32 = 0,
        killCalls: UnsafeMutablePointer<[ (pid_t, Int32) ]>? = nil
    ) -> ProcessTerminator {
        ProcessTerminator(
            ownPID: ownPID,
            killFn: { pid, sig in
                killCalls?.pointee.append((pid, sig))
                return killResult
            },
            errnoFn: { errnoValue },
            blacklist: ProcessTerminator.blacklistedNames,
            selfNames: ["omniforge", "myapp"]
        )
    }

    // MARK: - Blacklist / canTerminate

    func test_canTerminate_blocksBlacklistedNames() {
        let t = makeTerminator()
        let blocked = [
            "kernel_task", "WindowServer", "launchd", "loginwindow",
            "Finder", "Dock", "SystemUIServer", "coreservicesd",
            "  launchd  ", " Finder ",
        ]
        for name in blocked {
            XCTAssertFalse(t.canTerminate(pid: 999, name: name), "should block \(name)")
            let result = t.terminate(pid: 999, name: name, signal: .term)
            XCTAssertEqual(result, .failure(.blacklisted), "terminate should fail for \(name)")
        }
    }

    func test_canTerminate_blocksSelfPIDAndSelfName() {
        let t = makeTerminator()
        XCTAssertFalse(t.canTerminate(pid: ownPID, name: "Xcode"))
        XCTAssertFalse(t.canTerminate(pid: 100, name: "OmniForge"))
        XCTAssertFalse(t.canTerminate(pid: 100, name: "MyApp"))
        XCTAssertEqual(t.terminate(pid: ownPID, name: "Xcode", signal: .term), .failure(.blacklisted))
    }

    func test_defaultSelfNames_includesNewAndLegacyNames() {
        // 默认白名单同时覆盖新名 omniforge 与历史名 inputlock（改名后兼容开发期残留进程）。
        let defaults = ProcessTerminator.defaultSelfNames()
        XCTAssertTrue(defaults.contains("omniforge"))
        XCTAssertTrue(defaults.contains("inputlock"))
    }

    func test_canTerminate_blocksInvalidPID() {
        let t = makeTerminator()
        XCTAssertFalse(t.canTerminate(pid: 0, name: "node"))
        XCTAssertFalse(t.canTerminate(pid: -1, name: "node"))
        XCTAssertEqual(t.terminate(pid: 0, name: "node", signal: .term), .failure(.invalidPID))
    }

    func test_canTerminate_allowsNormalProcess() {
        let t = makeTerminator()
        XCTAssertTrue(t.canTerminate(pid: 1234, name: "node"))
        XCTAssertTrue(t.canTerminate(pid: 2345, name: "Google Chrome"))
    }

    // MARK: - SIGTERM / SIGKILL

    func test_terminate_sigtermSuccess() {
        var calls: [(pid_t, Int32)] = []
        let t = ProcessTerminator(
            ownPID: ownPID,
            killFn: { pid, sig in
                calls.append((pid, sig))
                return 0
            },
            errnoFn: { 0 },
            selfNames: ["omniforge"]
        )
        let result = t.terminate(pid: 777, name: "node", signal: .term)
        XCTAssertEqual(result, .success(.signalSent(.term)))
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].0, 777)
        XCTAssertEqual(calls[0].1, SIGTERM)
    }

    func test_terminate_sigkillSuccess() {
        var calls: [(pid_t, Int32)] = []
        let t = ProcessTerminator(
            ownPID: ownPID,
            killFn: { pid, sig in
                calls.append((pid, sig))
                return 0
            },
            errnoFn: { 0 },
            selfNames: ["omniforge"]
        )
        let result = t.terminate(pid: 888, name: "node", signal: .kill)
        XCTAssertEqual(result, .success(.signalSent(.kill)))
        XCTAssertEqual(calls[0].1, SIGKILL)
    }

    func test_terminate_esrchMapsToNotFound() {
        let t = ProcessTerminator(
            ownPID: ownPID,
            killFn: { _, _ in -1 },
            errnoFn: { ESRCH },
            selfNames: ["omniforge"]
        )
        XCTAssertEqual(t.terminate(pid: 1, name: "gone", signal: .term), .failure(.notFound))
    }

    func test_terminate_epermMapsToPermissionDenied() {
        let t = ProcessTerminator(
            ownPID: ownPID,
            killFn: { _, _ in -1 },
            errnoFn: { EPERM },
            selfNames: ["omniforge"]
        )
        XCTAssertEqual(t.terminate(pid: 1, name: "rootd", signal: .term), .failure(.permissionDenied))
    }

    func test_terminate_otherErrnoMapsToFailed() {
        let t = ProcessTerminator(
            ownPID: ownPID,
            killFn: { _, _ in -1 },
            errnoFn: { EINVAL },
            selfNames: ["omniforge"]
        )
        XCTAssertEqual(t.terminate(pid: 1, name: "x", signal: .term), .failure(.failed(errno: EINVAL)))
    }

    func test_blacklistedDoesNotCallKill() {
        var calls = 0
        let t = ProcessTerminator(
            ownPID: ownPID,
            killFn: { _, _ in
                calls += 1
                return 0
            },
            errnoFn: { 0 },
            selfNames: ["omniforge"]
        )
        _ = t.terminate(pid: 1, name: "launchd", signal: .term)
        XCTAssertEqual(calls, 0)
    }

    // MARK: - Command generation

    func test_sudoKillCommands() {
        XCTAssertEqual(ProcessTerminator.sudoKillCommand(pid: 4321), "sudo kill 4321")
        XCTAssertEqual(ProcessTerminator.sudoKill9Command(pid: 4321), "sudo kill -9 4321")
    }

    func test_shouldOfferForceKillAndSudo() {
        XCTAssertTrue(ProcessTerminator.shouldOfferForceKill(after: .permissionDenied))
        XCTAssertTrue(ProcessTerminator.shouldOfferForceKill(after: .notFound))
        XCTAssertFalse(ProcessTerminator.shouldOfferForceKill(after: .blacklisted))

        XCTAssertTrue(ProcessTerminator.shouldOfferSudoKill9(after: .permissionDenied))
        XCTAssertFalse(ProcessTerminator.shouldOfferSudoKill9(after: .notFound))
        XCTAssertFalse(ProcessTerminator.shouldOfferSudoKill9(after: .blacklisted))
    }

    func test_postTermRefreshDelay() {
        XCTAssertEqual(ProcessTerminator.postTermRefreshDelay, 1.5, accuracy: 0.001)
    }
}
