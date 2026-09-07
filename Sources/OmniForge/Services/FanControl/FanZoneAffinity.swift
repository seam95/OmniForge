import Foundation

/// 热区 → 风扇亲和度 — 各热区对左右风扇的散热责任权重（0...1）。
/// 每风扇目标转速 = max over 热区(曲线% × 亲和度)，再与档位地板取最大。
enum FanZoneAffinity {
    /// 双风扇（左/右）亲和度；单风扇机器取两者较大值
    static func affinity(for zone: ThermalZone) -> (left: Double, right: Double) {
        switch zone {
        case .cpu: return (1.0, 1.0)          // SoC 居中，双风扇等责
        case .gpu: return (1.0, 1.0)          // GPU 与 CPU 同封装
        case .memory: return (1.0, 1.0)       // 封装内存，双风扇
        case .ssd: return (0.4, 1.0)          // SSD 控制器通常偏右
        case .powerDelivery: return (0.8, 0.8) // 供电分布两侧
        case .battery: return (0.6, 0.6)      // 电池横跨，低优先
        case .ambient, .unknown: return (0.5, 0.5) // 一般热区，最小贡献
        }
    }

    /// 单风扇贡献权重
    static func singleFanAffinity(for zone: ThermalZone) -> Double {
        let pair = affinity(for: zone)
        return max(pair.left, pair.right)
    }
}
