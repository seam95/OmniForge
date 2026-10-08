import AppKit
import Combine
import SwiftUI

/// 飞行/掉落动画出口（真身 Task 10；测试注入替身）。
protocol CaptureFlightAnimating: AnyObject {
    func fly(image: CGImage, from: CGRect, to: CGRect, tilt: CGFloat, on screen: NSScreen,
             completion: @escaping () -> Void)
    func fall(image: CGImage, card: CGRect, tilt: CGFloat, on screen: NSScreen)
}

/// Task 10 前的空实现：只完成落地回调，不画动画。
final class NoopCaptureFlightAnimator: CaptureFlightAnimating {
    func fly(image: CGImage, from: CGRect, to: CGRect, tilt: CGFloat, on screen: NSScreen,
             completion: @escaping () -> Void) { completion() }
    func fall(image: CGImage, card: CGRect, tilt: CGFloat, on screen: NSScreen) {}
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
    private let inbox: ScreenshotInboxSettings
    private let outputConfiguration: ScreenshotOutputConfiguration
    private let animator: CaptureFlightAnimating
    private let userDefaults: UserDefaults
    private var panel: ClotheslinePanel?
    private var cancellables = Set<AnyCancellable>()
    private var mouseMonitors: [Any] = []
    private var keyObserver: NSObjectProtocol?
    private var signalSources: [DispatchSourceSignal] = []
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
         animator: CaptureFlightAnimating = NoopCaptureFlightAnimator()) {
        self.userDefaults = userDefaults
        self.manager = manager
        self.watcher = watcher
        self.inbox = inbox
        self.outputConfiguration = outputConfiguration
        self.animator = animator
        super.init()
    }

    // MARK: 生命周期

    func start() {
        let host = NSHostingView(rootView: ClotheslineView(manager: manager))
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
    }

    func teardown() {
        if inbox.isEnabled { inbox.restore() }
        watcher.stop()
        removeMonitors()
        panel?.orderOut(nil)
        panel = nil
        cancellables.removeAll()
        wanted = false
        isPresent = false
        manager.revealed = false
    }

    /// 总开关 / 保存目录 / Inbox 变化后的统一重挂点。
    func syncWithPreferences() {
        let enabled = userDefaults.object(forKey: UserDefaultsKeys.screenshotClotheslineEnabled) == nil
            ? true   // 默认开（拍板 1a）
            : userDefaults.bool(forKey: UserDefaultsKeys.screenshotClotheslineEnabled)
        guard enabled else {
            if inbox.isEnabled { inbox.restore() }
            watcher.stop()
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
        } else {
            // 未接管：监听系统截图落点（默认桌面，带标记过滤）。
            let folder = systemScreenshotFolder()
            let isDesktop = folder.standardizedFileURL.path
                == ScreenshotSaver.defaultDirectory.standardizedFileURL.path
            watcher.start(folder: folder, desktopOnlyTagged: isDesktop,
                          onNew: { [weak self] in self?.hangCapture($0) },
                          onChange: { [weak self] in self?.manager.prune() })
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

    private func reapplyInboxIfNeeded() {
        inbox.apply(targetDirectory: saveDirectory)   // 目录变化后重写接管（幂等）
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

    // MARK: 鼠标驱动（monitor 版，无轮询）

    private func installMouseMonitors() {
        let moved: (NSEvent?) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.tick(mouse: event?.locationInWindow ?? NSEvent.mouseLocation) }
        }
        // global monitor 无 locationInWindow 语义，统一取全局 mouseLocation。
        let globalMoved: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(mouse: NSEvent.mouseLocation) }
        }
        mouseMonitors.append(contentsOf: [
            NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: globalMoved),
            NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { moved($0); return $0 }),
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
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000)
            guard let self, let to = self.cardFrame(for: id) else { self?.manager.land(id); return }
            self.animator.fly(image: cg, from: from, to: to,
                              tilt: CGFloat(manager.items.first { $0.id == id }?.tilt ?? 0),
                              on: screen) { [weak self] in self?.manager.land(id) }
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
        animator.fly(image: cg, from: from, to: to, tilt: CGFloat(item.tilt), on: screen) { [weak self] in
            self?.manager.land(id)
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
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        mouseMonitors.removeAll()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
    }
}
