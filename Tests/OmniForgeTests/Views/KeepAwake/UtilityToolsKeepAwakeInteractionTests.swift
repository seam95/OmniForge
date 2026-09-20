import AppKit
import SwiftUI
import XCTest
@testable import OmniForge

/// 唤醒工具页交互链路的端到端契约（真实 NSEvent 派发）：
/// - 测试 1 复刻控制中心工具页装配（真实 UtilityToolsView + ControlCenterSizingContext
///   挂载屏障 + 真实 KeepAwakeManager），进入详情页转场完成后，返回栏与会话开关
///   必须可点击——守护 PageSwitchHost 的 allowsHitTesting 门控随 enterCompleted 放开。
/// - 测试 2 叠加完整容器链（真 AppState bindToRuntime + objectWillChange 转发 +
///   ControlCenterContainerView 双层 PageSwitchHost 嵌套），守护状态发布到视图
///   刷新的转发链；单工具直达详情路径下点击开关必须启动会话。
@MainActor
final class UtilityToolsKeepAwakeInteractionTests: XCTestCase {

    final class RouteBox: ObservableObject {
        @Published var value: UtilityToolsRoute = .list

        var binding: Binding<UtilityToolsRoute> {
            Binding(get: { self.value }, set: { self.value = $0 })
        }
    }

    private var window: NSWindow?

    override func tearDown() {
        // XCTest 下 window.close() 会撕裂 NSHostingView 私有视图导致
        // SIGSEGV（进程退出时自然清理），这里只解引用不动窗口。
        window = nil
        FeatureRuntime.shared.resetForTesting()
        super.tearDown()
    }

    private func makeManager() -> KeepAwakeManager {
        let clock = FakeKeepAwakeClock()
        let scheduler = FakeKeepAwakeScheduler(clock: clock)
        let powerAssertions = FakePowerAssertions()
        let powerReader = FakePowerReader()
        let config = KeepAwakeConfigurationSnapshot(
            defaultDuration: .minutes15,
            batteryLimit: .disabled,
            autoStart: false,
            showCountdown: false,
            mouseJiggleEnabled: false,
            mouseJiggleInterval: .minutes5,
            clamshellPreferred: false,
            shortcutEnabled: true,
            hotkey: .defaultKeepAwake
        )
        return KeepAwakeManager(
            assertions: powerAssertions,
            powerReader: powerReader,
            scheduler: scheduler,
            clock: clock,
            configuration: { config },
            notifications: FakeUserNotificationPoster(),
            isFeatureAvailable: { true },
            blocksStart: { false }
        )
    }

    /// 独立 defaults 域：availability 全默认可用、免受宿主 defaults 与其它测试污染。
    private func makeIsolatedRuntime() {
        let suiteName = "UtilityToolsKeepAwakeInteractionTests"
        let suite = UserDefaults(suiteName: suiteName)
        suite?.removePersistentDomain(forName: suiteName)
        let runtime = FeatureRuntime.shared
        runtime.setDefaultsForTesting(suite ?? .standard)
        runtime.overrideBindingsForTesting { _ in }
    }

    // MARK: - 测试 1：工具页装配，转场后返回栏与开关可点

    func test_enterKeepAwakeDetail_backBarAndSessionToggleRemainClickable() async throws {
        makeIsolatedRuntime()
        let manager = makeManager()
        let box = RouteBox()
        let sizingContext = ControlCenterSizingContext()
        let rootView = RouteObservingHost(box: box, sizingContext: sizingContext) { box in
            UtilityToolsView(
                strings: L10n().s,
                route: box.binding,
                keepAwakeManager: manager,
                clamshellRecoveryCoordinator: nil,
                onOpenSettings: { _ in }
            )
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 580),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingView(rootView: rootView)
        window.contentView = hosting
        window.orderFrontRegardless()
        self.window = window
        try await tick(0.15)

        // 进入保持唤醒详情页（真实转场：退出 → 挂载屏障 → 淡入）。
        box.value = .detail(.keepAwake)
        try await tick(1.0)

        // 断言 A：详情页顶部返回栏可点（FlatBackBar 顶部行，热区在左侧）。
        sendClick(hosting: hosting, window: window, local: NSPoint(x: 40, y: 18))
        try await tick(0.5)
        XCTAssertEqual(
            box.value,
            .list,
            "转场完成后返回栏必须可点击并把 route 弹回列表"
        )

        // 重新进入详情，断言 B：会话开关可点并启动唤醒会话。
        box.value = .detail(.keepAwake)
        try await tick(1.0)
        // 头部行开关位置：FlatBackBar（约 37pt）下方第一行右端。
        sendClick(hosting: hosting, window: window, local: NSPoint(x: 340, y: 66))
        try await tick(0.3)
        XCTAssertTrue(
            manager.state.isActive,
            "点击会话开关必须触发 manager.start()；实际 state=\(manager.state)"
        )
    }

