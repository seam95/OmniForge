import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import CoreGraphics

/// 任务栏式 Dock 点击：点击已在前台的 App 的 Dock 图标会最小化其窗口，
/// 如同传统任务栏；Dock 的原生行为（激活、恢复、修饰键快捷键）对其他
/// 所有点击保持不变。需要辅助功能权限。
final class DockClickService: ObservableObject {
    static let shared = DockClickService()

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    private struct ActionRecord {
        let kind: DockClickAction
        let time: CFAbsoluteTime
        /// 该动作针对的窗口，使后续切换即便 AX 状态仍在收尾也能精确
        /// 撤销它们。
        let targets: [AXUIElement]
    }

    /// 在 mouse down 时决定、等待其 mouse up 的点击。在 down 上动作
    /// 曾经会吞掉 Dock 启动图标拖拽所需的那一个事件，导致任何点击
    /// 会动作的 App 的图标永远无法重排（Terminal 和 Activity Monitor
    /// 上报告过）。动作现在在干净的 mouse up 上提交，越过 slop 的
    /// 移动会回放 down，使按下重新变回原生 Dock 拖拽。
    private struct PendingClick {
        let pid: pid_t
        let app: NSRunningApplication
        let origin: CGPoint
        let action: DockClickAction
        let unminimized: [AXUIElement]
        let minimized: [AXUIElement]
        let priorRecord: ActionRecord?
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var dockPIDCache: pid_t?
    private var pendingClick: PendingClick?
    /// 每个 App 最后处理的点击：后续点击从此记录切换，而不是从动画
    /// 进行中、模糊的 AX 状态重新推导。tap 运行在主 run loop，因此
    /// 两个字典都仅限主线程。
    private var lastAction: [pid_t: ActionRecord] = [:]

    /// 标记回放的 mouse down，使 tap 放行自己的事件（与 snippets tap
    /// 对合成事件使用的相同手法）。
    private static let syntheticEventMarker: Int64 = 0x564F5253
    private var pendingSweeps: [pid_t: DispatchWorkItem] = [:]
    private let userDefaults: UserDefaults
    private let featureAvailable: () -> Bool
    private let permissionGranted: () -> Bool
    private let startOverride: (() throws -> Void)?
    private let stopOverride: (() -> Void)?

    init(
        userDefaults: UserDefaults = .standard,
        featureAvailable: @escaping () -> Bool = {
            MainActor.assumeIsolated { FeatureRuntime.shared.isAvailable(.dockClick) }
        },
        permissionGranted: @escaping () -> Bool = { AXIsProcessTrusted() },
        startOverride: (() throws -> Void)? = nil,
        stopOverride: (() -> Void)? = nil
    ) {
        self.userDefaults = userDefaults
        self.featureAvailable = featureAvailable
        self.permissionGranted = permissionGranted
        self.startOverride = startOverride
        self.stopOverride = stopOverride
    }

    func syncWithPreferences() {
        synchronize(retry: false)
    }

    func retry() { synchronize(retry: true) }

    var runState: FeatureRunState {
        let input = gateInput
        return FeatureRunState.resolve(
            isEnabled: input.isAvailable && input.featureEnabled,
            isRunning: isRunning,
            hasPermission: input.hasPermission,
            lastError: lastError
        )
    }

    /// 无论偏好如何都强制停止 tap。用于 App 重置自身权限之前，使一个
    /// 被撤销的辅助功能授权永远不会留下一个活跃的 tap。
    func suspend() {
        removeEventTap()
        isRunning = false
        lastError = nil
    }

    private var gateInput: MouseRunGate.Input {
        let featureEnabled = userDefaults.bool(forKey: UserDefaultsKeys.dockClickMinimize)
            || userDefaults.bool(forKey: UserDefaultsKeys.dockClickCycleWindows)
        return .init(
            isAvailable: featureAvailable(),
            featureEnabled: featureEnabled,
            hasPermission: permissionGranted()
        )
    }

