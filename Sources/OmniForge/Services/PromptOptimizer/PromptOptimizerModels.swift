import Foundation

/// 提示词优化失败的错误类别（决策 D7）——HUD 文案的最小判别单位。
enum PromptOptimizerErrorKind: Error, Equatable {
    /// 未配置 API Key（设置页可见，但不发请求）。
    case notConfigured
    /// AX 读不到选中文本。
    case noSelection
    /// 辅助功能权限缺失。
    case noAccessibility
    /// 连接错误 / 无网络。
    case network
    /// 请求超时（30s）。
    case timeout
    /// HTTP 401/403。
    case unauthorized
    /// 其余失败（含 API 4xx/5xx、响应形状异常——长度不设上限时上下文超限走此兜底）。
    case generic
}

/// 优化服务边界：输入选中文本，返回优化后的提示词全文。
protocol PromptOptimizing: AnyObject {
    func optimize(selectedText: String) async throws -> String
}
