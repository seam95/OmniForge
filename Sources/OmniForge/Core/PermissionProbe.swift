import ApplicationServices
import CoreGraphics
import Foundation
import Security

enum PermissionSignatureKind: String, Equatable {
    case stable
    case adHoc = "ad-hoc"
    case unsigned
}

/// 权限诊断只公开签名类型、bundle identifier 与 team identifier，不包含证书或路径信息。
struct PermissionSignatureSummary: Equatable {
    let kind: PermissionSignatureKind
    let identifier: String
    let teamIdentifier: String?

    init(kind: PermissionSignatureKind, identifier: String, teamIdentifier: String? = nil) {
        self.kind = kind
        self.identifier = identifier
        self.teamIdentifier = teamIdentifier
    }
}

protocol PermissionProbing: AnyObject {
    var accessibilityGranted: Bool { get }
    var inputMonitoringGranted: Bool { get }
    var screenRecordingGranted: Bool { get }
    var signatureSummary: PermissionSignatureSummary { get }
}

final class SystemPermissionProbe: PermissionProbing {
    var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    var inputMonitoringGranted: Bool {
        CGPreflightListenEventAccess()
    }

    var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    var signatureSummary: PermissionSignatureSummary {
        CodeSignatureInspector.current()
    }
}

enum CodeSignatureInspector {
    /// Security/CSCommon.h 的 kSecCodeSignatureAdhoc；该 C 常量未桥接到 Swift。
    private static let adHocSignatureFlag: UInt32 = 0x0002

    static func current() -> PermissionSignatureSummary {
        let fallbackIdentifier = Bundle.main.bundleIdentifier ?? "unknown"
        guard let executableURL = Bundle.main.executableURL else {
            return PermissionSignatureSummary(kind: .unsigned, identifier: fallbackIdentifier)
        }

        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(executableURL as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            return PermissionSignatureSummary(kind: .unsigned, identifier: fallbackIdentifier)
        }

        var signingInformation: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        )
        guard informationStatus == errSecSuccess,
              let information = signingInformation as? [CFString: Any] else {
            return PermissionSignatureSummary(kind: .unsigned, identifier: fallbackIdentifier)
        }

        let identifier = information[kSecCodeInfoIdentifier] as? String ?? fallbackIdentifier
        let teamIdentifier = information[kSecCodeInfoTeamIdentifier] as? String
        let rawFlags = (information[kSecCodeInfoFlags] as? NSNumber)?.uint32Value ?? 0
        let isAdHoc = rawFlags & adHocSignatureFlag != 0

        return PermissionSignatureSummary(
            kind: isAdHoc ? .adHoc : .stable,
            identifier: identifier,
            teamIdentifier: teamIdentifier
        )
    }
}
