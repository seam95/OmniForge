import Foundation

/// 风扇相关 SMC key
public enum SMCFanKey {
    /// 风扇数量（ui8）
    public static let fanCount = "FNum"
    /// 第 index 颗风扇的实际转速
    public static func actualSpeed(_ index: Int) -> String { "F\(index)Ac" }
    /// 硬件最小转速
    public static func minSpeed(_ index: Int) -> String { "F\(index)Mn" }
    /// 硬件最大转速
    public static func maxSpeed(_ index: Int) -> String { "F\(index)Mx" }
    /// 目标转速（手动模式下由写入方设定）
    public static func targetSpeed(_ index: Int) -> String { "F\(index)Tg" }
    /// 手动/自动模式（1 = 手动；Apple Silicon）
    public static func mode(_ index: Int) -> String { "F\(index)Md" }
    /// 全局手动模式位掩码（每风扇一位；Intel）
    public static let forceMode = "FS! "
    /// SMC 测试模式 — Apple Silicon 上接管风扇（绕过系统温控）的先决写入
    public static let testMode = "Ftst"
}

/// SMC 数值编码器
public enum SMCCodec {
    /// fpe2（无符号 14.2 定点，高字节在前）编码
    public static func encodeFPE2(_ value: Double) -> [UInt8] {
        let raw = UInt16(min(max(value * 4.0, 0), Double(UInt16.max)))
        return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
    }

    /// float32 小端编码（Apple Silicon SMC 字节序）
    public static func encodeFloat32(_ value: Double) -> [UInt8] {
        let bits = Float(value).bitPattern
        return [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF),
                UInt8((bits >> 16) & 0xFF), UInt8(bits >> 24)]
    }
}
