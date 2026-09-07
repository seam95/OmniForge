import Foundation
import OmniForgeSMC

/// 风扇采样器 — FNum 发现 + 每风扇五 key 读取（当前/目标/最小/最大/模式）。
/// min/max 为硬件常量，首读缓存；所有读取失败以 valid 标志溯源，不与 0 值混同。
final class FanSampler: FanSampling {
    private let smc: FanSMCCommanding
    private var cachedMinRPM: [Int: Double] = [:]
    private var cachedMaxRPM: [Int: Double] = [:]

    init(smc: FanSMCCommanding) {
        self.smc = smc
    }

    func sampleFans() throws -> [FanReading] {
        guard let count = smc.readUInt8(forKey: SMCFanKey.fanCount) else {
            throw MetricSamplingError.systemCall("FNum unreadable")
        }
        guard count > 0 else { return [] }

        return (0..<Int(count)).map { index in
            let current = clampRPM(smc.readDouble(forKey: SMCFanKey.actualSpeed(index)))
            let target = clampRPM(smc.readDouble(forKey: SMCFanKey.targetSpeed(index)))
            let isManual = smc.readUInt8(forKey: SMCFanKey.mode(index)).map { $0 != 0 }

            return FanReading(
                id: index,
                currentRPM: current ?? 0,
                minRPM: minRPM(for: index),
                maxRPM: maxRPM(for: index),
                targetRPM: target ?? 0,
                isManualMode: isManual ?? false,
                currentRPMValid: current != nil,
                targetRPMValid: target != nil,
                isManualModeValid: isManual != nil
            )
        }
    }

    // MARK: - 内部

    /// 硬件最小转速 — 首读缓存；读不到或异常小时回退保守默认
    private func minRPM(for index: Int) -> Double {
        if let cached = cachedMinRPM[index] { return cached }
        var value = clampRPM(smc.readDouble(forKey: SMCFanKey.minSpeed(index))) ?? 0
        if value < 100 { value = 1000 }
        cachedMinRPM[index] = value
        return value
    }

    /// 硬件最大转速 — 首读缓存；读不到或不大于 min 时回退保守默认
    private func maxRPM(for index: Int) -> Double {
        if let cached = cachedMaxRPM[index] { return cached }
        var value = clampRPM(smc.readDouble(forKey: SMCFanKey.maxSpeed(index))) ?? 0
        if value < 1000 || value <= minRPM(for: index) { value = 15000 }
        cachedMaxRPM[index] = value
        return value
    }

    /// RPM 合理性钳制 — 防异常浮点与解码毛刺；非法输入返回 nil 以保留失败溯源
    private func clampRPM(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 20000)
    }
}
