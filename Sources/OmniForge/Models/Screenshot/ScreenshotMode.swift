import Foundation

/// 一次捕获的模式：描述「捕获是什么」，与入口意图正交。
enum ScreenshotMode: String, Equatable, Sendable, CaseIterable {
    case allInOne
    case fullScreen
}

/// 截图入口意图：描述「捕获后做什么」。
/// 作为值传入会话编排与结果管线；禁止全局可变 currentIntent。
enum ScreenshotEntryIntent: String, Equatable, Sendable, CaseIterable {
    /// 复制到剪贴板后结束
    case copy
    /// 按设置编码并保存
    case save
    /// 创建钉图窗口
    case pin
    /// 准备可拖放临时文件
    case drag
}
