import SwiftUI

/// 四色便签语义色板（燕麦黄/灰绿/石灰蓝/陶粉低饱和纸质色系）。
/// 亮色为设计稿给定 hex；暗色为同色相低明度纸背 + 底色压暗文字；
/// accent 用于色点与选中高亮环（陶粉 accent 为按其余三色明度规律推得的补值）。
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
            // 燕麦黄：底 #F0E7D2 / 正文 #6B5B38 / accent #AE9159
            return StickyNotePalette(
                backgroundLight: Color(red: 0.941, green: 0.906, blue: 0.824),
                backgroundDark: Color(red: 0.29, green: 0.25, blue: 0.15),
                accent: Color(red: 0.682, green: 0.569, blue: 0.349),
                textLight: Color(red: 0.420, green: 0.357, blue: 0.220),
                textDark: Color(red: 0.89, green: 0.86, blue: 0.79)
            )
        case .mint:
            // 灰绿：底 #DCE5D5 / 正文 #4A5F43 / accent #7A9A70
            return StickyNotePalette(
                backgroundLight: Color(red: 0.863, green: 0.898, blue: 0.835),
                backgroundDark: Color(red: 0.14, green: 0.24, blue: 0.18),
                accent: Color(red: 0.478, green: 0.604, blue: 0.439),
                textLight: Color(red: 0.290, green: 0.373, blue: 0.263),
                textDark: Color(red: 0.83, green: 0.87, blue: 0.80)
            )
        case .blue:
            // 石灰蓝：底 #D9DFE6 / 正文 #42536B / accent #7285A0
            return StickyNotePalette(
                backgroundLight: Color(red: 0.851, green: 0.875, blue: 0.902),
                backgroundDark: Color(red: 0.15, green: 0.21, blue: 0.31),
                accent: Color(red: 0.447, green: 0.522, blue: 0.627),
                textLight: Color(red: 0.259, green: 0.325, blue: 0.420),
                textDark: Color(red: 0.83, green: 0.86, blue: 0.89)
            )
        case .pink:
            // 陶粉：底 #EBDDD8 / 正文 #7A4E44 / accent #A87467（推定值）
            return StickyNotePalette(
                backgroundLight: Color(red: 0.922, green: 0.867, blue: 0.847),
                backgroundDark: Color(red: 0.29, green: 0.18, blue: 0.16),
                accent: Color(red: 0.659, green: 0.455, blue: 0.404),
                textLight: Color(red: 0.478, green: 0.306, blue: 0.267),
                textDark: Color(red: 0.88, green: 0.84, blue: 0.83)
            )
        }
    }
}

/// 便签窗口的视觉常量。
enum StickyNoteChrome {
    /// 窗口圆角半径（Big Sur 连续曲线卡片，与系统窗口阴影配合）。
    static let cornerRadius: CGFloat = 14
    /// 右下角缩放热区边长。
    static let resizeHandleLength: CGFloat = 16
    /// 工具栏按钮通用尺寸。
    static let toolbarButtonSize: CGFloat = 22
    /// 窄窗口时色点组收起的宽度阈值。
    static let colorDotsCollapseWidth: CGFloat = 272
    /// 置顶激活态按钮的橙色底（白图标压其上）。
    static let pinActiveBackground = Color(red: 0.96, green: 0.62, blue: 0.04)
    /// 状态栏「已保存」指示绿点。
    static let savedDotColor = Color(red: 0.20, green: 0.78, blue: 0.35)
}
