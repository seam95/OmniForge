import Foundation
import UserNotifications
import XCTest
@testable import OmniForge

final class CleanerNotificationStatusGateTests: XCTestCase {
    func test_appBundleReadsNotificationStatus() {
        let gate = CleanerNotificationStatusGate(
            bundleURL: URL(fileURLWithPath: "/Applications/InputLock.app")
        )
        var readCount = 0
        var receivedStatus: UNAuthorizationStatus?

        gate.read(using: { completion in
            readCount += 1
            completion(.authorized)
        }, completion: { receivedStatus = $0 })

        XCTAssertTrue(gate.canAccessNotificationCenter)
        XCTAssertEqual(readCount, 1)
        XCTAssertEqual(receivedStatus, .authorized)
    }

    func test_commandLineBundleDoesNotReadNotificationStatus() {
        let gate = CleanerNotificationStatusGate(
            bundleURL: URL(fileURLWithPath: "/tmp/InputLock/.build/debug")
        )
        var readCount = 0

        gate.read(using: { _ in readCount += 1 }, completion: { _ in })

        XCTAssertFalse(gate.canAccessNotificationCenter)
        XCTAssertEqual(readCount, 0)
    }
}
