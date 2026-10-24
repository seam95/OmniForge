import Foundation

/// 聚合发布源条目 — 客户端模型选择器里的一行。
/// `model` 是剥掉 1M 标记后的名字（Stack id 与展示用）；`upstream` 是发往上游的原始值（可能带标记）。
struct AggregationPublishedModel: Equatable {
    let tool: ProviderTool
    let key: String
    let profileName: String
    let model: String
    let upstream: String
    let displayName: String
    let oneM: Bool
    let window: UInt64

    /// Stack id（按工具分派编码形态）— 客户端选择器里出现的模型 id。
    var id: String {
        AggregationModelID.encode(tool: tool, key: key, model: model, oneM: oneM)
    }

    /// 选择器显示名（按工具分派形态）。
    /// Claude Code：`模型（供应商）`（全角括号，对齐 cc-switch 聚合目录口径）。
    /// Codex：与 Claude Code 同形。
    /// Desktop：`供应商 / 模型`（对齐 cc-switch `desktop_models` 的 label 形态，SPEC 功能 D）。
    var label: String {
        switch tool {
        case .claudeCode, .codex:
            return "\(displayName)（\(profileName)）"
        case .claudeDesktop:
            return "\(profileName) / \(displayName)"
        }
    }

    /// 选择器描述行：`模型 · 窗口`（窗口缺省时不带后缀）。
    var description: String {
        AggregationModelPublisher.windowLabel(window).map { "\(model) · \($0)" } ?? model
    }
}
