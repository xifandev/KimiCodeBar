# KimiBar

一个简洁的 macOS 菜单栏小工具，实时显示 [Kimi Code](https://www.kimi.com/code) 的额度使用情况。

## 功能

- 在菜单栏直接显示本周用量和 5 小时用量百分比
- 点击图标展开面板，查看详细额度、重置时间
- 支持手动刷新和自动刷新（每分钟）
- 只需填入 Kimi Code API Key 即可使用

## 截图

![菜单栏显示](Screenshots/menu-bar.png)

![展开面板](Screenshots/panel.png)

## 安装

### 直接运行（推荐）

1. 下载 Releases 中的最新版本（暂未发布，可自行编译）
2. 将 `KimiBar.app` 拖入「应用程序」文件夹
3. 首次运行请在「系统设置 → 隐私与安全性」中允许打开

### 自行编译

```bash
git clone https://github.com/xifandev/KimiBar.git
cd KimiBar
open KimiBar.xcodeproj
```

使用 Xcode 选择你的 Mac，点击 Run 即可。

## 使用

1. 点击菜单栏中的 KimiBar 图标
2. 在「API Key」输入框中填入你的 Kimi Code API Key
3. 点击「保存」或「立即刷新」

> API Key 可在 [KimiCode 控制台](https://www.kimi.com/code/console) 获取。

## 接口说明

如果你想参考接口自己实现一个类似工具，核心请求如下：

```http
GET https://api.kimi.com/coding/v1/usages
Authorization: Bearer <你的 API Key>
```

返回示例（节选）：

```json
{
  "usage": {
    "limit": "1000000",
    "used": "12345",
    "remaining": "987655",
    "resetTime": "2026-07-18T00:00:00.000Z"
  },
  "limits": [
    {
      "window": { "duration": 300 },
      "detail": {
        "limit": "100000",
        "used": "5000",
        "remaining": "95000",
        "resetTime": "2026-07-11T16:00:00.000Z"
      }
    }
  ]
}
```

说明：

- `usage` 表示本周（7 天）总用量
- `limits` 数组中包含多个时间窗口的限额，`duration: 300` 表示 5 小时窗口（300 秒）
- 所有数值字段目前为字符串类型，使用时建议先做数值转换

## 隐私说明

- API Key 仅保存在本地设备的 `NSUserDefaults`（`~/Library/Preferences/com.kimibar.app.plist`）中
- 不会上传到任何第三方服务器
- 所有网络请求均直接发往 Kimi 官方 API（`api.kimi.com`）

## 技术栈

- Swift
- SwiftUI
- AppKit（MenuBarExtra）

## 许可证

[MIT](LICENSE)
