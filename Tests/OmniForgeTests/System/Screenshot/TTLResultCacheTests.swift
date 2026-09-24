import XCTest
@testable import OmniForge

/// `TTLResultCache` 契约：TTL 内复用、并发单飞、失败不污染后续调用。
///
/// 为什么值得单测：截图会话里冻屏与「选区先于冻屏就绪」的实时回退会在几十毫秒内
/// 接连请求同一份 `SCShareableContent`。本机实测一次枚举 ~1.05s（3222 个窗口，
/// CursorUIViewService 占 2855 个），实际捕获仅 ~60ms；不复用就等于把这一秒吃两遍，
/// 标注工具栏凭空晚出现一两秒（用户报的回归）。
final class TTLResultCacheTests: XCTestCase {
    private struct Boom: Error, Equatable {}

    func test_sequentialCalls_reuseCachedValueWithinTTL() async throws {
        let cache = TTLResultCache<Int>(ttl: 10)
        var calls = 0

        let first = try await cache.value { calls += 1; return 1 }
        let second = try await cache.value { calls += 1; return 2 }
        let third = try await cache.value { calls += 1; return 3 }

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 1, "TTL 内必须复用缓存，不得重新生产")
        XCTAssertEqual(third, 1)
        XCTAssertEqual(calls, 1)
    }

    func test_valueExpiresAfterTTL() async throws {
        let cache = TTLResultCache<Int>(ttl: 0.05)
        var calls = 0

        let first = try await cache.value { calls += 1; return 1 }
        try await Task.sleep(nanoseconds: 120_000_000) // 越过 TTL
        let second = try await cache.value { calls += 1; return 2 }

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2, "过期后必须重新生产")
        XCTAssertEqual(calls, 2)
    }

    func test_concurrentCalls_shareSingleProduction() async throws {
        // 单飞：冻屏与回退同时到达时只能发起一次生产（生产期间后来者挂靠等待）。
        let cache = TTLResultCache<Int>(ttl: 10)
        let counter = CallCounter()

        async let a: Int = cache.value { await counter.tick(1) }
        async let b: Int = cache.value { await counter.tick(2) }
        async let c: Int = cache.value { await counter.tick(3) }
        let results = try await [a, b, c]

        XCTAssertEqual(results, [1, 1, 1], "并发调用必须共享同一份生产结果")
        XCTAssertEqual(counter.count, 1, "并发调用不得各发起一次生产")
    }

    func test_failure_doesNotPoisonLaterCalls() async throws {
        let cache = TTLResultCache<Int>(ttl: 10)
        var calls = 0

        do {
            _ = try await cache.value { calls += 1; throw Boom() }
            XCTFail("生产者抛错时必须传播")
        } catch {
            XCTAssertEqual(error as? Boom, Boom())
        }

        let recovered = try await cache.value { calls += 1; return 7 }

        XCTAssertEqual(recovered, 7, "失败后必须允许重新发起生产")
        XCTAssertEqual(calls, 2)
        // 成功后缓存应生效
        let cached = try await cache.value { calls += 1; return 99 }
        XCTAssertEqual(cached, 7)
        XCTAssertEqual(calls, 2)
    }

    func test_concurrentCalls_afterFailure_retryIndependently() async throws {
        let cache = TTLResultCache<Int>(ttl: 10)
        let counter = CallCounter()

        do {
            _ = try await cache.value { await counter.tick(-1); throw Boom() }
            XCTFail("生产者抛错时必须传播")
        } catch {
            XCTAssertEqual(error as? Boom, Boom())
        }

        async let a: Int = cache.value { await counter.tick(5) }
        async let b: Int = cache.value { await counter.tick(6) }
        let results = try await [a, b]

        // 谁先抢到单飞不确定，但两次调用必须共享同一份生产结果，且只多生产一次。
        XCTAssertEqual(results[0], results[1], "失败后的新并发调用仍须单飞共享")
        XCTAssertTrue(results[0] == 5 || results[0] == 6)
        XCTAssertEqual(counter.count, 2, "失败一次 + 成功后一次，不得各发起一次")
    }
}

/// 线程安全计数器：并发单飞断言用。
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func tick(_ result: Int) async -> Int {
        lock.lock()
        value += 1
        lock.unlock()
        try? await Task.sleep(nanoseconds: 30_000_000) // 拉长生产窗口，逼出并发
        return result
    }
}
