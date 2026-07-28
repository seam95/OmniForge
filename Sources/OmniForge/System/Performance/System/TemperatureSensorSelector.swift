import Darwin
import Foundation

enum CPUTemperaturePlatform: Equatable {
    case appleM1Family
    case appleM2Family
    case appleM3Family
    case appleM4Family
    case appleM5Family
    case generic
}

enum TemperatureSensorSelector {
    // 旧键 + 现代 M1 固件键（本机枚举实测：Tc*/Tp2*-Tp9* 等）
    private static let appleM1CPUCoreKeys: Set<String> = [
        // 旧表
        "Tp09", "Tp0T",
        "Tp01", "Tp05", "Tp0D", "Tp0H",
        "Tp0L", "Tp0P", "Tp0X", "Tp0b",
        // 现代 M1
        "Tc0a", "Tc0b", "Tc0x", "Tc0z",
        "Tc1a", "Tc1b", "Tc1x", "Tc1z",
        "Tc2a", "Tc2b", "Tc2x", "Tc2z",
        "Tc3a", "Tc3b", "Tc3x", "Tc3z",
        "Tc4a", "Tc4b", "Tc4x", "Tc4z",
        "Tc5a", "Tc5b", "Tc5x", "Tc5z",
        "Tc6a", "Tc6b", "Tc6x", "Tc6z",
        "Tc7a", "Tc7b", "Tc7x", "Tc7z",
        "Tc8a", "Tc8b", "Tc8x", "Tc8z",
        "Tc9a", "Tc9b", "Tc9x", "Tc9z",
        "Tcaa", "Tcab", "Tcax", "Tcaz",
        "Tp2a", "Tp2b", "Tp2x", "Tp2z",
        "Tp3a", "Tp3b", "Tp3x", "Tp3z",
        "Tp4a", "Tp4b", "Tp4x", "Tp4z",
        "Tp5a", "Tp5b", "Tp5x", "Tp5z",
        "Tp7a", "Tp7b", "Tp7x", "Tp7z",
        "Tp8a", "Tp8b", "Tp8x", "Tp8z",
        "Tp9a", "Tp9b", "Tp9x", "Tp9z",
        "Te0a", "Te0b", "Te0x", "Te0z",
        "Te3a", "Te3b", "Te3x", "Te3z",
    ]

    private static let appleM2CPUCoreKeys: Set<String> = [
        "Tp1h", "Tp1t", "Tp1p", "Tp1l",
        "Tp01", "Tp05", "Tp09", "Tp0D",
        "Tp0X", "Tp0b", "Tp0f", "Tp0j",
    ]

    private static let appleM3CPUCoreKeys: Set<String> = [
        "Te05", "Te0L", "Te0P", "Te0S",
        "Tf04", "Tf09", "Tf0A", "Tf0B",
        "Tf0D", "Tf0E", "Tf44", "Tf49",
        "Tf4A", "Tf4B", "Tf4D", "Tf4E",
    ]

    private static let appleM4CPUCoreKeys: Set<String> = [
        "Te05", "Te0S", "Te09", "Te0H",
        "Tp01", "Tp05", "Tp09", "Tp0D",
        "Tp0V", "Tp0Y", "Tp0b", "Tp0e",
    ]

    private static let appleM5CPUCoreKeys: Set<String> = [
        "Tp00", "Tp04", "Tp08", "Tp0C",
        "Tp0G", "Tp0K",
        "Tp0O", "Tp0R", "Tp0U", "Tp0X",
        "Tp0a", "Tp0d", "Tp0g", "Tp0j",
        "Tp0m", "Tp0p", "Tp0u", "Tp0y",
    ]

    /// Preferred + fallback CPU keys probed when SMC enumeration is unavailable.
    static let knownCPUKeys: [String] = Array(
        appleM1CPUCoreKeys
            .union(appleM2CPUCoreKeys)
            .union(appleM3CPUCoreKeys)
            .union(appleM4CPUCoreKeys)
            .union(appleM5CPUCoreKeys)
    ).sorted()

