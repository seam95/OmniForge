import Foundation

/// What's New 版本内容目录 — 发版时唯一需要维护的文件。
///
/// 维护规则：
/// - 发版时在 `releases` 顶部追加一组，版本号与 `Resources/Info.plist` 的
///   `CFBundleShortVersionString` 保持一致（新版本在前，降序排列）。
/// - 条目文案从该版本 release notes 提炼，控制在用户可感知的功能变化，
///   纯内部重构与文档调整不记录。
enum WhatsNewReleaseCatalog {
    /// 历次版本的更新内容，新版本在前
    static let releases: [WhatsNewRelease] = [
        WhatsNewRelease(
            version: "3.5",
            entries: [
                WhatsNewEntry(type: .added, text: "监控面板全新平面分区设计，折线图悬浮可查看各时间点具体数值"),
                WhatsNewEntry(type: .added, text: "Token 面板平面化改版，新增「余额 / 用量」双分区切换"),
                WhatsNewEntry(type: .added, text: "供应商列表升级为卡片式设计，品牌标识更醒目"),
                WhatsNewEntry(type: .added, text: "实用工具各页统一平面分区风格：便签、DSH、网络诊断、卸载器与清理"),
                WhatsNewEntry(type: .added, text: "菜单栏网速块改为双行堆叠布局，上下行速度同屏可见"),
                WhatsNewEntry(type: .added, text: "控制中心面板高度自适应内容，打开后位置保持稳定"),
                WhatsNewEntry(type: .changed, text: "页面切换动画全局统一，转场更流畅"),
                WhatsNewEntry(type: .fixed, text: "剪贴板粘贴不再抢占输入焦点；修复监控页底部灰带等多项细节"),
            ]
        ),
        WhatsNewRelease(
            version: "3.4",
            entries: [
                WhatsNewEntry(type: .added, text: "桌面便签新增字号档位调节，工具栏 Aa 按钮即时切换小 / 中 / 大三档"),
                WhatsNewEntry(type: .added, text: "网络诊断、卸载器、清理页升级为仪表盘风格，关键数据一眼可见"),
                WhatsNewEntry(type: .changed, text: "设置页说明文字收敛为 ⓘ 悬浮提示，侧栏功能入口改为彩色徽章"),
                WhatsNewEntry(type: .changed, text: "截图标注移动手柄支持点击切换移动模式，无需长按拖拽"),
                WhatsNewEntry(type: .fixed, text: "截图标注子工具栏样式与色板颜色点击后即时同步生效"),
                WhatsNewEntry(type: .fixed, text: "修复 Token 限额卡重置时间列被截断的问题"),
            ]
        ),
    ]

    /// 返回用户上次查看版本之后的新内容（新版本在前）。
    /// 结果为空时回退到最新一组，保证窗口不会出现空列表；
    /// lastSeen 为空视为从未查看，返回全部。
    /// catalog 参数供测试注入，生产调用使用默认目录。
    static func releases(
        after lastSeen: String?,
        in catalog: [WhatsNewRelease] = releases
    ) -> [WhatsNewRelease] {
        guard !catalog.isEmpty else { return catalog }
        guard let lastSeen, !lastSeen.isEmpty else { return catalog }
        let newer = catalog.filter { compareVersions($0.version, lastSeen) > 0 }
        return newer.isEmpty ? [catalog[0]] : newer
    }

    /// 语义化版本比较：按 "." 分段转整数逐段比较，段数不足按 0 补齐
    /// （"3.4" 与 "3.4.0" 相等，"3.10" 大于 "3.9"）。
    /// 无法解析的段按 0 处理。
    static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let lhsParts = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let rhsParts = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(lhsParts.count, rhsParts.count)
        for index in 0..<count {
            let l = index < lhsParts.count ? lhsParts[index] : 0
            let r = index < rhsParts.count ? rhsParts[index] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}