    private func synchronize(retry: Bool) {
        var running = isRunning
        var error = lastError
        MouseRunGate.synchronize(
            input: gateInput,
            retry: retry,
            isRunning: &running,
            lastError: &error,
            start: { [self] in try installEventTap() },
            stop: { [self] in removeEventTap() }
        )
        isRunning = running
        lastError = error
    }

    private func installEventTap() throws {
        if let startOverride {
            try startOverride()
            return
        }
        guard tap == nil else { return }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
                | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
                | CGEventMask(1 << CGEventType.leftMouseUp.rawValue),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<DockClickService>.fromOpaque(userInfo).takeUnretainedValue()
                return service.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { throw MouseServiceError.eventTapCreationFailed(service: "DockClickService") }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeEventTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        for (_, sweep) in pendingSweeps { sweep.cancel() }
        pendingSweeps = [:]
        lastAction = [:]
        pendingClick = nil
        stopOverride?()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // 一个变成拖拽的按下所回放的 down：Dock 必须原样收到它。
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
            return Unmanaged.passUnretained(event)
        }
        switch type {
        case .leftMouseDragged:
            return handleDragged(event)
        case .leftMouseUp:
            return handleUp(event)
        case .leftMouseDown:
            break
        default:
            return Unmanaged.passUnretained(event)
        }

        // 全新的按下总是干净开始；一个陈旧的待处理点击（tap 在超时期间
        // 错过了 up）绝不能阻塞新的那个。
        pendingClick = nil

        // 修饰键点击保留 Dock 的原生快捷键（⌘ 定位、⌥ 隐藏…）。
        guard event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
        else { return Unmanaged.passUnretained(event) }

        let point = event.location
        guard Self.insideDockStrip(point) else {
            return Unmanaged.passUnretained(event)
        }

        // 边缘带在每台显示器都存在，即便自动隐藏时 Dock 在屏幕外也如此，
        // 但下方的 AX 项框架仍报告停泊布局，且只沿 Dock 长轴匹配——一个
        // 靠近无 Dock 显示器边缘、长轴坐标与某个图标对齐的点击，会凭空
        // 最小化或恢复应用。只有真正在屏幕上的 Dock 条带内的点击，才可能
        // 意味着一个图标。
        guard let dockPID = dockProcessID(),
              let dockBounds = Self.revealedDockBounds(dockPID: dockPID),
              dockBounds.insetBy(dx: -8, dy: -8).contains(point) else {
            return Unmanaged.passUnretained(event)
        }

        // 辅助功能失效（如重置）：下方的 AX 命中测试会在 tap 内部挂起
        // 并冻结点击，因此原样放行点击。
        guard AXIsProcessTrusted() else { return Unmanaged.passUnretained(event) }

        let hit = dockApplication(at: point)
        guard let app = hit, app.processIdentifier != getpid()
        else { return Unmanaged.passUnretained(event) }

        let pid = app.processIdentifier
        let now = CFAbsoluteTimeGetCurrent()
        lastAction = lastAction.filter { now - $0.value.time < DockClickSupport.toggleIntentWindow }
        let record = lastAction[pid]
        let decision = DockClickSupport.repeatDecision(lastAction: record?.kind,
                                                       elapsed: record.map { now - $0.time })
        if decision == .swallow { return nil }

        var windows = Self.standardWindows(pid: pid)
        var windowServerSeesWindows = false
        if windows.unminimized.isEmpty, windows.minimized.isEmpty {
            // AX 列表返回空；窗口服务器是关于该 App 是否真无窗口的廉价、
            // 无 AX 的真相。Java 和 Eclipse 应用（DBeaver，issue #200）
            // 经常在其窗口就在眼前时让 AX 失败或超时。
            windowServerSeesWindows = Self.windowServerHasStandardWindows(pid: pid)
            if windowServerSeesWindows {
                // 一次较慢的重试：繁忙的 JVM 通常只是错过了 0.35 秒牵绳。
                // 罕见路径，因此额外等待绝不拖累正常应用。
                windows = Self.standardWindows(pid: pid, timeout: 0.7)
            }
        }
        guard !windows.hasFullscreen else { return Unmanaged.passUnretained(event) }

