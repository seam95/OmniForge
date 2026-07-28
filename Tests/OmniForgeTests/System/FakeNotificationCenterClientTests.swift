import XCTest
@testable import OmniForge

final class FakeNotificationCenterClientTests: XCTestCase {
    func test_postInvokesObserverBlocks() {
        let notifications = FakeNotificationCenterClient()

        var calls = 0
        _ = notifications.addObserver(forName: .tisSelectedKeyboardInputSourceChanged) {
            calls += 1
        }

        notifications.post(name: .tisSelectedKeyboardInputSourceChanged)

        XCTAssertEqual(calls, 1)
    }
}
