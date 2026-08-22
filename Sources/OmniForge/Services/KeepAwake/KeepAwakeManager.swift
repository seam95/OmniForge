import AppKit
import Combine
import Foundation

/// 保持唤醒唯一会话状态源（普通会话 + 可选合盖子能力）。
@MainActor
final class KeepAwakeManager: ObservableObject {
    @Published private(set) var state: KeepAwakeSessionState = .inactive
    @Published private(set) var clamshellState: ClamshellState = .off
    @Published private(set) var lastOperationError: KeepAwakeError?
    @Published private(set) var batteryMonitoringError: KeepAwakeError?
    @Published private(set) var pointerActivityError: KeepAwakeError?
    @Published private(set) var notificationDeliveryError: KeepAwakeError?

    private let assertions: PowerAssertionControlling
    private let powerReader: KeepAwakePowerSourceReading
    private let scheduler: KeepAwakeScheduling
    private let clock: KeepAwakeClock
    private let notifications: UserNotificationPosting?
    private let pointerService: PointerActivityService?
    private let isFeatureAvailable: () -> Bool
    private let blocksStart: () -> Bool
    private let configuration: () throws -> KeepAwakeConfigurationSnapshot
    private let clamshellController: ClamshellControlling?
    private let clamshellStore: ClamshellRecoveryStore?
    private let clamshellUserName: String
    private let clamshellUID: uid_t

    private var generation: UInt64 = 0
    private var clamshellOperationID: String?
    private var endReason: KeepAwakeEndReason?
    private var systemToken: PowerAssertionToken?
    private var displayToken: PowerAssertionToken?
    private var deadlineTask: AnyCancellable?
    private var batteryTask: AnyCancellable?
    private var heartbeatTask: AnyCancellable?
    private var batteryLimit: KeepAwakeBatteryLimit = .percent10
    private var clamshellPreferredRuntime: Bool?
    private var powerObservers: [NSObjectProtocol] = []
    private var clockObservers: [NSObjectProtocol] = []

    init(
        assertions: PowerAssertionControlling,
        powerReader: KeepAwakePowerSourceReading,
        scheduler: KeepAwakeScheduling,
        clock: KeepAwakeClock,
        configuration: @escaping () throws -> KeepAwakeConfigurationSnapshot,
        notifications: UserNotificationPosting? = nil,
        pointerService: PointerActivityService? = nil,
        isFeatureAvailable: @escaping () -> Bool = { true },
        blocksStart: @escaping () -> Bool = { false },
        clamshellController: ClamshellControlling? = nil,
        clamshellStore: ClamshellRecoveryStore? = nil,
        clamshellUserName: String = NSUserName(),
        clamshellUID: uid_t = getuid()
    ) {
        self.assertions = assertions
        self.powerReader = powerReader
        self.scheduler = scheduler
        self.clock = clock
        self.configuration = configuration
        self.notifications = notifications
        self.pointerService = pointerService
        self.isFeatureAvailable = isFeatureAvailable
        self.blocksStart = blocksStart
        self.clamshellController = clamshellController
        self.clamshellStore = clamshellStore
        self.clamshellUserName = clamshellUserName
        self.clamshellUID = clamshellUID
        installDiagnosticsObservers()
        KeepAwakeDiagnostics.info(
            "manager.init featureAvailable=\(isFeatureAvailable()) blocksStart=\(blocksStart()) \(KeepAwakeDiagnostics.timeSnapshot(clockNow: clock.now))"
        )
    }

