import Foundation
import GRDB

// MARK: - 凭证包与读取边界

/// Cursor 凭证包 — 从本地只读，永不落盘副本（SPEC 2.6：凭证只用不存）。
struct CursorAuthBundle: Equatable {
    /// `state.vscdb → ItemTable → cursorAuth/accessToken` 的 JWT。
    var jwt: String
    /// WorkOS subject 标准化后的 userId（`user_XXXXX` 或 `<provider>|<id>`）。
    var userId: String
    /// 拼好的会话 cookie：`WorkosCursorSessionToken=<userId>%3A%3A<jwt>`（参考 08/cursor-config.js:97）。
    var sessionCookie: String
}

/// Cursor 凭证读取边界（参考 04：探测与读秘密在同一文件读取完成）。
protocol CursorCredentialReading: AnyObject {
    /// state.vscdb 缺失 / JWT 缺失或过短 / userId 不可得 → nil（未配置）；读库异常同样降级未配置。
    func readBundle() throws -> CursorAuthBundle?
}

/// `state.vscdb`（SQLite ItemTable）+ `~/.cursor/cli-config.json`（authInfo.authId）。
///
/// 读取即用即弃：JWT 只在内存中用于拼 cookie，绝不写盘副本（隐私红线，SPEC 2.6）。
/// userId 来源：cli-config.json 优先，JWT `sub` 兜底（参考 extractCursorSessionToken）。
final class CursorVSCDBCredentialReader: CursorCredentialReading {
    let stateDBPath: URL
    let cliConfigPath: URL
    private let fileManager: FileManager

    /// 默认路径解析（参考 resolveCursorPaths / cursor-config.js:29-30）：
    /// `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`、
    /// `~/.cursor/cli-config.json`。
    static func defaultStateDBPath(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> URL {
        URL(fileURLWithPath: homePath)
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb", isDirectory: false)
    }

    static func defaultCLIConfigPath(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> URL {
        URL(fileURLWithPath: homePath).appendingPathComponent(".cursor/cli-config.json", isDirectory: false)
    }

    init(
        stateDBPath: URL = CursorVSCDBCredentialReader.defaultStateDBPath(),
        cliConfigPath: URL = CursorVSCDBCredentialReader.defaultCLIConfigPath(),
        fileManager: FileManager = .default
    ) {
        self.stateDBPath = stateDBPath
        self.cliConfigPath = cliConfigPath
        self.fileManager = fileManager
    }

    /// 是否构造时使用了真实用户路径（采集器单测环境防探针判断）。
    var usesDefaultPaths: Bool {
        stateDBPath == CursorVSCDBCredentialReader.defaultStateDBPath()
            && cliConfigPath == CursorVSCDBCredentialReader.defaultCLIConfigPath()
    }

    func readBundle() throws -> CursorAuthBundle? {
        guard fileManager.fileExists(atPath: stateDBPath.path) else { return nil }
        guard let jwt = Self.readAccessToken(from: stateDBPath, fileManager: fileManager),
              jwt.count >= 10 else {
            return nil
        }
        var userId = Self.readUserId(fromCLIConfig: cliConfigPath, fileManager: fileManager)
        if userId == nil {
            userId = CursorSubjectNormalizer.fromJWT(jwt)
        }
        guard let userId else { return nil }
        return CursorAuthBundle(
            jwt: jwt,
            userId: userId,
            sessionCookie: CursorSessionCookieBuilder.cookie(userId: userId, jwt: jwt)
        )
    }

    /// 只读打开 SQLite 取 `cursorAuth/accessToken`；文件不存在/读失败 → nil（降级未配置）。
    /// read-only：绝不写 WAL/journal，避免与运行中的 Cursor 互写。
    static func readAccessToken(from stateDBPath: URL, fileManager: FileManager = .default) -> String? {
        guard fileManager.fileExists(atPath: stateDBPath.path) else { return nil }
        var configuration = Configuration()
        configuration.readonly = true
        do {
            let queue = try DatabaseQueue(path: stateDBPath.path, configuration: configuration)
            return try queue.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT value FROM ItemTable WHERE key = ?",
                    arguments: ["cursorAuth/accessToken"]
                )
            }
        } catch {
            // 读库失败（被锁/损坏/未知 schema）：降级未配置，不打扰用户。
            return nil
        }
    }

    static func readUserId(fromCLIConfig cliConfigPath: URL, fileManager: FileManager = .default) -> String? {
        guard fileManager.fileExists(atPath: cliConfigPath.path) else { return nil }
        guard let data = try? Data(contentsOf: cliConfigPath),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let authInfo = root["authInfo"] as? [String: Any],
              let authId = authInfo["authId"] as? String else {
            return nil
        }
        return CursorSubjectNormalizer.normalize(authId)
    }
}

// MARK: - WorkOS subject 标准化（参考 cursor-config.js:95-124）

/// WorkOS subject 白名单：Cursor 会话 cookie 只接受 `user_` 原生 subject 或
/// WorkOS 桥接的带前缀 subject（google-oauth2/github/oidc/auth0），其余一律拒绝。
enum CursorSubjectNormalizer {
    private static let bridgePrefixes = ["google-oauth2", "github", "oidc", "auth0"]

    /// 原生 Cursor 账号：`auth0|user_XXXXX` → `user_XXXXX`；
    /// WorkOS 桥接：`<prefix>|<id>` 原样保留；其余 → nil。
    static func normalize(_ subject: String?) -> String? {
        guard let subject, !subject.isEmpty else { return nil }
        let nativePattern = "\\|user_[A-Za-z0-9_]+$" // 字面管道转义（裸 | 在正则里是或运算）
        if let match = subject.range(of: nativePattern, options: .regularExpression) {
            return String(subject[match].dropFirst())
        }
        if let prefix = bridgePrefixes.first(where: { subject.hasPrefix("\($0)|") }) {
            let id = subject.dropFirst(prefix.count + 1)
            guard !id.isEmpty, !id.contains("|") else { return nil }
            return subject
        }
        return nil
    }

    /// JWT payload `sub` → 标准化 userId（cli-config 兜底源）。
    static func fromJWT(_ jwt: String?) -> String? {
        guard let jwt else { return nil }
        guard let payload = JWTPayloadDecoder.decodePayload(jwt) else { return nil }
        guard let subject = payload["sub"] as? String else { return nil }
        return normalize(subject)
    }
}

// MARK: - 会话 cookie 拼装

/// `WorkosCursorSessionToken=<userId>%3A%3A<jwt>` — `%3A%3A` 即 `::` 的百分号编码，
/// 是 WorkOS 会话 cookie 的固定分隔符，原样保留（不二次转义 JWT）。
enum CursorSessionCookieBuilder {
    static func cookie(userId: String, jwt: String) -> String {
        "WorkosCursorSessionToken=\(userId)%3A%3A\(jwt)"
    }
}
