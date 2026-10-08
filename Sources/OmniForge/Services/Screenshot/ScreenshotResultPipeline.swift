import AppKit
import Foundation
import os.log

/// 管线内部副作用
enum ScreenshotPipelineSideEffect: Equatable, Sendable {
    case copy
    case save
    case pin
    case hangOnLine
}

enum ScreenshotPipelineError: Error, Equatable {
    case intentNotImplemented(ScreenshotEntryIntent)
    case encodingFailed(String)
    case directoryCreationFailed(String)
    case writeFailed(String)
    case invalidFileNamePrefix(String)
    case saveEmptyPayload
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

/// 晾衣绳管线钩子：save 落盘登记排除集（watcher 不得自动挂绳）；hang 意图直接挂绳。
/// 宿主是晾衣绳协调桥（不反向强持管线），pipeline → hooks 单向无环。
protocol ClotheslinePipelineHooks: AnyObject {
    /// 所有经管线写盘的路径（save 与 hang）都要登记进自家排除集。
    func noteOwnWrite(path: String)
    /// hang 意图落盘完成后挂绳；origin 为可选屏幕原点（AppKit 坐标）。
    func hangFromPipeline(path: String, origin: NSPoint?)
}

/// 截图结果副作用出口（便于编辑器注入 fake 断言 intent）。
protocol ScreenshotResultRunning: AnyObject {
    @discardableResult
    func run(
        result: ScreenshotResult,
        intent: ScreenshotEntryIntent,
        pinOrigin: NSPoint?,
        hangOrigin: NSPoint?
    ) throws -> ScreenshotPipelineOutcome
}

extension ScreenshotResultRunning {
    /// 兼容旧签名：编辑器等既有调用不关心挂绳原点，透传 nil。
    @discardableResult
    func run(
        result: ScreenshotResult,
        intent: ScreenshotEntryIntent,
        pinOrigin: NSPoint?
    ) throws -> ScreenshotPipelineOutcome {
        try run(result: result, intent: intent, pinOrigin: pinOrigin, hangOrigin: nil)
    }
}

/// 截图结果管线：统一 copy / save / pin 副作用出口。
final class ScreenshotResultPipeline: ScreenshotResultRunning {
    private static let logger = Logger(subsystem: "com.omniforge.app", category: "ScreenshotPipeline")

    private let pasteboard: PasteboardWriting
    private let userDefaults: UserDefaults
    private let encoder: ImageOutputEncoding
    private let clipboardWriter: ClipboardImageWriting
    private let saver: ScreenshotSaving
    private let outputConfigurationProvider: () -> ScreenshotOutputConfigurationSnapshot

    /// 弱引用，避免 `PinnedScreenshotRegistry → pipeline → pinBridge → registry` 环。
    weak var pinService: ScreenshotPinning?

    /// 晾衣绳钩子。strong 而非 weak：宿主桥不反向强持管线，链路
    /// `pipeline → 晾衣绳桥 → (weak) coordinator` 单向无环；与 pinService
    /// 的 weak 断环理由（pinBridge 强持 registry，registry 又持管线）不同链路。
    var clotheslineHooks: ClotheslinePipelineHooks?

    init(
        pasteboard: PasteboardWriting = SystemPasteboardWriter(),
        userDefaults: UserDefaults = .standard,
        encoder: ImageOutputEncoding = ImageOutputEncoder(),
        clipboardWriter: ClipboardImageWriting = ClipboardImageWriter(),
        saver: ScreenshotSaving = ScreenshotSaver(),
        outputConfigurationProvider: (() -> ScreenshotOutputConfigurationSnapshot)? = nil
    ) {
        self.pasteboard = pasteboard
        self.userDefaults = userDefaults
        self.encoder = encoder
        self.clipboardWriter = clipboardWriter
        self.saver = saver
        // 默认从注入的 userDefaults 读输出配置；测试可覆写 provider。
        if let outputConfigurationProvider {
            self.outputConfigurationProvider = outputConfigurationProvider
        } else {
            let configuration = ScreenshotOutputConfiguration(userDefaults: userDefaults)
            self.outputConfigurationProvider = { configuration.load() }
        }
    }

    @discardableResult
    func runAsync(
        result: ScreenshotResult,
        intent: ScreenshotEntryIntent,
        pinOrigin: NSPoint? = nil,
        hangOrigin: NSPoint? = nil
    ) async throws -> ScreenshotPipelineOutcome {
        try run(result: result, intent: intent, pinOrigin: pinOrigin, hangOrigin: hangOrigin)
    }

