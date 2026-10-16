import Foundation

/// 聚合模式发布源条目（Claude 侧有序列表）— 对应客户端模型选择器里的一行。
/// `oneM` 为 true 时发布 id 带 `[1M]` 标记（对齐模型名字面约定，大小写不敏感）。
struct ClaudeStackModel: Codable, Equatable {
    /// 上游模型名（还原请求时替换回去的名字）。
    var model: String
    /// 展示名（选择器里 `模型（供应商）` 的前半段）；缺省时由上游模型名兜底。
    var displayName: String?
    /// 是否标记 1M 上下文窗口。
    var oneM: Bool
}
