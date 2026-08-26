import Foundation

/// profile 文件管理错误。
enum ProviderProfileStoreError: Error, Equatable {
    /// 目标文件名已存在且不属于同一档案（CCQ 或其它档案）→ 拒绝写入，提示改名（SPEC 2.4）。
    case nameConflict(key: String)
    case writeFailed(path: String)
}

/// profile 文件管理边界 — CCQ 兼容路径（SPEC 2.4）。
/// Claude Code → `~/.claude/providers/<key>.json`；Codex → `~/.codex/<key>.config.toml`。
protocol ProviderProfileStoring: AnyObject {
    /// 列举该工具目录下全部 profile 文件（含非本 App 创建的外部文件，如 CCQ）。
    /// 损坏/无法解析的文件仍列出（连接参数为空，不可激活）。
    func list(for tool: ProviderTool) -> [ProviderProfile]
    /// 新增或编辑。目标文件已存在且档案 id 与文件名不符 → 抛 `nameConflict`（不提供覆盖）。
    /// 本 App 写入一律带 `_managedBy: "omniforge"` 标记；编辑后删除旧文件名副本（重命名）。
    func upsert(_ profile: ProviderProfile) throws
    /// 删除该档案文件。
    func delete(_ profile: ProviderProfile) throws
    /// 收编未托管配置为新档案（SPEC 2.6）：以给定名称落盘。
    func adopt(
        name: String,
        tool: ProviderTool,
        baseURL: String,
        token: String,
        modelOverride: String?
    ) throws -> ProviderProfile
}

/// profile 文件 CRUD 实现（JSON / TOML 双格式，按工具区分）。
final class ProviderProfileStore: ProviderProfileStoring {
    let claudeProfileDirectory: URL
    let codexProfileDirectory: URL
    let fileManager: FileManager

    init(
        claudeProfileDirectory: URL,
        codexProfileDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.claudeProfileDirectory = claudeProfileDirectory
        self.codexProfileDirectory = codexProfileDirectory
        self.fileManager = fileManager
    }

    // MARK: - 目录与文件名

    func directory(for tool: ProviderTool) -> URL {
        switch tool {
        case .claudeCode: return claudeProfileDirectory
        case .codex: return codexProfileDirectory
        }
    }

    static func fileExtension(for tool: ProviderTool) -> String {
        switch tool {
        case .claudeCode: return "json"
        case .codex: return "config.toml"
        }
    }

    static func fileName(for tool: ProviderTool, key: String) -> String {
        "\(key).\(fileExtension(for: tool))"
    }

    /// 从文件名还原档案 id（Codex 档案为双扩展名 `<key>.config.toml`，需去掉两层）。
    static func profileKey(from fileName: String, tool: ProviderTool) -> String {
        switch tool {
        case .claudeCode:
            return (fileName as NSString).deletingPathExtension
        case .codex:
            let suffix = ".\(fileExtension(for: tool))"
            guard fileName.hasSuffix(suffix) else { return fileName }
            let base = String(fileName.dropLast(suffix.count))
            return (base as NSString).deletingPathExtension
        }
    }

    // MARK: - 列举

    func list(for tool: ProviderTool) -> [ProviderProfile] {
        let dir = directory(for: tool)
        let ext = Self.fileExtension(for: tool)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        var isDirectory: ObjCBool = false
        return urls
            .filter { $0.lastPathComponent.hasSuffix(".\(ext)") }
            .filter { fileManager.fileExists(atPath: $0.path, isDirectory: &isDirectory) && !isDirectory.boolValue }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                let id = Self.profileKey(from: url.lastPathComponent, tool: tool)
                guard let data = try? Data(contentsOf: url) else {
                    return ProviderProfile(
                        id: id,
                        name: id,
                        tool: tool,
                        baseURL: "",
                        token: "",
                        modelOverride: nil,
                        smallFastModelOverride: nil,
                        managedBy: nil
                    )
                }
                return ProviderProfileFileCodec.decode(
                    data: data,
                    tool: tool,
                    fallbackID: id
                ) ?? ProviderProfile(
                    id: id,
                    name: id,
                    tool: tool,
                    baseURL: "",
                    token: "",
                    modelOverride: nil,
                    smallFastModelOverride: nil,
                    managedBy: nil
                )
            }
    }

    // MARK: - 写入 / 删除 / 收编

    func upsert(_ profile: ProviderProfile) throws {
        var profile = profile
        if profile.id.isEmpty {
            profile.id = profile.profileKey
        }
        let tool = profile.tool
        let dir = directory(for: tool)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let target = dir.appendingPathComponent(Self.fileName(for: tool, key: profile.profileKey))
        if fileManager.fileExists(atPath: target.path), profile.id != profile.profileKey {
            // 撞名：目标文件已存在，且不是同一档案（编辑中的档案 id 即旧文件名）。
            throw ProviderProfileStoreError.nameConflict(key: profile.profileKey)
        }
        guard let data = ProviderProfileFileCodec.encode(profile) else {
            throw ProviderProfileStoreError.writeFailed(path: target.path)
        }
        try AtomicFileWriter.write(data, to: target, fileManager: fileManager)

        // 重命名：删除旧文件名副本（仅当旧文件存在且不同于目标）。
        if !profile.id.isEmpty, profile.id != profile.profileKey {
            let oldPath = dir.appendingPathComponent(Self.fileName(for: tool, key: profile.id))
            if fileManager.fileExists(atPath: oldPath.path) {
                try? fileManager.removeItem(at: oldPath)
            }
        }
    }

    func delete(_ profile: ProviderProfile) throws {
        guard !profile.id.isEmpty else { return }
        let path = directory(for: profile.tool)
            .appendingPathComponent(Self.fileName(for: profile.tool, key: profile.id))
        guard fileManager.fileExists(atPath: path.path) else { return }
        try fileManager.removeItem(at: path)
    }

    func adopt(
        name: String,
        tool: ProviderTool,
        baseURL: String,
        token: String,
        modelOverride: String?
    ) throws -> ProviderProfile {
        let profile = ProviderProfile(
            id: "",
            name: name,
            tool: tool,
            baseURL: baseURL,
            token: token,
            modelOverride: modelOverride,
            smallFastModelOverride: nil,
            managedBy: ProviderProfile.managedByMarker
        )
        try upsert(profile)
        return profile
    }
}

