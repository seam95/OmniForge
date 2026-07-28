import Foundation

enum MouseNavigationDirection: Equatable {
    case back
    case forward
}

enum MouseNavigationSupport {
    /// CoreGraphics 在左键、右键、中键之后，将前两个侧键编号为 3 和 4。
    /// 这是多键鼠标在没有被其他驱动重映射时，标准 Back/Forward 按键的编号。
    static let backButtonNumber: Int64 = 3
    static let forwardButtonNumber: Int64 = 4

    static func direction(forButtonNumber buttonNumber: Int64) -> MouseNavigationDirection? {
        switch buttonNumber {
        case backButtonNumber: return .back
        case forwardButtonNumber: return .forward
        default: return nil
        }
    }

    static func commandCharacter(for direction: MouseNavigationDirection) -> String {
        direction == .back ? "[" : "]"
    }
}