    @discardableResult
    func run(
        result: ScreenshotResult,
        intent: ScreenshotEntryIntent,
        pinOrigin: NSPoint? = nil,
        hangOrigin: NSPoint? = nil
    ) throws -> ScreenshotPipelineOutcome {
        let effects = try Self.sideEffects(for: intent)
        var outcome = ScreenshotPipelineOutcome()
        // 编码结果缓存：同一 run 内多副作用只编码一次。
        var encodedOutput: EncodedImageOutput?

        for effect in effects {
            switch effect {
            case .copy:
                let output = try encodedOutput ?? encodeOnce(result: result)
                encodedOutput = output
                try performCopy(output: output)
                outcome.didCopy = true

            case .save:
                let output = try encodedOutput ?? encodeOnce(result: result)
                encodedOutput = output
                let path = try performSave(output: output)
                outcome.savedFilePath = path

            case .pin:
                let id = try performPin(result: result, origin: pinOrigin)
                outcome.didPin = true
                outcome.pinnedID = id

            case .hangOnLine:
                // 挂绳发生在 save 落盘之后（副作用序保证）；落盘失败不会走到这里。
                if let path = outcome.savedFilePath {
                    clotheslineHooks?.hangFromPipeline(path: path, origin: hangOrigin)
                }
            }
        }

        return outcome
    }

    static func sideEffects(for intent: ScreenshotEntryIntent) throws -> [ScreenshotPipelineSideEffect] {
        switch intent {
        case .copy: return [.copy]
        case .save: return [.save]
        case .pin: return [.pin]
        case .hang: return [.save, .hangOnLine]
        case .drag: throw ScreenshotPipelineError.intentNotImplemented(intent)
        }
    }

    // MARK: - 副作用

    /// 将 `CGImage` 转为物理像素尺寸的 `NSImage` 后编码，质量固定 `.original`。
    private func encodeOnce(result: ScreenshotResult) throws -> EncodedImageOutput {
        let cgImage = result.pixelImage
        let pixelSize = NSSize(width: cgImage.width, height: cgImage.height)
        let nsImage = NSImage(cgImage: cgImage, size: pixelSize)
        do {
            return try encoder.encode(image: nsImage, quality: .original)
        } catch let error as ScreenshotPipelineError {
            throw error
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            throw ScreenshotPipelineError.encodingFailed(message)
        }
    }

    private func performCopy(output: EncodedImageOutput) throws {
        guard clipboardWriter.writeImage(output) else {
            throw ScreenshotPipelineError.pasteboardWriteFailed
        }
    }

    private func performSave(output: EncodedImageOutput) throws -> String {
        let snapshot = outputConfigurationProvider()
        let fileName = ScreenshotSaver.timestampedFileName(
            prefix: snapshot.fileNamePrefix,
            quality: .original,
            date: Date()
        )
        do {
            let url = try saver.save(
                output: output,
                quality: .original,
                fileName: fileName,
                directory: snapshot.saveDirectory
            )
            // 所有经管线的写盘（save 与 hang）都登记排除集：
            // watcher 对自家写入只挂绳一次，避免 hang 意图双重挂载。
            clotheslineHooks?.noteOwnWrite(path: url.path)
            return url.path
        } catch let error as ScreenshotPipelineError {
            throw error
        } catch let error as ScreenshotSavingError {
            throw mapSavingError(error)
        } catch {
            throw ScreenshotPipelineError.writeFailed(String(describing: error))
        }
    }

    private func performPin(result: ScreenshotResult, origin: NSPoint?) throws -> UUID {
        guard let pinService else {
            throw ScreenshotPipelineError.pinServiceUnavailable
        }
        do {
            return try pinService.pinFromPipeline(result: result, at: origin)
        } catch let error as ScreenshotPipelineError {
            throw error
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            throw ScreenshotPipelineError.pinFailed(message)
        }
    }

    private func mapSavingError(_ error: ScreenshotSavingError) -> ScreenshotPipelineError {
        switch error {
        case let .directoryCreationFailed(path):
            return .directoryCreationFailed(path)
        case let .writeFailed(path):
            return .writeFailed(path)
        case .emptyPayload:
            return .saveEmptyPayload
        }
    }
}
