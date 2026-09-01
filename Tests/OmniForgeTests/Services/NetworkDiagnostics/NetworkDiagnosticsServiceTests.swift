import AppKit
import XCTest
@testable import OmniForge

// MARK: - Fakes

private final class FakeIdentityProvider: NetworkIdentityProviding {
    var identity = NetworkIdentity(
        hostname: "test-host",
        interfaces: [
            NetworkInterface(name: "en0", ipv4: "192.168.1.10", ipv6: nil, mac: "aa:bb:cc:dd:ee:ff"),
        ],
        defaultRoute: DefaultRoute(gateway: "192.168.1.1", interface: "en0"),
        dnsServers: ["8.8.8.8"],
        publicIPv4: nil,
        publicIPv6: nil
    )
    private(set) var callCount = 0

    func makeIdentity(publicIPv4: String?, publicIPv6: String?) -> NetworkIdentity {
        callCount += 1
        return NetworkIdentity(
            hostname: identity.hostname,
            interfaces: identity.interfaces,
            defaultRoute: identity.defaultRoute,
            dnsServers: identity.dnsServers,
            publicIPv4: publicIPv4,
            publicIPv6: publicIPv6
        )
    }
}

private final class FakePublicIPFetcher: PublicIPFetching {
    var ipv4: String?
    var ipv6: String?
    var delayNanoseconds: UInt64 = 0
    private(set) var ipv4Calls = 0
    private(set) var ipv6Calls = 0

    func fetchIPv4() async -> String? {
        ipv4Calls += 1
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return ipv4
    }

    func fetchIPv6() async -> String? {
        ipv6Calls += 1
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return ipv6
    }
}

private final class FakePortProbe: PortProbing {
    var result: Result<[PortEntry], Error> = .success([])
    private(set) var callCount = 0

    func probe() throws -> [PortEntry] {
        callCount += 1
        switch result {
        case let .success(entries):
            return entries
        case let .failure(error):
            throw error
        }
    }
}

private final class FakeNameResolver: ProcessNameResolving {
    var names: [pid_t: String] = [:]

    func resolveDisplayName(pid: pid_t, fallbackCommand: String) -> String {
        names[pid] ?? fallbackCommand
    }
}

private final class FakeTerminator: ProcessTerminating {
    var canTerminateResult = true
    var terminateResult: Result<TerminationOutcome, TerminationError> = .success(.signalSent(.term))
    private(set) var lastTerminate: (pid: pid_t, name: String, signal: TerminationSignal)?

    func canTerminate(pid: pid_t, name: String) -> Bool {
        canTerminateResult
    }

    func terminate(
        pid: pid_t,
        name: String,
        signal: TerminationSignal
    ) -> Result<TerminationOutcome, TerminationError> {
        lastTerminate = (pid, name, signal)
        return terminateResult
    }
}

private final class RecordingPasteboardWriter: PasteboardWriting {
    private(set) var strings: [String] = []
    private(set) var clearCount = 0

    func clearContents() {
        clearCount += 1
    }

    @discardableResult
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool {
        strings.append(string)
        return true
    }

    @discardableResult
    func setData(_ data: Data, forType type: NSPasteboard.PasteboardType) -> Bool { true }

    @discardableResult
    func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool { true }
}

// MARK: - Helpers

private func makeEntry(
    proto: PortEntry.Proto = .tcp,
    localIP: String = "127.0.0.1",
    localPort: Int,
    state: String? = "LISTEN",
    pid: pid_t,
    command: String
) -> PortEntry {
    PortEntry(
        proto: proto,
        localIP: localIP,
        localPort: localPort,
        remoteIP: nil,
        remotePort: nil,
        state: state,
        pid: pid,
        command: command
    )
}

// MARK: - Tests

@MainActor
final class NetworkDiagnosticsServiceTests: XCTestCase {

    private var identity: FakeIdentityProvider!
    private var publicIP: FakePublicIPFetcher!
    private var probe: FakePortProbe!
    private var names: FakeNameResolver!
    private var terminator: FakeTerminator!
    private var writer: RecordingPasteboardWriter!
    private var service: NetworkDiagnosticsService!

    override func setUp() {
        super.setUp()
        identity = FakeIdentityProvider()
        publicIP = FakePublicIPFetcher()
        probe = FakePortProbe()
        names = FakeNameResolver()
        terminator = FakeTerminator()
        writer = RecordingPasteboardWriter()
        service = NetworkDiagnosticsService(
            identityProvider: identity,
            publicIPFetcher: publicIP,
            portProbe: probe,
            nameResolver: names,
            terminator: terminator,
            writer: writer,
            // Sync fakes: run collectors immediately so tests need no extra wait for probe path.
            blockingRunner: NetworkDiagnosticsService.immediateBlockingRunner
        )
    }