        let cycleEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.dockClickCycleWindows)
        let minimizeEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.dockClickMinimize)
        // 启动器式应用可能误报 isActive；工作区的前台应用是裁决者。
        let frontmost = app.isActive
            || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        let hasUnminimized = DockClickSupport.effectiveHasUnminimized(
            unminimizedCount: windows.unminimized.count,
            minimizedCount: windows.minimized.count,
            windowServerSeesWindows: windowServerSeesWindows)
        let action: DockClickAction
        if case .toggle(let toggled) = decision {
            action = toggled
        } else {
            action = DockClickSupport.action(appIsFrontmost: frontmost,
                                             hasUnminimizedWindows: hasUnminimized,
                                             hasMinimizedWindows: !windows.minimized.isEmpty,
                                             hasFullscreenWindows: false,
                                             hasModifiers: false,
                                             minimizeEnabled: minimizeEnabled,
                                             cycleWindowsEnabled: cycleEnabled,
                                             unminimizedWindowCount: windows.unminimized.count)
        }

        // 已处理的点击被吞掉（否则 Dock 会与我们对抗：最小化时重新激活，
        // 恢复时打开一个全新窗口），但动作只在按钮抬起且未移动时提交：
        // 这次按下仍可能是一个图标拖拽的开始。
        guard action != .passThrough else { return Unmanaged.passUnretained(event) }
        pendingClick = PendingClick(pid: pid, app: app, origin: point, action: action,
                                    unminimized: windows.unminimized,
                                    minimized: windows.minimized,
                                    priorRecord: record)
        return nil
    }

    /// 待处理点击期间的移动：越过 slop 后按下是 Dock 图标拖拽，因此被吞
    /// 的 down 被回放（标记，放行）让 Dock 接管；slop 以内的抖动仍是待
    /// 处理点击的一部分。
    private func handleDragged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let pending = pendingClick else { return Unmanaged.passUnretained(event) }
        let point = event.location
        if DockClickSupport.isDragMovement(from: pending.origin, to: point) {
            pendingClick = nil
            guard let down = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
                                     mouseType: .leftMouseDown,
                                     mouseCursorPosition: point,
                                     mouseButton: .left) else { return nil }
            down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
            down.post(tap: .cghidEventTap)
        }
        return nil
    }

    /// 干净的释放提交待处理动作；up 像 down 一样被吞掉，因此 Dock 永远
    /// 看不到半个点击。
    private func handleUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let pending = pendingClick else { return Unmanaged.passUnretained(event) }
        pendingClick = nil
        commit(pending)
        return nil
    }

    /// 执行一个已决定的点击。
    private func commit(_ pending: PendingClick) {
        let pid = pending.pid
        let now = CFAbsoluteTimeGetCurrent()
        switch pending.action {
        case .cycleWindows:
            lastAction[pid] = ActionRecord(kind: .cycleWindows, time: now, targets: [])
            let unminimized = pending.unminimized
            DispatchQueue.main.async {
                Self.cycleWindows(pid: pid, windows: unminimized)
            }
        case .minimize:
            lastAction[pid] = ActionRecord(kind: .minimize, time: now, targets: pending.unminimized)
            // 某些应用对 Minimize All 菜单动作报告成功却让窗口纹丝不动。立即
            // 启动逐窗口 AX 动作，使这些应用不必等收尾扫描；菜单路径仍覆盖
            // AX 盲和多窗口应用。
            Self.setMinimized(true, windows: pending.unminimized)
            DispatchQueue.main.async {
                Self.postMinimizeAll(pid: pid)
            }
            scheduleSweep(pid: pid, targets: pending.unminimized, minimized: true,
                          delay: DockClickSupport.minimizeSweepDelay)
        case .restore:
            // 最小化之后紧接着的切换也会重新打开 AX 状态尚未翻转的已捕获
            // 窗口；与实时最小化列表的重复是无害的（集合幂等）。
            var targets = pending.minimized
            if let record = pending.priorRecord, record.kind == .minimize {
                targets += record.targets
            }
            lastAction[pid] = ActionRecord(kind: .restore, time: now, targets: targets)
            Self.setMinimized(false, windows: targets)
            scheduleSweep(pid: pid, targets: targets, minimized: false,
                          delay: DockClickSupport.restoreSweepDelay)
            DispatchQueue.main.async {
                pending.app.activate()
            }
        case .passThrough:
            break
        }
    }

    // MARK: - 收尾扫描

    /// 动画收尾后重新断言动作：批量 Minimize All 遗留的窗口（缺少标准
    /// 绑定的应用）被逐个最小化，而最小化仍在进行时切入的恢复会重新
    /// 打开掉队者。仅扫描点击时捕获的窗口——在触发时重新查询会抓取
    /// 用户在此期间更改的窗口——而同一应用的每个新动作都会取消上一次
    /// 扫描，因此恰好一个方向胜出。
    private func scheduleSweep(pid: pid_t, targets: [AXUIElement], minimized: Bool, delay: TimeInterval) {
        pendingSweeps[pid]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingSweeps.removeValue(forKey: pid)
            let value: CFBoolean = minimized ? kCFBooleanTrue : kCFBooleanFalse
            DispatchQueue.global(qos: .userInteractive).async {
                // != 也扫描状态无法读取（nil）的窗口：设置一个已正确的
                // 状态是空操作，而跳过不可读的会把 Java 应用窗口留下（#200）。
                for window in targets where Self.isMinimized(window) != minimized {
                    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, value)
                }
            }
        }
        pendingSweeps[pid] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func postMinimizeAll(pid: pid_t) {
        DispatchQueue.global(qos: .userInteractive).async {
            // 按下应用自身的 Minimize All 菜单项胜过合成 ⌥⌘M：即便焦点
            // 偏移它也定位正确的应用，跳过其间的每个事件 tap，且与布局
            // 无关（kVK_ANSI_M 是物理键——在 AZERTY 上它根本不打出 M）。
            guard !handleMinimizeMenu(pid: pid) else { return }
            DispatchQueue.main.async {
                Self.postMinimizeAllShortcut()
            }
        }
    }

    /// 通过扫描应用菜单栏两层深度，找到并按下绑定到 ⌥⌘M（Minimize All）
    /// 的菜单项——该项直接位于 Window 菜单中，因此永不进入子菜单。按
    /// 命令字符 + 修饰符而非本地化标题匹配，适用于目标应用发布的每种
    /// 语言。没有 Minimize All 的应用（Java 和 Eclipse 应用如 DBeaver，
    /// issue #200）回退到其普通 Minimize 项（⌘M）：每次点击一个窗口，
    /// 但点击可用。这在 tap 外运行，因此能负担比 tap 侧窗口枚举更长的
    /// 牵绳——繁忙的 JVM 经常需要它。
    /// 当某个菜单动作运行，或存在冲突的 Option-Command-M 项使合成快捷键
    /// 不安全时返回 true。False 意味着快捷键是安全的最后手段，因为菜单
    /// 层次未暴露可用动作。
    private static func handleMinimizeMenu(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let menuBar = elementAttribute(app, kAXMenuBarAttribute as String),
              let topLevel = elementArray(menuBar, kAXChildrenAttribute as String)
        else { return false }

        var plainMinimize: AXUIElement?
        var minimizeAll: AXUIElement?
        var hasConflictingOptionM = false
        // Window 菜单靠近菜单栏末尾。
        for barItem in topLevel.reversed() {
            guard let menus = elementArray(barItem, kAXChildrenAttribute as String) else { continue }
            for menu in menus {
                guard let items = elementArray(menu, kAXChildrenAttribute as String) else { continue }
                for item in items {
                    let commandCharacter = stringAttribute(item, "AXMenuItemCmdChar")
                    let modifiers = intAttribute(item, "AXMenuItemCmdModifiers")
                    let isVerifiedMinimizeAll = DockClickSupport.isVerifiedMinimizeAll(
                        commandCharacter: commandCharacter,
                        modifiers: modifiers,
                        identifier: stringAttribute(item, kAXIdentifierAttribute as String)
                    )
                    if isVerifiedMinimizeAll, minimizeAll == nil {
                        minimizeAll = item
                    } else if commandCharacter?.uppercased() == "M", modifiers == 2 {
                        hasConflictingOptionM = true
                    }
                    if commandCharacter?.uppercased() == "M",
                       modifiers == 0, plainMinimize == nil { // ⌘M: 普通 Minimize
                        plainMinimize = item
                    }
                }
            }
        }
        if let minimizeAll {
            guard boolAttribute(minimizeAll, kAXEnabledAttribute as String) != false else { return true }
            if AXUIElementPerformAction(minimizeAll, kAXPressAction as CFString) == .success {
                return true
            }
        }
        if let plainMinimize,
           boolAttribute(plainMinimize, kAXEnabledAttribute as String) != false {
            if AXUIElementPerformAction(plainMinimize, kAXPressAction as CFString) == .success {
                return true
            }
        }
        return hasConflictingOptionM
    }

    private static func postMinimizeAllShortcut() {
        // 修饰键 KEY 必须显式按下和释放，模拟真实打字。仅投递带 ⌘⌥ 标志的
        // M 事件会把这些修饰符锁存进会话的标志状态——此后每次点击在用户
        // 物理按下它们之前都会变成 ⌘⌉-点击。
        let source = CGEventSource(stateID: .hidSystemState)
        let sequence: [(key: Int, down: Bool, flags: CGEventFlags)] = [
            (kVK_Command, true, [.maskCommand]),
            (kVK_Option, true, [.maskCommand, .maskAlternate]),
            (kVK_ANSI_M, true, [.maskCommand, .maskAlternate]),
            (kVK_ANSI_M, false, [.maskCommand, .maskAlternate]),
            (kVK_Option, false, [.maskCommand]),
            (kVK_Command, false, []),
        ]
        for step in sequence {
            guard let event = CGEvent(keyboardEventSource: source,
                                      virtualKey: CGKeyCode(step.key),
                                      keyDown: step.down) else { continue }
            event.flags = step.flags
            event.post(tap: .cghidEventTap)
        }
    }

    private static func setMinimized(_ minimized: Bool, windows: [AXUIElement]) {
        let value: CFBoolean = minimized ? kCFBooleanTrue : kCFBooleanFalse
        for window in windows {
            DispatchQueue.global(qos: .userInteractive).async {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, value)
            }
        }
    }

    /// 通过把最后排的窗口提升到前面来循环应用的非最小化窗口，模拟
    /// ⌘`（Command-反引号）行为。
    ///
    /// 最后排窗口来自 WindowServer 的真实 z 序，而非 AX windows 数组：
    /// 该数组保持聚焦窗口在最前，因此「从聚焦窗口前进」退化为在最前
    /// 两个窗口间翻转，其余永不被访问。提升真正最后排的窗口以轮询顺序
    /// 走遍每个窗口。
    private static func cycleWindows(pid: pid_t, windows: [AXUIElement]) {
        guard windows.count > 1 else { return }

        let rearWindow: AXUIElement
        if let rear = rearmostByZOrder(pid: pid, windows: windows) {
            rearWindow = rear
        } else {
            // 无 z 序可用（窗口 id 未解析）：AX 数组是聚焦优先，因此其
            // 最后元素仍是最佳最后排猜测。
            rearWindow = windows[windows.count - 1]
        }

        AXUIElementPerformAction(rearWindow, kAXRaiseAction as CFString)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, rearWindow)
    }

    /// WindowServer 屏幕前后列表中位于最深处的候选。其他 Space 上的窗口
    /// 不在该列表中，这正是想要的：从 Dock 循环绝不应把用户拽到其他 Space。
    private static func rearmostByZOrder(pid: pid_t, windows: [AXUIElement]) -> AXUIElement? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        let orderedIDs = info.compactMap { entry -> CGWindowID? in
            guard entry[kCGWindowOwnerPID as String] as? pid_t == pid,
                  entry[kCGWindowLayer as String] as? Int == 0,
                  let number = entry[kCGWindowNumber as String] as? CGWindowID else { return nil }
            return number
        }
        guard orderedIDs.count > 1 else { return nil }
        var rear: (window: AXUIElement, depth: Int)?
        for window in windows {
            guard let id = AXWindowResolver.windowID(for: window),
                  let depth = orderedIDs.firstIndex(of: id) else { continue }
            if rear == nil || depth > rear!.depth {
                rear = (window, depth)
            }
        }
        return rear?.window
    }

    // MARK: - 几何

    /// Dock 条带的屏幕边界，使用与事件位置相同的左上原点全局坐标，
    /// 离屏时为 nil。该条带是 Dock 拥有的单一 layer-20 窗口；自动隐藏
    /// 时其屏幕状态随滑动进出而翻转，在 macOS 27 上实测确认。边界还把
    /// 条带钉在有它的那台显示器上，因此其他显示器上的边缘点击永远
    /// 到不了图标匹配。
    private static func revealedDockBounds(dockPID: pid_t) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        for window in list {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == dockPID,
                  (window[kCGWindowLayer as String] as? Int) == dockLevel,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width > 0, bounds.height > 0
            else { continue }
            return bounds
        }
        return nil
    }

    /// 任何 AX 调用之前的廉价预过滤，使用事件的左上原点全局坐标。放大时
    /// 悬停的图标可能长到超过保留条带；此类点击回退到 Dock 的原生处理。
    private static func insideDockStrip(_ point: CGPoint) -> Bool {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        for screen in NSScreen.screens {
            let frame = axRect(screen.frame, primaryHeight: primaryHeight)
            let visible = axRect(screen.visibleFrame, primaryHeight: primaryHeight)
            if DockClickSupport.dockStripContains(point, screenFrame: frame, visibleFrame: visible) {
                return true
            }
        }
        return false
    }

    private static func axRect(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX,
               y: primaryHeight - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    // MARK: - Dock 命中测试

    /// 通过遍历 Dock 的项列表并仅沿 Dock 长轴匹配，解析一次点击落在哪个
    /// Dock 应用图标上。基于位置的 AX 命中测试在此无用：macOS 报告的
    /// Dock 条带 AX 框架在短轴上偏移（macOS 27 上观察到约 72 pt），而
    /// 长轴坐标保持真实。上方的条带门控已经约束了短轴。
    private func dockApplication(at point: CGPoint) -> NSRunningApplication? {
        guard let dockPID = dockProcessID() else { return nil }
        let dockElement = AXUIElementCreateApplication(dockPID)
        AXUIElementSetMessagingTimeout(dockElement, 0.35)
        guard let children = Self.elementArray(dockElement, kAXChildrenAttribute as String) else { return nil }

        for child in children where Self.roleString(child) == "AXList" {
            guard let items = Self.elementArray(child, kAXChildrenAttribute as String),
                  let listFrame = Self.axFrame(child)
            else { continue }
            let horizontal = listFrame.width >= listFrame.height
            for item in items {
                guard let frame = Self.axFrame(item) else { continue }
                let hit = horizontal
                    ? (point.x >= frame.minX && point.x <= frame.maxX)
                    : (point.y >= frame.minY && point.y <= frame.maxY)
                guard hit, let url = Self.urlAttribute(item) else { continue }
                let standardized = url.standardizedFileURL.path
                return NSWorkspace.shared.runningApplications.first {
                    $0.activationPolicy == .regular && !$0.isTerminated
                        && $0.bundleURL?.standardizedFileURL.path == standardized
                }
            }
        }
        return nil
    }

    private static func elementArray(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let array = value as? [AXUIElement]
        else { return nil }
        return array
    }

    private static func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func roleString(_ element: AXUIElement) -> String? {
        stringAttribute(element, kAXRoleAttribute as String)
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func intAttribute(_ element: AXUIElement, _ attribute: String) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return (value as? NSNumber)?.intValue
    }

    private static func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? Bool
    }

    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        AXFrameReader.frame(element)
    }

    private func dockProcessID() -> pid_t? {
        if let dockPIDCache,
           NSRunningApplication(processIdentifier: dockPIDCache)?.isTerminated == false {
            return dockPIDCache
        }
        let pid = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "com.apple.dock"
        }?.processIdentifier
        dockPIDCache = pid
        return pid
    }

    private static func urlAttribute(_ element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == CFURLGetTypeID()
        else { return nil }
        return (value as! CFURL) as URL
    }

    // MARK: - 窗口

    private static func isMinimized(_ window: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success
        else { return nil }
        return value as? Bool
    }

    /// 窗口服务器是否为该 pid 列出任何正常的屏幕窗口。无 AX，因此对
    /// 辅助功能端繁忙或无响应的应用保持真实。
    private static func windowServerHasStandardWindows(pid: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { entry in
            entry[kCGWindowOwnerPID as String] as? pid_t == pid
                && entry[kCGWindowLayer as String] as? Int == 0
        }
    }

    /// 按 App 标准窗口按最小化状态拆分，以及是否有任何窗口全屏（它们
    /// 无法最小化且必须否决动作）。
    private static func standardWindows(pid: pid_t, timeout: Float = 0.35)
        -> (unminimized: [AXUIElement], minimized: [AXUIElement], hasFullscreen: Bool) {
        let appElement = AXUIElementCreateApplication(pid)
        // 这在 tap 回调内针对用户刚点击的应用运行——通常是繁忙或挂起的
        // 那个。没有显式超时，这里的每次调用都会等满 AX 数秒默认值并
        // 系统级停滞点击投递。
        AXUIElementSetMessagingTimeout(appElement, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return ([], [], false) }
        var unminimized: [AXUIElement] = []
        var minimized: [AXUIElement] = []
        var hasFullscreen = false
        for window in windows {
            AXUIElementSetMessagingTimeout(window, timeout)
            // 角色必须是真正的窗口：Finder 也在此列出桌面（AXScrollArea），
            // 否则它会被算作窗口。
            guard Self.roleString(window) == (kAXWindowRole as String) else { continue }
            // 一个不可读的最小化状态（繁忙 JVM、SWT 怪癖）绝不能从两个
            // 列表中都抹去窗口——一个前台应用其窗口全部读取失败会看起来
            // 无窗口，点击会什么都不做（issue #200）。未知读作「未最小化」：
            // 过度包含最小化目标是无害的，而恢复动作在有一个存在时永不触发。
            let isWindowMinimized = isMinimized(window) ?? false
            if isWindowMinimized {
                // 无 subrole 检查：macOS 会把最小化窗口的 subrole 从
                // AXStandardWindow 翻转为 AXDialog。
                minimized.append(window)
                continue
            }
            if boolAttribute(window, "AXFullScreen") == true {
                hasFullscreen = true
                continue
            }
            if let subroleString = stringAttribute(window, kAXSubroleAttribute as String),
               subroleString != "AXStandardWindow" {
                continue
            }
            unminimized.append(window)
        }
        return (unminimized, minimized, hasFullscreen)
    }
}
