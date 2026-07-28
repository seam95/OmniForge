import XCTest
@testable import OmniForge

final class SingleInstanceCoordinatorTests: XCTestCase {
    func test_acquirePrimary_returnsLeaseWithoutPostingWakeNotification() throws {
        let locker = FakeInstanceLocker(result: .success(SingleInstanceLease {}))
        let notifications = FakeNotificationCenterClient()
        let coordinator = SingleInstanceCoordinator(
            locker: locker,
            notifications: notifications
        )

        let result = try coordinator.acquire()

        guard case .primary = result else {
            return XCTFail("首次启动应取得主实例租约")
        }
        XCTAssertEqual(locker.requestedKeys, [SingleInstanceCoordinator.lockKey])
        XCTAssertEqual(notifications.postedNames, [])
    }

    func test_acquireSecondary_postsWakeNotificationAndReturnsSecondary() throws {
        let locker = FakeInstanceLocker(result: .success(nil))
        let notifications = FakeNotificationCenterClient()
        let coordinator = SingleInstanceCoordinator(
            locker: locker,
            notifications: notifications
        )

        let result = try coordinator.acquire()

        guard case .secondary = result else {
            return XCTFail("锁已占用时应识别为次实例")
        }
        XCTAssertEqual(notifications.postedNames, [.inputLockWakeExistingInstance])
    }

    func test_acquireLockFailure_isExposedWithoutPostingFalseWake() {
        let expected = NSError(domain: "SingleInstanceTests", code: 7)
        let locker = FakeInstanceLocker(result: .failure(expected))
        let notifications = FakeNotificationCenterClient()
        let coordinator = SingleInstanceCoordinator(
            locker: locker,
            notifications: notifications
        )

        XCTAssertThrowsError(try coordinator.acquire()) { error in
            XCTAssertEqual((error as NSError).domain, expected.domain)
            XCTAssertEqual((error as NSError).code, expected.code)
        }
        XCTAssertEqual(notifications.postedNames, [])
    }
}

private final class FakeInstanceLocker: InstanceLocking {
    let result: Result<SingleInstanceLease?, Error>
    private(set) var requestedKeys: [String] = []

    init(result: Result<SingleInstanceLease?, Error>) {
        self.result = result
    }

    func tryAcquire(key: String) throws -> SingleInstanceLease? {
        requestedKeys.append(key)
        return try result.get()
    }
}

private final class FakeNotificationCenterClient: NotificationCenterClient {
    private(set) var postedNames: [Notification.Name] = []

    func addObserver(forName name: Notification.Name, using block: @escaping () -> Void) -> AnyObject {
        NSObject()
    }

    func removeObserver(_ token: AnyObject) {}

    func post(name: Notification.Name) {
        postedNames.append(name)
    }
}
