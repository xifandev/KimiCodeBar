# KimiCodeBar 领域词汇表

## 账号与凭证

### Kimi 账号（KimiAccount）

一个 Kimi 账号 = 一对 OAuth token（access_token + refresh_token）+ 用户别名 + 可选的账号唯一标识。Bar 在「设置 → 账号」中管理多个 Kimi 账号。

### 主账号（Primary Account）

Bar 面板中用于展示配额的账号。只影响 Bar 自己的 UI 展示，与 CLI 无关。已有功能：账号列表中「设为主账号」。

### CLI 活跃账号

Kimi Code CLI 实际使用的账号，即 `~/.kimi-code/credentials/kimi-code.json` 中保存的那份凭证对应的账号。CLI 本身不支持多账号，任意时刻只有一个 CLI 活跃账号。

### 切换账号（Switch Account）

**专指更换 CLI 活跃账号**：把 Bar 账号列表中某个已登录账号的 token 复制写入 CLI 凭证文件，让之后启动的 kimi CLI 以该账号运行。不改变 Bar 的主账号。

### CLI 使用中

账号列表里的状态标签：展示时实时读取 CLI 凭证文件，与 Bar 账号列表比对 token，匹配上的账号即为 CLI 活跃账号，显示「CLI 使用中」。CLI 轮换 token 后匹配失效，标签自然消失——标签表达的是「此刻凭证一致」，不是持久的归属记录。

### 凭证隔离原则

Bar 的授权、刷新、删除只操作 Bar 自己的凭证文件（`~/Library/Application Support/KimiCodeBar/credentials.json`），历史上刻意不读写 CLI 凭证，避免 refresh_token 服务端轮换导致互相失效。「切换账号」是该原则唯一的、显式的例外：仅在用户主动触发切换的瞬间写入 CLI 凭证文件，此后两边各自独立、不再同步。
