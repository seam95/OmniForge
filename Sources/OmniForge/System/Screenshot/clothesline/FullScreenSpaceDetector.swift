// Sources/OmniForge/System/Screenshot/clothesline/FullScreenSpaceDetector.swift
import AppKit

// 本项目首个私有 API 引用：窗口服务器知道每个屏当前 Space 的类型。
// 该调用十年稳定（窗口管理器同类工具依赖），无权限要求；
// 我们不走 App Store，接受系统更新风险，失败回退 false（不抑制晾衣绳）。
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> CFArray

enum FullScreenSpaceDetector {
    private static let fullScreenSpaceType = 4

    /// 该屏当前是否在全屏应用 Space（视频/演示不该被绳子横穿）。
    static func isActive(on screen: NSScreen) -> Bool {
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]],
              !displays.isEmpty
        else { return false }
        // 「显示器各有独立 Space」关闭时只有一条记录覆盖所有屏。
        let entry: [String: Any]?
        if displays.count == 1 {
            entry = displays.first
        } else {
            let uuid = uuidString(for: screen)
            entry = displays.first { ($0["Display Identifier"] as? String) == uuid }
        }
        return (entry?["Current Space"] as? [String: Any])?["type"] as? Int == fullScreenSpaceType
    }

    private static func uuidString(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}
