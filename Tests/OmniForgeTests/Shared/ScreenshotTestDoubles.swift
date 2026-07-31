import AppKit
import CoreGraphics
import Foundation
import KeyboardShortcuts
@testable import OmniForge

// MARK: - ScreenCaptureClient fake

/// 参照 KeepAwake Fake 范式：副作用计数 + 失败注入。
/// 用于 ScreenshotFeatureManager / 捕获会话单测；不触碰真实 ScreenCaptureKit。
final class FakeScreenCaptureClient: ScreenCaptureClient {
    struct CaptureDisplayCall: Equatable {
        let displayID: CGDirectDisplayID
    }

    struct CaptureRegionCall: Equatable {
        let rect: CGRect
        let displayID: CGDirectDisplayID
        let scaleFactor: CGFloat
        let excludingWindowIDs: [CGWindowID]
    }

    private(set) var captureDisplayCalls: [CaptureDisplayCall] = []
    private(set) var captureRegionCalls: [CaptureRegionCall] = []
    private(set) var captureSnapshotCalls: [CGDirectDisplayID] = []

    /// 控制下次异步捕获抛错；为空则返回占位图像。
    var captureDisplayError: Error?
    var captureRegionError: Error?
    /// captureSnapshot 同步返回值（默认 nil，模拟无预抓快照）。
    var stubbedSnapshot: CGImage?
    /// 控制 captureSnapshot 是否模拟后台延迟语义（默认 false=同步）。
    /// 协议签名同步，无法真正 await；时序测试用 onSnapshot + 调用顺序标志，不依赖 sleep。
    var captureSnapshotDeferred = false
    /// 每次 captureSnapshot 被调用时的回调；时序测试在此断言 startCapture 已先发生。
    var onSnapshot: ((CGDirectDisplayID) -> Void)?
    /// Optional delay before captureRegion returns (tests async cancel race).
    var captureRegionDelayNanoseconds: UInt64 = 0

    func captureDisplay(displayID: CGDirectDisplayID) async throws -> CGImage {
        captureDisplayCalls.append(CaptureDisplayCall(displayID: displayID))
        if let captureDisplayError { throw captureDisplayError }
        return FakeScreenCaptureClient.placeholderImage()
    }

    func captureRegion(
        _ rect: CGRect,
        displayID: CGDirectDisplayID,
        scaleFactor: CGFloat,
        excludingWindowIDs: [CGWindowID]
    ) async throws -> CGImage {
        captureRegionCalls.append(
            CaptureRegionCall(
                rect: rect,
                displayID: displayID,
                scaleFactor: scaleFactor,
                excludingWindowIDs: excludingWindowIDs
            )
        )
        if captureRegionDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: captureRegionDelayNanoseconds)
        }
        if let captureRegionError { throw captureRegionError }
        return FakeScreenCaptureClient.placeholderImage()
    }

    func captureSnapshot(displayID: CGDirectDisplayID) -> CGImage? {
        captureSnapshotCalls.append(displayID)
        onSnapshot?(displayID)
        // captureSnapshotDeferred 预留给需要阻塞/延迟语义的扩展；
        // 当前协议为同步签名，时序由调用顺序标志验证。
        _ = captureSnapshotDeferred
        return stubbedSnapshot
    }

    /// 1×1 透明占位图，避免 0 维触发 ScreenshotResult 校验失败。
    static func placeholderImage() -> CGImage {
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }
}

// MARK: - ScreenshotKeyboardShortcutsClient fake

/// 捕获 setShortcut / onKeyDown 调用，避免触碰真实 KeyboardShortcuts 全局状态。
final class FakeScreenshotKeyboardShortcutsClient: ScreenshotKeyboardShortcutsClient {
    struct SetShortcutCall: Equatable {
        let name: String
        let hasShortcut: Bool
    }

    private(set) var setShortcutCalls: [SetShortcutCall] = []
    /// 注册的 onKeyDown 回调，按 name 索引（测试可手动触发）。
    private(set) var keyDownHandlers: [String: () -> Void] = [:]

    func setShortcut(_ shortcut: KeyboardShortcuts.Shortcut?, for name: KeyboardShortcuts.Name) {
        setShortcutCalls.append(SetShortcutCall(name: name.rawValue, hasShortcut: shortcut != nil))
    }

    func onKeyDown(for name: KeyboardShortcuts.Name, action: @escaping () -> Void) {
        keyDownHandlers[name.rawValue] = action
    }

    /// 触发已注册的 onKeyDown（模拟用户按下快捷键）。
    func fireKeyDown(for name: KeyboardShortcuts.Name) {
        keyDownHandlers[name.rawValue]?()
    }
}
