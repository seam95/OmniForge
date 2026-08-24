import Foundation

/// DeepSeek 余额设置输入清洗（纯函数，便于测试）。
enum DeepSeekSettingsValidation {
    /// API Key 清洗：去除首尾空白；空串 = 无效。
    static func sanitizedAPIKey(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 阈值解析：仅接受正有限数（Decimal 分隔符按当前区域解析，与用户输入一致）。
    static func parseThreshold(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = Double(trimmed), value.isFinite else { return nil }
        return value > 0 ? value : nil
    }
}
