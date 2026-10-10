import Foundation
import CryptoKit

/// 聚合契约摘要 — 写前算客户端配置投影的摘要；与已落定的一致时**不重写文件**
/// （避免无谓改写配置，也就避免无谓触发重新选模型提示）。
enum AggregationContractDigest {
    /// Claude 侧摘要：投影 root 里只取**拥有键**（`env` 下的 `claudeOwnedEnvKeys` 与
    /// 顶层 `claudeOwnedTopLevelKeys`），规范序列化（键排序）后哈希。
    /// 非拥有键不参与——用户改 `permissions` 不会触发重写。
    static func claude(projectedRoot: [String: Any]) -> String {
        let env = projectedRoot["env"] as? [String: Any] ?? [:]
        let ownedEnv = ProviderTool.claudeOwnedEnvKeys.sorted().compactMap { key -> String? in
            guard let value = env[key] else { return nil }
            return "\(key)=\(canonicalValue(value))"
        }
        let ownedTopLevel = ProviderTool.claudeOwnedTopLevelKeys.sorted().compactMap { key -> String? in
            guard let value = projectedRoot[key] else { return nil }
            return "\(key)=\(canonicalValue(value))"
        }
        return sha256Hex(Data((ownedEnv + ownedTopLevel).joined(separator: "\n").utf8))
    }

    /// Codex 侧摘要：三部分拼接后哈希——
    /// ① `codexOwnedTopLevelKeys` 顶层键的解析值（注释与空行不参与）；
    /// ② `[model_providers.custom]` 表的规范序列化，**序列化前剥掉 `requires_openai_auth`**
    ///    （它跟随磁盘登录状态，不属于契约——登录态变化不得触发重写）；
    /// ③ 目录字节（nil 记 `"none"`）——增删成员时顶层键往往不变，目录必须参与摘要。
    static func codex(configText: String, catalogData: Data?) -> String {
        let document = TOMLFile.parse(configText) ?? TOMLFile()
        let topLevel = ProviderTool.codexOwnedTopLevelKeys.sorted().map { key -> String in
            "\(key)=\(document.stringValue(key: key, table: nil) ?? absentSentinel)"
        }.joined(separator: "\n")
        let table = customTableDigest(document)
        let catalog = sha256Hex(catalogData ?? Data("none".utf8))
        return sha256Hex(Data("\(topLevel)\n---\n\(table)\n---\n\(catalog)".utf8))
    }

    // MARK: - private

    /// 顶层键缺省哨兵（区别于「存在但值为空」）。
    private static let absentSentinel = "<absent>"

    private static func customTableDigest(_ document: TOMLFile) -> String {
        let customTable = ["model_providers", "custom"]
        let pairs: [(String, String)] = document.entries
            .filter { $0.tablePath == customTable }
            .map(\.key)
            .filter { $0 != "requires_openai_auth" }
            .sorted()
            .map { key in (key, document.stringValue(key: key, table: customTable) ?? "") }
        return sha256Hex(Data(pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "\n").utf8))
    }

    /// 值的规范形态：容器（字典/数组）走排序键 JSON；标量（字符串等）用原值
    /// （JSONSerialization 对裸标量顶层会抛 ObjC 异常，`try?` 捕不到——先判类型）。
    private static func canonicalValue(_ value: Any) -> String {
        if value is [String: Any] || value is [Any],
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            return String(decoding: data, as: UTF8.self)
        }
        return "\(value)"
    }

    private static func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }
}
