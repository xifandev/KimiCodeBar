namespace KimiCodeBar.Core;

/// <summary>
/// 跨文件共享常量。集中管理 API 基址、URL、候选端口、超时与 User-Agent，
/// 便于在 Windows 端确认 Kimi Web 实际端口 / CLI 参数后统一修改。
/// </summary>
public static class Constants
{
    // ===================== API =====================
    /// <summary>Kimi 用量 API 基址。</summary>
    public const string KimiApiBase = "https://api.kimi.com";

    /// <summary>用量查询端点（POST）。</summary>
    public const string UsagesEndpoint = "/coding/v1/usages";

    /// <summary>Authorization 头前缀。</summary>
    public const string BearerPrefix = "Bearer ";

    /// <summary>请求 User-Agent。</summary>
    public const string UserAgent = "KimiCodeBar/1.0";

    /// <summary>HTTP 请求超时（秒）。</summary>
    public const int HttpTimeoutSeconds = 30;

    // ===================== 外部 URL =====================
    /// <summary>中文 changelog 地址（用于抓取最新 CLI 版本与 release notes）。</summary>
    public const string ChangelogUrl = "https://moonshotai.github.io/kimi-code/zh/release-notes/changelog.md";

    /// <summary>GitHub 最新 Release 接口（用于检查 App 更新）。</summary>
    public const string GitHubReleaseApi = "https://api.github.com/repos/xifandev/KimiCodeBar/releases/latest";

    /// <summary>Kimi Code 控制台地址。</summary>
    public const string ConsoleUrl = "https://www.kimi.com/code/console";

    /// <summary>GitHub Release 发布页。</summary>
    public const string ReleasePageUrl = "https://github.com/xifandev/KimiCodeBar/releases/";

    // ===================== 端口探测 =====================
    /// <summary>Kimi Web 候选监听端口，按顺序探测。</summary>
    public static readonly IReadOnlyList<int> CandidatePorts = new[] { 3210, 8080, 8000, 3000, 8888 };

    /// <summary>
    /// Kimi Web 默认端口（兜底）。
    /// TODO: 待 Windows 端确认 kimi web 实际监听端口后回填。
    /// </summary>
    public const int DefaultKimiWebPort = 3210;

    /// <summary>单端口探测超时（毫秒）。</summary>
    public const int ProbeTimeoutMilliseconds = 2000;

    // ===================== kimi 启动 =====================
    /// <summary>
    /// kimi web 启动命令（Mac 基线一致）。
    /// TODO: 待 Windows 端确认 CLI 是否支持相同参数。
    /// </summary>
    public const string KimiWebCommand = "web --no-open --dangerous-bypass-auth";

    // ===================== 凭据 =====================
    /// <summary>凭据存储的资源名（Windows 凭据管理器 Resource）。</summary>
    public const string CredentialResourceName = "KimiCodeBar";

    /// <summary>API Key 在凭据存储中的键名。</summary>
    public const string CredentialApiKey = "api_key";
}
