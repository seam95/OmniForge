import Foundation

/// 改名（InputLock → OmniForge）一次性数据迁移工具。
///
/// 老版本把用户数据写在 `~/Library/Application Support/InputLock/...` 等以 `InputLock`
/// 为字面量的目录下，与 bundle id 解耦。改名后这些路径统一改为 `OmniForge`。
/// 本工具在新目录不存在、旧目录存在时整体搬迁一次；失败不阻断启动（保留旧数据供手动恢复）。
enum LegacyDataMigrator {
    /// 将 `legacy` 目录整体移动到 `target`。
    /// - 仅当 `target` 不存在且 `legacy` 存在时执行。
    /// - 移动失败只记日志，不抛错，避免阻断 app 启动。
    static func migrateDirectory(from legacy: URL, to target: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path) else { return }
        guard !fm.fileExists(atPath: target.path) else { return }

        // 确保父目录存在后再搬迁。
        let parent = target.deletingLastPathComponent()
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)

        do {
            try fm.moveItem(at: legacy, to: target)
        } catch {
            // 迁移失败不阻断：用户可手动从旧路径恢复。这里不接入 Logger 以避免循环依赖。
            FileHandle.standardError.write(
                Data("OmniForge 数据迁移失败：\(legacy.path) → \(target.path)：\(error)\n".utf8)
            )
        }
    }
}
