# KimiCodeBar 交互规范

## 平台规范优先

在实现任何涉及系统组件、框架 API 或平台特定行为的功能前，务必先阅读对应系统的官方文档 / Human Interface Guidelines / API Reference，确认推荐用法。不要凭直觉或跨平台经验直接套用。

典型案例：本项目的主题切换曾尝试对 `MenuBarExtra` 内容视图使用 `.preferredColorScheme()` 强制切换 Light/Dark，结果触发 SwiftUI 运行时警告 `Publishing changes from within view updates is not allowed` 且界面无法正常响应。正确的 macOS 做法是通过 `NSApplication.shared.appearance` 控制应用整体外观，让 `NSColor` 动态配色自动适配。

## 可点击元素反馈规范

所有可点击的 UI 元素必须同时满足以下两条反馈规则，以保证 macOS 菜单栏应用的操作体验一致、清晰：

1. **鼠标悬停时显示手型光标（pointingHand）**
   - 使用自定义 `.cursor(.pointingHand)` 扩展实现。
   - 系统原生按钮（如 `.borderedProminent`）默认不会变成手型光标，仍需显式添加。

2. **鼠标悬停时提供高亮反馈**
   - 必须改变背景色或前景色，让用户明确感知到当前元素可点击。
   - 推荐做法：背景从 `Color.white.opacity(0.08)` 提升到 `Color.white.opacity(0.14)`，前景从 `.kimiTextSecondary` 提升到 `.kimiTextPrimary`。
   - 使用 `@State private var isHoveredXXX` 配合 `.onHover { isHoveredXXX = $0 }` 实现。

## 当前已应用该规范的位置

- `ActionButton`：面板底部四个操作按钮。
- `CommunityButton`：面板右上角「社区版」GitHub 链接按钮。
- `LinkRow`：通用链接行组件。
- `SettingsView` 关闭按钮：设置气泡右上角圆形 × 按钮。
- `SettingsView` 「去控制台获取」链接按钮。
- `SettingsView` 「修改 / 保存 / 完成」按钮。
- `UpdateAlertView` 「稍后再说 / 安装更新」按钮。
- `AppUpdateAlertView` 「忽略本次更新 / 查看更新」按钮。
- 版本卡片右侧的「更新日志」入口：悬停高亮并弹出更新记录气泡。
- `UpdateLogView` 关闭按钮：更新日志气泡右上角圆形 × 按钮。
- `ErrorMessageView` 错误信息复制按钮。

## 新增可点击元素时的 checklist

- [ ] 是否为该元素添加 `.cursor(.pointingHand)`？
- [ ] 是否为该元素添加 `@State isHovered` 状态？
- [ ] 是否在 `.onHover` 中改变背景/前景色，产生明显的高亮反馈？
- [ ] 禁用状态下是否移除了手型光标并降低视觉权重？

## 相关实现文件

- `macOS/KimiCodeBar/KimiCodeBarApp.swift`：主面板、设置气泡、更新弹窗等 UI 组件。

## 版本号管理

- **App 本地版本号**来自 macOS 标准的 `CFBundleShortVersionString`，读取位置：
  - `macOS/KimiCodeBar/Info.plist` -> `CFBundleShortVersionString`
  - 代码中通过 `Bundle.main.infoDictionary?["CFBundleShortVersionString"]` 读取（不要硬编码）。
- **Xcode 构建设置**里也有一个 `MARKETING_VERSION`，打包时会写入 `Info.plist`。因此发版前需要**同时改两处**，保持一致：
  1. `macOS/KimiCodeBar/Info.plist` 的 `CFBundleShortVersionString`
  2. `macOS/KimiCodeBar.xcodeproj/project.pbxproj` 里的 `MARKETING_VERSION`
- **GitHub Release tag** 建议用 `v{VERSION}` 格式，例如 `v1.0.0`，`normalizeVersion` 会自动提取出版本号。
- 发版时创建 GitHub Release 并上传 `.app.zip` 或 `.dmg` 即可；App 内的「查看更新」会跳转到 `https://github.com/xifandev/KimiCodeBar/releases/`。
