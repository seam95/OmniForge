import Foundation
import CryptoKit

/// Claude Desktop 聚合投影写入边界（对齐两个既有 writer 的协议形态）。
protocol AggregationClaudeDesktopConfigWriting: AnyObject {
    /// 写聚合投影：代理 origin + gateway token + inferenceModels（4 文件事务）。
    func applyAggregation(
        defaultProfile: ProviderProfile,
        memberPublished: [AggregationPublishedModel],
        port: UInt16,
        gatewayToken: String
    ) throws
    /// 磁盘现状的契约摘要（供「未变更不重写」比对）。
    func currentContractDigest() -> String
    /// 给定投影的契约摘要（不落盘）。
    func projectedContractDigest(
        defaultProfile: ProviderProfile,
        memberPublished: [AggregationPublishedModel],
        port: UInt16,
        gatewayToken: String
    ) -> String
}

/// Desktop 聚合投影：profile 指向 `http://127.0.0.1:<port>/claude-desktop`、
/// 凭证为 gateway token；`inferenceModels` = 默认那家四档（映射卡改写 / 直连卡 identity）
/// + 成员发布（`claude-fable-om-<hash>` 条目），上限 200 截断；有成员时
/// `modelDiscoveryEnabled: false`（模型列表完全由 profile 决定，SPEC 功能 C）。
/// 写入复用 `ClaudeDesktopSettingsStore` 的 4 文件事务（pending 自愈同源）。
final class AggregationClaudeDesktopConfigWriter: AggregationClaudeDesktopConfigWriting {
    /// Desktop schema 的 `inferenceModels` maxItems。
    static let inferenceModelsLimit = 200

    private let store: ClaudeDesktopSettingsStoring
    private let profileReader: () throws -> [String: Any]

    init(store: ClaudeDesktopSettingsStoring, profileReader: @escaping () throws -> [String: Any]) {
        self.store = store
        self.profileReader = profileReader
    }

    /// 生产装配（profileReader 读 3P profile 文件，供摘要比对）。
    static func production(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        applicationSupportRoot: URL,
        fileManager: FileManager = .default
    ) -> AggregationClaudeDesktopConfigWriter {
        let profileURL = ProviderSwitchPaths.claudeDesktopProfileURL(homePath: homePath)
        return AggregationClaudeDesktopConfigWriter(
            store: ClaudeDesktopSettingsStore.production(
                homePath: homePath,
                applicationSupportRoot: applicationSupportRoot,
                fileManager: fileManager
            ),
            profileReader: {
                guard let data = try? Data(contentsOf: profileURL),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    return [:]
                }
                return object
            }
        )
    }

    // MARK: - 投影值构造（纯函数，可单测）

    /// 投影的网关地址：`http://127.0.0.1:<port>/claude-desktop`。
    static func projectedBaseURL(port: UInt16) -> String {
        "http://127.0.0.1:\(port)/claude-desktop"
    }

    /// inferenceModels 条目构造：
    /// - 默认那家映射卡 → 四档条目（name = 档名；有 labelOverride/supports1M 时对象形态，
    ///   `prefer1m` 随 `supports1m` 一起写，否则纯字符串）；
    /// - 默认那家直连卡 → 四档 identity（纯字符串档名）；
    /// - 成员发布 → 对象条目（name = 聚合 id、labelOverride = `供应商 / 模型名`、
    ///   supports1m/prefer1m 合并）；id 非 Claude-safe 时原样写入（发布 id 恒 `claude-fable-` 前缀）。
    /// 上限 200 截断（Desktop schema maxItems；超一个名整组被拒）。
    static func inferenceModels(
        defaultProfile: ProviderProfile,
        memberPublished: [AggregationPublishedModel]
    ) -> [Any] {
        var entries: [Any] = []
        if let routes = defaultProfile.desktopModelRoutes, !routes.isEmpty {
            // 映射卡：按固定四档顺序取（UI 同款口径），只写已配置的档。
            for slot in ClaudeDesktopSettingsStore.defaultRoutes {
                guard let route = routes[slot] else { continue }
                entries.append(Self.slotEntry(name: slot, route: route))
            }
        } else {
            // 直连卡做默认：四档 identity（Claude-safe 名原样透传，代理不改写）。
            for slot in ClaudeDesktopSettingsStore.defaultRoutes {
                entries.append(slot)
            }
        }
        for model in memberPublished {
            var entry: [String: Any] = ["name": model.id]
            if !model.label.isEmpty {
                entry["labelOverride"] = model.label
            }
            if model.oneM {
                entry["supports1m"] = true
                entry["prefer1m"] = true
            }
            entries.append(entry)
        }
        return Array(entries.prefix(inferenceModelsLimit))
    }

    /// 四档条目：只有 `labelOverride` 或 `supports1M` 时用对象形态，否则纯字符串。
    private static func slotEntry(name: String, route: DesktopModelRoute) -> Any {
        guard route.supports1M || !(route.labelOverride ?? "").isEmpty else {
            return name
        }
        var entry: [String: Any] = ["name": name]
        if let label = route.labelOverride, !label.isEmpty {
            entry["labelOverride"] = label
        }
        if route.supports1M {
            entry["supports1m"] = true
            entry["prefer1m"] = true // 必须随 supports1m 一起写，否则 Desktop 每模型列两行
        }
        return entry
    }

    // MARK: - 写入与摘要

    func applyAggregation(
        defaultProfile: ProviderProfile,
        memberPublished: [AggregationPublishedModel],
        port: UInt16,
        gatewayToken: String
    ) throws {
        try store.applyAggregation(
            gatewayBaseURL: Self.projectedBaseURL(port: port),
            gatewayToken: gatewayToken,
            inferenceModels: Self.inferenceModels(defaultProfile: defaultProfile, memberPublished: memberPublished),
            // 聚合模式恒关自动发现（SPEC 机制事实）：模型菜单完全由 profile 的
            // inferenceModels 决定。只对有成员时关会让单默认聚合仍自动发现，
            // 与投影列表合并出计划外条目（cc-switch `route_profile` 同口径）。
            modelDiscoveryEnabled: false
        )
    }

    func currentContractDigest() -> String {
        Self.digest(of: (try? profileReader()) ?? [:])
    }

    func projectedContractDigest(
        defaultProfile: ProviderProfile,
        memberPublished: [AggregationPublishedModel],
        port: UInt16,
        gatewayToken: String
    ) -> String {
        Self.digest(of: [
            "inferenceGatewayBaseUrl": Self.projectedBaseURL(port: port),
            "inferenceGatewayApiKey": gatewayToken,
            "inferenceModels": Self.inferenceModels(defaultProfile: defaultProfile, memberPublished: memberPublished),
            "modelDiscoveryEnabled": false,
        ])
    }

    /// 摘要 = 网关三键（baseURL/token/models）+ 可选 discovery 键的规范序列化 SHA-256。
    private static func digest(of profile: [String: Any]) -> String {
        var lines: [String] = []
        for key in ["inferenceGatewayBaseUrl", "inferenceGatewayApiKey", "inferenceModels", "modelDiscoveryEnabled"].sorted() {
            guard let value = profile[key] else { continue }
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                lines.append("\(key)=\(String(decoding: data, as: UTF8.self))")
            } else {
                lines.append("\(key)=\(value)")
            }
        }
        let hash = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
