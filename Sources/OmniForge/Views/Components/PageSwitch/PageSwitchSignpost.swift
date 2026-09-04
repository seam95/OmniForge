import os

/// 页面切换统一 signpost：唯一实例，供 Page Switch 模块与迁移期调用点共用。
/// Release 真机用 Instruments 的 os_signpost 模板采集阶段耗时（PLAN 阶段 8）。
enum PageSwitchSignpost {
    static let poster = OSSignposter(subsystem: "com.omniforge.ui", category: "page-switch")

    /// 事件名：调用方一律引用此处常量，避免字符串漂移。
    enum Event {
        /// route 请求到达（导航点击 / 分段切换）。
        static let routeRequested = "routeRequested"
        /// 导航选中底块动画开始。
        static let indicatorStarted = "indicatorStarted"
        /// 旧内容退出动画完成（route 交换点）。
        static let exitCompleted = "exitCompleted"
        /// displayedRoute 无动画替换。
        static let routeSwapped = "routeSwapped"
        /// 新内容进入动画完成。
        static let enterCompleted = "enterCompleted"
    }

    /// 单点事件打点。
    static func emit(_ event: String) {
        let state = poster.beginInterval(event)
        poster.endInterval(event, state)
    }
}
