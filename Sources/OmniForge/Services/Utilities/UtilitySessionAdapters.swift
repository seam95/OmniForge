import Foundation

struct UtilityPathFailure: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let message: String

    init(id: UUID = UUID(), url: URL, message: String) {
        self.id = id
        self.url = url
        self.message = message
    }

    static func == (lhs: UtilityPathFailure, rhs: UtilityPathFailure) -> Bool {
        lhs.url == rhs.url && lhs.message == rhs.message
    }
}

extension Array where Element == UtilityPathFailure {
    func deduplicatedByPathAndMessage() -> [UtilityPathFailure] {
        var seen = Set<String>()
        return filter { failure in
            seen.insert("\(failure.url.standardizedFileURL.path)\u{0}\(failure.message)").inserted
        }
    }
}

struct UtilityFileOperationOutcome: Equatable {
    let url: URL
    let errorMessage: String?

    static func success(_ url: URL) -> Self {
        Self(url: url, errorMessage: nil)
    }

    static func failure(_ url: URL, error: Error) -> Self {
        Self(url: url, errorMessage: error.localizedDescription)
    }

    static func failure(_ url: URL, message: String) -> Self {
        Self(url: url, errorMessage: message)
    }
}

protocol UtilityFileOperating {
    /// 先逐项使用 FileManager；无权限项目集中交给 Finder 一次处理，最后逐项核实。
    func moveToTrash(_ urls: [URL]) -> [UtilityFileOperationOutcome]
    func emptyTrash(at url: URL) -> UtilityFileOperationOutcome
}

final class DefaultUtilityFileOperator: UtilityFileOperating {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func moveToTrash(_ urls: [URL]) -> [UtilityFileOperationOutcome] {
        var outcomes: [UtilityFileOperationOutcome] = []
        var finderCandidates: [(url: URL, originalError: Error)] = []

        for url in urls {
            do {
                try fileManager.trashItem(at: url, resultingItemURL: nil)
                outcomes.append(.success(url))
            } catch {
                finderCandidates.append((url, error))
            }
        }

        guard !finderCandidates.isEmpty else { return outcomes }
        let finderError = trashViaFinder(finderCandidates.map(\.url))
        for candidate in finderCandidates {
            if !fileManager.fileExists(atPath: candidate.url.path) {
                outcomes.append(.success(candidate.url))
            } else if let finderError {
                outcomes.append(.failure(candidate.url, message: finderError))
            } else {
                outcomes.append(.failure(candidate.url, error: candidate.originalError))
            }
        }
        return outcomes
    }

    func emptyTrash(at url: URL) -> UtilityFileOperationOutcome {
        guard AppleScriptRunner.consentToAutomate(bundleID: "com.apple.finder") else {
            return .failure(url, message: "未获得 Finder 自动化权限")
        }
        let result = AppleScriptRunner.run("tell application \"Finder\" to empty trash")
        guard result.ok else {
            return .failure(url, message: result.output.isEmpty ? "Finder 清空废纸篓失败" : result.output)
        }
        return .success(url)
    }

    /// 返回 Finder 批处理本身的真实错误；成功后由调用方逐项核实路径是否仍存在。
    private func trashViaFinder(_ urls: [URL]) -> String? {
        guard AppleScriptRunner.consentToAutomate(bundleID: "com.apple.finder") else {
            return "未获得 Finder 自动化权限"
        }
        let targets = urls
            .map { "set end of targets to POSIX file \(AppleScriptRunner.literal($0.path))" }
            .joined(separator: "\n")
        let source = """
        set targets to {}
        \(targets)
        tell application "Finder" to delete targets
        """
        let result = AppleScriptRunner.run(source)
        guard !result.ok else { return nil }
        return result.output.isEmpty ? "Finder 移到废纸篓失败" : result.output
    }
}

protocol UtilityFileReading {
    func fileExists(at url: URL) -> Bool
    func isDirectory(at url: URL) throws -> Bool
    func directoryEntries(at url: URL) throws -> [URL]
    func allocatedSize(at url: URL) throws -> Int64
    func allocatedSize(at url: URL, cancellation: CleanerScanCancellation) throws -> Int64
}

extension UtilityFileReading {
    func allocatedSize(at url: URL, cancellation: CleanerScanCancellation) throws -> Int64 {
        try cancellation.checkCancellation()
        let size = try allocatedSize(at: url)
        try cancellation.checkCancellation()
        return size
    }
}

final class DefaultUtilityFileReader: UtilityFileReading {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func isDirectory(at url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    }

    func directoryEntries(at url: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
    }

    func allocatedSize(at url: URL) throws -> Int64 {
        try allocatedSizeImpl(at: url, cancellation: nil)
    }

    func allocatedSize(at url: URL, cancellation: CleanerScanCancellation) throws -> Int64 {
        try allocatedSizeImpl(at: url, cancellation: cancellation)
    }

    private func allocatedSizeImpl(
        at url: URL,
        cancellation: CleanerScanCancellation?
    ) throws -> Int64 {
        try cancellation?.checkCancellation()
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { return try fileSize(url) }

        var firstError: Error?
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [],
            errorHandler: { _, error in
                if firstError == nil { firstError = error }
                return false
            }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        var total: Int64 = 0
        for case let item as URL in enumerator {
            try cancellation?.checkCancellation()
            do {
                total += try fileSize(item)
            } catch {
                firstError = firstError ?? error
                break
            }
        }
        try cancellation?.checkCancellation()
        if let firstError { throw firstError }
        return total
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }
}
