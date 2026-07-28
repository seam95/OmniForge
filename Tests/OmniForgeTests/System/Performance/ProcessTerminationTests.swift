import XCTest
@testable import OmniForge

final class ProcessTerminationTests: XCTestCase {
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    func test_canTerminate_blocksInvalidPID() {
        XCTAssertFalse(ProcessTermination.canTerminate(pid: 0, name: "X", ownPID: ownPID))
        XCTAssertFalse(ProcessTermination.canTerminate(pid: -1, name: "X", ownPID: ownPID))
    }

    func test_canTerminate_blocksSelf() {
        XCTAssertFalse(ProcessTermination.canTerminate(pid: ownPID, name: "OmniForge", ownPID: ownPID))
    }

    func test_canTerminate_blocksCriticalSystemProcesses() {
        let blocked = ["kernel_task", "launchd", "loginwindow", "WindowServer",
                       "Finder", "SystemUIServer", "Dock", "coreservicesd"]
        for name in blocked {
            XCTAssertFalse(
                ProcessTermination.canTerminate(pid: 999, name: name, ownPID: ownPID),
                "应拦截系统关键进程：\(name)"
            )
        }
    }

    func test_canTerminate_allowsNormalApps() {
        XCTAssertTrue(ProcessTermination.canTerminate(pid: 1234, name: "Xcode", ownPID: ownPID))
        XCTAssertTrue(ProcessTermination.canTerminate(pid: 2345, name: "Google Chrome", ownPID: ownPID))
    }
}
