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
            version: "3.15.0",
            entries: [
                WhatsNewEntry(type: .added, text: "新增截图晾衣绳：系统截图自动挂到屏幕顶部的晾衣绳上，鼠标停菜单栏即滑出；支持单击标注、双击复制、拖到应用或文件夹、右键菜单，⌃⌥⌘T 随时唤出"),
                WhatsNewEntry(type: .added, text: "晾衣绳容量可配置（1–20 张），屏幕摆不下的旧照片折叠为绳尾「+N」徽章，点击展开列表"),
                WhatsNewEntry(type: .added, text: "编辑器点对勾后截图自动缓存并挂上晾衣绳（临时缓存，超出容量自动销毁，不占磁盘），且标注完成后结果直接进剪贴板、绳上图片同步更新"),
                WhatsNewEntry(type: .fixed, text: "修复打开设置截图页即闪退（第三方热键组件缺少资源文件）"),
                WhatsNewEntry(type: .fixed, text: "修复晾衣绳唤出/收回不灵敏（静止鼠标不触发），改为持续轮询驱动"),
                WhatsNewEntry(type: .fixed, text: "修复系统标注窗口无法移动的问题"),
                WhatsNewEntry(type: .fixed, text: "修复桌面上截图在晾衣绳上点叉号被误删，现仅从绳上取下、不动文件"),
                WhatsNewEntry(type: .fixed, text: "修复剪贴板历史里图片条目没有缩略图、显示无法预览（含微信复制图片的场景）"),
            ]
        ),
        WhatsNewRelease(
            version: "3.14.0",
            entries: [
                WhatsNewEntry(type: .added, text: "新增访达鼠标右键增强：新建文件与终端、用编辑器打开、复制文件路径、管理常用目录并一键跳转"),
                WhatsNewEntry(type: .added, text: "StepFun 支持账号密码自动登录与 Token 自动续期，并接入 Step Plan 订阅限额与用量监控"),
                WhatsNewEntry(type: .added, text: "Codex 供应商支持配置多个模型，首位为默认模型且全部进入模型目录"),
                WhatsNewEntry(type: .changed, text: "移除桌面宠物功能；完整实现保留在 feat/desktop-pet 分支，需要可从该分支检出恢复"),
                WhatsNewEntry(type: .changed, text: "移除 DSH Web 服务功能，并清理 workbuddy、dsh 两个已失效的 Token 供应商"),
                WhatsNewEntry(type: .fixed, text: "修复全能截图框选完成后底部标注工具栏要等一两秒才出现（重复枚举系统窗口所致）"),
                WhatsNewEntry(type: .fixed, text: "修复启动后菜单栏性能指标需等十余秒才出数，改为启动首轮全量采样"),
                WhatsNewEntry(type: .fixed, text: "修复访达右键切换显示隐藏文件不生效、扩展总开关失效，以及菜单动作点击无反应"),
                WhatsNewEntry(type: .fixed, text: "修复 StepFun 计数型额度窗数值只显示一个「剩」字，改为按百分比展示"),
                WhatsNewEntry(type: .fixed, text: "修复 Codex 模型目录缺少必需字段导致桌面端无法加载配置"),
            ]
        ),
        WhatsNewRelease(
            version: "3.13.0",
            entries: [
                WhatsNewEntry(type: .added, text: "Token 用量趋势图与热力图的悬浮数值改为跟随鼠标的气泡，读数不再遮挡图表"),
                WhatsNewEntry(type: .added, text: "通用设置新增「显示菜单栏图标」开关，可只保留指标文字与倒计时"),
                WhatsNewEntry(type: .changed, text: "菜单栏状态改由图标右下角圆点表达：唤醒中橙色、待清理红色，自动适配明暗"),
                WhatsNewEntry(type: .fixed, text: "修复打开保持唤醒后菜单栏图标显示为黑色"),
                WhatsNewEntry(type: .fixed, text: "修复总开关开启后菜单栏图标被误隐藏、保持唤醒页开关点击无反应"),
            ]
        ),
        WhatsNewRelease(
            version: "3.12.1",
            entries: [
                WhatsNewEntry(type: .fixed, text: "修复系统监控读数异常：温度等 SMC 指标读取失效、CPU 占用采样溢出、菜单栏指标重复显示"),
                WhatsNewEntry(type: .fixed, text: "修复切换桌面宠物后内存持续增长（长时间运行可膨胀数百 MB），及关闭桌宠后点击穿透未复位"),
                WhatsNewEntry(type: .fixed, text: "修复 Token 用量统计：Codex 推理 token 重复计入、异常数据导致崩溃、多采集器刷新卡顿"),
                WhatsNewEntry(type: .fixed, text: "修复截图取消后偶发无法再次框选；长截图中键盘滚动不再意外中断会话"),
                WhatsNewEntry(type: .fixed, text: "修复新手向导「开机自启」选项不生效，及红钮关闭后 What's New 反复弹出"),
                WhatsNewEntry(type: .fixed, text: "修复清理计划修改触发时间后仍按旧时间执行、页面切换动效方向错乱"),
                WhatsNewEntry(type: .fixed, text: "修复剪贴板历史数据库故障时伪装成空列表，现显示错误原因与重试入口"),
                WhatsNewEntry(type: .fixed, text: "快捷用语、保持唤醒、新手向导等页面文案接入中英双语，英文环境不再残留中文"),
            ]
        ),
        WhatsNewRelease(
            version: "3.12.0",
            entries: [
                WhatsNewEntry(type: .added, text: "Token 用量统计支持中文单位：设置中切换为「万 / 亿」，如 100万、1.2亿"),
                WhatsNewEntry(type: .changed, text: "「开机自启」移至通用设置，特性页不再单独列出"),
                WhatsNewEntry(type: .changed, text: "反转滚动、平滑滚动、鼠标导航、Dock 点击合并为单一「鼠标增强」，一次开关整体启停"),
            ]
        ),
        WhatsNewRelease(
            version: "3.11.0",
            entries: [
                WhatsNewEntry(type: .added, text: "新增应用内自动更新：自动检查、下载并一键安装新版本，升级更无感"),
                WhatsNewEntry(type: .added, text: "应用菜单新增「检查更新…」入口，可随时手动检查"),
                WhatsNewEntry(type: .added, text: "升级场景化新手向导：引入 4 大场景预设卡片、快捷键演练场与菜单栏定锚指引"),
                WhatsNewEntry(type: .changed, text: "提示词优化自动替换模式隔离剪贴板，并提供专属双态提示文案"),
                WhatsNewEntry(type: .changed, text: "Antigravity Token 额度支持直接通过 agy CLI 兜底读取"),
                WhatsNewEntry(type: .changed, text: "本版本是最后一个需要手动下载安装的版本，之后的升级将全自动完成"),
                WhatsNewEntry(type: .fixed, text: "修复卸载器与清理器在紧凑模式下的各阶段高度对齐问题"),
                WhatsNewEntry(type: .fixed, text: "修复额度重置烟花不可见的问题"),
            ]
        ),
        WhatsNewRelease(
            version: "3.10.0",
            entries: [
                WhatsNewEntry(type: .added, text: "桌面宠物交互升级：拖起后甩出带惯性与弹跳，拖动时随方向切换动作"),
                WhatsNewEntry(type: .added, text: "桌面宠物会转头看向鼠标，悬停时有回应；尺寸支持连续滑杆调节，并内置哆啦A梦素材"),
                WhatsNewEntry(type: .added, text: "桌面宠物新增对话气泡与自主小动作，日常表现更生动"),
                WhatsNewEntry(type: .added, text: "桌面便签新建时在鼠标位置弹出，并沿用上次调整的尺寸"),
                WhatsNewEntry(type: .added, text: "Token 用量 Top 列表支持按模型 / App 维度切换"),
                WhatsNewEntry(type: .changed, text: "便签正文字号与行高支持调节，调整结果自动成为新便签的默认排版"),
                WhatsNewEntry(type: .changed, text: "移除风扇监控与控制功能"),
                WhatsNewEntry(type: .changed, text: "供应商管理入口收敛到控制中心，设置窗口移除重复的切换页"),
                WhatsNewEntry(type: .fixed, text: "修复 macOS 27 下剪贴板面板无法拖动、位置半悬屏外"),
                WhatsNewEntry(type: .fixed, text: "修复多屏环境下控制中心首次打开位置偏移与页面高度震荡"),
                WhatsNewEntry(type: .fixed, text: "修复退出应用时便签中未保存的内容可能丢失"),
                WhatsNewEntry(type: .fixed, text: "修复 zcode / codex 用量统计中断与模型归属错误"),
                WhatsNewEntry(type: .fixed, text: "修复桌宠走路停不下来、社区宠物抚摸消失等播放异常"),
                WhatsNewEntry(type: .fixed, text: "修复截图时窗口遮罩的异常淡入淡出动画"),
            ]
        ),
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
