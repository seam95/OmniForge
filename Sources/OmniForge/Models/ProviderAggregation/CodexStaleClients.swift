import Foundation

/// Codex 陈旧客户端检测结果 — daemon（托管守护进程）与 others（其余 app-server 客户端）
/// 分别报告，界面据此给不同的重启指引；`loginChanged` 走登录代次（文件身份变了），
/// `unverified` 表示进程表不可得（看不到有没有客户端开着）。
struct CodexStaleClients: Equatable, Codable {
    let daemon: Bool
    let others: Bool
    /// 文件登录的身份变了，进程可能还缓存着旧账号（推断，非确认）——映射 cc-switch
    /// `codex_client_catalog.rs:70-72` `StaleClients.auth`。
    let loginChanged: Bool
    /// 进程表不可得（`ps` 读不出）时的降级信号——映射 cc-switch `:74-76` `unverified`。
    /// 此时 `others` 只表示「用户上次确认后目录或登录变了」，不知是否开着。
    /// macOS 上 `ps` 可读，正常情况恒 false。
    let unverified: Bool

    init(daemon: Bool, others: Bool, loginChanged: Bool = false, unverified: Bool = false) {
        self.daemon = daemon
        self.others = others
        self.loginChanged = loginChanged
        self.unverified = unverified
    }

    /// 手写 decoder：老负载（只有 `daemon`/`others` 两个键）缺键不抛，缺省 false。
    /// 合成 `Codable` 对缺键抛 `keyNotFound`——`AggregationStack.ToolStack` 同款坑。
    private enum CodingKeys: String, CodingKey {
        case daemon, others, loginChanged, unverified
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        daemon = try container.decode(Bool.self, forKey: .daemon)
        others = try container.decode(Bool.self, forKey: .others)
        loginChanged = try container.decodeIfPresent(Bool.self, forKey: .loginChanged) ?? false
        unverified = try container.decodeIfPresent(Bool.self, forKey: .unverified) ?? false
    }
}

/// 用户上次确认（关掉陈旧横幅）时的目录与登录指纹 — 指纹再变才重现提示
/// （对齐 cc-switch `codex_client_catalog.rs:98-104` `Acknowledged {catalog, login?}`）。
struct CodexStaleClientAck: Codable, Equatable {
    let catalog: String
    let login: String

    private enum CodingKeys: String, CodingKey {
        case catalog, login
    }

    init(catalog: String, login: String) {
        self.catalog = catalog
        self.login = login
    }

    /// 手写 decoder：老负载没有 `login` 键（那时还没有登录代次）时按「无登录」算。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        catalog = try container.decode(String.self, forKey: .catalog)
        login = try container.decodeIfPresent(String.self, forKey: .login) ?? CodexFingerprint.missing
    }
}

/// 一次目录代记录：代写入时刻（epoch ms）+ 目录字节指纹（非我方目录记 `"none"`）。
/// 登录代次复用同一形态（`codex-login-history.json`，指纹 = auth.json 字节）。
struct CodexCatalogGeneration: Codable, Equatable {
    let sinceMs: Int64
    let fingerprint: String
}

/// 指纹口径：文件缺失/不可读时的占位（对齐 cc-switch `codex_client_catalog.rs:46` `NO_CATALOG`）。
enum CodexFingerprint {
    static let missing = "none"
}
