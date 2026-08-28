import SwiftUI

/// 四色便签语义色板（SPEC D12：色值取本应用设计系统，不抄参考应用）。
/// 亮色为便签纸暖色，暗色为低饱和深色变体；accent 用于色点与选中高亮环。
struct StickyNotePalette {
    let backgroundLight: Color
    let backgroundDark: Color
    let accent: Color
    let textLight: Color
    let textDark: Color

    func background(colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? backgroundDark : backgroundLight
    }

    func text(colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? textDark : textLight
    }

    static func palette(for color: StickyNoteColor) -> StickyNotePalette {
        switch color {
        case .yellow:
            return StickyNotePalette(
                backgroundLight: Color(red: 0.984, green: 0.914, blue: 0.663),
                backgroundDark: Color(red: 0.29, green: 0.25, blue: 0.12),
                accent: Color(red: 0.85, green: 0.62, blue: 0.05),
                textLight: Color(red: 0.26, green: 0.22, blue: 0.12),
                textDark: Color(red: 0.93, green: 0.89, blue: 0.76)
            )
        case .mint:
            return StickyNotePalette(
                backgroundLight: Color(red: 0.843, green: 0.949, blue: 0.890),
                backgroundDark: Color(red: 0.13, green: 0.26, blue: 0.20),
                accent: Color(red: 0.16, green: 0.60, blue: 0.34),
                textLight: Color(red: 0.12, green: 0.28, blue: 0.19),
                textDark: Color(red: 0.85, green: 0.93, blue: 0.88)
            )
        case .blue:
            return StickyNotePalette(
                backgroundLight: Color(red: 0.851, green: 0.914, blue: 0.980),
                backgroundDark: Color(red: 0.14, green: 0.22, blue: 0.33),
                accent: Color(red: 0.25, green: 0.52, blue: 0.82),
                textLight: Color(red: 0.14, green: 0.23, blue: 0.36),
                textDark: Color(red: 0.86, green: 0.91, blue: 0.96)
            )
        case .pink:
            return StickyNotePalette(
                backgroundLight: Color(red: 0.980, green: 0.863, blue: 0.906),
                backgroundDark: Color(red: 0.31, green: 0.18, blue: 0.24),
                accent: Color(red: 0.85, green: 0.36, blue: 0.58),
                textLight: Color(red: 0.36, green: 0.16, blue: 0.24),
                textDark: Color(red: 0.95, green: 0.87, blue: 0.90)
            )
        }
    }
}

/// 便签窗口的视觉常量。
enum StickyNoteChrome {
    /// 窗口圆角半径（与阴影配合形成卡片观感）。
    static let cornerRadius: CGFloat = 12
    /// 右下角缩放热区边长。
    static let resizeHandleLength: CGFloat = 16
    /// 工具栏按钮通用尺寸。
    static let toolbarButtonSize: CGFloat = 22
    /// 窄窗口时色点组收起的宽度阈值。
    static let colorDotsCollapseWidth: CGFloat = 272
}
