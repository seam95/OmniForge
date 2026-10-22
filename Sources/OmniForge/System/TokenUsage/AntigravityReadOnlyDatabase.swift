import Foundation
import SQLite3

/// Antigravity 会话库的只读快照读取（immutable 模式）。
///
/// 背景：Antigravity 的会话库是 WAL 模式。只读连接打开 WAL 库需要同目录的
/// `-shm` 文件；Antigravity 退出后 SQLite 会清理 `-shm`，此时只读打开失败
/// （SQLite error 14）。本读取器用 SQLite 的 `immutable=1` URI 打开主库，
/// 忽略不可用的 WAL 侧文件，覆盖「应用已退出」这一常态。
///
/// 只用于 GRDB 只读打开失败后的兜底；只管三张表的 BLOB 读取，不写任何文件。
final class AntigravityReadOnlyDatabase {
    private var handle: OpaquePointer?

    init?(url: URL) {
        var database: OpaquePointer?
        // 路径可能含空格/中文：SQLite 的 URI 文件名要求百分号编码。
        let encodedPath = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        let uri = "file:\(encodedPath)?immutable=1"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &database, flags, nil) == SQLITE_OK, let database else {
            sqlite3_close(database)
            return nil
        }
        handle = database
    }

    deinit {
        sqlite3_close(handle)
    }

    /// gen_metadata：idx + data BLOB（按 idx 升序）。
    func generationRows() -> [(sequence: Int, data: Data)]? {
        guard let handle else { return nil }
        var statement: OpaquePointer?
        let sql = "SELECT idx, data FROM gen_metadata WHERE data IS NOT NULL ORDER BY idx"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var rows: [(sequence: Int, data: Data)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 1) else { continue }
            let count = Int(sqlite3_column_bytes(statement, 1))
            rows.append((Int(sqlite3_column_int64(statement, 0)), Data(bytes: bytes, count: count)))
        }
        return rows
    }

    /// steps 表中模型轮次（step_type = 15）的 metadata BLOB；失败降级为空。
    func stepRows() -> [Data] {
        guard let handle else { return [] }
        var statement: OpaquePointer?
        let sql = "SELECT metadata FROM steps WHERE step_type = 15 AND metadata IS NOT NULL"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [Data] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            let count = Int(sqlite3_column_bytes(statement, 0))
            rows.append(Data(bytes: bytes, count: count))
        }
        return rows
    }

    /// 会话级元数据（trajectory_metadata_blob.id = 'main'）；失败降级为 nil。
    func trajectoryData() -> Data? {
        guard let handle else { return nil }
        var statement: OpaquePointer?
        let sql = "SELECT data FROM trajectory_metadata_blob WHERE id = 'main' AND data IS NOT NULL"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0) else {
            return nil
        }
        let count = Int(sqlite3_column_bytes(statement, 0))
        return Data(bytes: bytes, count: count)
    }
}
