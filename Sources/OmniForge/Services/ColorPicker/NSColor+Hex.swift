import AppKit

// MARK: - NSColor 与 HEX 字符串互转
//
// 取色器子系统的纯函数工具：系统 `NSColorSampler` 回调返回 `NSColor`，
// 此处负责把它归一化到 sRGB 并与 `#RRGGBB` 字符串互转。
// 截图标注子系统后续若需要 hex 序列化也可复用此扩展。

extension NSColor {
    /// 从 HEX 字符串构造 sRGB 颜色，alpha 固定为 1。
    ///
    /// 兼容三种输入：
    /// - `#RRGGBB`、`RRGGBB`（6 位）
    /// - `#RGB`、`RGB`（3 位，每位扩展为两位，如 `#F0A` → `#FF00AA`）
    ///
    /// 非法输入（长度不符、非十六进制字符）返回 nil。
    convenience init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }

        guard digits.allSatisfy({ $0.isHexDigit }), digits.count == 3 || digits.count == 6 else { return nil }

        if digits.count == 3 {
            digits = digits.map { "\($0)\($0)" }.joined()
        }

        guard let value = UInt32(digits, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    /// 输出大写 `#RRGGBB`，忽略 alpha（取色场景恒为不透明）。
    /// 先归一化到 sRGB，再做 clamp 与四舍五入。
    var hexString: String {
        let rgb = usingColorSpace(.sRGB) ?? self
        let r = Int(round(clamped(rgb.redComponent) * 255))
        let g = Int(round(clamped(rgb.greenComponent) * 255))
        let b = Int(round(clamped(rgb.blueComponent) * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// 把分量夹到 [0, 1]，防止非 sRGB 色域外值越界。
    private func clamped(_ component: CGFloat) -> CGFloat {
        min(max(component, 0), 1)
    }
}
