import CoreGraphics

/// 本进程合成输入事件的共享标记（写在 `eventSourceUserData` 字段）。
///
/// 事件 tap（滚动反转、平滑滚动）看到带此标记的事件一律直通：
/// 这些事件是本进程刻意合成的输入（长截图自动滚轮、平滑滚动滑行流），
/// 不应再被自家的修改型 tap 反转方向或二次重放——否则自动滚动会被
/// 滚动反转翻成向上、滑行流会被再次平滑。
enum SyntheticEventTag {
    /// "VORS"——沿用平滑滚动滑行流的既有标记值，行为完全兼容。
    static let ours: Int64 = 0x564F5253

    /// 事件是否带本进程合成标记。
    static func isOurs(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == ours
    }
}
