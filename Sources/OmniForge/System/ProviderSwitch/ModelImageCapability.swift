import Foundation

/// 模型图像输入能力判定 — 对齐 cc-switch v4.0.16 `model_capabilities.rs` 的口径。
///
/// Codex 客户端只认目录行里的 `input_modalities`：不含 `image` 时，添加图片会被
/// 直接拦下（toast「此模型不支持图像输入。请尝试其他模型」）。因此目录生成采用
/// **fail-open**：
/// - 只有「确认纯文本」名单命中的模型写 `["text"]`；
/// - 其余（含未确认的新模型、视觉变体、别名）一律 `["text", "image"]`。
///
/// 这样聚合模式下选中的多模态模型不会再被客户端提前拦死。若上游其实不支持图像，
/// 请求会由上游拒绝，用户可换模型；后续如需再补代理层剥图兜底。
enum ModelImageCapability {
    /// 规范化输入模态。显式声明优先（非空时原样使用），否则按名单推导。
    static func inputModalities(for model: String, declared: [String]? = nil) -> [String] {
        if let declared {
            let cleaned = declared
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            if !cleaned.isEmpty {
                return cleaned
            }
        }
        return isConfirmedTextOnlyModel(model) ? ["text"] : ["text", "image"]
    }

    /// 已确认只接受文本输入的模型（尾段精确匹配，不做前缀继承）。
    ///
    /// 名单刻意精确且 fail-open：未来的 `-vision` / `-vl` 变体不会被自动判成纯文本。
    /// 来源：cc-switch v4.0.16 `src-tauri/src/model_capabilities.rs` 的 `CONFIRMED_TAILS`
    /// （2026-10-19 核对）。`deepseek-v4-flash` / `deepseek-v4-pro` 刻意不在名单：
    /// 它们是旧别名，上游会路由到识图版本，必须 fail-open。
    static func isConfirmedTextOnlyModel(_ model: String) -> Bool {
        let tail = normalized(model).split(separator: "/").last.map(String.init) ?? ""
        return confirmedTextOnlyTails.contains(tail)
    }

    /// 归一化：去首尾空白与 `models/` 前缀、转小写、去 `[1M]` 上下文标记。
    private static func normalized(_ model: String) -> String {
        var value = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("models/") {
            value = String(value.dropFirst("models/".count))
        }
        if value.hasSuffix("[1m]") {
            value = String(value.dropLast("[1m]".count)).trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    /// 确认纯文本模型名单（尾段精确匹配）。
    private static let confirmedTextOnlyTails: Set<String> = [
        "ark-code-latest",
        "deepseek-chat",
        "deepseek-reasoner",
        "glm-5.1",
        "glm-5.2",
        "glm-5.3",
        "kat-coder",
        "kat-coder-pro",
        "kat-coder-pro v1",
        "kat-coder-pro v2",
        "kat-coder-pro-v1",
        "kat-coder-pro-v2",
        "ling-2.5-1t",
        "ling-2.6-1t",
        "longcat-2.0",
        "longcat-flash-chat",
        "minimax-m2.7",
        "minimax-m2.7-highspeed",
        "mimo-v2.5-pro",
        "qwen3-coder-480b",
        "qwen3-coder-480b-a35b-instruct",
        "qwen3-coder-flash",
        "qwen3-coder-next",
        "qwen3-coder-plus",
        "step-3.5-flash",
        "step-3.5-flash-2603",
        "us.deepseek.r1-v1",
    ]
}
