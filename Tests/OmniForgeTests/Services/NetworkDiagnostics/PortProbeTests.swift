import XCTest
@testable import OmniForge

final class PortProbeTests: XCTestCase {

    // MARK: - Sample fixtures

    private let sampleStdout = """
    COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
    node       4321 seam   23u  IPv4 0xabc              0t0  TCP *:3000 (LISTEN)
    Docker      987 seam   10u  IPv4 0xdef              0t0  TCP 127.0.0.1:8080 (LISTEN)
    VivoConnS   550 seam   99u  IPv4 0x111              0t0  TCP 127.0.0.1:9197->127.0.0.1:52616 (ESTABLISHED)
    sharingd    508 seam    4u  IPv4 0x222              0t0  UDP *:5353
    VivoConnS   550 seam   16u  IPv6 0x333              0t0  TCP *:10191 (LISTEN)
    ZCode\\x20H  7580 seam   21u  IPv6 0x444              0t0  TCP [fdfe:dcba:9876::1]:49995->[fdfe:dcba:9876::13]:443 (ESTABLISHED)
    WeChat    14299 seam  302u  IPv6 0x555              0t0  TCP [fdfe:dcba:9876::1]:61141->[2409:8c20:818:3002::c]:80 (CLOSE_WAIT)
    identitys   485 seam   19u  IPv4 0x666              0t0  UDP *:*
    VivoConnS   550 seam    4u  IPv4 0x777              0t0  UDP 127.0.0.1:55678->127.0.0.1:9997
    """

    // MARK: - LISTEN / ESTABLISHED / UDP / IPv6

    func test_parse_listenTCP() {
        let entries = PortProbe.parse(stdout: sampleStdout)
        let node = entries.first { $0.localPort == 3000 && $0.state == "LISTEN" }
        XCTAssertNotNil(node)
        XCTAssertEqual(node?.proto, .tcp)
        XCTAssertEqual(node?.localIP, "*")
        XCTAssertEqual(node?.pid, 4321)
        XCTAssertEqual(node?.command, "node")
        XCTAssertNil(node?.remoteIP)
    }

    func test_parse_establishedTCP() {
        let entries = PortProbe.parse(stdout: sampleStdout)
        let est = entries.first { $0.state == "ESTABLISHED" && $0.localPort == 9197 }
        XCTAssertNotNil(est)
        XCTAssertEqual(est?.proto, .tcp)
        XCTAssertEqual(est?.localIP, "127.0.0.1")
        XCTAssertEqual(est?.remoteIP, "127.0.0.1")
        XCTAssertEqual(est?.remotePort, 52616)
    }

    func test_parse_udpWithoutState() {
        let entries = PortProbe.parse(stdout: sampleStdout)
        let udp = entries.first { $0.proto == .udp && $0.localPort == 5353 }
        XCTAssertNotNil(udp)
        XCTAssertNil(udp?.state)
        XCTAssertEqual(udp?.command, "sharingd")
    }

    func test_parse_udpWildcardPort() {
        let entries = PortProbe.parse(stdout: sampleStdout)
        let any = entries.first { $0.command == "identitys" && $0.proto == .udp }
        XCTAssertNotNil(any)
        XCTAssertEqual(any?.localIP, "*")
        XCTAssertEqual(any?.localPort, 0)
        XCTAssertNil(any?.state)
    }

    func test_parse_udpConnected() {
        let entries = PortProbe.parse(stdout: sampleStdout)
        let conn = entries.first { $0.proto == .udp && $0.localPort == 55678 }
        XCTAssertNotNil(conn)
        XCTAssertEqual(conn?.remoteIP, "127.0.0.1")
        XCTAssertEqual(conn?.remotePort, 9997)
        XCTAssertNil(conn?.state)
    }

    func test_parse_ipv6ListenAsTCP6() {
        let entries = PortProbe.parse(stdout: sampleStdout)
        let v6 = entries.first { $0.localPort == 10191 && $0.proto == .tcp6 }
        XCTAssertNotNil(v6)
        XCTAssertEqual(v6?.state, "LISTEN")
        XCTAssertEqual(v6?.localIP, "*")
    }

