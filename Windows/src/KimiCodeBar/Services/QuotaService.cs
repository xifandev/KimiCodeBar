using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using KimiCodeBar.Core;
using KimiCodeBar.Core.Exceptions;
using KimiCodeBar.Core.Models;
using KimiCodeBar.Core.Services;

namespace KimiCodeBar.Services;

/// <summary>
/// 用量查询服务（App 层实现）。
/// 使用 <see cref="HttpClient"/> 调用 Kimi 用量 API（Bearer 鉴权），
/// 复用纯逻辑 <see cref="QuotaParser"/> 解析响应，并提供错误文本抽取。
/// </summary>
public sealed class QuotaService : IQuotaService
{
    private readonly HttpClient _http;

    public QuotaService(HttpClient http)
    {
        _http = http;
    }

    /// <inheritdoc/>
    public async Task<Result<KimiQuota, QuotaError>> FetchQuotaAsync(string token)
    {
        if (string.IsNullOrWhiteSpace(token))
        {
            return Result<KimiQuota, QuotaError>.Fail(QuotaError.InvalidKeyFormat);
        }

        if (!Uri.TryCreate(Constants.KimiApiBase + Constants.UsagesEndpoint, UriKind.Absolute, out var uri))
        {
            return Result<KimiQuota, QuotaError>.Fail(QuotaError.InvalidUrl);
        }

        using var request = new HttpRequestMessage(HttpMethod.Post, uri);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Headers.UserAgent.ParseAdd(Constants.UserAgent);

        HttpResponseMessage response;
        try
        {
            response = await _http.SendAsync(request).ConfigureAwait(false);
        }
        catch (HttpRequestException)
        {
            return Result<KimiQuota, QuotaError>.Fail(QuotaError.NetworkError);
        }
        catch (TaskCanceledException)
        {
            return Result<KimiQuota, QuotaError>.Fail(QuotaError.NetworkError);
        }

        var bytes = await response.Content.ReadAsByteArrayAsync().ConfigureAwait(false);

        if (!response.IsSuccessStatusCode)
        {
            // 非 2xx：记录抽取到的错误文本（详细错误写调试日志），统一返回 HttpError。
            _ = ExtractErrorMessage(bytes);
            return Result<KimiQuota, QuotaError>.Fail(QuotaError.HttpError);
        }

        try
        {
            var quota = QuotaParser.Parse(bytes);
            return Result<KimiQuota, QuotaError>.Ok(quota);
        }
        catch (JsonException)
        {
            return Result<KimiQuota, QuotaError>.Fail(QuotaError.InvalidResponse);
        }
    }

    /// <summary>
    /// 从错误响应体抽取友好错误文本，兼容 <c>error</c> / <c>message</c> / <c>detail</c> 字段
    /// （error 亦可能为包含 message 的对象）。无法解析时回退原文。
    /// </summary>
    public static string? ExtractErrorMessage(ReadOnlySpan<byte> data)
    {
        try
        {
            using var doc = JsonDocument.Parse(data);
            var root = doc.RootElement;

            if (root.TryGetProperty("error", out var error))
            {
                if (error.ValueKind == JsonValueKind.String)
                {
                    return error.GetString();
                }

                if (error.ValueKind == JsonValueKind.Object
                    && error.TryGetProperty("message", out var errMsg)
                    && errMsg.ValueKind == JsonValueKind.String)
                {
                    return errMsg.GetString();
                }
            }

            if (root.TryGetProperty("message", out var message) && message.ValueKind == JsonValueKind.String)
            {
                return message.GetString();
            }

            if (root.TryGetProperty("detail", out var detail) && detail.ValueKind == JsonValueKind.String)
            {
                return detail.GetString();
            }
        }
        catch
        {
            // 忽略解析失败，回退到原文。
        }

        try
        {
            var text = Encoding.UTF8.GetString(data.ToArray());
            return string.IsNullOrEmpty(text) ? null : text;
        }
        catch
        {
            return null;
        }
    }
}