    // MARK: - 测试 2：完整容器链（AppState 转发 + 双层 PageSwitchHost 嵌套）

    func test_fullContainerChain_toggleStartsSessionViaAppStateForwarding() async throws {
        makeIsolatedRuntime()
        let manager = makeManager()
        FeatureRuntime.shared.register(.keepAwake, manager: manager)

        // AppState 走生产路径（bindToRuntime）：从 FeatureRuntime 拉取
        // keepAwakeManager 并转发其 objectWillChange——这是控制中心刷新链。
        let appState = AppState(
            l10n: L10n(),
            appearance: AppearanceSettings(),
            launchAtLogin: LaunchAtLoginManager(client: FakeLaunchAtLoginClient())
        )

        // 单工具直达详情：仅保持唤醒可用，容器 onAppear 的 reentry 规则
        // 会把工具页路由直接解析到 .detail(.keepAwake)（初始挂载、无内层转场）。
        let suite = UserDefaults.standard
        let originalPanel = suite.object(forKey: UserDefaultsKeys.lastControlCenterPanel)
        let originalTool = suite.object(forKey: UserDefaultsKeys.lastUtilityTool)
        let availabilityBackups: [(String, Any?)] = AppFeature.allCases.map {
            ($0.availabilityKey, suite.object(forKey: $0.availabilityKey))
        }
        defer {
            if let originalPanel {
                suite.set(originalPanel, forKey: UserDefaultsKeys.lastControlCenterPanel)
            } else {
                suite.removeObject(forKey: UserDefaultsKeys.lastControlCenterPanel)
            }
            if let originalTool {
                suite.set(originalTool, forKey: UserDefaultsKeys.lastUtilityTool)
            } else {
                suite.removeObject(forKey: UserDefaultsKeys.lastUtilityTool)
            }
            for (key, value) in availabilityBackups {
                if let value {
                    suite.set(value, forKey: key)
                } else {
                    suite.removeObject(forKey: key)
                }
            }
        }
        suite.set(MenuPanel.utilities.rawValue, forKey: UserDefaultsKeys.lastControlCenterPanel)
        // runtime 的 availability store 绑定在隔离 suite 上，直接写键。
        let isolated = UserDefaults(suiteName: "UtilityToolsKeepAwakeInteractionTests")
        for feature in AppFeature.allCases where feature != .keepAwake {
            isolated?.set(false, forKey: feature.availabilityKey)
        }

        let sizingContext = ControlCenterSizingContext()
        let rootView = ControlCenterContainerView(
            state: appState,
            onOpenSettings: { _ in },
            sizingContext: sizingContext
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 580),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingView(rootView: rootView)
        window.contentView = hosting
        window.orderFrontRegardless()
        self.window = window
        try await tick(0.5)

        // 唤醒详情页在容器 chrome（恢复 banner + 导航条）下方；开关在头部行
        // 右端。y 步进扫描点击，任一位置命中即应启动会话（其余命中最多写
        // defaults，无破坏性）。
        var started = false
        for y: CGFloat in stride(from: 90, through: 260, by: 12) {
            sendClick(hosting: hosting, window: window, local: NSPoint(x: 340, y: y))
            try await tick(0.12)
            if manager.state.isActive {
                started = true
                break
            }
        }
        XCTAssertTrue(
            started,
            "完整容器链下点击会话开关必须启动会话；实际 state=\(manager.state)"
        )
    }

    // MARK: - harness

    /// 在 NSHostingView 本地（flipped，左上原点）坐标处派发一对真实
    /// mouseDown/mouseUp（经 NSApp.sendEvent 走 SwiftUI 命中分发路径）。
    private func sendClick(hosting: NSView, window: NSWindow, local: NSPoint) {
        let windowPoint = hosting.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            NSApp.sendEvent(event)
        }
    }

    private func tick(_ duration: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }
}

/// 观察宿主：让 box（ObservableObject）驱动视图树刷新——复刻生产
/// ControlCenterContainerView 以 @State 持有 route 并经 $binding 下传的
/// 观察语义；手写 Binding(get:set:) 不会驱动 NSHostingView 重算。
private struct RouteObservingHost<Content: View>: View {
    @ObservedObject var box: UtilityToolsKeepAwakeInteractionTests.RouteBox
    let sizingContext: ControlCenterSizingContext
    @ViewBuilder let content: (UtilityToolsKeepAwakeInteractionTests.RouteBox) -> Content

    var body: some View {
        content(box)
            .frame(width: ControlCenterContentMetrics.panelWidth)
            .environment(\.controlCenterSizing, sizingContext)
    }
}