    deinit {
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in powerObservers {
            workspace.removeObserver(observer)
        }
        for observer in clockObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - 公开操作

    func start(duration: KeepAwakeDuration? = nil) {
        KeepAwakeDiagnostics.info(
            "start.request durationArg=\(duration.map { "\($0.minutes)m" } ?? "nil(useDefault)") state=\(KeepAwakeDiagnostics.describeSession(state, now: clock.now)) \(KeepAwakeDiagnostics.timeSnapshot(clockNow: clock.now))"
        )
        switch KeepAwakeSessionSupport.decide(action: .start, state: state) {
        case .reject(let error):
            lastOperationError = error
            KeepAwakeDiagnostics.warning("start.reject decision=\(error)")
            return
        case .allow:
            break
        }

        guard isFeatureAvailable() else {
            lastOperationError = .featureUnavailable
            KeepAwakeDiagnostics.warning("start.reject featureUnavailable")
            return
        }
        guard !blocksStart() else {
            lastOperationError = .operationInProgress
            KeepAwakeDiagnostics.warning("start.reject blocksStart")
            return
        }

        let config: KeepAwakeConfigurationSnapshot
        do {
            config = try configuration()
        } catch let error as KeepAwakeError {
            lastOperationError = error
            KeepAwakeDiagnostics.error("start.configError \(error)")
            return
        } catch {
            lastOperationError = .invalidDuration(-1)
            KeepAwakeDiagnostics.error("start.configError unknown \(error)")
            return
        }

        let resolvedDuration = duration ?? config.defaultDuration
        batteryLimit = config.batteryLimit
        KeepAwakeDiagnostics.info(
            "start.resolved duration=\(resolvedDuration.minutes)m batteryLimit=\(batteryLimit.percent)% clamshellPreferred=\(config.clamshellPreferred) jiggle=\(config.mouseJiggleEnabled)"
        )

        // 启动前低电量检查：阈值非 0 时先读电源。
        if !batteryLimit.isDisabled {
            do {
                let snapshot = try powerReader.read()
                batteryMonitoringError = nil
                KeepAwakeDiagnostics.info(
                    "start.battery hasBattery=\(snapshot.hasBattery) onBattery=\(snapshot.isOnBattery) pct=\(snapshot.percentage.map(String.init) ?? "nil")"
                )
                if PowerSourceReader.shouldEndForLowBattery(snapshot: snapshot, limit: batteryLimit) {
                    lastOperationError = .batteryReadFailed("battery at or below limit before start")
                    KeepAwakeDiagnostics.warning("start.reject lowBatteryBeforeStart")
                    return
                }
            } catch let error as KeepAwakeError {
                lastOperationError = error
                KeepAwakeDiagnostics.error("start.batteryError \(error)")
                return
            } catch {
                lastOperationError = .batteryReadFailed(String(describing: error))
                KeepAwakeDiagnostics.error("start.batteryError \(error)")
                return
            }
        }

        generation &+= 1
        let gen = generation
        endReason = nil
        state = .activating
        lastOperationError = nil
        KeepAwakeDiagnostics.info("start.activating generation=\(gen)")

        do {
            let system = try assertions.acquireSystemAssertion(reason: "OmniForge KeepAwake System")
            systemToken = system
            KeepAwakeDiagnostics.info("start.assertion system id=\(system.assertionID)")
            do {
                let display = try assertions.acquireDisplayAssertion(reason: "OmniForge KeepAwake Display")
                displayToken = display
                KeepAwakeDiagnostics.info("start.assertion display id=\(display.assertionID)")
            } catch {
                // 第二断言失败：回滚第一断言。
                KeepAwakeDiagnostics.error("start.displayAssertionFailed \(error); rolling back system")
                try rollbackSystemToken(afterDisplayFailure: error, generation: gen)
                return
            }
        } catch let error as KeepAwakeError {
            clearTokensIfGeneration(gen)
            state = .inactive
            lastOperationError = error
            KeepAwakeDiagnostics.error("start.systemAssertionFailed \(error)")
            return
        } catch {
            clearTokensIfGeneration(gen)
            state = .inactive
            lastOperationError = .systemAssertionFailed(code: -1)
            KeepAwakeDiagnostics.error("start.systemAssertionFailed unknown \(error)")
            return
        }

        guard gen == generation else {
            // 过期 generation：补偿清理。
            KeepAwakeDiagnostics.warning("start.staleGeneration gen=\(gen) current=\(generation); cleanup")
            Task { await self.cleanupResources(reason: .manual, generation: gen, notify: false) }
            return
        }

        let endDate = KeepAwakeSessionSupport.initialEndDate(duration: resolvedDuration, now: clock.now)
        state = .active(endDate: endDate)
        KeepAwakeDiagnostics.info(
            "start.active generation=\(gen) endDate=\(endDate.map { String($0.timeIntervalSince1970) } ?? "nil") \(KeepAwakeDiagnostics.describeSession(state, now: clock.now)) \(KeepAwakeDiagnostics.timeSnapshot(clockNow: clock.now))"
        )
        scheduleDeadline(endDate, generation: gen)
        scheduleBatteryMonitoring(generation: gen)
        scheduleHeartbeat(generation: gen)
        syncPointerActivity(config: config, generation: gen)

        let preferClamshell = clamshellPreferredRuntime ?? config.clamshellPreferred
        if preferClamshell {
            KeepAwakeDiagnostics.info("start.clamshell enable requested generation=\(gen)")
            Task { await self.enableClamshellIfNeeded(generation: gen) }
        } else {
            clamshellState = .off
            KeepAwakeDiagnostics.info("start.clamshell off")
        }
    }

    /// 活动会话中根据最新配置即时同步指针微动（SPEC §5.8）；仅 active 生效。
    /// 配置非法时写入 lastOperationError / pointerActivityError 并停止微动，不静默吞错。
    /// 配置解析与同步成功后，清除此前由 resync/指针相关路径写入的 lastOperationError。
    func resyncPointerActivityFromConfiguration() {
        guard case .active = state else { return }
        do {
            let config = try configuration()
            syncPointerActivity(config: config, generation: generation)
            // 成功路径：只清指针/配置 resync 相关错误，不掩盖无关的 start/stop 错误。
            switch lastOperationError {
            case .invalidPointerInterval,
                 .accessibilityPermissionMissing,
                 .pointerEventFailed,
                 .invalidDuration,
                 .invalidBatteryLimit:
                lastOperationError = nil
            default:
                break
            }
        } catch {
            pointerService?.stop()
            if let keepAwakeError = error as? KeepAwakeError {
                pointerActivityError = keepAwakeError
                lastOperationError = keepAwakeError
            } else {
                let wrapped = KeepAwakeError.invalidPointerInterval(-1)
                pointerActivityError = wrapped
                lastOperationError = wrapped
            }
        }
    }

    /// 活动会话中即时开关合盖偏好；关闭时立即恢复 SleepDisabled。
    func setClamshellPreferred(_ preferred: Bool) async {
        clamshellPreferredRuntime = preferred
        guard case .active = state else { return }
        if preferred {
            await enableClamshellIfNeeded(generation: generation)
        } else {
            await restoreClamshellIfNeeded(generation: generation, markOffOnSuccess: true)
        }
    }

    /// 刷新合盖 capability（授权探测 + SleepDisabled）。
    func refreshClamshellCapability() async -> ClamshellCapability {
        guard let controller = clamshellController else {
            return .unsupported(reason: "clamshell controller unavailable")
        }
        return await controller.refreshCapability()
    }

    /// 用户显式确认后安装受限 sudoers 授权；设置页唯一安装入口。
    func installClamshellAuthorization() async throws {
        guard let controller = clamshellController else {
            throw KeepAwakeError.clamshellUnsupported("clamshell controller unavailable")
        }
        try await controller.installAuthorization()
    }

    /// 用户显式确认后移除当前 UID 的 sudoers 规则；要求 SleepDisabled 已为 0。
    func removeClamshellAuthorization() async throws {
        guard let controller = clamshellController else {
            throw KeepAwakeError.clamshellUnsupported("clamshell controller unavailable")
        }
        try await controller.removeAuthorization()
    }

    func stop(reason: KeepAwakeEndReason = .manual) {
        KeepAwakeDiagnostics.info(
            "stop.request reason=\(reason) state=\(KeepAwakeDiagnostics.describeSession(state, now: clock.now)) endReasonExisting=\(String(describing: endReason)) \(KeepAwakeDiagnostics.timeSnapshot(clockNow: clock.now))"
        )
        switch state {
        case .inactive:
            lastOperationError = .alreadyInactive
            KeepAwakeDiagnostics.warning("stop.reject alreadyInactive")
            return
        case .deactivating:
            lastOperationError = .operationInProgress
            KeepAwakeDiagnostics.warning("stop.reject alreadyDeactivating")
            return
        case .cleanupRequired:
            KeepAwakeDiagnostics.info("stop.redirect cleanupRequired -> retryCleanup")
            Task { await retryCleanup() }
            return
        case .activating, .active:
            break
        }

        guard KeepAwakeSessionSupport.shouldAcceptEndReason(
            currentState: state,
            existingEndReason: endReason
        ) else {
            lastOperationError = .operationInProgress
            KeepAwakeDiagnostics.warning("stop.reject shouldAcceptEndReason=false existing=\(String(describing: endReason))")
            return
        }

        endReason = reason
        let gen = generation
        state = .deactivating
        KeepAwakeDiagnostics.info("stop.deactivating generation=\(gen) reason=\(reason)")
        Task { await cleanupResources(reason: reason, generation: gen, notify: true) }
    }

    func toggle() {
        KeepAwakeDiagnostics.info("toggle state=\(KeepAwakeDiagnostics.describeSession(state, now: clock.now))")
        switch state {
        case .inactive:
            start()
        case .active:
            stop(reason: .manual)
        case .activating:
            stop(reason: .manual)
        case .deactivating, .cleanupRequired:
            lastOperationError = .operationInProgress
            KeepAwakeDiagnostics.warning("toggle.reject state=\(state)")
        }
    }

    func extend(byMinutes minutes: Int) {
        KeepAwakeDiagnostics.info(
            "extend.request +\(minutes)m state=\(KeepAwakeDiagnostics.describeSession(state, now: clock.now))"
        )
        guard case .allow = KeepAwakeSessionSupport.decide(action: .extend, state: state) else {
            lastOperationError = .operationInProgress
            KeepAwakeDiagnostics.warning("extend.reject decision")
            return
        }
        guard case let .active(currentEnd?) = state else {
            lastOperationError = .operationInProgress
            KeepAwakeDiagnostics.warning("extend.reject notTimedActive")
            return
        }
        let newEnd = KeepAwakeSessionSupport.extendedEndDate(
            currentEndDate: currentEnd,
            now: clock.now,
            extensionMinutes: minutes
        )
        state = .active(endDate: newEnd)
        KeepAwakeDiagnostics.info(
            "extend.applied oldEnd=\(currentEnd.timeIntervalSince1970) newEnd=\(newEnd.timeIntervalSince1970) \(KeepAwakeDiagnostics.describeSession(state, now: clock.now))"
        )
        scheduleDeadline(newEnd, generation: generation)
    }

    /// 在活动会话中即时切换或更新时长设定（无限期或指定分钟数）。
    func setDuration(_ duration: KeepAwakeDuration) {
        KeepAwakeDiagnostics.info(
            "setDuration.request duration=\(duration.minutes)m state=\(KeepAwakeDiagnostics.describeSession(state, now: clock.now))"
        )
        guard case .active = state else { return }
        let newEnd = KeepAwakeSessionSupport.initialEndDate(duration: duration, now: clock.now)
        state = .active(endDate: newEnd)
        KeepAwakeDiagnostics.info(
            "setDuration.applied newEnd=\(newEnd.map { String($0.timeIntervalSince1970) } ?? "nil") \(KeepAwakeDiagnostics.describeSession(state, now: clock.now))"
        )
        scheduleDeadline(newEnd, generation: generation)
    }

    func retryCleanup() async {
        guard case .cleanupRequired = state else {
            lastOperationError = .alreadyInactive
            return
        }
        let gen = generation
        state = .deactivating
        await cleanupResources(reason: endReason ?? .manual, generation: gen, notify: false)
    }

    /// Feature 卸载 / App 退出使用的同步清理入口。
    func shutdown(reason: KeepAwakeEndReason) async {
        if case .inactive = state { return }
        if endReason == nil {
            endReason = reason
        }
        let gen = generation
        state = .deactivating
        await cleanupResources(reason: reason, generation: gen, notify: false)
    }

    /// 墙钟已过截止但 DispatchTime 定时器可能因睡眠未触发时补结束。
    /// 在唤醒 / 时钟变化 / 心跳中调用；幂等，非过期 active 无操作。
    func reconcileExpiredDeadlineIfNeeded(trigger: String) {
        let now = clock.now
        guard KeepAwakeSessionSupport.shouldEndForExpiredDeadline(state: state, now: now) else {
            return
        }
        KeepAwakeDiagnostics.warning(
            "deadline.reconcile trigger=\(trigger) generation=\(generation) state=\(KeepAwakeDiagnostics.describeSession(state, now: now)) \(KeepAwakeDiagnostics.timeSnapshot(clockNow: now))"
        )
        stop(reason: .durationElapsed)
    }

    // MARK: - 内部

    private func rollbackSystemToken(afterDisplayFailure error: Error, generation gen: UInt64) throws {
        guard let system = systemToken else {
            state = .inactive
            lastOperationError = mapDisplayError(error)
            return
        }
        do {
            try assertions.release(system)
            systemToken = nil
            state = .inactive
            lastOperationError = mapDisplayError(error)
        } catch let releaseError as KeepAwakeError {
            // 回滚失败 → cleanupRequired，保留 system token。
            state = .cleanupRequired(.systemAssertion, releaseError)
            lastOperationError = releaseError
        } catch {
            state = .cleanupRequired(
                .systemAssertion,
                .assertionRollbackFailed(kind: "system", code: -1)
            )
            lastOperationError = .assertionRollbackFailed(kind: "system", code: -1)
        }
        _ = gen
    }

    private func mapDisplayError(_ error: Error) -> KeepAwakeError {
        if let keep = error as? KeepAwakeError { return keep }
        return .displayAssertionFailed(code: -1)
    }

    private func scheduleDeadline(_ endDate: Date?, generation gen: UInt64) {
        deadlineTask?.cancel()
        deadlineTask = nil
        guard let endDate else {
            KeepAwakeDiagnostics.info("deadline.clear indefinite generation=\(gen)")
            return
        }
        let now = clock.now
        let delay = endDate.timeIntervalSince(now)
        KeepAwakeDiagnostics.info(
            "deadline.schedule generation=\(gen) endDate=\(endDate.timeIntervalSince1970) wallDelay=\(String(format: "%.3f", delay))s \(KeepAwakeDiagnostics.timeSnapshot(clockNow: now))"
        )
        deadlineTask = scheduler.scheduleOnce(at: endDate) { [weak self] in
            guard let self else {
                KeepAwakeDiagnostics.warning("deadline.fire managerDeallocated generation=\(gen)")
                return
            }
            let current = self.generation
            let match = KeepAwakeSessionSupport.isCurrentGeneration(
                callbackGeneration: gen,
                currentGeneration: current
            )
            KeepAwakeDiagnostics.info(
                "deadline.fire generation=\(gen) current=\(current) match=\(match) state=\(KeepAwakeDiagnostics.describeSession(self.state, now: self.clock.now)) \(KeepAwakeDiagnostics.timeSnapshot(clockNow: self.clock.now))"
            )
            guard match else {
                KeepAwakeDiagnostics.warning("deadline.fire ignored stale generation=\(gen)")
                return
            }
            self.stop(reason: .durationElapsed)
        }
    }

    private func scheduleBatteryMonitoring(generation gen: UInt64) {
        batteryTask?.cancel()
        batteryTask = nil
        guard !batteryLimit.isDisabled else {
            KeepAwakeDiagnostics.info("battery.monitoring disabled generation=\(gen)")
            return
        }

        let check = { [weak self] in
            guard let self else { return }
            guard KeepAwakeSessionSupport.isCurrentGeneration(
                callbackGeneration: gen,
                currentGeneration: self.generation
            ) else { return }
            self.checkBattery(generation: gen)
        }
        // 活动后立即检查 + 每 30 秒（tolerance 5）。
        check()
        batteryTask = scheduler.scheduleRepeating(every: 30, tolerance: 5) {
            check()
        }
        KeepAwakeDiagnostics.info("battery.monitoring armed generation=\(gen) every=30s")
    }

    /// 活动会话心跳：每 15s 打一次墙钟/uptime/剩余时间，便于对照睡眠冻结。
    private func scheduleHeartbeat(generation gen: UInt64) {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        heartbeatTask = scheduler.scheduleRepeating(every: 15, tolerance: 1) { [weak self] in
            guard let self else { return }
            guard KeepAwakeSessionSupport.isCurrentGeneration(
                callbackGeneration: gen,
                currentGeneration: self.generation
            ) else { return }
            self.logHeartbeat(generation: gen)
        }
        KeepAwakeDiagnostics.info("heartbeat.armed generation=\(gen) every=15s")
    }

    private func logHeartbeat(generation gen: UInt64) {
        let now = clock.now
        var expiredNote = ""
        if KeepAwakeSessionSupport.shouldEndForExpiredDeadline(state: state, now: now) {
            expiredNote = " EXPIRED_BUT_STILL_ACTIVE"
            KeepAwakeDiagnostics.warning(
                "heartbeat.expiredStillActive generation=\(gen) state=\(KeepAwakeDiagnostics.describeSession(state, now: now)) \(KeepAwakeDiagnostics.timeSnapshot(clockNow: now))"
            )
        }
        KeepAwakeDiagnostics.info(
            "heartbeat generation=\(gen) state=\(KeepAwakeDiagnostics.describeSession(state, now: now)) clamshell=\(clamshellState) systemToken=\(systemToken != nil) displayToken=\(displayToken != nil)\(expiredNote) \(KeepAwakeDiagnostics.timeSnapshot(clockNow: now))"
        )
        // 安全网：即便唤醒通知丢失，心跳也会按墙钟补结束。
        reconcileExpiredDeadlineIfNeeded(trigger: "heartbeat")
    }

    private func checkBattery(generation gen: UInt64) {
        do {
            let snapshot = try powerReader.read()
            batteryMonitoringError = nil
            let shouldEnd = PowerSourceReader.shouldEndForLowBattery(snapshot: snapshot, limit: batteryLimit)
            KeepAwakeDiagnostics.info(
                "battery.check generation=\(gen) onBattery=\(snapshot.isOnBattery) pct=\(snapshot.percentage.map(String.init) ?? "nil") limit=\(batteryLimit.percent) shouldEnd=\(shouldEnd)"
            )
            if shouldEnd {
                stop(reason: .lowBattery)
            }
        } catch let error as KeepAwakeError {
            batteryMonitoringError = error
            KeepAwakeDiagnostics.error("battery.checkError \(error)")
        } catch {
            batteryMonitoringError = .batteryReadFailed(String(describing: error))
            KeepAwakeDiagnostics.error("battery.checkError \(error)")
        }
        _ = gen
    }

    private func installDiagnosticsObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        let powerNames: [NSNotification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.screensDidWakeNotification
        ]
        for name in powerNames {
            let observer = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in
                    self?.logSystemPowerEvent(note.name.rawValue)
                }
            }
            powerObservers.append(observer)
        }
        let clockNames: [NSNotification.Name] = [
            .NSSystemClockDidChange,
            .NSSystemTimeZoneDidChange
        ]
        for name in clockNames {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in
                    self?.logSystemPowerEvent(note.name.rawValue)
                }
            }
            clockObservers.append(observer)
        }
        KeepAwakeDiagnostics.info("diagnostics.observersInstalled power=\(powerNames.count) clock=\(clockNames.count)")
    }

    private func logSystemPowerEvent(_ name: String) {
        let now = clock.now
        let session = KeepAwakeDiagnostics.describeSession(state, now: now)
        KeepAwakeDiagnostics.info(
            "system.event \(name) generation=\(generation) state=\(session) clamshell=\(clamshellState) endReason=\(String(describing: endReason)) \(KeepAwakeDiagnostics.timeSnapshot(clockNow: now))"
        )
        if case let .active(endDate?) = state, endDate <= now {
            KeepAwakeDiagnostics.warning(
                "system.event.expiredStillActive event=\(name) endDate=\(endDate.timeIntervalSince1970) overdue=\(String(format: "%.1f", now.timeIntervalSince(endDate)))s — deadline timer may have been frozen during sleep"
            )
        }
        // 唤醒 / 时钟变化后立刻按墙钟对账；willSleep 时通常尚未过期，reconcile 为空操作。
        reconcileExpiredDeadlineIfNeeded(trigger: name)
    }

    private func syncPointerActivity(config: KeepAwakeConfigurationSnapshot, generation gen: UInt64) {
        guard let pointerService else { return }
        if config.mouseJiggleEnabled {
            pointerService.start(intervalMinutes: config.mouseJiggleInterval)
            pointerActivityError = pointerService.lastError
        } else {
            pointerService.stop()
            pointerActivityError = nil
        }
        _ = gen
    }

    private func cleanupResources(
        reason: KeepAwakeEndReason,
        generation gen: UInt64,
        notify: Bool
    ) async {
        KeepAwakeDiagnostics.info(
            "cleanup.begin generation=\(gen) reason=\(reason) notify=\(notify) \(KeepAwakeDiagnostics.timeSnapshot(clockNow: clock.now))"
        )
        // 取消任务（即使 generation 已变化也要清本 generation 的句柄）。
        deadlineTask?.cancel()
        deadlineTask = nil
        batteryTask?.cancel()
        batteryTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        pointerService?.stop()
        KeepAwakeDiagnostics.info("cleanup.tasksCancelled generation=\(gen)")

        var residual = KeepAwakeResidualEffects()
        var lastError: KeepAwakeError?

        // 合盖优先恢复，再释放 IOKit 断言。
        let clamshellError = await restoreClamshellIfNeeded(
            generation: gen,
            markOffOnSuccess: true
        )
        if let clamshellError {
            residual.insert(.clamshellSleepDisabled)
            lastError = clamshellError
            KeepAwakeDiagnostics.error("cleanup.clamshell residual \(clamshellError)")
        } else {
            KeepAwakeDiagnostics.info("cleanup.clamshell ok")
        }

        if let display = displayToken {
            do {
                try assertions.release(display)
                displayToken = nil
                KeepAwakeDiagnostics.info("cleanup.display released id=\(display.assertionID)")
            } catch let error as KeepAwakeError {
                residual.insert(.displayAssertion)
                lastError = error
                KeepAwakeDiagnostics.error("cleanup.display failed \(error)")
            } catch {
                residual.insert(.displayAssertion)
                lastError = .assertionReleaseFailed(kind: "display", code: -1)
                KeepAwakeDiagnostics.error("cleanup.display failed \(error)")
            }
        }

        if let system = systemToken {
            do {
                try assertions.release(system)
                systemToken = nil
                KeepAwakeDiagnostics.info("cleanup.system released id=\(system.assertionID)")
            } catch let error as KeepAwakeError {
                residual.insert(.systemAssertion)
                lastError = error
                KeepAwakeDiagnostics.error("cleanup.system failed \(error)")
            } catch {
                residual.insert(.systemAssertion)
                lastError = .assertionReleaseFailed(kind: "system", code: -1)
                KeepAwakeDiagnostics.error("cleanup.system failed \(error)")
            }
        }

        // 仅当前 generation 可写入最终状态。
        guard gen == generation else {
            KeepAwakeDiagnostics.warning("cleanup.staleGeneration gen=\(gen) current=\(generation); skip final state")
            return
        }

        let enteredCleanup = !residual.isEmpty
        if enteredCleanup {
            state = .cleanupRequired(residual, lastError ?? .assertionReleaseFailed(kind: "unknown", code: -1))
            self.lastOperationError = lastError
            KeepAwakeDiagnostics.error(
                "cleanup.done cleanupRequired residual=\(residual.rawValue) error=\(String(describing: lastError))"
            )
        } else {
            state = .inactive
            systemToken = nil
            displayToken = nil
            endReason = nil
            clamshellState = .off
            clamshellOperationID = nil
            KeepAwakeDiagnostics.info("cleanup.done inactive reason=\(reason) \(KeepAwakeDiagnostics.timeSnapshot(clockNow: clock.now))")
        }

        if notify {
            let decision = KeepAwakeSessionSupport.notificationDecision(
                endReason: reason,
                enteredCleanupRequired: enteredCleanup
            )
            KeepAwakeDiagnostics.info("cleanup.notify decision=\(decision)")
            deliverNotification(decision)
        }
    }

    // MARK: - 合盖

    /// 普通会话 active 后启用合盖；任一步失败只更新子状态，不结束普通会话。
    private func enableClamshellIfNeeded(generation gen: UInt64) async {
        guard gen == generation else { return }
        guard case .active = state else { return }
        guard let controller = clamshellController, let store = clamshellStore else {
            clamshellState = .off
            return
        }
        guard ClamshellSupport.isValidUsername(clamshellUserName) else {
            clamshellState = .failed(.clamshellUnsupported("invalid username"))
            return
        }

        clamshellState = .checking
        let operationID = UUID().uuidString
        clamshellOperationID = operationID

        let actual: Int
        do {
            actual = try await controller.readSleepDisabled()
        } catch let error as KeepAwakeError {
            guard gen == generation else { return }
            clamshellState = .failed(error)
            return
        } catch {
            guard gen == generation else { return }
            clamshellState = .failed(.clamshellStateUnverified(String(describing: error)))
            return
        }

        guard gen == generation, case .active = state else { return }

        let hasRecord: Bool
        do {
            hasRecord = try store.load(
                expectedUID: clamshellUID,
                expectedUserName: clamshellUserName
            ) != nil
        } catch {
            // 损坏记录：不写 1，报告冲突/失败。
            guard gen == generation else { return }
            clamshellState = .conflict(.recoveryRecordReadFailed(String(describing: error)))
            return
        }

        let baseline = ClamshellSupport.enableBaselineDecision(
            actualSleepDisabled: actual,
            hasMatchingPreparedOrEnabledRecord: hasRecord
        )
        switch baseline {
        case .ready:
            break
        case .conflict(let reason):
            guard gen == generation else { return }
            clamshellState = .conflict(.clamshellStateUnverified(reason))
            return
        case .unsupported(let reason):
            guard gen == generation else { return }
            clamshellState = .failed(.clamshellUnsupported(reason))
            return
        default:
            guard gen == generation else { return }
            clamshellState = .failed(.clamshellUnsupported("baseline not ready"))
            return
        }

        // 已是 1 且有匹配记录：视为已启用。
        if actual == 1, hasRecord {
            guard gen == generation else { return }
            clamshellState = .active
            return
        }

        clamshellState = .enabling
        var record = ClamshellRecoveryRecord.makePrepared(
            userName: clamshellUserName,
            uid: clamshellUID,
            operationID: operationID
        )
        do {
            try store.save(record)
        } catch let error as KeepAwakeError {
            guard gen == generation else { return }
            clamshellState = .failed(error)
            return
        } catch {
            guard gen == generation else { return }
            clamshellState = .failed(.recoveryRecordWriteFailed(String(describing: error)))
            return
        }

        guard gen == generation, case .active = state else { return }

        do {
            try await controller.setSleepDisabled(1, allowPasswordPrompt: false)
        } catch let error as KeepAwakeError {
            // prepared 已写：保留记录供启动恢复；普通会话继续。
            guard gen == generation else { return }
            clamshellState = .failed(error)
            return
        } catch {
            guard gen == generation else { return }
            clamshellState = .failed(.administratorCommandFailed(
                command: "pmset disablesleep 1",
                status: -1,
                output: String(describing: error)
            ))
            return
        }

        guard gen == generation else { return }

        record.phase = .enabled
        record.changedByInputLock = true
        do {
            try store.save(record)
            clamshellState = .active
        } catch let error as KeepAwakeError {
            // pmset 已成功但 enabled 写入失败：记录仍为 prepared+1，可恢复；子状态失败。
            clamshellState = .failed(error)
        } catch {
            clamshellState = .failed(.recoveryRecordWriteFailed(String(describing: error)))
        }
    }

    /// 恢复合盖副作用；返回错误表示残留未确认清理。
    @discardableResult
    private func restoreClamshellIfNeeded(
        generation gen: UInt64,
        markOffOnSuccess: Bool
    ) async -> KeepAwakeError? {
        guard let controller = clamshellController, let store = clamshellStore else {
            if markOffOnSuccess { clamshellState = .off }
            return nil
        }

        // 无记录且从未启用：直接 off。
        let record: ClamshellRecoveryRecord?
        do {
            record = try store.load(
                expectedUID: clamshellUID,
                expectedUserName: clamshellUserName
            )
        } catch let error as KeepAwakeError {
            clamshellState = .failed(error)
            return error
        } catch {
            let err = KeepAwakeError.recoveryRecordReadFailed(String(describing: error))
            clamshellState = .failed(err)
            return err
        }

        // 无记录且子状态也不是 active/enabling：无需恢复。
        if record == nil {
            switch clamshellState {
            case .active, .enabling, .restoring, .authorizing, .checking:
                break
            default:
                if markOffOnSuccess { clamshellState = .off }
                return nil
            }
        }

        if gen == generation {
            clamshellState = .restoring
        }

        let actual: Int
        do {
            actual = try await controller.readSleepDisabled()
        } catch let error as KeepAwakeError {
            if gen == generation { clamshellState = .failed(error) }
            return error
        } catch {
            let err = KeepAwakeError.clamshellStateUnverified(String(describing: error))
            if gen == generation { clamshellState = .failed(err) }
            return err
        }

        let action = ClamshellSupport.recoveryAction(
            phase: record?.phase,
            actualSleepDisabled: actual,
            recordValid: record != nil || actual == 0,
            restoreTargetIsZero: record?.restoreTargetSleepDisabled == 0 || record == nil
        )

        switch action {
        case .deleteRecord:
            do {
                if record != nil {
                    try store.deleteValidatedRecord(
                        expectedUID: clamshellUID,
                        expectedUserName: clamshellUserName
                    )
                }
                if gen == generation, markOffOnSuccess {
                    clamshellState = .off
                    clamshellOperationID = nil
                }
                return nil
            } catch let error as KeepAwakeError {
                if gen == generation { clamshellState = .failed(error) }
                return error
            } catch {
                let err = KeepAwakeError.recoveryRecordWriteFailed(String(describing: error))
                if gen == generation { clamshellState = .failed(err) }
                return err
            }

        case .restoreToZero:
            do {
                if var rec = record {
                    rec.phase = .restoring
                    try store.save(rec)
                }
                try await controller.setSleepDisabled(0, allowPasswordPrompt: false)
                if record != nil {
                    try store.deleteValidatedRecord(
                        expectedUID: clamshellUID,
                        expectedUserName: clamshellUserName
                    )
                }
                if gen == generation, markOffOnSuccess {
                    clamshellState = .off
                    clamshellOperationID = nil
                }
                return nil
            } catch let error as KeepAwakeError {
                if gen == generation { clamshellState = .failed(error) }
                return error
            } catch {
                let err = KeepAwakeError.sleepRestoreFailed(String(describing: error))
                if gen == generation { clamshellState = .failed(err) }
                return err
            }

        case .conflict(let reason):
            let err = KeepAwakeError.clamshellStateUnverified(reason)
            if gen == generation { clamshellState = .conflict(err) }
            return err

        case .refuse(let reason):
            // 无记录且 actual=0：可视为干净。
            if record == nil, actual == 0 {
                if gen == generation, markOffOnSuccess {
                    clamshellState = .off
                    clamshellOperationID = nil
                }
                return nil
            }
            let err = KeepAwakeError.clamshellStateUnverified(reason)
            if gen == generation { clamshellState = .failed(err) }
            return err
        }
    }

    private func deliverNotification(_ decision: KeepAwakeNotificationDecision) {
        guard let notifications else { return }
        let title = Strings.en.keepAwakeNotificationTitle
        let payload: (String, String)?
        switch decision {
        case .none:
            payload = nil
        case .sessionEnded(.durationElapsed):
            payload = (title, Strings.en.keepAwakeNotifDurationElapsed)
        case .sessionEnded(.lowBattery):
            payload = (title, Strings.en.keepAwakeNotifLowBattery)
        case .sessionEnded:
            payload = nil
        case .cleanupRequiredWarning(.durationElapsed):
            payload = (title, Strings.en.keepAwakeNotifCleanupDuration)
        case .cleanupRequiredWarning(.lowBattery):
            payload = (title, Strings.en.keepAwakeNotifCleanupLowBattery)
        case .cleanupRequiredWarning:
            payload = nil
        }
        guard let payload else { return }
        notifications.post(title: payload.0, body: payload.1) { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success:
                    self?.notificationDeliveryError = nil
                case .failure(let error):
                    self?.notificationDeliveryError = .notificationDeliveryFailed(error.localizedDescription)
                }
            }
        }
    }

    private func clearTokensIfGeneration(_ gen: UInt64) {
        guard gen == generation else { return }
        systemToken = nil
        displayToken = nil
    }
}
