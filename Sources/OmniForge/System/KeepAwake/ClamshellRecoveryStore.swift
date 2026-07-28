import Foundation

/// 合盖恢复记录安全存储。
/// 生产根目录：`~/Library/Application Support/app.omniforge`
/// 测试必须注入临时根目录。
final class ClamshellRecoveryStore {
    static let relativeDirectory = "KeepAwake"
    static let fileName = "clamshell-recovery.json"

    private let rootDirectory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameter applicationSupportRoot: Application Support 下的 app 根目录（不含 KeepAwake）。
    init(
        applicationSupportRoot: URL,
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = applicationSupportRoot
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    /// 生产默认路径。
    static func production() throws -> ClamshellRecoveryStore {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("app.omniforge", isDirectory: true)
        return ClamshellRecoveryStore(applicationSupportRoot: root)
    }

    var directoryURL: URL {
        rootDirectory.appendingPathComponent(Self.relativeDirectory, isDirectory: true)
    }

    var fileURL: URL {
        directoryURL.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    /// 读取并校验记录；文件不存在返回 nil。
    func load(
        expectedUID: uid_t,
        expectedUserName: String,
        expectedBundleID: String = ClamshellSupport.expectedBundleIdentifier
    ) throws -> ClamshellRecoveryRecord? {
        let url = fileURL
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        try validateFileSecurity(at: url)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw KeepAwakeError.recoveryRecordReadFailed(error.localizedDescription)
        }
        let record: ClamshellRecoveryRecord
        do {
            record = try decoder.decode(ClamshellRecoveryRecord.self, from: data)
        } catch {
            throw KeepAwakeError.recoveryRecordReadFailed("corrupt JSON: \(error.localizedDescription)")
        }
        switch record.validate(
            expectedUID: expectedUID,
            expectedUserName: expectedUserName,
            expectedBundleID: expectedBundleID
        ) {
        case .success:
            return record
        case .failure(let error):
            throw error
        }
    }

    /// 原子写入：临时文件 → fsync → rename。
    func save(_ record: ClamshellRecoveryRecord) throws {
        try ensureSecureDirectory()
        let target = fileURL
        // 若目标存在，必须仍是安全普通文件。
        if fileManager.fileExists(atPath: target.path) {
            try validateFileSecurity(at: target)
        }

        let data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            throw KeepAwakeError.recoveryRecordWriteFailed("encode failed: \(error.localizedDescription)")
        }

        let temp = directoryURL.appendingPathComponent(
            ".\(Self.fileName).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        do {
            try data.write(to: temp, options: .atomic)
            // 再以显式句柄 fsync，确保落盘语义可测。
            let handle = try FileHandle(forWritingTo: temp)
            defer { try? handle.close() }
            if #available(macOS 10.15, *) {
                try handle.synchronize()
            } else {
                handle.synchronizeFile()
            }
            // 原子替换目标。
            if fileManager.fileExists(atPath: target.path) {
                _ = try fileManager.replaceItemAt(target, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: target)
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: target.path
            )
        } catch let error as KeepAwakeError {
            try? fileManager.removeItem(at: temp)
            throw error
        } catch {
            try? fileManager.removeItem(at: temp)
            throw KeepAwakeError.recoveryRecordWriteFailed(error.localizedDescription)
        }
    }

    /// 仅允许删除已完整校验且事务确认完成的记录。
    func deleteValidatedRecord(
        expectedUID: uid_t,
        expectedUserName: String,
        expectedBundleID: String = ClamshellSupport.expectedBundleIdentifier
    ) throws {
        // 先 load 校验；失败则拒绝删除。
        _ = try load(
            expectedUID: expectedUID,
            expectedUserName: expectedUserName,
            expectedBundleID: expectedBundleID
        )
        let url = fileURL
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw KeepAwakeError.recoveryRecordWriteFailed("delete failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Security

    private func ensureSecureDirectory() throws {
        let dir = directoryURL
        if !fileManager.fileExists(atPath: rootDirectory.path) {
            try fileManager.createDirectory(
                at: rootDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try validateDirectorySecurity(at: dir)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    private func validateDirectorySecurity(at url: URL) throws {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw KeepAwakeError.recoveryRecordWriteFailed("recovery directory missing")
        }
        let values = try url.resourceValues(forKeys: [
            .isSymbolicLinkKey,
            .isDirectoryKey,
        ])
        if values.isSymbolicLink == true {
            throw KeepAwakeError.recoveryRecordWriteFailed("recovery directory is a symlink")
        }
    }

    private func validateFileSecurity(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .isSymbolicLinkKey,
            .isRegularFileKey,
        ])
        if values.isSymbolicLink == true {
            throw KeepAwakeError.recoveryRecordReadFailed("recovery file is a symlink")
        }
        if values.isRegularFile != true {
            throw KeepAwakeError.recoveryRecordReadFailed("recovery path is not a regular file")
        }
    }
}
