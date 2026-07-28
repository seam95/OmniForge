import Combine
import Foundation
@testable import OmniForge

// MARK: - Clock / Scheduler

final class FakeKeepAwakeClock: KeepAwakeClock {
    var now: Date

    init(now: Date = Date(timeIntervalSince1970: 1_000)) {
        self.now = now
    }

    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

final class FakeKeepAwakeScheduler: KeepAwakeScheduling {
    struct OnceTask {
        let id: UUID
        let date: Date
        let action: @MainActor () -> Void
        var cancelled = false
    }

    struct RepeatingTask {
        let id: UUID
        let interval: TimeInterval
        let tolerance: TimeInterval
        let action: @MainActor () -> Void
        var cancelled = false
        var fireCount = 0
    }

    private(set) var onceTasks: [OnceTask] = []
    private(set) var repeatingTasks: [RepeatingTask] = []
    private let clock: FakeKeepAwakeClock

    init(clock: FakeKeepAwakeClock) {
        self.clock = clock
    }

    func scheduleOnce(
        at date: Date,
        action: @escaping @MainActor () -> Void
    ) -> AnyCancellable {
        let id = UUID()
        onceTasks.append(OnceTask(id: id, date: date, action: action))
        return AnyCancellable { [weak self] in
            guard let self, let index = self.onceTasks.firstIndex(where: { $0.id == id }) else { return }
            self.onceTasks[index].cancelled = true
        }
    }

    func scheduleRepeating(
        every interval: TimeInterval,
        tolerance: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> AnyCancellable {
        let id = UUID()
        repeatingTasks.append(
            RepeatingTask(id: id, interval: interval, tolerance: tolerance, action: action)
        )
        return AnyCancellable { [weak self] in
            guard let self, let index = self.repeatingTasks.firstIndex(where: { $0.id == id }) else { return }
            self.repeatingTasks[index].cancelled = true
        }
    }

    /// 推进虚拟时间并触发到期的一次性任务（取消的跳过）。
    @MainActor
    func advance(to date: Date) {
        clock.now = date
        for index in onceTasks.indices where !onceTasks[index].cancelled {
            if onceTasks[index].date <= date {
                onceTasks[index].action()
                onceTasks[index].cancelled = true
            }
        }
    }

    @MainActor
    func fireRepeating(id: UUID? = nil) {
        for index in repeatingTasks.indices where !repeatingTasks[index].cancelled {
            if let id, repeatingTasks[index].id != id { continue }
            repeatingTasks[index].action()
            repeatingTasks[index].fireCount += 1
        }
    }
}

// MARK: - Command runner

final class FakeCommandRunner: CommandRunning {
    struct Call: Equatable {
        let executable: URL
        let arguments: [String]
    }

    private(set) var calls: [Call] = []
    var results: [CommandResult] = []
    var errorToThrow: Error?

    func run(executable: URL, arguments: [String]) async throws -> CommandResult {
        calls.append(Call(executable: executable, arguments: arguments))
        if let errorToThrow { throw errorToThrow }
        if results.isEmpty {
            return CommandResult(terminationStatus: 0, standardOutput: "", standardError: "")
        }
        return results.removeFirst()
    }
}

// MARK: - Assertion / notification / pointer recorders

struct FakePowerAssertionToken: Equatable, Hashable {
    let kind: String
    let id: UInt32
}

final class FakePowerAssertionRecorder {
    private(set) var acquired: [FakePowerAssertionToken] = []
    private(set) var released: [FakePowerAssertionToken] = []
    var failAcquireKind: String?
    var failReleaseIDs: Set<UInt32> = []

    func acquire(kind: String) throws -> FakePowerAssertionToken {
        if failAcquireKind == kind {
            throw KeepAwakeError.systemAssertionFailed(code: -1)
        }
        let token = FakePowerAssertionToken(kind: kind, id: UInt32(acquired.count + 1))
        acquired.append(token)
        return token
    }

    func release(_ token: FakePowerAssertionToken) throws {
        if failReleaseIDs.contains(token.id) {
            throw KeepAwakeError.assertionReleaseFailed(kind: token.kind, code: -2)
        }
        released.append(token)
    }
}

final class FakeUserNotificationPoster: UserNotificationPosting {
    struct Request: Equatable {
        let title: String
        let body: String
    }

    private(set) var requests: [Request] = []
    var errorToReturn: Error?

    func post(title: String, body: String, completion: @escaping (Result<Void, Error>) -> Void) {
        requests.append(Request(title: title, body: body))
        if let errorToReturn {
            completion(.failure(errorToReturn))
        } else {
            completion(.success(()))
        }
    }
}

final class FakePointerEventRecorder {
    struct Event: Equatable {
        let x: Double
        let y: Double
    }

    private(set) var events: [Event] = []
    var shouldFail = false

    func postMove(x: Double, y: Double) throws {
        if shouldFail { throw KeepAwakeError.pointerEventFailed }
        events.append(Event(x: x, y: y))
    }
}
