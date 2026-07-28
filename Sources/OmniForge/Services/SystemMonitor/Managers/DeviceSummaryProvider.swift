import Foundation

struct DeviceSummary: Equatable {
    var hostName: String
    var osVersionText: String?
    var uptimeText: String?
}

struct DeviceSummaryProvider {
    var hostNameProvider: () -> String?
    var osVersionProvider: () -> OperatingSystemVersion
    var bootDateProvider: () -> Date?

    init(
        hostNameProvider: @escaping () -> String? = { Host.current().localizedName },
        osVersionProvider: @escaping () -> OperatingSystemVersion = { ProcessInfo.processInfo.operatingSystemVersion },
        bootDateProvider: @escaping () -> Date? = { DeviceSummaryProvider.systemBootDate() }
    ) {
        self.hostNameProvider = hostNameProvider
        self.osVersionProvider = osVersionProvider
        self.bootDateProvider = bootDateProvider
    }

    func makeSummary(now: Date = Date(), fallbackHostName: String) -> DeviceSummary {
        let hostName: String = {
            if let name = hostNameProvider(), !name.isEmpty {
                return name
            }
            return fallbackHostName
        }()

        let version = osVersionProvider()
        let osVersionText = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"

        let uptimeText: String? = {
            guard let boot = bootDateProvider() else { return nil }
            return Self.formatUptime(from: boot, now: now)
        }()

        return DeviceSummary(
            hostName: hostName,
            osVersionText: osVersionText,
            uptimeText: uptimeText
        )
    }

    /// Reads system boot time via `sysctl kern.boottime`.
    static func systemBootDate() -> Date? {
        var boottime = timeval()
        var size = MemoryLayout<timeval>.stride
        let result = sysctlbyname("kern.boottime", &boottime, &size, nil, 0)
        guard result == 0, boottime.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(boottime.tv_sec))
    }

    /// Formats total uptime as hours:minutes, e.g. `"14:02"` or `"0:01"`.
    static func formatUptime(from boot: Date, now: Date) -> String {
        let totalSeconds = max(0, Int(now.timeIntervalSince(boot)))
        let totalMinutes = totalSeconds / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return "\(hours):\(String(format: "%02d", minutes))"
    }
}
