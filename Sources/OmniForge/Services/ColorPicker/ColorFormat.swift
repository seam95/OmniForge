import AppKit

// MARK: - 颜色格式转换
//
// 取色器详情页同时展示 HEX / RGB / HSL 三种文本，每行可点击复制。
// 所有转换都先把 `NSColor` 归一化到 sRGB，保证显示与复制一致。

enum ColorFormat: String, CaseIterable {
    case hex
    case rgb
    case hsl

    /// 把颜色渲染为当前格式对应的字符串。
    func string(from color: NSColor) -> String {
        switch self {
        case .hex: return Self.hex(from: color)
        case .rgb: return Self.rgb(from: color)
        case .hsl: return Self.hsl(from: color)
        }
    }

    /// `#RRGGBB`（大写）。与 `NSColor.hexString` 一致，此处复用。
    static func hex(from color: NSColor) -> String {
        color.hexString
    }

    /// `rgb(r, g, b)`，分量取 0–255 整数。
    static func rgb(from color: NSColor) -> String {
        let srgb = normalized(color)
        let r = Int(round(clamped(srgb.redComponent) * 255))
        let g = Int(round(clamped(srgb.greenComponent) * 255))
        let b = Int(round(clamped(srgb.blueComponent) * 255))
        return "rgb(\(r), \(g), \(b))"
    }

    /// `hsl(h, s%, l%)`，h 取 0–360 整数，s/l 取 0–100 整数。
    static func hsl(from color: NSColor) -> String {
        let srgb = normalized(color)
        let r = clamped(srgb.redComponent)
        let g = clamped(srgb.greenComponent)
        let b = clamped(srgb.blueComponent)
        let maximum = max(r, max(g, b))
        let minimum = min(r, min(g, b))
        let lightness = (maximum + minimum) / 2

        guard maximum != minimum else {
            // 灰阶：色相与饱和度无意义，归零。
            return "hsl(0, 0%, \(Int(round(lightness * 100)))%)"
        }

        let delta = maximum - minimum
        let saturation = lightness > 0.5
            ? delta / (2 - maximum - minimum)
            : delta / (maximum + minimum)

        let hue: CGFloat
        switch maximum {
        case r:
            hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        case g:
            hue = (b - r) / delta + 2
        default:
            hue = (r - g) / delta + 4
        }
        let hueDegrees = hue * 60 < 0 ? hue * 60 + 360 : hue * 60

        let h = Int(round(hueDegrees))
        let s = Int(round(saturation * 100))
        let l = Int(round(lightness * 100))
        return "hsl(\(h), \(s)%, \(l)%)"
    }

    /// 归一化到 sRGB；若颜色空间不可转换（极少见）退回原色。
    private static func normalized(_ color: NSColor) -> NSColor {
        color.usingColorSpace(.sRGB) ?? color
    }

    private static func clamped(_ component: CGFloat) -> CGFloat {
        min(max(component, 0), 1)
    }
}
