import AppKit
import XCTest
@testable import OmniForge

/// 录屏静默保存（配置目录直存）失败时的数据安全行为：
/// 已录制的临时 MP4 必须保留、在访达中定位并给出失败 toast；
/// 对照成功路径：临时文件正常移动到配置目录且不触发访达定位。
/// 该协调器此前零测试，本套件补齐保存失败/成功两条关键回归。
@MainActor
final class RecordingSessionCoordinatorTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private var workDirectory: URL!
    private var recordedFileURL: URL!
    private var saveDirectory: URL!
    private var revealedURLs: [[URL]] = []
    private var presentedMessages: [String] = []
    private var coordinator: RecordingSessionCoordinator!

    private let testSuiteName = "RecordingSessionCoordinatorTests"
    private let filePayload = Data("recorded-mp4-payload".utf8)

    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaults().removePersistentDomain(forName: testSuiteName)
        userDefaults = UserDefaults(suiteName: testSuiteName)!

        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingSessionCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        // 模拟引擎已产出的临时录制文件。
        recordedFileURL = workDirectory.appendingPathComponent("tmp-recording.mp4")
        try filePayload.write(to: recordedFileURL)

        // 配置「静默保存到目录 + MP4」偏好，跳过格式选择弹窗直达保存流程。
        saveDirectory = workDirectory.appendingPathComponent("recordings", isDirectory: true)
        userDefaults.set(saveDirectory.path, forKey: UserDefaultsKeys.recordingSaveDirectoryPath)
        RecordingOutputConfiguration(userDefaults: userDefaults).setSavePreference(.mp4)
    }

    override func tearDownWithError() throws {
        coordinator = nil
        if FileManager.default.fileExists(atPath: workDirectory.path) {
            try? FileManager.default.removeItem(at: workDirectory)
        }
        UserDefaults().removePersistentDomain(forName: testSuiteName)
        try super.tearDownWithError()
    }

    /// 用抛错的目录保障 fake 构建协调器：静默保存阶段即失败。
    private func makeCoordinatorWithFailingDirectoryCreation() {
        let throwingManager = DirectoryCreationThrowingFileManager()
        throwingManager.createDirectoryError = CocoaError(.fileWriteUnknown)
        makeCoordinator(fileManager: throwingManager)
    }

    private func makeCoordinator(fileManager: FileManager) {
        revealedURLs = []
        presentedMessages = []
        let coordinator = RecordingSessionCoordinator(
            userDefaults: userDefaults,
            stringsProvider: { .en },
            fileManager: fileManager,
            suppressesWindowDisplay: true
        ) { urls in
            self.revealedURLs.append(urls)
        }
        coordinator.onStatusPresented = { message in
            self.presentedMessages.append(message)
        }
        self.coordinator = coordinator
    }

    func test_saveDirectoryFailure_keepsTmpFileAndRevealsInFinder() throws {
        makeCoordinatorWithFailingDirectoryCreation()

        // 录制引擎完成回调落点：静默保存因目录创建抛错而失败。
        coordinator.finishRecording(url: recordedFileURL, error: nil)

        // 核心：已录制内容不得被删除（回归断言，旧实现直接删掉临时文件）。
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: recordedFileURL.path),
            "保存失败后临时 MP4 必须保留，避免录制内容丢失"
        )
        // 在访达中定位保留的临时文件（对齐 GIF 失败路径）。
        XCTAssertEqual(revealedURLs.count, 1)
        XCTAssertEqual(revealedURLs.first, [recordedFileURL])
        // 失败 toast 仍需提示用户。
        XCTAssertEqual(presentedMessages.count, 1)
        XCTAssertTrue(
            presentedMessages.first?.hasPrefix(Strings.en.recordingFailedFormat.split(separator: "%").first.map(String.init) ?? "") == true,
            "应展示失败 toast，实际为 \(presentedMessages)"
        )
    }

    func test_saveSuccess_movesTmpFileIntoConfiguredDirectory() throws {
        makeCoordinator(fileManager: .default)

        coordinator.finishRecording(url: recordedFileURL, error: nil)

        // 成功路径：临时文件移动（而非复制）到配置目录，内容不丢失。
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: recordedFileURL.path),
            "保存成功后临时文件应已被移动"
        )
        let savedFiles = try FileManager.default.contentsOfDirectory(at: saveDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mp4" }
        XCTAssertEqual(savedFiles.count, 1, "配置目录中应恰好出现一个 MP4 文件")
        XCTAssertEqual(try Data(contentsOf: savedFiles[0]), filePayload)
        // 成功不应触发访达定位。
        XCTAssertTrue(revealedURLs.isEmpty)
        XCTAssertEqual(presentedMessages.count, 1)
    }
}

/// 目录保障 fake：`createDirectory` 按注入的错误抛出，其余走真实实现，
/// 以驱动 `ensureDirectory` 失败并命中静默保存的 catch 分支。
private final class DirectoryCreationThrowingFileManager: FileManager {
    var createDirectoryError: Error?

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]?
    ) throws {
        if let createDirectoryError {
            throw createDirectoryError
        }
        try super.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
    }
}
