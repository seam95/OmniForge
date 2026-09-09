import AppKit
import Foundation

/// 应用外观三态。持久化字符串必须稳定，不得重命名。
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// NSAppearance 映射：system → nil（跟随系统，恢复语义），
    /// light → .aqua、dark → .darkAqua。
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}