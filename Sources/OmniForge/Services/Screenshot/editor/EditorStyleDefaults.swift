import AppKit

/// 编辑器样式默认值。
///
/// 参照 capcap `EditorStyleDefaults.swift`：定义调色板、线宽档位与默认值。
/// 与 capcap 的差异：OmniForge 暂不接 `Defaults.*Hex` 持久化，先以内存
/// 默认值落地（阶段 5/设置页再接 UserDefaults），保持简单。
enum EditorStyleDefaults {
    /// 8 色调色板（红蓝绿黄橙白灰黑）。
    /// 参照 capcap L4-13。
    static let paletteColors: [NSColor] = [
        NSColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1.0),     // Red
        NSColor(srgbRed: 0.0, green: 0.48, blue: 1.0, alpha: 1.0),      // Blue
        NSColor(srgbRed: 0.0, green: 0.83, blue: 0.42, alpha: 1.0),     // Green
        NSColor(srgbRed: 1.0, green: 0.8, blue: 0.0, alpha: 1.0),       // Yellow
        NSColor(srgbRed: 0.843, green: 0.467, blue: 0.341, alpha: 1.0), // #D77757 橙
        .white,
        NSColor(white: 0.5, alpha: 1.0),                                 // Gray
        .black,
    ]

    /// 普通画笔/形状的默认颜色（红）。
    static let primaryColor: NSColor = paletteColors[0]
    /// 荧光笔的默认颜色（黄）。
    static let markerColor: NSColor = paletteColors[3]

    /// 普通画笔/形状线宽档位。
    static let standardLineSizes: [CGFloat] = [2, 4, 6]
    /// 荧光笔线宽档位。
    static let markerLineSizes: [CGFloat] = [3, 5, 8]

    /// 普通画笔/形状默认线宽。
    static let standardLineWidth: CGFloat = 4
    /// 荧光笔默认线宽。
    static let markerLineWidth: CGFloat = 5

    /// 普通线宽可调范围（子工具栏滑块用）。
    static let standardLineWidthMin: CGFloat = 1
    static let standardLineWidthMax: CGFloat = 20
    /// 荧光笔线宽可调范围。
    static let markerLineWidthMin: CGFloat = 2
    static let markerLineWidthMax: CGFloat = 30
    /// 文字字号可调范围。
    static let fontSizeMin: CGFloat = 10
    static let fontSizeMax: CGFloat = 100
    /// 文字默认字号。
    static let fontSize: CGFloat = 18
    /// 马赛克块大小可调范围。
    static let mosaicBlockSizeMin: CGFloat = 4
    static let mosaicBlockSizeMax: CGFloat = 60
    /// 马赛克默认块大小。
    static let mosaicBlockSize: CGFloat = 12

    /// 从 HEX 字符串解析颜色（容错 '#' 前缀与非法值）。
    static func color(fromHex hex: String?) -> NSColor? {
        guard var trimmed = hex?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() else {
            return nil
        }
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}
