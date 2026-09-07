import Foundation

/// 风扇性能曲线 — 纯函数核心，四档预设温度→转速百分比映射。
/// 曲线连续无悬崖（相邻段斜率衔接），避免转速可听突变。
enum FanCurve {

    /// 性能档位
    enum Level: String, CaseIterable, Equatable, Codable {
        case low, medium, high, max
    }

    /// 档位转速地板（相对 minRPM 的占比）：性能模式开启期间风扇不低于该值，
    /// 且始终处于手动模式 — 消除手动/自动反复切换的「忽开忽停」噪音
    static func minSpeedFloor(_ level: Level) -> Double {
        switch level {
        case .low: return 0.0    // 贴 minRPM 静音，但从不回自动
        case .medium: return 0.10
        case .high: return 0.25
        case .max: return 0.50   // 预防性基线，冷机不从头起转
        }
    }

    /// 每 2s 周期的升速上限（RPM）— 越低越平缓
    static func rampUpRate(_ level: Level) -> Double {
        switch level {
        case .low: return 400
        case .medium: return 700
        case .high: return 1200
        case .max: return 2000
        }
    }

    /// 每 2s 周期的降速上限（RPM）— 恒慢于升速，防转速骤降噪音
    static func rampDownRate(_ level: Level) -> Double {
        switch level {
        case .low: return 150
        case .medium: return 250
        case .high: return 400
        case .max: return 500
        }
    }

    /// 热区温度 EMA 平滑因子 — 越小越重平滑，毛刺越难传导到转速
    static func smoothingFactor(_ level: Level) -> Double {
        switch level {
        case .low: return 0.15
        case .medium: return 0.25
        case .high: return 0.35
        case .max: return 0.50
        }
    }

    /// （平滑后）热区峰值温度 → 风扇转速百分比（0...1，相对 minRPM→maxRPM 区间）
    static func speedPercent(level: Level, temperature: Double) -> Double {
        switch level {
        case .low:
            // 地板贴 minRPM：仅在机身确实偏热后才介入
            switch temperature {
            case ...70: return 0.0
            case 70..<85: return (temperature - 70) / 15.0 * 0.30   // 0 → 30%
            case 85..<95: return 0.30 + (temperature - 85) / 10.0 * 0.30  // 30 → 60%
            case 95..<105: return 0.60 + (temperature - 95) / 10.0 * 0.20 // 60 → 80%
            default: return 0.80
            }
        case .medium:
            switch temperature {
            case ...55: return 0.10
            case 55..<70: return 0.10 + (temperature - 55) / 15.0 * 0.25  // 10 → 35%
            case 70..<82: return 0.35 + (temperature - 70) / 12.0 * 0.30  // 35 → 65%
            case 82..<92: return 0.65 + (temperature - 82) / 10.0 * 0.25  // 65 → 90%
            default: return min(0.90 + (temperature - 92) / 8.0 * 0.10, 1.0)
            }
        case .high:
            switch temperature {
            case ...45: return 0.25
            case 45..<58: return 0.25 + (temperature - 45) / 13.0 * 0.25  // 25 → 50%
            case 58..<70: return 0.50 + (temperature - 58) / 12.0 * 0.25  // 50 → 75%
            case 70..<82: return 0.75 + (temperature - 70) / 12.0 * 0.20  // 75 → 95%
            default: return min(0.95 + (temperature - 82) / 8.0 * 0.05, 1.0)  // 95 → 100%
            }
        case .max:
            // 高基线预防性散热：远早于温控墙就爬到全速；
            // 非恒 100% — 有热余量时全速只是噪音与磨损
            switch temperature {
            case ...40: return 0.50
            case 40..<55: return 0.50 + (temperature - 40) / 15.0 * 0.20  // 50 → 70%
            case 55..<68: return 0.70 + (temperature - 55) / 13.0 * 0.30  // 70 → 100%
            default: return 1.0
            }
        }
    }

    /// EMA 平滑：previous 为 nil 时直接采用当前值（首轮）
    static func smoothed(previous: Double?, current: Double, factor: Double) -> Double {
        guard let previous else { return current }
        return previous + factor * (current - previous)
    }

    /// 斜坡限速：单周期内目标转速相对上次下发值的最大变化量约束
    static func rampedTarget(desired: Double, lastSent: Double?, upRate: Double, downRate: Double) -> Double {
        guard let lastSent else { return desired }
        if desired > lastSent {
            return min(desired, lastSent + upRate)
        } else {
            return max(desired, lastSent - downRate)
        }
    }
}
