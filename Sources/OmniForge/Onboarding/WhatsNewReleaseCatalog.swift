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
            version: "3.9.0",
            entries: [
                WhatsNewEntry(type: .added, text: "新增桌面宠物：像素猫常驻桌面，会散步休息，并对复制、低电量、高温等状态做出反应，支持导入社区宠物"),
                WhatsNewEntry(type: .added, text: "新增提示词优化：任意应用选中文字，⌥⌘P 一键 AI 增强"),
                WhatsNewEntry(type: .added, text: "新增主题外观切换：跟随系统 / 浅色 / 深色"),
                WhatsNewEntry(type: .changed, text: "控制中心收敛为 4 大板块，特性与侧栏按使用形态重新分组"),
                WhatsNewEntry(type: .changed, text: "供应商页底部链接收纳为齿轮菜单，新增供应商直接在面板内完成"),
                WhatsNewEntry(type: .changed, text: "折线悬浮气泡改挂图表下方不再遮挡走势，并显示采样时间"),
                WhatsNewEntry(type: .changed, text: "设置页 ⓘ 说明改为悬浮即时弹出"),
                WhatsNewEntry(type: .changed, text: "安装包体积精简一半以上"),
                WhatsNewEntry(type: .fixed, text: "修复切换页面时设置窗口标题栏高度跳变"),
                WhatsNewEntry(type: .fixed, text: "修复特性页开关功能后滚动位置回顶"),
                WhatsNewEntry(type: .fixed, text: "修复 GPU / 网络排行首次打开长时间空等"),
            ]
        ),
        WhatsNewRelease(
            version: "3.8.2",
            entries: [
                WhatsNewEntry(type: .fixed, text: "重设计 DMG 安装窗口：修复背景错位与图标不对齐，安装页焕新为放置槽引导布局"),
            ]
        ),
        WhatsNewRelease(
            version: "3.8",
            entries: [
                WhatsNewEntry(type: .changed, text: "长截图引擎重写：手动滚动驱动拼接更稳，滚动停止后自动完成，Esc 随时取消"),
                WhatsNewEntry(type: .changed, text: "长截图回归纯手动滚动模式，移除自动滚动及相关设置项"),
                WhatsNewEntry(type: .fixed, text: "修复风扇助手首次安装等待批准时误报失败，批准后自动转为就绪"),
                WhatsNewEntry(type: .fixed, text: "修复全局滚动周期性卡顿（风扇注册状态查询不再阻塞主线程）"),
                WhatsNewEntry(type: .fixed, text: "卸载或关闭监控时归还风扇控制，转速不再停留在最后一次下发值"),
                WhatsNewEntry(type: .fixed, text: "截图窗口吸附可正确命中控制中心、剪贴板等自有面板"),
            ]
        ),
        WhatsNewRelease(
            version: "3.7",
            entries: [
                WhatsNewEntry(type: .added, text: "新增风扇监控与控制：实时转速、温度传感器与四档风扇曲线，支持手动调速"),
                WhatsNewEntry(type: .added, text: "菜单栏新增风扇转速指标，散热状态随时可见"),
                WhatsNewEntry(type: .changed, text: "温度传感器改为分组摘要展示，处理器等热点区域一目了然"),
                WhatsNewEntry(type: .changed, text: "磁盘详情页迁移平面分区风格，读写速率更醒目"),
                WhatsNewEntry(type: .changed, text: "菜单栏直指标精简，移除日期 / 磁盘 / 电源与 token 用量块"),
                WhatsNewEntry(type: .fixed, text: "修复电池健康长期显示 100% 的口径失真"),
                WhatsNewEntry(type: .fixed, text: "老配置自动并入新增面板指标，风扇卡对老用户可见"),
            ]
        ),
        WhatsNewRelease(
            version: "3.6",
            entries: [
                WhatsNewEntry(type: .changed, text: "唤醒页迁移平面分区风格，与全应用视觉统一"),
                WhatsNewEntry(type: .changed, text: "平级 tab 切换改为方向化横向滑移，层级关系更直观"),
                WhatsNewEntry(type: .fixed, text: "控制中心稳定期内容变化只平滑调整高度，不再整页闪烁"),
                WhatsNewEntry(type: .fixed, text: "修复卸载器选择 APP 弹窗随面板一起消失的问题"),
            ]
        ),
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
