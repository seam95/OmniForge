import Foundation
import IOKit.pwr_mgt

/// 断言类型；token 对外暴露类型而非裸系统 ID。
enum PowerAssertionKind: String, Equatable {
    case system
    case display
}

/// 持有系统断言 ID 的不透明 token；所有权属于 Manager。
struct PowerAssertionToken: Equatable, Hashable {
    let kind: PowerAssertionKind
    /// 系统断言 ID，仅适配器与 Manager 使用。
    let assertionID: IOPMAssertionID
}

/// 可注入的 IOPM 函数表，便于单元测试。
struct PowerAssertionAPI {
    var createWithName: (
        _ type: CFString,
        _ level: IOPMAssertionLevel,
        _ name: CFString,
        _ assertionID: UnsafeMutablePointer<IOPMAssertionID>
    ) -> IOReturn

    var release: (_ assertionID: IOPMAssertionID) -> IOReturn

    static let live = PowerAssertionAPI(
        createWithName: { type, level, name, idPtr in
            IOPMAssertionCreateWithName(type, level, name, idPtr)
        },
        release: { id in
            IOPMAssertionRelease(id)
        }
    )
}

protocol PowerAssertionControlling: AnyObject {
    func acquireSystemAssertion(reason: String) throws -> PowerAssertionToken
    func acquireDisplayAssertion(reason: String) throws -> PowerAssertionToken
    func release(_ token: PowerAssertionToken) throws
}

/// IOPM 断言适配器：不缓存业务状态，token 所有权属于 Manager。
final class PowerAssertionController: PowerAssertionControlling {
    private let api: PowerAssertionAPI

    init(api: PowerAssertionAPI = .live) {
        self.api = api
    }

    func acquireSystemAssertion(reason: String) throws -> PowerAssertionToken {
        try acquire(
            kind: .system,
            type: kIOPMAssertionTypeNoIdleSleep as CFString,
            reason: reason
        )
    }

    func acquireDisplayAssertion(reason: String) throws -> PowerAssertionToken {
        try acquire(
            kind: .display,
            type: kIOPMAssertionTypeNoDisplaySleep as CFString,
            reason: reason
        )
    }

    func release(_ token: PowerAssertionToken) throws {
        let status = api.release(token.assertionID)
        guard status == kIOReturnSuccess else {
            throw KeepAwakeError.assertionReleaseFailed(
                kind: token.kind.rawValue,
                code: status
            )
        }
    }

    private func acquire(
        kind: PowerAssertionKind,
        type: CFString,
        reason: String
    ) throws -> PowerAssertionToken {
        var assertionID: IOPMAssertionID = 0
        let status = api.createWithName(
            type,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        guard status == kIOReturnSuccess else {
            switch kind {
            case .system:
                throw KeepAwakeError.systemAssertionFailed(code: status)
            case .display:
                throw KeepAwakeError.displayAssertionFailed(code: status)
            }
        }
        return PowerAssertionToken(kind: kind, assertionID: assertionID)
    }
}
