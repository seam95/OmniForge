import Darwin
import Foundation

/// 持有进程级文件锁；对象释放时由内核释放锁。
final class SingleInstanceLease {
    private let releaseAction: () -> Void
    private var isReleased = false

    init(release: @escaping () -> Void) {
        releaseAction = release
    }

    deinit {
        release()
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        releaseAction()
    }
}

protocol InstanceLocking {
    /// 成功取得锁时返回租约；锁已被其他进程占用时返回 nil；系统错误直接抛出。
    func tryAcquire(key: String) throws -> SingleInstanceLease?
}

struct POSIXInstanceLocker: InstanceLocking {
    func tryAcquire(key: String) throws -> SingleInstanceLease? {
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(key)-\(getuid()).lock", isDirectory: false)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            close(descriptor)
            if lockError == EWOULDBLOCK {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: lockError) ?? .EIO)
        }

        return SingleInstanceLease {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }
}

enum SingleInstanceAcquisition {
    case primary(SingleInstanceLease)
    case secondary
}

struct SingleInstanceCoordinator {
    static let lockKey = "com.omniforge.app"

    private let locker: InstanceLocking
    private let notifications: NotificationCenterClient

    init(
        locker: InstanceLocking = POSIXInstanceLocker(),
        notifications: NotificationCenterClient = DistributedNotificationCenterAdapter()
    ) {
        self.locker = locker
        self.notifications = notifications
    }

    func acquire() throws -> SingleInstanceAcquisition {
        guard let lease = try locker.tryAcquire(key: Self.lockKey) else {
            notifications.post(name: .inputLockWakeExistingInstance)
            return .secondary
        }
        return .primary(lease)
    }
}

extension Notification.Name {
    static let inputLockWakeExistingInstance = Notification.Name(
        "com.omniforge.app.wake-existing-instance"
    )
}