    func test_parse_ipv6EstablishedWithBrackets() {
        let entries = PortProbe.parse(stdout: sampleStdout)
        let v6 = entries.first { $0.localPort == 49995 && $0.proto == .tcp6 }
        XCTAssertNotNil(v6)
        XCTAssertEqual(v6?.localIP, "fdfe:dcba:9876::1")
        XCTAssertEqual(v6?.remoteIP, "fdfe:dcba:9876::13")
        XCTAssertEqual(v6?.remotePort, 443)
        XCTAssertEqual(v6?.state, "ESTABLISHED")
        // COMMAND 中 \\x20 还原为空格
        XCTAssertEqual(v6?.command, "ZCode H")
    }

    func test_parse_closeWaitState() {
        let entries = PortProbe.parse(stdout: sampleStdout)
        let cw = entries.first { $0.state == "CLOSE_WAIT" }
        XCTAssertNotNil(cw)
        XCTAssertEqual(cw?.proto, .tcp6)
        XCTAssertEqual(cw?.localPort, 61141)
    }

    // MARK: - Malformed / header

    func test_parse_skipsHeaderAndMalformedLines() {
        let stdout = """
        COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        not-a-valid-line
        node
        node       abc seam   23u  IPv4 0xabc              0t0  TCP *:3000 (LISTEN)
        node       100 seam   23u  IPv4 0xabc              0t0  TCP
        node       101 seam   23u  IPv4 0xabc              0t0  TCP *:3000 (LISTEN)
        """
        let entries = PortProbe.parse(stdout: stdout)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].pid, 101)
        XCTAssertEqual(entries[0].localPort, 3000)
    }

    func test_parse_emptyStdout() {
        XCTAssertEqual(PortProbe.parse(stdout: ""), [])
        XCTAssertEqual(PortProbe.parse(stdout: "\n\n"), [])
    }

    func test_parseLine_dockerListen() {
        let line = "Docker      987 seam   10u  IPv4 0xdef              0t0  TCP 127.0.0.1:8080 (LISTEN)"
        let entry = PortProbe.parseLine(line)
        XCTAssertEqual(entry?.command, "Docker")
        XCTAssertEqual(entry?.pid, 987)
        XCTAssertEqual(entry?.localIP, "127.0.0.1")
        XCTAssertEqual(entry?.localPort, 8080)
        XCTAssertEqual(entry?.state, "LISTEN")
        XCTAssertEqual(entry?.proto, .tcp)
    }

    // MARK: - probe() with injected runner

    func test_probe_parsesRunnerStdout() throws {
        let sample = sampleStdout
        let probe = PortProbe { _ in
            (stdout: sample, exitCode: 0, stderr: "")
        }
        let entries = try probe.probe()
        XCTAssertGreaterThanOrEqual(entries.count, 8)
        XCTAssertTrue(entries.contains { $0.localPort == 3000 && $0.state == "LISTEN" })
    }

    func test_probe_exitCode1EmptyStdoutReturnsEmpty() throws {
        let probe = PortProbe { _ in
            (stdout: "", exitCode: 1, stderr: "")
        }
        let entries = try probe.probe()
        XCTAssertEqual(entries, [])
    }

    func test_probe_nonzeroWithoutOutputThrows() {
        let probe = PortProbe { _ in
            (stdout: "", exitCode: 127, stderr: "lsof: not found")
        }
        XCTAssertThrowsError(try probe.probe()) { error in
            guard let probeError = error as? PortProbeError,
                  case .lsofFailed(let code, let stderr) = probeError
            else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(code, 127)
            XCTAssertTrue(stderr.contains("lsof"))
        }
    }

    func test_hostPortCopyText_ipv6() {
        let entry = PortEntry(
            proto: .tcp6,
            localIP: "fdfe:dcba:9876::1",
            localPort: 443,
            remoteIP: nil,
            remotePort: nil,
            state: "LISTEN",
            pid: 1,
            command: "x"
        )
        XCTAssertEqual(entry.hostPortCopyText, "[fdfe:dcba:9876::1]:443")
    }
}
