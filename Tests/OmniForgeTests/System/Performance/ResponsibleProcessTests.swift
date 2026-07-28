import XCTest
@testable import OmniForge

final class ResponsibleProcessTests: XCTestCase {
    func test_ownerDoesNotCrashForSelf() {
        let selfPid = ProcessInfo.processInfo.processIdentifier
        let owner = ResponsibleProcess.owner(of: selfPid)
        XCTAssertGreaterThan(owner, 0)
    }

    func test_displayNameFallsBackWhenUnknown() {
        let name = ResponsibleProcess.displayName(pid: pid_t.max / 2, fallback: "helper")
        XCTAssertEqual(name, "helper")
    }

    func test_displayNameForSelfIsNonEmpty() {
        let selfPid = ProcessInfo.processInfo.processIdentifier
        let name = ResponsibleProcess.displayName(pid: selfPid, fallback: "self")
        XCTAssertFalse(name.isEmpty)
    }
}
