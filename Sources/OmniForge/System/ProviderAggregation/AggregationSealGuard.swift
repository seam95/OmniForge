import CryptoKit
import Foundation

/// 跨供应商 reasoning/compaction 清洗 — 对齐 magpie 的 `withoutReasoning` /
/// `withoutCompaction` / `refusedSeals`。
///
/// Responses 历史里的 reasoning 和 compaction 都带 `encrypted_content`，只有写它的
/// 供应商（或同一账号组织）能读。会话从 A 家切到 B 家后，B 家会回
/// `invalid_encrypted_content` / “could not be verified”。Codex 每轮都会把历史原样
/// 带回，所以要么在转发前去掉已知被拒的 seal，要么在失败后去掉并重试一次。
enum AggregationSealSanitizer {
    /// 上游拒绝别家 seal 时的错误文本（大小写不敏感）。
    private static let foreignSealPattern = try! NSRegularExpression(
        pattern: #"invalid_encrypted_content|encrypted[ _]content.{0,80}could not be (verified|decrypted)|could not (decrypt|verify).{0,40}encrypted[ _]content"#,
        options: [.caseInsensitive]
    )

    /// Responses 里由供应商密封的 item 类型。
    static let sealedTypes: Set<String> = ["reasoning", "compaction", "compaction_summary"]
    static let compactionTypes: Set<String> = ["compaction", "compaction_summary"]

    /// 错误体是否表示“别家的密封内容读不了”。
    static func isForeignSealError(_ body: Data) -> Bool {
        guard let text = String(data: body, encoding: .utf8), !text.isEmpty else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return foreignSealPattern.firstMatch(in: text, range: range) != nil
    }

    /// 去掉所有 reasoning item（无论是否带密封内容）。
    static func removingReasoning(from body: Data) -> Data? {
        removingKinds(from: body, types: ["reasoning"])
    }

    /// 去掉 compaction / compaction_summary item。
    static func removingCompaction(from body: Data) -> Data? {
        removingKinds(from: body, types: compactionTypes)
    }

    /// 请求体里所有密封内容的 SHA-256 指纹（按 item 类型筛选）。
    static func seals(in body: Data, types: Set<String> = sealedTypes) -> [String] {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let items = object["input"] as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            guard let type = item["type"] as? String, types.contains(type),
                  let sealed = item["encrypted_content"] as? String, !sealed.isEmpty else {
                return nil
            }
            return sha256(sealed)
        }
    }

    struct Retry {
        let body: Data
        let seals: [String]
    }

    /// 根据错误体决定下一次重试的请求体（magpie 的顺序：先 reasoning，再 compaction）。
    /// `attempt` 0 = 第一次失败；1 = 去掉 reasoning 后仍失败；>=2 不再重试。
    static func retryBody(after body: Data, errorBody: Data, attempt: Int) -> Retry? {
        guard attempt <= 1, isForeignSealError(errorBody) else { return nil }
        var next: Data?
        if attempt == 0 {
            next = removingReasoning(from: body)
        }
        if next == nil {
            next = removingCompaction(from: body)
        }
        guard let next else { return nil }
        return Retry(body: next, seals: seals(in: body))
    }

    /// 去掉命中 `refused` 指纹的密封 item；没有变化 → nil。
    static func removingRefused(from body: Data, refused: Set<String>) -> Data? {
        guard !refused.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let items = object["input"] as? [[String: Any]] else {
            return nil
        }
        let kept = items.filter { item in
            guard let type = item["type"] as? String, sealedTypes.contains(type),
                  let sealed = item["encrypted_content"] as? String, !sealed.isEmpty else {
                return true
            }
            return !refused.contains(sha256(sealed))
        }
        guard kept.count != items.count else { return nil }
        var root = object
        root["input"] = kept
        return (try? JSONSerialization.data(withJSONObject: root)) ?? nil
    }

    private static func removingKinds(from body: Data, types: Set<String>) -> Data? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let items = object["input"] as? [[String: Any]] else {
            return nil
        }
        let kept = items.filter { item in
            guard let type = item["type"] as? String else { return true }
            return !types.contains(type)
        }
        guard kept.count != items.count else { return nil }
        var root = object
        root["input"] = kept
        return (try? JSONSerialization.data(withJSONObject: root)) ?? nil
    }

    private static func sha256(_ text: String) -> String {
        Data(SHA256.hash(data: Data(text.utf8))).map { String(format: "%02x", $0) }.joined()
    }
}

/// 记住“哪家拒绝过哪些 seal”，后续请求直接预清洗，避免每轮都失败重试一次。
final class AggregationRefusedSealStore {
    static let shared = AggregationRefusedSealStore()

    private let lock = NSLock()
    /// target key → 被该目标拒绝的 seal 指纹。
    private var refused: [String: Set<String>] = [:]
    /// 插入顺序，超过上限时淘汰最旧的目标。
    private var order: [String] = []
    private let capacity = 4096

    func record(targetKey: String, seals: [String]) {
        guard !seals.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var current = refused[targetKey] ?? []
        current.formUnion(seals)
        refused[targetKey] = current
        order.removeAll { $0 == targetKey }
        order.append(targetKey)
        while refused.values.reduce(0, { $0 + $1.count }) > capacity, order.count > 1 {
            let oldest = order.removeFirst()
            refused.removeValue(forKey: oldest)
        }
    }

    func refusedSeals(for targetKey: String) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return refused[targetKey] ?? []
    }

    func removingRefused(from body: Data, targetKey: String) -> Data? {
        AggregationSealSanitizer.removingRefused(
            from: body, refused: refusedSeals(for: targetKey)
        )
    }

    /// 测试隔离用。
    func reset() {
        lock.lock()
        refused.removeAll()
        order.removeAll()
        lock.unlock()
    }
}
