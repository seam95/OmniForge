import XCTest
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
}
