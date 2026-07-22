namespace KimiCodeBar.Core.Services;

/// <summary>
/// 更新检查服务接口（由 App 层的 <c>UpdateService</c> 实现）。
/// </summary>
public interface IUpdateService
{
    /// <summary>获取最新 Kimi CLI 版本（从 changelog 抓取）。返回 (版本号, 错误信息)。</summary>
    Task<(string? Version, string? Error)> FetchLatestCliVersionAsync();

    /// <summary>获取最新 App Release 版本（从 GitHub 抓取）。返回 (版本号, 错误信息)。</summary>
    Task<(string? Version, string? Error)> FetchLatestAppReleaseAsync();

    /// <summary>获取 changelog 全文。返回 (文本, 错误信息)。</summary>
    Task<(string? Text, string? Error)> FetchChangelogAsync();
}
