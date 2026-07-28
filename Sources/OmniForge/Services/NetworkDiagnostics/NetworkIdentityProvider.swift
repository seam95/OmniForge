import Foundation
import SystemConfiguration
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Value types

struct NetworkInterface: Equatable {
    let name: String
    let ipv4: String?
    let ipv6: String?
    let mac: String?
}

struct DefaultRoute: Equatable {
    let gateway: String?
    let interface: String?

    /// 复制文案：`网关 if 接口`；缺一则只输出有值的部分。
    var copyText: String {
        switch (gateway, interface) {
        case let (g?, i?): return "\(g) if \(i)"
        case let (g?, nil): return g
        case let (nil, i?): return "if \(i)"
        case (nil, nil): return ""
        }
    }
}

struct NetworkIdentity: Equatable {
    let hostname: String
    let interfaces: [NetworkInterface]
    let defaultRoute: DefaultRoute
    let dnsServers: [String]
    let publicIPv4: String?
    let publicIPv6: String?
}

// MARK: - Sample types for pure parsing / tests

enum InterfaceAddressFamily: Equatable {
    case ipv4
    case ipv6
    case link
}

/// getifaddrs 的可测试中间表示（name + family + 文本地址）。
struct InterfaceAddressSample: Equatable {
    let name: String
    let family: InterfaceAddressFamily
    let address: String
}

// MARK: - Protocol

protocol NetworkIdentityProviding {
    /// 采集本机网络身份；公网 IP 由调用方（PublicIPFetcher）异步填入。
    func makeIdentity(publicIPv4: String?, publicIPv6: String?) -> NetworkIdentity
}

// MARK: - Production provider

final class NetworkIdentityProvider: NetworkIdentityProviding {
    private let hostnameProvider: () -> String
    private let interfaceSamplesProvider: () -> [InterfaceAddressSample]
    private let ipv4GlobalProvider: () -> [String: Any]?
    private let dnsGlobalProvider: () -> [String: Any]?
    private let scutilDNSProvider: () -> String?

    init(
        hostnameProvider: @escaping () -> String = NetworkIdentityProvider.resolveHostname,
        interfaceSamplesProvider: @escaping () -> [InterfaceAddressSample] = NetworkIdentityProvider.liveInterfaceSamples,
        ipv4GlobalProvider: @escaping () -> [String: Any]? = {
            NetworkIdentityProvider.copyDynamicStoreDictionary(key: "State:/Network/Global/IPv4")
        },
        dnsGlobalProvider: @escaping () -> [String: Any]? = {
            NetworkIdentityProvider.copyDynamicStoreDictionary(key: "State:/Network/Global/DNS")
        },
        scutilDNSProvider: @escaping () -> String? = NetworkIdentityProvider.runScutilDNS
    ) {
        self.hostnameProvider = hostnameProvider
        self.interfaceSamplesProvider = interfaceSamplesProvider
        self.ipv4GlobalProvider = ipv4GlobalProvider
        self.dnsGlobalProvider = dnsGlobalProvider
        self.scutilDNSProvider = scutilDNSProvider
    }

    func makeIdentity(publicIPv4: String? = nil, publicIPv6: String? = nil) -> NetworkIdentity {
        let interfaces = Self.parseInterfaces(from: interfaceSamplesProvider())
        let parsed = Self.parseDynamicStore(
            ipv4Global: ipv4GlobalProvider(),
            dnsGlobal: dnsGlobalProvider(),
            scutilDNSFallback: scutilDNSProvider
        )
        return NetworkIdentity(
            hostname: hostnameProvider(),
            interfaces: interfaces,
            defaultRoute: parsed.defaultRoute,
            dnsServers: parsed.dnsServers,
            publicIPv4: publicIPv4,
            publicIPv6: publicIPv6
        )
    }

    // MARK: Pure parse — interfaces

    /// 按接口名聚合 IPv4 / IPv6 / MAC；过滤 loopback（lo / lo0）；MAC 仅保留 en*。
    static func parseInterfaces(from samples: [InterfaceAddressSample]) -> [NetworkInterface] {
        var order: [String] = []
        var ipv4ByName: [String: String] = [:]
        var ipv6ByName: [String: String] = [:]
        var macByName: [String: String] = [:]

        for sample in samples {
            let name = sample.name
            guard !name.isEmpty, !isLoopbackInterface(name) else { continue }
            if !order.contains(name) {
                order.append(name)
            }
            switch sample.family {
            case .ipv4:
                if ipv4ByName[name] == nil {
                    ipv4ByName[name] = sample.address
                }
            case .ipv6:
                // 跳过 link-local 以外的重复时保留首个；fe80:: 也展示（局域网排查有用）
                if ipv6ByName[name] == nil {
                    ipv6ByName[name] = sample.address
                }
            case .link:
                guard name.hasPrefix("en") else { continue }
                if macByName[name] == nil {
                    macByName[name] = sample.address
                }
            }
        }

        return order.compactMap { name in
            let ipv4 = ipv4ByName[name]
            let ipv6 = ipv6ByName[name]
            let mac = macByName[name]
            // 无任何地址信息的接口丢弃
            guard ipv4 != nil || ipv6 != nil || mac != nil else { return nil }
            return NetworkInterface(name: name, ipv4: ipv4, ipv6: ipv6, mac: mac)
        }
    }

