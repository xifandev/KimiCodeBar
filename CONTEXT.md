# KimiCodeBar 领域词汇表

## 账号与凭证

### Kimi 账号（KimiAccount）

一个 Kimi 账号 = 一份凭证（`AccountCredential`：OAuth token 对，或 API Key）+ 用户别名 + 可选的账号唯一标识 + 提供方（`AccountProvider`，目前只有 `kimi`）。Bar 在「设置 → 账号管理」中统一管理全部账号，添加时由用户选择授权登录（浏览器 OAuth）或 API Key 登录。

凭证文件（`~/Library/Application Support/KimiCodeBar/credentials.json`，DEV 版为 `KimiCodeBarDev/credentials.json`，两边账号池完全隔离）只认新格式（provider + credential 结构）；旧版单 token 格式按无账号处理，不做迁移，用户升级后重新登录即可。

**扩展路径**：未来接入其它提供方（如 DeepSeek 余额监测）时，给 `AccountProvider` 加 case，在 `refreshAllAccounts` 的刷新任务组里按 provider 分派对应的查询服务，设置页与面板卡片按 provider 渲染即可。注意「切换账号」（写 CLI 凭证）仅对 OAuth 凭证的 Kimi 账号有意义。

### 加油包余额（自动显示）

加油包按账号归属，面板中是否展示完全由接口返回的开通状态自动决定：`BoosterWallet.isEnabled`（官方后台已开通加油包）为真时，对应账号才显示加油包余额（单账号出独立卡片，多账号在账号卡片内出一行）；未开通则不占位，无任何手动开关。

### 主账号（Primary Account）

Bar 面板中用于展示配额的账号。只影响 Bar 自己的 UI 展示，与 CLI 无关。已有功能：账号列表中「设为主账号」。

### CLI 活跃账号

Kimi Code CLI 实际使用的账号，即 `~/.kimi-code/credentials/kimi-code.json` 中保存的那份凭证对应的账号。CLI 本身不支持多账号，任意时刻只有一个 CLI 活跃账号。

### 切换账号（Switch Account）

**专指更换 CLI 活跃账号**：把 Bar 账号列表中某个已登录账号的 OAuth token 复制写入 CLI 凭证文件，让之后启动的 kimi CLI 以该账号运行。不改变 Bar 的主账号。仅 OAuth 账号可切换——CLI 凭证格式是 access/refresh token 对，API Key 账号没有「切换账号」入口。

### CLI 使用中

账号列表里的状态标签：展示时实时读取 CLI 凭证文件，与 Bar 账号列表比对 token，匹配上的账号即为 CLI 活跃账号，显示「CLI 使用中」。CLI 轮换 token 后匹配失效，标签自然消失——标签表达的是「此刻凭证一致」，不是持久的归属记录。

### 凭证隔离原则

Bar 的授权、刷新、删除只操作 Bar 自己的凭证文件（`~/Library/Application Support/KimiCodeBar/credentials.json`，DEV 版为 `KimiCodeBarDev/credentials.json`），历史上刻意不读写 CLI 凭证，避免 refresh_token 服务端轮换导致互相失效。「切换账号」是该原则唯一的、显式的例外：仅在用户主动触发切换的瞬间写入 CLI 凭证文件，此后两边各自独立、不再同步。
