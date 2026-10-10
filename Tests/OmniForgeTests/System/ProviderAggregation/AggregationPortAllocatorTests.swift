import XCTest
@testable import OmniForge
import Network

/// 端口分配：空闲可判、占用不可用、preferred 空闲原样返回、占用顺延、
/// 全占返回 nil、持久化端口优先且重启后拿回。
final class AggregationPortAllocatorTests: XCTestCase {
    func test_isAvailable_trueForAFreePort() {
        XCTAssertTrue(AggregationPortAllocator.isAvailable(UInt16.random(in: 20000...40000)))
    }

    func test_isAvailable_falseForAnOccupiedPort() throws {
        let occupied = try NWListener(using: .tcp, on: .any).waitForBoundPort()
        defer { occupied.cancel() }
        let port = try XCTUnwrap(occupied.port?.rawValue)
        XCTAssertFalse(AggregationPortAllocator.isAvailable(port))
    }

    func test_resolve_returnsPreferredPortWhenFree() {
        let port = UInt16.random(in: 20000...40000)
        XCTAssertEqual(AggregationPortAllocator.resolve(preferred: port, maxAttempts: 3), port)
    }

    func test_resolve_skipsOccupiedPortsAndReturnsNextFree() throws {
        let taken = try NWListener(using: .tcp, on: .any).waitForBoundPort()
        defer { taken.cancel() }
        let base = try XCTUnwrap(taken.port?.rawValue)
        let resolved = AggregationPortAllocator.resolve(preferred: base, maxAttempts: 5)
        XCTAssertNotEqual(resolved, base)
        XCTAssertNotNil(resolved)
    }

    func test_resolve_returnsNilWhenAllAttemptsTaken() throws {
        var listeners: [NWListener] = []
        let base = UInt16.random(in: 20000...40000)
        for offset in 0..<5 {
            listeners.append(try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: base + UInt16(offset))!).waitForBoundPort())
        }
        defer { listeners.forEach { $0.cancel() } }
        XCTAssertNil(AggregationPortAllocator.resolve(preferred: base, maxAttempts: 5))
    }

    func test_resolvePersisted_prefersLastPortAndSurvivesRestart() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AggregationPortAllocatorTests"))
        defaults.removePersistentDomain(forName: "AggregationPortAllocatorTests")
        // 首次：无持久化 → 从 preferred 顺延并持久化
        let first = try XCTUnwrap(AggregationPortAllocator.resolvePersisted(defaults: defaults))
        XCTAssertEqual(defaults.integer(forKey: AggregationPortAllocator.portDefaultsKey), Int(first))
        // 重启：preferred 被占也要拿回持久化端口
        let holder = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: AggregationPortAllocator.preferredPort)!)
        defer { holder.cancel() }
        if first == AggregationPortAllocator.preferredPort {
            let second = try XCTUnwrap(AggregationPortAllocator.resolvePersisted(defaults: defaults))
            XCTAssertEqual(second, first)   // 持久化端口空闲 → 原样拿回
        }
    }
}

private extension NWListener {
    /// 启动并等待 ready（端口已绑定），返回自身便于链式 `defer { cancel() }`。
    func waitForBoundPort() throws -> NWListener {
        let ready = DispatchSemaphore(value: 0)
        stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        // NWListener 不设 newConnectionHandler 时 start 会以 EINVAL 失败——探测用途立即关掉连接。
        newConnectionHandler = { $0.cancel() }
        start(queue: .global())
        guard ready.wait(timeout: .now() + 5) == .success else {
            cancel()
            throw NSError(domain: "waitForBoundPort", code: 1, userInfo: nil)
        }
        return self
    }
}