    /// Wait until a refresh flag clears (covers both sync and async runners).
    private func waitUntilRefreshSettled(
        network: Bool = false,
        ports: Bool = false,
        timeout: TimeInterval = 1
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let networkDone = !network || !service.isRefreshingNetwork
            let portsDone = !ports || !service.isRefreshingPorts
            if networkDone && portsDone { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: refreshNetwork

    func test_refreshNetwork_setsIdentityAndLoadsPublicIP() async {
        publicIP.ipv4 = "203.0.113.10"
        publicIP.ipv6 = "2001:db8::9"

        service.refreshNetwork()
        await waitUntilRefreshSettled(network: true)

        XCTAssertEqual(identity.callCount, 1)
        XCTAssertEqual(service.networkIdentity?.hostname, "test-host")

        // 等待异步公网 IP 完成
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if case .resolved = service.publicIPState { break }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(service.publicIPState, .resolved(ipv4: "203.0.113.10", ipv6: "2001:db8::9"))
        XCTAssertEqual(service.networkIdentity?.publicIPv4, "203.0.113.10")
        XCTAssertEqual(service.networkIdentity?.publicIPv6, "2001:db8::9")
        XCTAssertEqual(publicIP.ipv4Calls, 1)
        XCTAssertEqual(publicIP.ipv6Calls, 1)
    }

    func test_refreshNetwork_publicIPFailureKeepsNil() async {
        publicIP.ipv4 = nil
        publicIP.ipv6 = nil

        service.refreshNetwork()

        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if case .resolved = service.publicIPState { break }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(service.publicIPState, .resolved(ipv4: nil, ipv6: nil))
        XCTAssertNil(service.networkIdentity?.publicIPv4)
        XCTAssertNil(service.networkIdentity?.publicIPv6)
    }

    func test_refreshNetwork_stalePublicIPIgnored() async {
        publicIP.delayNanoseconds = 30_000_000
        publicIP.ipv4 = "1.1.1.1"

        service.refreshNetwork()
        publicIP.ipv4 = "2.2.2.2"
        publicIP.delayNanoseconds = 0
        service.refreshNetwork()

        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if case let .resolved(v4, _) = service.publicIPState, v4 == "2.2.2.2" {
                break
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(service.publicIPState, .resolved(ipv4: "2.2.2.2", ipv6: nil))
        // 第二次刷新后不应被第一次慢结果覆盖
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(service.publicIPState, .resolved(ipv4: "2.2.2.2", ipv6: nil))
    }

    // MARK: refreshPorts

    func test_refreshPorts_successResolvesNamesAndHintNone() async {
        let entries = [
            makeEntry(localPort: 3000, pid: 111, command: "node"),
            makeEntry(localPort: 8080, state: "ESTABLISHED", pid: 222, command: "Docker"),
        ]
        probe.result = .success(entries)
        names.names = [111: "Node.js", 222: "Docker Desktop"]

        service.refreshPorts()
        await waitUntilRefreshSettled(ports: true)

        XCTAssertEqual(probe.callCount, 1)
        XCTAssertEqual(service.ports.count, 2)
        XCTAssertEqual(service.processDisplayName(for: entries[0]), "Node.js")
        XCTAssertEqual(service.permissionHint, .none)
    }

    func test_refreshPorts_partialPermissionWhenPIDMissing() async {
        probe.result = .success([
            makeEntry(localPort: 80, pid: 0, command: ""),
            makeEntry(localPort: 443, pid: 99, command: "nginx"),
        ])

        service.refreshPorts()
        await waitUntilRefreshSettled(ports: true)

        XCTAssertEqual(service.permissionHint, .partialPermission)
        XCTAssertEqual(service.ports.count, 2)
    }

    func test_refreshPorts_loadFailureClearsList() async {
        probe.result = .failure(PortProbeError.lsofMissing)

        service.refreshPorts()
        await waitUntilRefreshSettled(ports: true)

        XCTAssertTrue(service.ports.isEmpty)
        XCTAssertEqual(service.permissionHint, .loadFailure)
        XCTAssertTrue(service.processDisplayNames.isEmpty)
    }

    // MARK: filteredPorts

    func test_filteredPorts_scopeListenOnly() async {
        probe.result = .success([
            makeEntry(localPort: 3000, state: "LISTEN", pid: 1, command: "node"),
            makeEntry(localPort: 3001, state: "ESTABLISHED", pid: 2, command: "node"),
            makeEntry(proto: .udp, localPort: 53, state: nil, pid: 3, command: "mDNSResponder"),
        ])
        service.refreshPorts()
        await waitUntilRefreshSettled(ports: true)

        service.portScope = .listen
        XCTAssertEqual(service.filteredPorts.map(\.localPort), [3000])

        service.portScope = .all
        XCTAssertEqual(service.filteredPorts.map(\.localPort), [3000, 3001, 53])
    }

    func test_filteredPorts_searchByPortAndProcessName() async {
        let a = makeEntry(localPort: 3000, pid: 10, command: "node")
        let b = makeEntry(localPort: 8080, pid: 20, command: "java")
        probe.result = .success([a, b])
        names.names = [10: "Node.js", 20: "IntelliJ IDEA"]
        service.refreshPorts()
        await waitUntilRefreshSettled(ports: true)
        service.portScope = .all

        service.searchText = "3000"
        XCTAssertEqual(service.filteredPorts.map(\.localPort), [3000])

        service.searchText = "idea"
        XCTAssertEqual(service.filteredPorts.map(\.localPort), [8080])

        service.searchText = "node"
        XCTAssertEqual(service.filteredPorts.map(\.localPort), [3000])

        service.searchText = "  "
        XCTAssertEqual(service.filteredPorts.count, 2)
    }

    // MARK: scopedPorts（hero 统计：按 scope 过滤、不受搜索影响）

    func test_scopedPorts_scopeFiltersOnly() async {
        probe.result = .success([
            makeEntry(localPort: 3000, state: "LISTEN", pid: 1, command: "node"),
            makeEntry(localPort: 3001, state: "ESTABLISHED", pid: 2, command: "node"),
            makeEntry(proto: .udp, localPort: 53, state: nil, pid: 3, command: "mDNSResponder"),
        ])
        service.refreshPorts()
        await waitUntilRefreshSettled(ports: true)

        service.portScope = .listen
        XCTAssertEqual(service.scopedPorts.map(\.localPort), [3000])

        service.portScope = .all
        XCTAssertEqual(service.scopedPorts.map(\.localPort), [3000, 3001, 53])
    }

    func test_scopedPorts_ignoresSearchText() async {
        probe.result = .success([
            makeEntry(localPort: 3000, pid: 10, command: "node"),
            makeEntry(localPort: 8080, pid: 20, command: "java"),
        ])
        service.refreshPorts()
        await waitUntilRefreshSettled(ports: true)
        service.portScope = .all

        service.searchText = "3000"
        // 列表只剩 3000，但 hero 统计仍是全量 2 条。
        XCTAssertEqual(service.filteredPorts.map(\.localPort), [3000])
        XCTAssertEqual(service.scopedPorts.count, 2)
    }

    func test_filteredPorts_matchesScopedPortsWhenSearchEmpty() async {
        probe.result = .success([
            makeEntry(localPort: 3000, state: "LISTEN", pid: 1, command: "node"),
            makeEntry(localPort: 3001, state: "ESTABLISHED", pid: 2, command: "node"),
        ])
        service.refreshPorts()
        await waitUntilRefreshSettled(ports: true)

        service.portScope = .listen
        service.searchText = ""
        XCTAssertEqual(service.filteredPorts, service.scopedPorts)

        service.searchText = "   "
        XCTAssertEqual(service.filteredPorts, service.scopedPorts)
    }

    // MARK: terminate / copy

    func test_terminate_delegatesToTerminatorWithDisplayName() async {
        let entry = makeEntry(localPort: 3000, pid: 555, command: "node")
        probe.result = .success([entry])
        names.names = [555: "Node.js"]
        service.refreshPorts()
        await waitUntilRefreshSettled(ports: true)

        terminator.terminateResult = .success(.signalSent(.kill))
        let result = service.terminate(entry, signal: .kill)

        XCTAssertEqual(result, .success(.signalSent(.kill)))
        XCTAssertEqual(terminator.lastTerminate?.pid, 555)
        XCTAssertEqual(terminator.lastTerminate?.name, "Node.js")
        XCTAssertEqual(terminator.lastTerminate?.signal, .kill)
    }

    func test_copy_writesToPasteboard() {
        service.copy("sudo kill 123")
        XCTAssertEqual(writer.clearCount, 1)
        XCTAssertEqual(writer.strings, ["sudo kill 123"])
    }

    // MARK: computePermissionHint pure

    func test_computePermissionHint_emptyIsNone() {
        XCTAssertEqual(NetworkDiagnosticsService.computePermissionHint(from: []), .none)
    }

    func test_computePermissionHint_incompletePID() {
        let entries = [makeEntry(localPort: 1, pid: 0, command: "x")]
        XCTAssertEqual(
            NetworkDiagnosticsService.computePermissionHint(from: entries),
            .partialPermission
        )
    }
}
