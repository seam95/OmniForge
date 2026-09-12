import Foundation

/// 桌面宠物连续尺寸：高度值域 64…224pt、步进 4、默认 96。
/// 持久化沿用 `desktopPet.size` 键的整数存储——真实旧整数偏好（64/96/128）直接兼容，
/// 无字符串档位迁移；新连续值同键保存。
struct DesktopPetSize: Hashable {
    /// 宠物窗口高度（pt，恒为 4 的倍数且在值域内）。
    let rawValue: Int

    /// 值域（pt）。
    static let range: ClosedRange<Int> = 64...224
    /// 步进（pt）。
    static let step = 4
    /// 默认值（pt）。
    static let defaultValue = 96

    /// 快捷预设（旧三档语义保留，UI 预设按钮与旧偏好等值）。
    static let small = DesktopPetSize(64)
    static let medium = DesktopPetSize(96)
    static let large = DesktopPetSize(128)
    /// UI 快捷预设（顺序即展示序）。
    static let presets: [DesktopPetSize] = [.small, .medium, .large]

    /// 窗口高度（点）。宽度由素材宽高比另行推导。
    var pointSize: CGFloat { CGFloat(rawValue) }

    /// 从持久化值恢复：先钳制到值域，再按步进取最近值（半步向上）。
    /// 有限越界值（如 10 / 300 / 真实 0）钳制；本方法不区分「缺失」与「非法」
    /// ——键缺失或非数值须由 `read(from:key:)` 先行判定回退默认。
    static func from(_ storedValue: Int) -> DesktopPetSize {
        normalized(clamping: Double(storedValue))
    }

    /// 双精度入口（滑杆连续拖动值）：钳制 + 取整（半步向上）。
    static func normalized(clamping raw: Double) -> DesktopPetSize {
        guard raw.isFinite else { return .medium }
        let clamped = min(max(raw, Double(range.lowerBound)), Double(range.upperBound))
        // .rounded() 对正数 x.5 远离零入（半步向上，如 66 → 68）。
        let stepped = (clamped / Double(step)).rounded() * Double(step)
        return DesktopPetSize(Int(stepped))
    }

    /// 从 defaults 读取并规范化（缺失 / 非数值 / 非有限值回退默认 96，
    /// 与真实 0 等有限越界值的钳制路径可区分——不依赖 `integer(forKey:)` 的缺省 0）。
    static func read(from defaults: UserDefaults, key: String) -> DesktopPetSize {
        guard let number = defaults.object(forKey: key) as? NSNumber else {
            return .medium  // 缺失或非数值（字符串等）。
        }
        return normalized(clamping: number.doubleValue)
    }

    /// 钳制 + 取整的原始构造（presets 等常量与规范化路径共用；不得反向调用
    /// `normalized`——那会经本构造形成无限递归）。
    init(_ value: Int) {
        let clamped = min(max(value, Self.range.lowerBound), Self.range.upperBound)
        // 对齐步进（半步向上；值域边界 64/224 均为 4 的倍数，取整后夹回防越界）。
        let stepped = Int((Double(clamped) / Double(Self.step)).rounded()) * Self.step
        rawValue = min(max(stepped, Self.range.lowerBound), Self.range.upperBound)
    }
}
