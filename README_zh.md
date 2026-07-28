# OmniForge

<p align="center">
  <img src="Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-256.png" width="128" alt="OmniForge 图标">
</p>

<p align="center">
  <strong>模块化的 macOS 菜单栏工具集</strong>：输入法锁定、剪贴板历史、截图标注、系统监控与日常实用工具。
</p>

<p align="center">
  <a href="./README.md">English</a> · <a href="./README_zh.md">中文</a>
</p>

---

## 截图

应用截图与演示 GIF 待补充。

## 功能

OmniForge 以 **功能中心** 为核心：按需安装功能、按功能授予权限，避免菜单栏与权限一次塞满。

### 输入

- **输入法锁定** — 按使用场景固定输入法，减少中英切换错乱。

### 剪贴板

- **剪贴板历史** — 本地记录文本、图片、文件、链接与富文本；支持搜索、筛选与再次粘贴。
- **快捷用语** — 保存、编辑并快速粘贴常用文本片段。

### 截图

- **全能截图** — 选区 / 全屏捕获，标注工具、钉图及相关捕获流程。

### 系统监控

- **监控面板** — CPU、GPU、内存、温度、网络、磁盘、电池与进程排行等。
- **菜单栏指标** — 自选常驻指标与布局，支持阈值告警。
- **告警** — CPU、温度、内存、磁盘空间、电池等通知提醒。

### 电源

- **保持唤醒** — 按时长或无限期阻止休眠；在机型与系统允许时支持合盖保持唤醒。

### 生产力

- **暂存架** — 停放文件、图片、链接与文本，稍后再拖入其他应用。
- **清理** — 扫描残留、缓存、日志等项目，确认后再处理。
- **卸载器** — 查找应用本体及相关支持文件，确认后移到废纸篓。
- **取色器** — 从屏幕取色，复制 HEX / RGB / HSL。
- **网络诊断** — 本机网络身份、公网 IP、监听端口与进程信息。

### 鼠标与触控板

- **反转滚动** — 单独反转鼠标滚轮，保留触控板自然滚动。
- **平滑滚动** — 将滚轮步进转换为更平滑的滚动。
- **鼠标导航** — 侧键映射为后退 / 前进。
- **Dock 点击** — 通过 Dock 图标最小化、恢复或循环窗口。

### 系统与体验

- 开机自启、可选隐藏 Dock 图标
- 首次引导、权限门户与功能中心
- 语言：简体中文、英文，或跟随系统

面向用户的行为变更记录见 [`docs/FEATURE_CHANGES.md`](docs/FEATURE_CHANGES.md)。

## 系统要求

- **macOS 14** 或更高版本
- 从源码构建：Xcode 16+，或匹配的 Swift 工具链与命令行工具（`swift`、`actool`、`codesign`）

## 安装

### 下载 Release

1. 打开 [Releases](https://github.com/seam95/OmniForge/releases)。
2. 下载最新的 `.dmg` 或 `.zip`。
3. 将 **OmniForge** 拖入「应用程序」并启动。
4. 按所启用功能授予系统权限（见下表）。

### 源码构建

```bash
git clone https://github.com/seam95/OmniForge.git
cd OmniForge
swift build
./build.sh
open build/stage/OmniForge.app
```

- `./build.sh` 组装并签名 `.app`（优先 Developer ID，否则 ad-hoc）。
- `./build.sh --install` 安装到 `/Applications`。

## 权限说明

权限按 **功能** 申请，不会在首次启动时一次性全部索取：

| 权限 | 常见相关功能 |
|------|----------------|
| 辅助功能 | 输入法锁定、鼠标相关工具；保持唤醒的指针微动（若开启） |
| 输入监控 | 部分输入相关能力（启用时） |
| 屏幕录制 | 截图 |
| 完全磁盘访问 | 清理、卸载器 |
| 通知 | 系统监控告警、保持唤醒（可选） |

剪贴板历史、快捷用语、暂存架、取色器、网络诊断在基础使用下对隐私权限要求较低。应用内 **设置 → 权限 / 功能中心** 可查看各功能实时状态。

## 开发

简要分层：

- **UI**（`Views/`）— SwiftUI，只订阅状态、触发意图
- **Services** — 每个 Manager 职责单一，构造器注入
- **System** — 系统 API 封装在协议后，便于测试

```bash
# Debug 编译
swift build

# 组装 .app
./build.sh

# 单元测试（XCTest；当前工具链需加此参数）
swift test --disable-swift-testing
```

架构约定、代码风格与 PR 流程见 [CONTRIBUTING.md](CONTRIBUTING.md)。

### 依赖

由根目录 [`Package.swift`](Package.swift) 管理：

- [GRDB.swift](https://github.com/groue/GRDB.swift) — 本地 SQLite
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) — 全局快捷键

## 贡献

欢迎 Issue 与 PR。提交前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

[MIT](LICENSE)
