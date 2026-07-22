using System.Net.Http;
using KimiCodeBar.Core;
using KimiCodeBar.Core.Models;

namespace KimiCodeBar.Services;

/// <summary>
/// 本地端口探测服务。按顺序探测候选端口是否响应（2xx/3xx 即视为 Kimi Web 运行中）。
/// 探测超时按 <see cref="Constants.ProbeTimeoutMilliseconds"/> 单端口控制。
/// </summary>
public sealed class PortProbeService
{
    private readonly HttpClient _http;

    public PortProbeService(HttpClient http)
    {
        _http = http;
        // 单端口硬超时由调用方 CTS 控制；此处仅设一个上限避免无限等待。
        _http.Timeout = TimeSpan.FromMilliseconds(Constants.ProbeTimeoutMilliseconds + 500);
    }

    /// <summary>候选端口列表（来自 <see cref="Constants.CandidatePorts"/>）。</summary>
    public IReadOnlyList<int> CandidatePorts => Constants.CandidatePorts;

    /// <summary>
    /// 探测第一个响应的端口。全部无响应返回 null。
    /// </summary>
    public async Task<int?> ProbeAsync()
    {
        foreach (var port in CandidatePorts)
        {
            using var cts = new CancellationTokenSource(Constants.ProbeTimeoutMilliseconds);
            if (await IsPortResponsiveAsync(port, cts.Token).ConfigureAwait(false))
            {
                return port;
            }
        }

        return null;
    }

    private async Task<bool> IsPortResponsiveAsync(int port, CancellationToken token)
    {
        // 优先探测根路径，其次 openapi.json（Kimi Web 可能仅暴露 API）。
        foreach (var path in new[] { "/", "/openapi.json" })
        {
            try
            {
                using var response = await _http.GetAsync(
                    $"http://127.0.0.1:{port}{path}", token).ConfigureAwait(false);
                var status = (int)response.StatusCode;
                if (status is >= 200 and < 400)
                {
                    return true;
                }
            }
            catch (OperationCanceledException)
            {
                // 端口超时，继续下一个路径。
            }
            catch
            {
                // 连接被拒 / 解析失败等，视为未响应。
            }
        }

        return false;
    }
}