/// profile 文件编解码：本 App 档案 ↔ 磁盘文件；外部文件（CCQ 等）尽力解析。
enum ProviderProfileFileCodec {
    /// 本 App 写入的 JSON 键（Claude 侧）。
    private static let managedByKey = "_managedBy"

    // MARK: - 编码（写入一律带 _managedBy 标记）

    static func encode(_ profile: ProviderProfile) -> Data? {
        switch profile.tool {
        case .claudeCode:
            let root: [String: Any] = [
                "name": profile.name,
                "tool": profile.tool.rawValue,
                "baseURL": profile.baseURL,
                "token": profile.token,
                "modelOverride": profile.modelOverride as Any,
                "smallFastModelOverride": profile.smallFastModelOverride as Any,
                managedByKey: ProviderProfile.managedByMarker,
            ]
            return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        case .codex:
            var document = TOMLFile()
            document.setValue(profile.name, key: "name", table: nil)
            document.setValue(profile.tool.rawValue, key: "tool", table: nil)
            document.setValue(profile.baseURL, key: "base_url", table: nil)
            document.setValue(profile.token, key: "token", table: nil)
            if let model = profile.modelOverride, !model.isEmpty {
                document.setValue(model, key: "model_override", table: nil)
            }
            document.setValue(ProviderProfile.managedByMarker, key: managedByKey, table: nil)
            return document.serialize().data(using: .utf8)
        }
    }

    // MARK: - 解码（本 App 格式优先，外部文件尽力解析）

    static func decode(data: Data, tool: ProviderTool, fallbackID: String) -> ProviderProfile? {
        switch tool {
        case .claudeCode:
            return decodeClaudeJSON(data: data, fallbackID: fallbackID)
        case .codex:
            return decodeCodexTOML(data: data, fallbackID: fallbackID)
        }
    }

    private static func decodeClaudeJSON(data: Data, fallbackID: String) -> ProviderProfile? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        // 本 App 格式：baseURL + token。
        if let baseURL = root["baseURL"] as? String, !baseURL.isEmpty,
           let token = root["token"] as? String {
            return ProviderProfile(
                id: fallbackID,
                name: root["name"] as? String ?? fallbackID,
                tool: .claudeCode,
                baseURL: baseURL,
                token: token,
                modelOverride: root["modelOverride"] as? String,
                smallFastModelOverride: root["smallFastModelOverride"] as? String,
                managedBy: root[managedByKey] as? String
            )
        }
        // CCQ 风格外部文件：baseUrl/base_url + apiKey/token/ANTHROPIC_AUTH_TOKEN。
        let baseURL = root["baseUrl"] as? String ?? root["base_url"] as? String ?? ""
        let token = root["apiKey"] as? String
            ?? root["token"] as? String
            ?? root["ANTHROPIC_AUTH_TOKEN"] as? String
            ?? ""
        let name = root["name"] as? String ?? fallbackID
        let model = root["model"] as? String ?? root["defaultModel"] as? String
        return ProviderProfile(
            id: fallbackID,
            name: name,
            tool: .claudeCode,
            baseURL: baseURL,
            token: token,
            modelOverride: model,
            smallFastModelOverride: nil,
            managedBy: root[managedByKey] as? String
        )
    }

    private static func decodeCodexTOML(data: Data, fallbackID: String) -> ProviderProfile? {
        guard let text = String(data: data, encoding: .utf8),
              let document = TOMLFile.parse(text) else {
            return nil
        }
        let baseURL = document.stringValue(key: "base_url", table: nil) ?? ""
        let token = document.stringValue(key: "token", table: nil)
            ?? document.stringValue(key: "experimental_bearer_token", table: nil)
            ?? ""
        let name = document.stringValue(key: "name", table: nil) ?? fallbackID
        return ProviderProfile(
            id: fallbackID,
            name: name,
            tool: .codex,
            baseURL: baseURL,
            token: token,
            modelOverride: document.stringValue(key: "model_override", table: nil),
            smallFastModelOverride: nil,
            managedBy: document.stringValue(key: managedByKey, table: nil)
        )
    }
}
