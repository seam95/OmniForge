import AppKit
import Combine
import os
import SwiftUI

/// 飞行/掉落动画出口（真身 CaptureFlightAnimator；测试注入替身）。
/// 动画器驱动 NSPanel 与 CALayer，必须在主线程；协议同步标注隔离，
/// 否则 @MainActor 真身的 fly/fall 无法见证 nonisolated 协议要求。
@MainActor
protocol CaptureFlightAnimating: AnyObject {
    func fly(image: CGImage, from: CGRect, to: CGRect, tilt: CGFloat, on screen: NSScreen,
             completion: @escaping () -> Void)
    func fall(image: CGImage, card: CGRect, tilt: CGFloat, on screen: NSScreen)
}

/// 晾衣绳运行时：面板窗口、显隐状态机、目录监听、Inbox 接管、飞行动画接线。
/// 显隐节奏与自动隐藏 Dock 同族：藏于顶边之上，热区唤出，离开即收。
@MainActor
final class ClotheslineCoordinator: NSObject, ObservableObject {
    // 节奏常量被 nonisolated 判定内核读取，自身也须 nonisolated（纯数值，无状态）。
    nonisolated static let revealDelay: TimeInterval = 0.25
    nonisolated static let retractDelay: TimeInterval = 0.5
    static let peekSeconds: TimeInterval = 2.5

    private let manager: ClotheslineManager
    private let watcher: ScreenshotFolderWatcher
    /// 桌面兜底监听（SPEC §14）：Inbox 接管生效时系统截图可能无视接管直接落桌面，
    /// 需第二实例监听桌面带标记文件；与主监听分开构造（各自独立的基线与防抖）。
    private let safetyWatcher = ScreenshotFolderWatcher()
    private let inbox: ScreenshotInboxSettings
    private let outputConfiguration: ScreenshotOutputConfiguration
    private let animator: CaptureFlightAnimating
    private let stringsProvider: () -> Strings
    private let userDefaults: UserDefaults
    private static let logger = Logger(subsystem: "com.omniforge.app", category: "Clothesline")
    private var panel: ClotheslinePanel?
    private var cancellables = Set<AnyCancellable>()
    private var mouseMonitors: [Any] = []
    private var mouseTimer: Timer?
    private var keyObserver: NSObjectProtocol?
    private var signalSources: [DispatchSourceSignal] = []
    private var isStarted = false
    private var isPresent = false
    private var pinned = false
    private var peekUntil = Date.distantPast
    private var hotZoneSince: Date?
    private var menuBarSuppressed = false
    private var awaySince: Date?
    private var wanted = false
    private var keepOpen = false
    private var lastLiveCount = 0
    private var pendingScreen: NSScreen?

    init(userDefaults: UserDefaults = .standard,
         manager: ClotheslineManager,
         watcher: ScreenshotFolderWatcher,
         inbox: ScreenshotInboxSettings,
         outputConfiguration: ScreenshotOutputConfiguration,
         animator: CaptureFlightAnimating,
         stringsProvider: @escaping () -> Strings = { .en }) {
        self.userDefaults = userDefaults
        self.manager = manager
        self.watcher = watcher
        self.inbox = inbox
        self.outputConfiguration = outputConfiguration
        self.animator = animator
        self.stringsProvider = stringsProvider
        super.init()
    }

    // MARK: 生命周期