    static func isLoopbackInterface(_ name: String) -> Bool {
        name == "lo0" || name == "lo" || name.hasPrefix("lo")
    }

    // MARK: Pure parse — SCDynamicStore + scutil fallback

    static func parseDynamicStore(
        ipv4Global: [String: Any]?,
        dnsGlobal: [String: Any]?,
        scutilDNSFallback: (() -> String?)? = nil
    ) -> (defaultRoute: DefaultRoute, dnsServers: [String]) {
        let gateway = stringValue(ipv4Global?["Router"])
        let interface = stringValue(ipv4Global?["PrimaryInterface"])
        let route = DefaultRoute(gateway: gateway, interface: interface)

        var dns = parseDNSServerAddresses(dnsGlobal?["ServerAddresses"])
        if dns.isEmpty, let fallback = scutilDNSFallback?() {
            dns = parseScutilDNS(fallback)
        }
        return (route, dns)
    }

    /// 解析 `scutil --dns` 文本中的 nameserver 行。
    static func parseScutilDNS(_ text: String) -> [String] {
        var servers: [String] = []
        var seen = Set<String>()
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // nameserver[0] : 8.8.8.8
            guard let colon = line.range(of: ":") else { continue }
            let key = line[..<colon.lowerBound].trimmingCharacters(in: .whitespaces).lowercased()
            guard key.hasPrefix("nameserver") else { continue }
            let value = line[colon.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, !seen.contains(value) else { continue }
            seen.insert(value)
            servers.append(value)
        }
        return servers
    }

    // MARK: Live collectors

    static func resolveHostname() -> String {
        if let localized = Host.current().localizedName, !localized.isEmpty {
            return localized
        }
        if let name = Host.current().name, !name.isEmpty {
            return name
        }
        let processHost = ProcessInfo.processInfo.hostName
        return processHost.isEmpty ? "—" : processHost
    }

    static func liveInterfaceSamples() -> [InterfaceAddressSample] {
        var samples: [InterfaceAddressSample] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else {
            return []
        }
        defer { freeifaddrs(ifaddrPtr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            let iface = ptr.pointee
            defer { cursor = iface.ifa_next }
            guard let addr = iface.ifa_addr else { continue }
            let name = String(cString: iface.ifa_name)
            let family = Int32(addr.pointee.sa_family)

            switch family {
            case AF_INET:
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    addr,
                    socklen_t(addr.pointee.sa_len),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if result == 0 {
                    samples.append(InterfaceAddressSample(
                        name: name,
                        family: .ipv4,
                        address: String(cString: hostname)
                    ))
                }
            case AF_INET6:
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    addr,
                    socklen_t(addr.pointee.sa_len),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if result == 0 {
                    // 去掉 %en0 等 zone id 后缀
                    let raw = String(cString: hostname)
                    let cleaned = raw.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: true)
                        .first
                        .map(String.init) ?? raw
                    samples.append(InterfaceAddressSample(
                        name: name,
                        family: .ipv6,
                        address: cleaned
                    ))
                }
            case AF_LINK:
                if let mac = macString(from: addr) {
                    samples.append(InterfaceAddressSample(
                        name: name,
                        family: .link,
                        address: mac
                    ))
                }
            default:
                continue
            }
        }
        return samples
    }

    private static func macString(from addr: UnsafePointer<sockaddr>) -> String? {
        addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { sdl in
            let link = sdl.pointee
            let macLen = Int(link.sdl_alen)
            guard macLen == 6 else { return nil }
            let offset = Int(link.sdl_nlen)
            return withUnsafePointer(to: link.sdl_data) { dataPtr in
                dataPtr.withMemoryRebound(to: UInt8.self, capacity: offset + macLen) { bytes in
                    let macBytes = (0..<macLen).map { bytes[offset + $0] }
                    return macBytes.map { String(format: "%02x", $0) }.joined(separator: ":")
                }
            }
        }
    }

    static func copyDynamicStoreDictionary(key: String) -> [String: Any]? {
        guard let store = SCDynamicStoreCreate(nil, "OmniForge.NetworkDiagnostics" as CFString, nil, nil) else {
            return nil
        }
        guard let value = SCDynamicStoreCopyValue(store, key as CFString) else {
            return nil
        }
        return value as? [String: Any]
    }

    static func runScutilDNS() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        process.arguments = ["--dns"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    // MARK: Helpers

    private static func stringValue(_ any: Any?) -> String? {
        switch any {
        case let s as String:
            return s.isEmpty ? nil : s
        case let n as NSNumber:
            return n.stringValue
        default:
            return nil
        }
    }

    private static func parseDNSServerAddresses(_ any: Any?) -> [String] {
        if let strings = any as? [String] {
            return strings.filter { !$0.isEmpty }
        }
        if let nsArray = any as? [Any] {
            return nsArray.compactMap { stringValue($0) }
        }
        return []
    }
}
