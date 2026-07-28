/// 截图捕获会话协议。
///
/// Session 由 `ScreenshotFeatureManager` 在会话期间强引用持有，避免会话
/// 进行中（尤其进入编辑器后异步触发 completion 时）局部变量过早释放，
/// 导致 `[weak self]` 转发闭包失效、`isSessionRunning` 无法复位。
/// completion 触发后由 manager 释放。
protocol ScreenshotCaptureSession: AnyObject {
    /// 启动会话。
    func start()
}
