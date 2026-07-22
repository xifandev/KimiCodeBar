using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;
using KimiCodeBar.Core;
using KimiCodeBar.Core.Services;

namespace KimiCodeBar.Services;

/// <summary>
/// 更新检查服务（App 层实现）。
/// 从 GitHub Release 接口抓取最新 App 版本，从 changelog 抓取最新 CLI 版本，
/// 复用纯逻辑 <see cref="VersionComparer"/> 与 <see cref="ChangelogParser"/>。
/// </summary>
public sealed class UpdateService : IUpdateService
{
    private readonly HttpClient _http;

    public UpdateService(HttpClient http)
    {
        _http = http;
    }

    /// <inheritdoc/>
    public async Task<(string? Version, string? Error)> FetchLatestCliVersionAsync()
    {
        try
        {
            var text = await GetStringWithUserAgentAsync(Constants.ChangelogUrl).ConfigureAwait(false);
            var entry = ChangelogParser.Parse(text);
            return entry is null
                ? (null, "未找到版本号")
                : (entry.Version, null);
        }
        catch (Exception ex)
        {
            return (null, ex.Message);
        }
    }

    /// <inheritdoc/>
    public async Task<(string? Version, string? Error)> FetchLatestAppReleaseAsync()
    {
        try
        {
            var json = await GetStringWithUserAgentAsync(Constants.GitHubReleaseApi).ConfigureAwait(false);
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.TryGetProperty("tag_name", out var tag) && tag.ValueKind == JsonValueKind.String)
            {
                var raw = tag.GetString();
                return (raw is null ? null : VersionComparer.Normalize(raw), null);
            }

            return (null, "未找到版本号");
        }
        catch (Exception ex)
        {
            return (null, ex.Message);
        }
    }

    /// <inheritdoc/>
    public async Task<(string? Text, string? Error)> FetchChangelogAsync()
    {
        try
        {
            var text = await GetStringWithUserAgentAsync(Constants.ChangelogUrl).ConfigureAwait(false);
            return (text, null);
        }
        catch (Exception ex)
        {
            return (null, ex.Message);
        }
    }

    private async Task<string> GetStringWithUserAgentAsync(string url)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.UserAgent.ParseAdd(Constants.UserAgent);
        // GitHub API 建议携带 Accept 头。
        if (url.Contains("api.github.com", StringComparison.OrdinalIgnoreCase))
        {
            request.Headers.Accept.ParseAdd("application/vnd.github+json");
        }

        using var response = await _http.SendAsync(request).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadAsStringAsync().ConfigureAwait(false);
    }
}
