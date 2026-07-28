import Combine
import CoreGraphics
import XCTest
@testable import OmniForge

final class FakePointerPoster: PointerActivityPosting {
    var location = CGPoint(x: 50, y: 50)
    var bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
    private(set) var posts: [CGPoint] = []
    var failPost = false

    func currentLocation() -> CGPoint { location }
    func displayBounds(containing point: CGPoint) -> CGRect { bounds }
    func postMouseMoved(to point: CGPoint) throws {
        if failPost { throw KeepAwakeError.pointerEventFailed }
        posts.append(point)
        location = point
    }
}

@MainActor
final class PointerActivityServiceTests: XCTestCase {
    func test_nudgeThenReturnToOrigin() {
        let clock = FakeKeepAwakeClock(now: Date(timeIntervalSince1970: 0))
        let scheduler = FakeKeepAwakeScheduler(clock: clock)
        let poster = FakePointerPoster()
        let service = PointerActivityService(
            poster: poster,
            scheduler: scheduler,
            clock: clock,
            isAccessibilityTrusted: { true }
        )

        service.start(intervalMinutes: .minutes1)
        // start 立即 nudge 一次
        XCTAssertEqual(poster.posts.count, 1)
        XCTAssertEqual(poster.posts[0], CGPoint(x: 51, y: 50))

        // 80ms 后返回
        scheduler.advance(to: Date(timeIntervalSince1970: 0.08))
        XCTAssertEqual(poster.posts.count, 2)
        XCTAssertEqual(poster.posts[1], CGPoint(x: 50, y: 50))
    }

    func test_userMoveCancelsReturn() {
        let clock = FakeKeepAwakeClock(now: Date(timeIntervalSince1970: 0))
        let scheduler = FakeKeepAwakeScheduler(clock: clock)
        let poster = FakePointerPoster()
        let service = PointerActivityService(
            poster: poster,
            scheduler: scheduler,
            clock: clock,
            isAccessibilityTrusted: { true }
        )
        service.start(intervalMinutes: .minutes1)
        XCTAssertEqual(poster.posts.count, 1)
        // 用户移动到别处
        poster.location = CGPoint(x: 80, y: 80)
        scheduler.advance(to: Date(timeIntervalSince1970: 0.08))
        XCTAssertEqual(poster.posts.count, 1, "should not steal pointer back")
    }

    func test_missingPermission_postsZeroEvents() {
        let clock = FakeKeepAwakeClock()
        let scheduler = FakeKeepAwakeScheduler(clock: clock)
        let poster = FakePointerPoster()
        let service = PointerActivityService(
            poster: poster,
            scheduler: scheduler,
            clock: clock,
            isAccessibilityTrusted: { false }
        )
        service.start(intervalMinutes: .minutes1)
        XCTAssertTrue(poster.posts.isEmpty)
        XCTAssertEqual(service.lastError, .accessibilityPermissionMissing)
    }

    func test_postFailure_stopsFurtherNudgesAndPublishesError() {
        let clock = FakeKeepAwakeClock(now: Date(timeIntervalSince1970: 0))
        let scheduler = FakeKeepAwakeScheduler(clock: clock)
        let poster = FakePointerPoster()
        poster.failPost = true
        let service = PointerActivityService(
            poster: poster,
            scheduler: scheduler,
            clock: clock,
            isAccessibilityTrusted: { true }
        )
        service.start(intervalMinutes: .minutes1)
        XCTAssertEqual(service.lastError, .pointerEventFailed)
        XCTAssertTrue(poster.posts.isEmpty)
        // 重复任务应已停止
        scheduler.fireRepeating()
        XCTAssertTrue(poster.posts.isEmpty)
    }

    func test_stopAndRestart_usesNewGeneration() {
        let clock = FakeKeepAwakeClock(now: Date(timeIntervalSince1970: 0))
        let scheduler = FakeKeepAwakeScheduler(clock: clock)
        let poster = FakePointerPoster()
        let service = PointerActivityService(
            poster: poster,
            scheduler: scheduler,
            clock: clock,
            isAccessibilityTrusted: { true }
        )
        service.start(intervalMinutes: .minutes1)
        let firstCount = poster.posts.count
        service.stop()
        service.start(intervalMinutes: .minutes1)
        XCTAssertGreaterThan(poster.posts.count, firstCount)
    }
}
