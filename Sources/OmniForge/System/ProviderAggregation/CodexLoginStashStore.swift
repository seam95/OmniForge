import Foundation

/// Codex 官方登录收纳边界 — 切往第三方聚合时把官方 `auth.json` 收起来，
/// 避免第三方 provider 抢占 Codex 的官方登录态；切回时还原。
protocol CodexLoginStashStoring: AnyObject {
    /// 磁盘上是否有可解析的官方登录。
    var hasNativeLogin: Bool { get }
    /// 收纳：有原生登录 → 移走并返回 true；无 → false（不动任何文件）。
    func stash() throws -> Bool
    /// 还原：无 stash → false；auth.json 已存在（用户重新登录过）→ false 且不动文件；
    /// 否则放回并返回 true。
    func restore() throws -> Bool
    /// 丢弃 stash（不存在则无事）。
    func discard() throws
}

/// 收纳实现：stash 文件与 auth.json 同放 Codex home 下。
final class CodexLoginStashStore: CodexLoginStashStoring {
    static let stashFileName = "codex-login-stash.json"

    private let authURL: URL
    private let stashURL: URL
    private let fileManager: FileManager

    init(authURL: URL, stashURL: URL, fileManager: FileManager = .default) {
        self.authURL = authURL
        self.stashURL = stashURL
        self.fileManager = fileManager
    }

    var hasNativeLogin: Bool {
        guard fileManager.fileExists(atPath: authURL.path) else { return false }
        // 复用只读解析能力，不复制解析逻辑；损坏 → 视为无有效登录。
        return (try? CodexAuthFileCredentialReader(authURL: authURL).readBundle()) != nil
    }

    func stash() throws -> Bool {
        guard hasNativeLogin else { return false }
        guard let data = try? Data(contentsOf: authURL) else { return false }
        // 先写 stash 再删原文件——中途崩溃至多两份并存，登录不丢。
        try AtomicFileWriter.write(data, to: stashURL, fileManager: fileManager)
        try? fileManager.removeItem(at: authURL)
        return true
    }

    func restore() throws -> Bool {
        guard fileManager.fileExists(atPath: stashURL.path) else { return false }
        // 用户重新登录过（auth.json 已存在）→ 不覆盖新登录。
        guard !fileManager.fileExists(atPath: authURL.path) else { return false }
        guard let data = try? Data(contentsOf: stashURL) else { return false }
        try AtomicFileWriter.write(data, to: authURL, fileManager: fileManager)
        try? fileManager.removeItem(at: stashURL)
        return true
    }

    func discard() throws {
        guard fileManager.fileExists(atPath: stashURL.path) else { return }
        try fileManager.removeItem(at: stashURL)
    }
}
