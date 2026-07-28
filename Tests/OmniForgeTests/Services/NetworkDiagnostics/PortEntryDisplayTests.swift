import XCTest
@testable import OmniForge

final class PortEntryDisplayTests: XCTestCase {
    func test_localPortDisplay_hasNoGroupingSeparators() {
        let entry = PortEntry(
            proto: .tcp,
            localIP: "127.0.0.1",
            localPort: 9197,
            remoteIP: nil,
            remotePort: nil,
            state: "LISTEN",
            pid: 1,
            command: "node"
        )
        XCTAssertEqual(entry.localPortDisplay, "9197")
        XCTAssertFalse(entry.localPortDisplay.contains(","))
        XCTAssertFalse(entry.localPortDisplay.contains(" "))
    }

    func test_localPortDisplay_largePort() {
        let entry = PortEntry(
            proto: .tcp,
            localIP: "*",
            localPort: 42950,
            remoteIP: nil,
            remotePort: nil,
            state: "LISTEN",
            pid: 2,
            command: "app"
        )
        XCTAssertEqual(entry.localPortDisplay, "42950")
    }

    func test_hostPortCopyText_usesRawPortDigits() {
        let entry = PortEntry(
            proto: .tcp,
            localIP: "127.0.0.1",
            localPort: 10191,
            remoteIP: nil,
            remotePort: nil,
            state: "LISTEN",
            pid: 3,
            command: "x"
        )
        XCTAssertEqual(entry.hostPortCopyText, "127.0.0.1:10191")
    }
}