    func start() {
        // 幂等守卫：重复 start 会造成 mouseMonitors 翻倍、keyObserver token 泄漏、
        // signalSources 累积（DispatchSource 对同一信号重复监听语义未定义）。
        guard !isStarted else { return }
        isStarted = true
        // 空提示与右键菜单文案在 start 时定格：面板内容只建一次，语言切换随重启生效。
        let strings = stringsProvider()
        let host = NSHostingView(rootView: ClotheslineView(
            manager: manager,
            emptyHint: strings.clotheslineEmptyHint,
            menuProvider: { [weak self] item in self?.menu(for: item) ?? NSMenu() }
        ))
        host.sizingOptions = []
        panel = ClotheslinePanel(content: host)
        panel?.placeOnScreen(nil)
        updateCapacity()
        manager.startBreeze()
        manager.onFall = { [weak self] item in self?.fall(item) }
        manager.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.itemsChanged() }
            .store(in: &cancellables)
        installMouseMonitors()
        installKeyObserver()          // 其他窗口（含控制中心）成为 key → 收绳
        installSignalRestore()        // SIGTERM/SIGINT/SIGHUP 兜底还原 Inbox
        syncWithPreferences()
        // 首次启用后 1.2s 一次性询问 Inbox 接管；改系统设置永远是用户的决定。
        if !inbox.wasOffered {
            inbox.wasOffered = true
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                self?.offerInbox()
            }
        }
    }

    func teardown() {
        if inbox.isEnabled { inbox.restore() }
        watcher.stop()
        safetyWatcher.stop()
        removeMonitors()
        // 恢复默认处置，防卸载后信号免疫：installSignalRestore 曾把三信号置 SIG_IGN，
        // 不清理则特性卸载后 App 对 SIGTERM/SIGINT/SIGHUP 无响应（kill 不退出）。
        for source in signalSources { source.cancel() }
        signalSources.removeAll()
        for sig in [SIGTERM, SIGINT, SIGHUP] { signal(sig, SIG_DFL) }
        panel?.orderOut(nil)
        panel = nil
        cancellables.removeAll()
        wanted = false
        isPresent = false
        isStarted = false   // 复位幂等守卫，允许 teardown 后重新 start
        manager.revealed = false
        // MarkupEditingService 是单例，装配时 onSaved 闭包强持 ClotheslineManager；
        // 不清理会跨装配存活到下次覆盖。恢复默认空闭包，让 manager 随协调器一同释放。
        MarkupEditingService.shared.onSaved = { _ in }
    }

    /// 总开关 / 保存目录 / Inbox 变化后的统一重挂点。
    func syncWithPreferences() {
        let enabled = userDefaults.object(forKey: UserDefaultsKeys.screenshotClotheslineEnabled) == nil
            ? true   // 默认开（拍板 1a）
            : userDefaults.bool(forKey: UserDefaultsKeys.screenshotClotheslineEnabled)
        guard enabled else {
            if inbox.isEnabled { inbox.restore() }
            watcher.stop()
            safetyWatcher.stop()
            wanted = false
            refresh()
            return
        }
        startWatchers()
        if inbox.isEnabled { reapplyInboxIfNeeded() }
        refresh()
    }

    // MARK: 监听矩阵（SPEC §2）

    private var saveDirectory: URL {
        outputConfiguration.load().saveDirectory ?? ScreenshotSaver.defaultDirectory
    }

    private var isDesktopSave: Bool {
        saveDirectory.standardizedFileURL.path
            == ScreenshotSaver.defaultDirectory.standardizedFileURL.path
    }

    private func startWatchers() {
        watcher.ownWriteConsumer = { [weak self] url in
            self?.manager.consumeOwnWrite(url) ?? false
        }
        if inbox.isEnabled, !isDesktopSave {
            // 接管生效：主监听 = 保存目录（全图片），兜底 = 桌面（系统截图标记）。
            watcher.start(folder: saveDirectory, desktopOnlyTagged: false,
                          onNew: { [weak self] in self?.hangCapture($0) },
                          onChange: { [weak self] in self?.manager.prune() })
            // 桌面兜底真实现：系统可能无视接管设置仍把截图落桌面，
            // 监听桌面带标记文件并挂绳，保证这类截图不失踪。
            safetyWatcher.ownWriteConsumer = { [weak self] url in
                self?.manager.consumeOwnWrite(url) ?? false
            }
            safetyWatcher.start(folder: ScreenshotSaver.defaultDirectory, desktopOnlyTagged: true,
                                onNew: { [weak self] url in
                Self.logger.warning("截图落桌面（系统无视接管设置）\(url.lastPathComponent, privacy: .public)")
                self?.hangCapture(url)
            }, onChange: { [weak self] in self?.manager.prune() })
        } else {
            // 未接管：监听系统截图落点（默认桌面，带标记过滤）；桌面兜底不适用。
            let folder = systemScreenshotFolder()
            let isDesktop = folder.standardizedFileURL.path
                == ScreenshotSaver.defaultDirectory.standardizedFileURL.path
            watcher.start(folder: folder, desktopOnlyTagged: isDesktop,
                          onNew: { [weak self] in self?.hangCapture($0) },
                          onChange: { [weak self] in self?.manager.prune() })
            safetyWatcher.stop()
        }
    }

    /// 读系统截图保存位置（macOS 27 键名漂移双读），回退桌面。
    private func systemScreenshotFolder() -> URL {
        let store = CFPreferencesScreenshotStore()
        let domain = "com.apple.screencapture"
        store.synchronize(domain: domain)
        for key in ["location-screenshot", "location"] {
            if let raw = store.copyValue(forKey: key, domain: domain) as? String, !raw.isEmpty {
                let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    return url
                }
            }
        }
        return ScreenshotSaver.defaultDirectory
    }

    // MARK: Inbox

    func setInboxEnabled(_ on: Bool) {
        if on {
            inbox.apply(targetDirectory: saveDirectory)
        } else {
            inbox.restore()
        }
        startWatchers()
    }

    /// 管线写盘路径转发进排除集：watcher 对自家写入只挂绳一次。
    func noteOwnWrite(_ path: String) {
        manager.noteOwnWrite(path)
    }

    // MARK: 右键菜单（SPEC §3：复制/打开/标注/Finder/(Inbox)存桌面/取下/移废纸篓）

    func menu(for photo: PeggedPhoto) -> NSMenu {
        let strings = stringsProvider()
        let id = photo.id
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: strings.clotheslineMenuCopy) { [weak manager] in manager?.copy(id) })
        menu.addItem(ClosureMenuItem(title: strings.clotheslineMenuOpen) { [weak manager] in manager?.openInDefaultApp(id) })
        menu.addItem(ClosureMenuItem(title: strings.clotheslineMenuMarkup) { [weak manager] in manager?.markup(id) })
        menu.addItem(ClosureMenuItem(title: strings.clotheslineMenuReveal) { [weak manager] in manager?.revealInFinder(id) })
        // 存到桌面仅 Inbox 文件有意义（文件在接管目录内才需要移出）。
        if manager.isInInbox(id) {
            menu.addItem(ClosureMenuItem(title: strings.clotheslineMenuSaveToDesktop) { [weak manager] in
                manager?.saveToDesktop(id)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: strings.clotheslineMenuTakeDown) { [weak manager] in manager?.drop(id) })
        menu.addItem(ClosureMenuItem(title: strings.clotheslineMenuTrash) { [weak manager] in manager?.trash(id) })
        return menu
    }

    private func reapplyInboxIfNeeded() {
        inbox.apply(targetDirectory: saveDirectory)   // 目录变化后重写接管（幂等）
    }

    /// 首启一次性询问 Inbox 接管；点「开启」才动系统设置。
    /// 已接管或保存目录为桌面时不打扰（桌面场景设置页有冲突说明）。
    private func offerInbox() {
        guard !inbox.isEnabled, !isDesktopSave else { return }
        let alert = NSAlert()
        alert.messageText = stringsProvider().clotheslineInboxOfferTitle
        alert.informativeText = stringsProvider().clotheslineInboxOfferBody
        alert.addButton(withTitle: stringsProvider().clotheslineInboxOfferEnable)
        alert.addButton(withTitle: stringsProvider().clotheslineInboxOfferLater)
        alert.icon = NSApp.applicationIconImage
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            setInboxEnabled(true)
        }
    }

    // MARK: 显隐状态机

    /// 纯函数不碰隔离状态：显隐判定内核需在无窗口/无 App 运行循环的单元测试里直接调用。
    nonisolated static func menuBarBand(of screen: NSScreen) -> NSRect {
        var h = screen.frame.maxY - screen.visibleFrame.maxY
        if h < 1 { h = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - h,
                      width: screen.frame.width, height: h)
    }

    nonisolated static func shouldRevealFromMenuBar(inMenuBar: Bool, suppressed: Bool,
                                                    hotZoneSince: Date?, now: Date) -> Bool {
        guard inMenuBar, !suppressed, let since = hotZoneSince else { return false }
        return now.timeIntervalSince(since) >= revealDelay
    }

    nonisolated static func shouldRetract(inside: Bool, busy: Bool, awaySince: Date?, now: Date) -> Bool {
        if inside || busy { return false }
        guard let since = awaySince else { return false }
        return now.timeIntervalSince(since) >= retractDelay
    }

    func toggleReveal() {
        if manager.revealed {
            setRevealed(false)
            if manager.liveCount == 0 {
                keepOpen = false
                wanted = false
                refresh()
            }
        } else {
            keepOpen = true
            wanted = true
            panel?.placeOnScreen(ClotheslinePanel.screenUnderPointer())
            updateCapacity()
            refresh()
            reveal(pinned: true)
        }
    }

    /// 控制中心等窗口成为 key 时收绳（替代对 StatusBar 的侵入式耦合）。
    func hideForControlCenter() {
        guard manager.revealed else { return }
        pinned = false
        setRevealed(false)
    }

    private func itemsChanged() {
        let live = manager.liveCount
        if live > lastLiveCount {
            panel?.placeOnScreen(pendingScreen)
            pendingScreen = nil
            updateCapacity()
            wanted = true
            refresh()
            reveal(peekFor: Self.peekSeconds)
        } else if live == 0, !keepOpen {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard let self, self.manager.liveCount == 0, !self.keepOpen else { return }
                self.wanted = false
                self.refresh()
            }
        }
        lastLiveCount = live
    }

    /// 面板是否该在场：有内容且该屏不在全屏 Space。
    private func refresh() {
        // 指针所在屏优先，面板所在屏兜底；该屏处于全屏 Space 则压制（视频/演示不横穿）。
        let screen = ClotheslinePanel.screenUnderPointer() ?? panel?.screen
        let blocked = screen.map(FullScreenSpaceDetector.isActive(on:)) ?? false
        if wanted, !blocked { present() } else { dismiss() }
        // 绳子在场才轮询鼠标（含藏起状态——还要等顶边推挤唤出）。
        if wanted { startMouseTracking() } else { stopMouseTracking() }
    }

    private func present() {
        guard !isPresent, let panel else { return }
        isPresent = true
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func dismiss() {
        guard isPresent else { return }
        isPresent = false
        setRevealed(false)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !self.isPresent else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func reveal(pinned: Bool = false, peekFor seconds: TimeInterval = 0) {
        guard isPresent else { return }
        if pinned { self.pinned = true }
        if seconds > 0 { peekUntil = Date().addingTimeInterval(seconds) }
        awaySince = nil
        setRevealed(true)
    }

    private func setRevealed(_ on: Bool) {
        guard on != manager.revealed else { return }
        manager.revealed = on
        if !on {
            pinned = false
            peekUntil = .distantPast
            panel?.ignoresMouseEvents = true
        }
    }

    private func updateCapacity() {
        manager.maxItems = ClotheslineLayout.capacity(width: panel?.frame.width ?? 1000)
    }

    // MARK: 鼠标驱动（30Hz 轮询，对齐参照实现）

    /// 鼠标位置用 30Hz Timer 轮询而非 mouseMoved monitor：静止的鼠标不产生
    /// 事件，「菜单栏停留 0.25s」的判定在 monitor 驱动下永远等不到下一次
    /// tick，必须晃一下才触发（体感不灵敏）。轮询仅在绳子在场（wanted）时
    /// 运行，空闲零开销。mouseDown 走 monitor（点击必产生事件）。
    private func startMouseTracking() {
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(mouse: NSEvent.mouseLocation) }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
    }

    private func installMouseMonitors() {
        mouseMonitors.append(contentsOf: [
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.menuBarClicked() }
            }),
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] e in
                MainActor.assumeIsolated { self?.menuBarClicked() }
                return e
            }),
        ].compactMap { $0 })
    }

    private func menuBarClicked() {
        let p = NSEvent.mouseLocation
        guard NSScreen.screens.contains(where: { Self.menuBarBand(of: $0).contains(p) }) else { return }
        menuBarSuppressed = true
        hotZoneSince = nil
        if manager.revealed {
            pinned = false
            setRevealed(false)
        }
    }

    private func tick(mouse: NSPoint) {
        let now = Date()
        let screenUnderPointer = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let inMenuBar = screenUnderPointer.map { Self.menuBarBand(of: $0).contains(mouse) } ?? false
        if !inMenuBar { menuBarSuppressed = false }

        guard manager.revealed else {
            if let screen = screenUnderPointer, inMenuBar, !menuBarSuppressed,
               !FullScreenSpaceDetector.isActive(on: screen) {
                hotZoneSince = hotZoneSince ?? now
                if Self.shouldRevealFromMenuBar(inMenuBar: true, suppressed: false,
                                                hotZoneSince: hotZoneSince, now: now) {
                    hotZoneSince = nil
                    if panel?.screen !== screen {
                        panel?.placeOnScreen(screen)
                        updateCapacity()
                    }
                    refresh()
                    reveal()
                }
            } else {
                hotZoneSince = nil
            }
            return
        }

        updateMousePassThrough(mouse)

        var zone = panel?.frame ?? .zero
        if let screen = panel?.screen { zone.size.height = screen.frame.maxY - zone.minY }
        let inside = NSMouseInRect(mouse, zone, false)
        if inside, pinned { pinned = false }

        let busy = pinned || GrabPhotoView.isDragging || manager.pressedID != nil || now < peekUntil
        if inside || busy {
            awaySince = nil
        } else {
            awaySince = awaySince ?? now
            if Self.shouldRetract(inside: false, busy: busy, awaySince: awaySince, now: now) {
                awaySince = nil
                setRevealed(false)
            }
        }
    }

    /// 整条面板默认穿透；仅光标落在照片命中区（±4pt 容差）才接收鼠标。
    private func updateMousePassThrough(_ mouse: NSPoint) {
        guard let panel, !GrabPhotoView.isDragging else { return }
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        let overPhoto = manager.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
        if panel.ignoresMouseEvents == overPhoto {
            panel.ignoresMouseEvents = !overPhoto
        }
    }

    private func installKeyObserver() {
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideForControlCenter() }
        }
    }

    // MARK: 飞行与掉落

    /// 新捕获：从截取区域起飞。无区域信息（如拖入目录的旧文件）直接落位。
    func hangCapture(_ url: URL) {
        var from: CGRect?
        if let main = NSScreen.screens.first {
            from = ScreenCaptureMetadata.captureGlobalRect(url, mainScreenMaxY: main.frame.maxY)
        }
        if let from {
            let center = CGPoint(x: from.midX, y: from.midY)
            pendingScreen = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
        }
        guard let id = manager.hang(url, flying: from != nil) else { return }
        guard let from else { return }
        // 等绳落下、布局稳定后再量落位。
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000)
            self?.fly(id: id, from: from)
        }
    }

    /// 管线 hang 意图入口（自家截图）：直接挂 + 已知起点。
    func hangFromPipeline(path: String, origin: NSPoint?) {
        let url = URL(fileURLWithPath: path)
        manager.noteOwnWrite(path)
        guard let id = manager.hang(url, flying: origin != nil) else { return }
        guard let origin, let thumb = manager.items.first(where: { $0.id == id })?.thumb,
              let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let screen = panel?.screen
        else { manager.land(id); return }
        // 起点矩形：origin 为选区左下角，尺寸按缩略图纵横比近似。
        let pointSize = CGSize(width: thumb.size.width / 4, height: thumb.size.height / 4)
        let from = CGRect(origin: origin, size: pointSize)
        Task { [weak self, manager] in
            try? await Task.sleep(nanoseconds: 30_000_000)
            // 落地兜底：manager 由外部注入，生命周期可长于本协调者。
            // 若经 self?.manager.land 的可选链调用，self 已释放时 land 会被静默跳过，
            // item 将永久停留在 flying 状态（卡在半空、无法掉落）。
            // 故闭包直接捕获 manager，保证任何失败路径都执行落地。
            guard let self, let to = self.cardFrame(for: id) else {
                manager.land(id)
                return
            }
            self.animator.fly(image: cg, from: from, to: to,
                              tilt: CGFloat(manager.items.first { $0.id == id }?.tilt ?? 0),
                              on: screen) { [manager] in manager.land(id) }
        }
    }

    private func fly(id: UUID, from: CGRect) {
        guard isPresent, manager.revealed, let screen = panel?.screen,
              let to = cardFrame(for: id),
              let item = manager.items.first(where: { $0.id == id }),
              let cg = item.thumb.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            manager.land(id)
            return
        }
        // 完成回调捕获 manager 而非 self：协调者先释放也要保证落地（land 必达）。
        animator.fly(image: cg, from: from, to: to, tilt: CGFloat(item.tilt), on: screen) { [manager] in
            manager.land(id)
        }
    }

    private func fall(_ item: PeggedPhoto) {
        guard isPresent, manager.revealed, !item.flying, let screen = panel?.screen,
              let card = cardFrame(for: item.id),
              let cg = item.thumb.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        animator.fall(image: cg, card: card, tilt: CGFloat(item.tilt), on: screen)
    }

    /// 卡片落位（屏幕坐标），与视图同一套布局数学。
    private func cardFrame(for id: UUID) -> CGRect? {
        guard let panel,
              let index = manager.items.firstIndex(where: { $0.id == id })
        else { return nil }
        let width = panel.frame.width
        let x = ClotheslineLayout.x(index: index, count: manager.items.count, width: width)
        let viewTop = ClotheslineLayout.ropeY(x: x, width: width) - ClotheslineLayout.pinAbove
        let size = PeggedPhotoView.cardSize(for: manager.items[index].thumb.size)
        return CGRect(x: panel.frame.minX + x - size.width / 2,
                      y: panel.frame.maxY - viewTop - size.height,
                      width: size.width, height: size.height)
    }

    // MARK: 终止信号兜底还原（普通 kill 不走 applicationWillTerminate）

    private func installSignalRestore() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            // 事件处理器指定主队列：还原 Inbox 与 exit(0) 在主线程串行执行，
            // 避免与 @MainActor 的设置写入竞争 cfprefsd。
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                if self?.inbox.isEnabled == true { self?.inbox.restore() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func removeMonitors() {
        stopMouseTracking()
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        mouseMonitors.removeAll()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
    }
}

/// 管线钩子桥：weak 持协调器。断环不变量（T5 裁定）：
/// `pipeline.clotheslineHooks` 为 strong（防桥被释放），桥内必须 weak 协调器，
/// 否则 pipeline → 桥 → coordinator → … → pipeline 成环，teardown 永不释放。
final class ClotheslinePipelineHooksBridge: ClotheslinePipelineHooks {
    private weak var coordinator: ClotheslineCoordinator?

    init(coordinator: ClotheslineCoordinator) {
        self.coordinator = coordinator
    }

    func noteOwnWrite(path: String) {
        MainActor.assumeIsolated { coordinator?.noteOwnWrite(path) }
    }

    func hangFromPipeline(path: String, origin: NSPoint?) {
        MainActor.assumeIsolated { coordinator?.hangFromPipeline(path: path, origin: origin) }
    }
}