    static let knownGPUKeys: [String] = [
        // 旧表
        "TG0p", "TG0P", "TG1p", "TG1P", "TG2p", "TG0D",
        "Tg0p", "Tg0P", "Tg1p", "Tg1P", "Tg2p", "Tg0D",
        // 现代 Apple Silicon
        "TG0B", "TG0C", "TG0H", "TG0V", "TG1B", "TG2B",
        "Tg1b", "Tg4b",
        "tGA0", "tGA1", "tGAM", "tGMD",
    ]

    static let knownBatteryKeys: [String] = [
        "TB0T", "TB1T", "TB2T", "TB3T",
    ]

    static func platform(brandString: String?) -> CPUTemperaturePlatform {
        let brand = brandString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch appleSiliconGeneration(in: brand) {
        case 1: return .appleM1Family
        case 2: return .appleM2Family
        case 3: return .appleM3Family
        case 4: return .appleM4Family
        case 5: return .appleM5Family
        default: return .generic
        }
    }

    static func currentPlatform() -> CPUTemperaturePlatform {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return .generic
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return .generic
        }
        return platform(brandString: String(cString: buffer))
    }

    static func displayedCPUTemperature(readings: [(key: String, value: Double)],
                                        platform: CPUTemperaturePlatform) -> Double? {
        let valid = readings.filter { isPlausibleTemperature($0.value) }
        guard !valid.isEmpty else { return nil }

        let core = valid.filter { isCPUCoreKey($0.key, platform: platform) }
        if let value = core.map({ $0.value }).max() {
            return value
        }
        return valid.map { $0.value }.max()
    }

    static func hasCPUCoreSet(platform: CPUTemperaturePlatform) -> Bool {
        switch platform {
        case .appleM1Family, .appleM2Family, .appleM3Family, .appleM4Family, .appleM5Family:
            return true
        case .generic: return false
        }
    }

    static func isCPUCoreKey(_ key: String, platform: CPUTemperaturePlatform) -> Bool {
        switch platform {
        case .appleM1Family:
            return appleM1CPUCoreKeys.contains(key)
        case .appleM2Family:
            return appleM2CPUCoreKeys.contains(key)
        case .appleM3Family:
            return appleM3CPUCoreKeys.contains(key)
        case .appleM4Family:
            return appleM4CPUCoreKeys.contains(key)
        case .appleM5Family:
            return appleM5CPUCoreKeys.contains(key)
        case .generic:
            return false
        }
    }

    /// Compatibility wrapper: collect known CPU key readings and select via platform core set.
    static func cpuTemperature(from smc: SMCReading,
                               platform: CPUTemperaturePlatform = TemperatureSensorSelector.currentPlatform()) -> Double? {
        let readings = knownCPUKeys.compactMap { key -> (key: String, value: Double)? in
            guard let value = smc.value(forKey: key) else { return nil }
            return (key, value)
        }
        return displayedCPUTemperature(readings: readings, platform: platform)
    }

    /// Max of known GPU keys (no first-success).
    static func gpuTemperature(from smc: SMCReading) -> Double? {
        maxPlausible(keys: knownGPUKeys, smc: smc)
    }

    /// Max of known battery keys (no first-success).
    static func batteryTemperature(from smc: SMCReading) -> Double? {
        maxPlausible(keys: knownBatteryKeys, smc: smc)
    }

    private static func maxPlausible(keys: [String], smc: SMCReading) -> Double? {
        let values = keys.compactMap { key -> Double? in
            guard let value = smc.value(forKey: key), isPlausibleTemperature(value) else { return nil }
            return value
        }
        return values.max()
    }

    private static func appleSiliconGeneration(in brand: String) -> Int? {
        guard brand.hasPrefix("Apple M") else { return nil }
        let remainder = brand.dropFirst("Apple M".count)
        guard let first = remainder.first, let generation = Int(String(first)) else { return nil }
        guard generation >= 1, generation <= 5 else { return nil }
        let afterGeneration = remainder.dropFirst()
        guard afterGeneration.isEmpty || afterGeneration.first == " " else { return nil }
        return generation
    }

    private static func isPlausibleTemperature(_ value: Double) -> Bool {
        value > 1 && value < 125
    }
}
