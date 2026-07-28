import Combine
import Foundation

/// 全局合盖恢复状态；始终装载，独立于 Feature availability。
enum ClamshellRecoveryUIState: Equatable {
    case idle
    case checking
    case recovering
    case recovered
    case cleanupRequired(KeepAwakeError)
    case conflict(String)
}

/// 启动/退出/Feature 卸载共用的恢复协调器。
@MainActor
final class ClamshellRecoveryCoordinator: ObservableObject {
    @Published private(set) var state: ClamshellRecoveryUIState = .idle
    @Published private(set) var blocksKeepAwakeStart: Bool = true

    private let store: ClamshellRecoveryStore
    private let controller: ClamshellControlling
    private let userName: String
    private let uid: uid_t
    private var inFlight = false

    init(
        store: ClamshellRecoveryStore,
        controller: ClamshellControlling,
        userName: String,
        uid: uid_t
    ) {
        self.store = store
        self.controller = controller
        self.userName = userName
        self.uid = uid
    }

    /// 启动时优先执行；完成前 blocksKeepAwakeStart=true。
    func recoverOnLaunch() async {
        await runRecovery(context: "launch")
    }

    /// 同步 compose 等跳过 `recoverOnLaunch` 的路径：解除默认启动门禁。
    /// 生产启动必须走 `recoverOnLaunch`，不得用此方法代替恢复。
    func releaseStartGateWithoutRecovery() {
        guard state == .idle else { return }
        blocksKeepAwakeStart = false
    }

    func retry() async {
        await runRecovery(context: "retry")
    }

    func prepareForApplicationTermination() async -> Bool {
        await runRecovery(context: "termination")
        switch state {
        case .recovered, .idle:
            return true
        default:
            return false
        }
    }

    func prepareForFeatureUninstall() async -> Bool {
        await runRecovery(context: "uninstall")
        switch state {
        case .recovered, .idle:
            return true
        default:
            return false
        }
    }

    /// Feature unavailable 时仍可移除当前 UID 的受限 sudoers 授权。
    /// 移除前要求 SleepDisabled 已为 0（由 Controller 强制）。
    func removeAuthorization() async throws {
        guard !inFlight else {
            throw KeepAwakeError.operationInProgress
        }
        inFlight = true
        defer { inFlight = false }
        try await controller.removeAuthorization()
    }

    private func runRecovery(context: String) async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        state = .checking
        blocksKeepAwakeStart = true

        let record: ClamshellRecoveryRecord?
        do {
            record = try store.load(expectedUID: uid, expectedUserName: userName)
        } catch let error as KeepAwakeError {
            state = .cleanupRequired(error)
            blocksKeepAwakeStart = true
            return
        } catch {
            state = .cleanupRequired(.recoveryRecordReadFailed(String(describing: error)))
            blocksKeepAwakeStart = true
            return
        }

        let actual: Int?
        do {
            actual = try await controller.readSleepDisabled()
        } catch {
            // 无记录时：若也无记录，可放行；有记录则 cleanupRequired。
            if record == nil {
                state = .recovered
                blocksKeepAwakeStart = false
            } else {
                state = .cleanupRequired(.clamshellStateUnverified("SleepDisabled unreadable during \(context)"))
                blocksKeepAwakeStart = true
            }
            return
        }

        let action = ClamshellSupport.recoveryAction(
            phase: record?.phase,
            actualSleepDisabled: actual,
            recordValid: record != nil,
            restoreTargetIsZero: record?.restoreTargetSleepDisabled == 0 || record == nil
        )

        switch action {
        case .deleteRecord:
            do {
                try store.deleteValidatedRecord(expectedUID: uid, expectedUserName: userName)
                state = .recovered
                blocksKeepAwakeStart = false
            } catch let error as KeepAwakeError {
                state = .cleanupRequired(error)
                blocksKeepAwakeStart = true
            } catch {
                state = .cleanupRequired(.recoveryRecordWriteFailed(String(describing: error)))
                blocksKeepAwakeStart = true
            }

        case .restoreToZero:
            state = .recovering
            do {
                // 写前：phase=restoring
                if var rec = record {
                    rec.phase = .restoring
                    try store.save(rec)
                }
                try await controller.setSleepDisabled(0, allowPasswordPrompt: false)
                try store.deleteValidatedRecord(expectedUID: uid, expectedUserName: userName)
                state = .recovered
                blocksKeepAwakeStart = false
            } catch let error as KeepAwakeError {
                state = .cleanupRequired(error)
                blocksKeepAwakeStart = true
            } catch {
                state = .cleanupRequired(.sleepRestoreFailed(String(describing: error)))
                blocksKeepAwakeStart = true
            }

        case .conflict(let reason):
            state = .conflict(reason)
            blocksKeepAwakeStart = true

        case .refuse(let reason):
            if record == nil, actual == 0 || actual == nil {
                state = .recovered
                blocksKeepAwakeStart = false
            } else if record == nil {
                state = .conflict(reason)
                blocksKeepAwakeStart = true
            } else {
                state = .cleanupRequired(.recoveryRecordReadFailed(reason))
                blocksKeepAwakeStart = true
            }
        }
    }
}
