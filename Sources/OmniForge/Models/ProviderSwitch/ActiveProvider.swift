import Foundation

/// 激活供应商 — 其连接值当前已写入目标工具配置文件的那个 profile。
/// 是指向 0..1 个 profile 的状态指针，不是独立实体（SPEC 2.2）。
enum ActiveProvider: Equatable {
    /// 官方：配置文件中无第三方 override（Claude 无 `ANTHROPIC_BASE_URL`；
    /// Codex 无自定义 `model_provider`）。选中它的实现是删除 override，而非写入新值。
    case official
    /// 当前激活的是某个 profile（其连接值已写入目标工具配置）。
    case profile(profileID: String)
    /// 未托管配置：目标配置文件里存在、但匹配不到任何 profile 的供应商设置（SPEC 2.6）。
    case unmanaged(summary: String)
    /// 目标配置文件 JSON/TOML 损坏 → 不硬写，提示「备份并重建」（SPEC 2.8.2）。
    case unreadable

    var profileID: String? {
        if case .profile(let id) = self { return id }
        return nil
    }

    var isOfficial: Bool { self == .official }
}
