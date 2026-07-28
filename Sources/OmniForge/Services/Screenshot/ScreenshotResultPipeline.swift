import AppKit
import Foundation
import os.log

/// 管线内部副作用
enum ScreenshotPipelineSideEffect: Equatable, Sendable {
    case copy
    case save
    case pin
}

enum ScreenshotPipelineError: Error, Equatable {
    case intentNotImplemented(ScreenshotEntryIntent)
    case encodingFailed(String)
    case directoryCreationFailed(String)
    case writeFailed(String)
    case invalidFileNamePrefix(String)
    case pasteboardEmptyPayload
    case pasteboardWriteFailed
    case unsupportedFormat(String)
    case pinServiceUnavailable
    case pinFailed(String)
}

struct ScreenshotPipelineOutcome: Equatable, Sendable {
    var didCopy: Bool
    var savedFilePath: String?
    var didPin: Bool
    var pinnedID: UUID?

    init(
        didCopy: Bool = false,
        savedFilePath: String? = nil,
        didPin: Bool = false,
        pinnedID: UUID? = nil
    ) {
        self.didCopy = didCopy
        self.savedFilePath = savedFilePath
        self.didPin = didPin
        self.pinnedID = pinnedID
    }
}

protocol ScreenshotPinning: AnyObject {
    /// 钉住截图结果。`at` 为可选的屏幕原点（AppKit 坐标），
    /// 非 nil 时按原位钉住（参照 capcap `PinLauncher.pin(image:at:)`）。
    @discardableResult
    func pinFromPipeline(result: ScreenshotResult, at origin: NSPoint?) throws -> UUID
}

extension ScreenshotPinning {
    /// 兼容旧调用：不带原点，退回各实现默认定位（居中）。
    @discardableResult
    func pinFromPipeline(result: ScreenshotResult) throws -> UUID {
        try pinFromPipeline(result: result, at: nil)
    }
}

/// 截图结果管线（最小可编译桩，task-5 正式重写）。
final class ScreenshotResultPipeline {
    private static let logger = Logger(subsystem: "com.omniforge.app", category: "ScreenshotPipeline")

    private let pasteboard: PasteboardWriting
    private let userDefaults: UserDefaults
    weak var pinService: ScreenshotPinning?

    init(
        pasteboard: PasteboardWriting = SystemPasteboardWriter(),
        userDefaults: UserDefaults = .standard
    ) {
        self.pasteboard = pasteboard
        self.userDefaults = userDefaults
    }

    @discardableResult
    func runAsync(result: ScreenshotResult, intent: ScreenshotEntryIntent) async throws -> ScreenshotPipelineOutcome {
        throw ScreenshotPipelineError.intentNotImplemented(intent)
    }

    @discardableResult
    func run(result: ScreenshotResult, intent: ScreenshotEntryIntent) throws -> ScreenshotPipelineOutcome {
        throw ScreenshotPipelineError.intentNotImplemented(intent)
    }

    static func sideEffects(for intent: ScreenshotEntryIntent) throws -> [ScreenshotPipelineSideEffect] {
        switch intent {
        case .copy: return [.copy]
        case .save: return [.save]
        case .pin: return [.pin]
        case .drag: throw ScreenshotPipelineError.intentNotImplemented(intent)
        }
    }
}
