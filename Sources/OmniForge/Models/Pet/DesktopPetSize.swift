import Foundation

/// 桌面宠物尺寸档位。
/// rawValue 是宠物窗口的像素边长（点），持久化标识稳定不得重命名。
/// 三档均为图集单元格的整数倍缩放，配合最近邻采样保证 Retina 下像素锐利。
enum DesktopPetSize: Int, CaseIterable {
    case small = 64
    case medium = 96
    case large = 128

    /// 窗口边长（点）。
    var pointSize: CGFloat { CGFloat(rawValue) }

    /// 从持久化值恢复，非法值回退中档。
    static func from(_ storedValue: Int) -> DesktopPetSize {
        DesktopPetSize(rawValue: storedValue) ?? .medium
    }
}
