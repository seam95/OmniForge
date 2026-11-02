import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import OmniForge

final class NetworkIdentityProviderTests: XCTestCase {

    // MARK: - parseInterfaces: loopback filter & aggregation

    func test_parseInterfaces_filtersLoopback() {
        let samples: [InterfaceAddressSample] = [
            .init(name: "lo0", family: .ipv4, address: "127.0.0.1"),
            .init(name: "lo0", family: .ipv6, address: "::1"),
            .init(name: "en0", family: .ipv4, address: "192.168.1.10"),
        ]
        let result = NetworkIdentityProvider.parseInterfaces(from: samples)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "en0")
        XCTAssertEqual(result[0].ipv4, "192.168.1.10")
        XCTAssertNil(result.first(where: { $0.name.hasPrefix("lo") }))
    }

    func test_parseInterfaces_aggregatesIPv4IPv6AndMACForEn() {
        let samples: [InterfaceAddressSample] = [
            .init(name: "en0", family: .ipv4, address: "10.0.0.5"),
            .init(name: "en0", family: .ipv6, address: "fe80::1"),
            .init(name: "en0", family: .link, address: "aa:bb:cc:dd:ee:ff"),
            .init(name: "utun0", family: .ipv4, address: "10.8.0.2"),
            .init(name: "utun0", family: .link, address: "11:22:33:44:55:66"),
        ]
        let result = NetworkIdentityProvider.parseInterfaces(from: samples)
        XCTAssertEqual(result.count, 2)

        let en0 = result.first { $0.name == "en0" }
        XCTAssertEqual(en0?.ipv4, "10.0.0.5")
        XCTAssertEqual(en0?.ipv6, "fe80::1")
        XCTAssertEqual(en0?.mac, "aa:bb:cc:dd:ee:ff")

        // 非 en* 不取 MAC
        let utun = result.first { $0.name == "utun0" }
        XCTAssertEqual(utun?.ipv4, "10.8.0.2")
        XCTAssertNil(utun?.mac)
    }

    func test_parseInterfaces_keepsFirstAddressPerFamily() {
        let samples: [InterfaceAddressSample] = [
            .init(name: "en0", family: .ipv4, address: "192.168.0.2"),
            .init(name: "en0", family: .ipv4, address: "192.168.0.3"),
        ]
        let result = NetworkIdentityProvider.parseInterfaces(from: samples)
        XCTAssertEqual(result.first?.ipv4, "192.168.0.2")
    }

    func test_parseInterfaces_preservesDiscoveryOrder() {
        let samples: [InterfaceAddressSample] = [
            .init(name: "en1", family: .ipv4, address: "1.1.1.1"),
            .init(name: "en0", family: .ipv4, address: "2.2.2.2"),
        ]
        let names = NetworkIdentityProvider.parseInterfaces(from: samples).map(\.name)
        XCTAssertEqual(names, ["en1", "en0"])
    }

    // MARK: - parseDynamicStore

    func test_parseDynamicStore_readsRouterAndDNS() {
        let ipv4: [String: Any] = [
            "Router": "192.168.1.1",
            "PrimaryInterface": "en0",
        ]
        let dns: [String: Any] = [
            "ServerAddresses": ["8.8.8.8", "1.1.1.1"],
        ]
        let parsed = NetworkIdentityProvider.parseDynamicStore(
            ipv4Global: ipv4,
            dnsGlobal: dns,
            scutilDNSFallback: nil
        )
        XCTAssertEqual(parsed.defaultRoute.gateway, "192.168.1.1")
        XCTAssertEqual(parsed.defaultRoute.interface, "en0")
        XCTAssertEqual(parsed.defaultRoute.copyText, "192.168.1.1 if en0")
        XCTAssertEqual(parsed.dnsServers, ["8.8.8.8", "1.1.1.1"])
    }

    func test_parseDynamicStore_missingKeys_emptyRouteAndDNS() {
        let parsed = NetworkIdentityProvider.parseDynamicStore(
            ipv4Global: nil,
            dnsGlobal: nil,
            scutilDNSFallback: nil
        )
        XCTAssertNil(parsed.defaultRoute.gateway)
        XCTAssertNil(parsed.defaultRoute.interface)
        XCTAssertTrue(parsed.dnsServers.isEmpty)
    }

    func test_parseDynamicStore_fallsBackToScutilWhenDNSMissing() {
        let scutil = """
        DNS configuration

        resolver #1
          nameserver[0] : 9.9.9.9
          nameserver[1] : 149.112.112.112
          if_index : 14 (en0)
          flags    : Request A records
          reach    : 0x00000002 (Reachable)

        resolver #2
          domain   : local
          nameserver[0] : 9.9.9.9
        """
        var fallbackCalled = false
        let parsed = NetworkIdentityProvider.parseDynamicStore(
            ipv4Global: ["Router": "10.0.0.1", "PrimaryInterface": "en0"],
            dnsGlobal: [:],
            scutilDNSFallback: {
                fallbackCalled = true
                return scutil
            }
        )
        XCTAssertTrue(fallbackCalled)
        XCTAssertEqual(parsed.dnsServers, ["9.9.9.9", "149.112.112.112"])
        XCTAssertEqual(parsed.defaultRoute.gateway, "10.0.0.1")
    }

    func test_parseDynamicStore_doesNotCallFallbackWhenDNSPresent() {
        var fallbackCalled = false
        let parsed = NetworkIdentityProvider.parseDynamicStore(
            ipv4Global: nil,
            dnsGlobal: ["ServerAddresses": ["8.8.4.4"]],
            scutilDNSFallback: {
                fallbackCalled = true
                return "nameserver[0] : 1.2.3.4"
            }
        )
        XCTAssertFalse(fallbackCalled)
        XCTAssertEqual(parsed.dnsServers, ["8.8.4.4"])
    }

    func test_parseScutilDNS_dedupesAndIgnoresNoise() {
        let text = """
        nameserver[0] : 1.1.1.1
        reach    : 0x00000002
        nameserver[1] : 1.0.0.1
        nameserver[0] : 1.1.1.1
        """
        XCTAssertEqual(
            NetworkIdentityProvider.parseScutilDNS(text),
            ["1.1.1.1", "1.0.0.1"]
        )
    }

    // MARK: - makeIdentity injection

    func test_makeIdentity_usesInjectedProviders() {
        let provider = NetworkIdentityProvider(
            hostnameProvider: { "Test-Mac" },
            interfaceSamplesProvider: {
                [
                    .init(name: "lo0", family: .ipv4, address: "127.0.0.1"),
                    .init(name: "en0", family: .ipv4, address: "192.168.1.20"),
                    .init(name: "en0", family: .link, address: "de:ad:be:ef:00:01"),
                ]
            },
            ipv4GlobalProvider: {
                ["Router": "192.168.1.1", "PrimaryInterface": "en0"]
            },
            dnsGlobalProvider: {
                ["ServerAddresses": ["8.8.8.8"]]
            },
            scutilDNSProvider: { XCTFail("should not fallback"); return nil }
        )

        let identity = provider.makeIdentity(publicIPv4: "203.0.113.1", publicIPv6: nil)
        XCTAssertEqual(identity.hostname, "Test-Mac")
        XCTAssertEqual(identity.interfaces.map(\.name), ["en0"])
        XCTAssertEqual(identity.interfaces.first?.mac, "de:ad:be:ef:00:01")
        XCTAssertEqual(identity.defaultRoute.gateway, "192.168.1.1")
        XCTAssertEqual(identity.dnsServers, ["8.8.8.8"])
        XCTAssertEqual(identity.publicIPv4, "203.0.113.1")
        XCTAssertNil(identity.publicIPv6)
    }

    func test_makeIdentity_dnsFallbackWhenGlobalEmpty() {
        let provider = NetworkIdentityProvider(
            hostnameProvider: { "Host" },
            interfaceSamplesProvider: { [] },
            ipv4GlobalProvider: { nil },
            dnsGlobalProvider: { nil },
            scutilDNSProvider: { "nameserver[0] : 208.67.222.222" }
        )
        let identity = provider.makeIdentity()
        XCTAssertEqual(identity.dnsServers, ["208.67.222.222"])
        XCTAssertTrue(identity.interfaces.isEmpty)
    }

    // MARK: - macString: sockaddr_dl 变长结构

    /// 构造 AF_LINK 的 sockaddr_dl 原始字节缓冲：8 字节固定头部 + 接口名数据 + MAC。
    /// sockaddr_dl 是变长结构，sdl_data 名义 12 字节只是最小工作区，实际长度由 sdl_len 决定。
    private func makeLinkLayerBuffer(nameBytes: [UInt8], mac: [UInt8]) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 8 + nameBytes.count + mac.count)
        buffer[0] = UInt8(buffer.count) // sdl_len = 总长度
        buffer[1] = UInt8(AF_LINK) // sdl_family
        // 偏移 2..<4 为 sdl_index，保持 0
        buffer[4] = 6 // sdl_type = IFT_ETHER
        buffer[5] = UInt8(nameBytes.count) // sdl_nlen = 接口名数据长度
        buffer[6] = UInt8(mac.count) // sdl_alen = 链路层地址长度
        buffer[7] = 0 // sdl_slen
        buffer.replaceSubrange(8..<(8 + nameBytes.count), with: nameBytes)
        buffer.replaceSubrange((8 + nameBytes.count)..., with: mac)
        return buffer
    }

    private func macStringFromBuffer(_ buffer: [UInt8]) -> String? {
        buffer.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            return NetworkIdentityProvider.macString(
                from: base.assumingMemoryBound(to: sockaddr.self)
            )
        }
    }

    func test_macString_longInterfaceNameReadsMACFromOriginalBuffer() {
        // nlen=15："bridge100"（9 字符）+ 6 字节额外长度字段；MAC 位于 8+15=23 偏移。
        // 旧实现把 sockaddr_dl 拷贝到固定 20 字节栈变量后按 8+nlen 偏移读，
        // nlen>6 即读到栈拷贝之外的垃圾；新实现应直接从原缓冲区读取。
        let nameBytes = Array("bridge100".utf8) + [UInt8](repeating: 0xAB, count: 6)
        let mac: [UInt8] = [0xde, 0xad, 0xbe, 0xef, 0x12, 0x34]
        let result = macStringFromBuffer(makeLinkLayerBuffer(nameBytes: nameBytes, mac: mac))
        XCTAssertEqual(result, "de:ad:be:ef:12:34")
    }

    func test_macString_regularInterfaceNameStillParses() {
        // nlen=3（"en0"）常规路径回归：确保改为直读原缓冲区后原有解析不受影响。
        let mac: [UInt8] = [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]
        let result = macStringFromBuffer(makeLinkLayerBuffer(nameBytes: Array("en0".utf8), mac: mac))
        XCTAssertEqual(result, "aa:bb:cc:dd:ee:ff")
    }
}
