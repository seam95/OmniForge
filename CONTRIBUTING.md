# 贡献指南

感谢你愿意为 OmniForge 贡献代码。请阅读以下约定。

## 开发环境

- macOS 14.0+
- Swift 5（Swift toolchain 6.x 可编译；`Package.swift` 为 tools-version 6.0）
- Xcode 16+ 或 Xcode 命令行工具（`swift` / `actool` / `codesign`）

## 快速开始

```bash
git clone https://github.com/seam95/OmniForge.git
cd OmniForge
swift build
./build.sh
```

本地调试可直接打开 `build/stage/OmniForge.app`，或执行 `./build.sh --install` 安装到 `/Applications`。

## 构建与测试

```bash
# Debug 编译
swift build

# Release 编译
swift build -c release

# 组装 .app bundle（含 actool 资源编译与 codesign）
./build.sh

# 安装到 /Applications
./build.sh --install

# 运行全部单元测试（本仓库使用 XCTest；须禁用默认 Swift Testing 运行器）
swift test --disable-swift-testing

# 运行单个测试套件
swift test --disable-swift-testing --filter OmniForgeTests.ClipboardHistoryManagerTests
```

## 架构与代码风格

### 分层

- **UI 层（`Sources/OmniForge/Views/`，SwiftUI）**：View 只订阅状态、触发意图，不含业务逻辑。
- **业务逻辑层（`Sources/OmniForge/Services/`）**：每个 Manager 职责单一，通过构造器注入依赖。
- **系统 API 层（`Sources/OmniForge/System/`）**：所有 macOS 系统 API 封装在协议后面，便于测试。

### 核心原则

- **`AppState` 是唯一的中心状态对象**（`@MainActor ObservableObject`），聚合所有 Manager，通过 Combine 转发 `objectWillChange`。
- **协议驱动的依赖注入**：为外部依赖定义协议（如 `TISClient`、`PasteboardClient`），并提供 Fake 实现用于测试。
- 遵循 SOLID、DRY、关注点分离、YAGNI。

### 代码风格

- 缩进：**4 个空格**
- 命名：类型 `UpperCamelCase`，成员 `lowerCamelCase`
- **注释语言：中文**（关键流程、核心逻辑、重点难点必须注释）
- SwiftUI-first：业务逻辑下沉到 Manager，View 保持纯净
- 删除无用代码，不保留旧的兼容性代码

## 测试约定

- 使用 XCTest 框架，Fake / Stub 模式做单元测试。
- `ImmediateScheduler` 替代 `MainQueueScheduler` 保证测试同步执行。
- 测试文件目录结构与源码镜像（`Tests/OmniForgeTests/`）。
- 每次行为变更应新增或更新测试；用户可见行为变更同步更新 `docs/FEATURE_CHANGES.md`。

## 提交规范

- 使用清晰的提交信息，推荐 [Conventional Commits](https://www.conventionalcommits.org/) 风格，例如：
  - `feat(clipboard): 支持文件类型剪贴项`
  - `fix(input-method): 修复纠正重试逻辑`
  - `docs: 更新 README`
- 一个 PR 聚焦一件事，便于 review。
- 只暂存与本次改动相关的文件，不混入无关工作区变更。

## 文档

- 新功能：在 `docs/active/YYYY-MM-DD-中文功能名/` 先确认 `SPEC.md`，再写 `PLAN.md`，完成后归档到 `docs/archive/`。
- 用户向功能与行为变更的唯一记录：`docs/FEATURE_CHANGES.md`。
- 根目录 `README.md`（英文）与 `README_zh.md`（中文）面向用户；开发细节放在本文件与 `docs/`。

## PR 流程

1. Fork 仓库并新建分支。
2. 确保本地测试通过：`swift test --disable-swift-testing`；需要时执行 `./build.sh`。
3. 如有必要，更新 README / `FEATURE_CHANGES.md` / 功能文档。
4. 提交 PR，描述变更内容与动机；涉及界面时尽量附截图。

再次感谢你的贡献。
