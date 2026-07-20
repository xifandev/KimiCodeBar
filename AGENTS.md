# KimiCodeBar 交互规范

## 代码提交规范

- 完成修改后，尤其是改动较多、涉及关键功能 / UI 重构 / bug 修复时，Agent 应直接执行 `git commit` 并 `git push` 推送到 GitHub，无需询问用户确认。
- 推送前只暂存与本次修改相关的改动，不要把工作区中无关的未提交改动一并提交。
- Commit message 使用中文，标题和正文都用中文，避免中英文混用。

## 平台规范优先

实现任何涉及系统组件、框架 API 或平台特定行为的功能前，先阅读对应系统的官方文档 / Human Interface Guidelines / API Reference，确认推荐用法。

> 案例：主题切换不要对 `MenuBarExtra` 内容视图使用 `.preferredColorScheme()`，这会触发 SwiftUI 运行时警告 `Publishing changes from within view updates is not allowed`。应通过 `NSApplication.shared.appearance` 控制应用整体外观，让 `NSColor` 动态配色自动适配。

## Kimi CLI 命令参考

涉及 `kimi` 命令（如 `kimi web`、`kimi server` 等）的改动前，必须先查阅官方文档确认命令的真实行为与参数，不要凭猜测实现：

- 命令参考：https://moonshotai.github.io/kimi-code/zh/reference/kimi-command.html
- 注意：从 Kimi Code 0.28 起，`kimi web` 是启动本地 Web 前台的唯一入口，并以**前台进程**运行；`kimi server` 已 deprecated，`kimi web kill`、`kimi web ps` 等生命周期命令已移除。停止服务应通过结束 `kimi web` 前台进程实现。
- 本地服务还会挂载 `GET /openapi.json`（REST 路由文档）与 `GET /asyncapi.json`（WebSocket 协议文档），需要接口细节时优先从运行中的实例拉取。

## 构建验证规范

- 写完代码后只做临时编译验证（`xcodebuild build` 确认编译通过），验证完删除本次构建产物（DerivedData 中对应的 Build 目录）。
- 不需要运行测试、也不需要启动 App 验证——维护者会自己用 Xcode 构建运行。

## 可点击元素反馈规范

所有可点击的 UI 元素必须同时满足：

1. **鼠标悬停时显示手型光标（pointingHand）**
   - 使用自定义 `.cursor(.pointingHand)` 扩展实现。
   - 即使是系统原生按钮（如 `.borderedProminent`）也需要显式添加。

2. **鼠标悬停时提供高亮反馈**
   - 改变背景色或前景色，让用户明确感知元素可点击。
   - 推荐：背景从 `Color.white.opacity(0.08)` 提升到 `Color.white.opacity(0.14)`，前景从 `.kimiTextSecondary` 提升到 `.kimiTextPrimary`。
   - 使用 `@State private var isHoveredXXX` 配合 `.onHover { isHoveredXXX = $0 }` 实现。

新增可点击元素时检查：

- [ ] 是否添加了 `.cursor(.pointingHand)`？
- [ ] 是否添加了 `@State isHovered` 状态？
- [ ] 是否在 `.onHover` 中改变背景/前景色？
- [ ] 禁用状态下是否移除了手型光标并降低视觉权重？

## 本地化规范（中 / 英双语）

App 支持应用内语言切换（跟随系统 / 中文 / English），机制见 `macOS/KimiCodeBar/LanguageManager.swift`：

- **中文字面量即本地化 key**，英文翻译维护在 `macOS/KimiCodeBar/Localizable.xcstrings`（String Catalog，编译进 `en.lproj`）。查不到译文时回退中文，界面不会出空白。
- 新增用户可见文案时：
  - `Text("中文")` 一律写成 `LText("中文")`（自观察包装，语言切换自动重渲染）。
  - String 类型场景（组件 title 参数、枚举 displayName 等）用 `languageManager.tr("中文")`（View 内需有 `@StateObject private var languageManager = LanguageManager.shared`）或静态 `LanguageManager.tr("中文")`。
  - 插值用 `%@`（多个用 `%1$@`/`%2$@`），字面量 `%` 写 `%%`。
  - 同时在 `Localizable.xcstrings` 补上 `en` 翻译，术语与已有条目保持一致（如 加油包 Booster Pack、归档 Archive）。
- 品牌名（Kimi / KimiCodeBar / Kimi Web）、菜单栏图形样式的 `7D`/`5H` 标注不做本地化。

## 版本号管理

- App 版本读取 `macOS/KimiCodeBar/Info.plist` 的 `CFBundleShortVersionString`，代码中通过 `Bundle.main.infoDictionary?["CFBundleShortVersionString"]` 读取。
- 发版前需同时修改两处，保持一致：
  1. `macOS/KimiCodeBar/Info.plist` 的 `CFBundleShortVersionString`
  2. `macOS/KimiCodeBar.xcodeproj/project.pbxproj` 的 `MARKETING_VERSION`
- GitHub Release tag 使用 `v{VERSION}` 格式，例如 `v1.0.0`。
- App 内「查看更新」跳转到 `https://github.com/xifandev/KimiCodeBar/releases/`。

## Release Notes 规范

- 不依赖 GitHub 自动生成的 Release Notes。
- 每个版本整理 3~5 条核心更新点，由维护者复制到 GitHub Release body。
- 一句话一条，不写细节堆砌，不写「修复了若干 bug」这类空话。
