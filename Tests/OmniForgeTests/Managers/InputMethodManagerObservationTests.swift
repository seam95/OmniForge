import XCTest
@testable import OmniForge

final class InputMethodManagerObservationTests: XCTestCase {
    func test_observerInvokesCallback() {
        let tis = FakeTISClient(inputSources: [], currentID: nil)
        let notifications = FakeNotificationCenterClient()
        let manager = InputMethodManager(tis: tis, notifications: notifications)

        let exp = expectation(description: "callback")
        manager.startObservingInputSourceChanges {
            exp.fulfill()
        }

        notifications.post(name: .tisSelectedKeyboardInputSourceChanged)
        wait(for: [exp], timeout: 1.0)
    }
}
