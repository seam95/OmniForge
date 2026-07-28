import Foundation

enum PeripheralBatterySupport {
    /// 从百分比字符串（如 "83%"）解析整数值
    static func percent(from raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("%") else { return nil }
        return Int(trimmed.dropLast())
    }
}
