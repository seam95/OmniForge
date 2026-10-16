import Foundation

/// 聚合模型 id 解不出来的四种原因。**一律不回落到默认供应商**——
/// 回落会用别家的凭证、别家的模型回答，用户无从察觉（SPEC 6.6）。
enum AggregationMiss: Equatable {
    /// 带前缀但该工具不在聚合模式。
    case stackOff
    /// id 切不出 key 与模型（malformed），或 key 未登记。
    case unknown
    /// 该成员已从名单移除（key 仍登记簿里保留）。
    case removed
    /// 对应 profile 已删除。
    case deleted

    /// 双语文案（中英之间空格 + 圆括号英文）。口径对齐 cc-switch，
    /// 其中产品名按本仓库规范替换为 `OmniForge`。
    func message(model: String) -> String {
        switch self {
        case .stackOff:
            return "聚合的模型 \(model) 只能在聚合模式下使用，当前没有开启聚合模式，请在 OmniForge 的模型列表里重新选择 (Aggregated model \(model) only works in Stack mode, which is off; pick a model from the model list in OmniForge again)"
        case .unknown:
            return "聚合的模型 \(model) 在 OmniForge 里不存在，请在模型列表里重新选择 (Aggregated model \(model) is unknown to OmniForge; pick a model from the model list again)"
        case .removed:
            return "聚合的模型 \(model) 已从 OmniForge 移除，请在模型列表里重新选择 (Aggregated model \(model) was removed from OmniForge; pick a model from the model list again)"
        case .deleted:
            return "聚合的模型 \(model) 对应的供应商已从 OmniForge 删除，请在模型列表里重新选择 (The provider of aggregated model \(model) was deleted from OmniForge; pick a model from the model list again)"
        }
    }
}
