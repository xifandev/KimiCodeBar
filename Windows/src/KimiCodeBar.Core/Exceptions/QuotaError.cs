namespace KimiCodeBar.Core.Exceptions;

/// <summary>
/// 用量查询错误枚举。网络 / HTTP / 解析等统一走此枚举，
/// 由 <c>QuotaService.ExtractErrorMessage</c> 抽取具体文本（兼容 error/message/detail 字段）。
/// </summary>
public enum QuotaError
{
    /// <summary>API Key 为空或格式不正确。</summary>
    InvalidKeyFormat,

    /// <summary>请求地址无效（无法构造 URL）。</summary>
    InvalidUrl,

    /// <summary>网络层错误（DNS / 超时 / 连接失败）。</summary>
    NetworkError,

    /// <summary>HTTP 非 2xx 响应。</summary>
    HttpError,

    /// <summary>响应体无法解析为用量结构。</summary>
    InvalidResponse
}

/// <summary>
/// <see cref="QuotaError"/> 到用户友好中文文案的扩展。
/// Core 不引用 WinUI/WinRT，故直接使用常量文案（v1 仅中文）。
/// </summary>
public static class QuotaErrorExtensions
{
    /// <summary>将错误枚举转换为用户可见的中文提示。</summary>
    public static string ToFriendlyMessage(this QuotaError error)
    {
        return error switch
        {
            QuotaError.InvalidKeyFormat => "API Key 格式不正确",
            QuotaError.InvalidUrl => "请求地址无效",
            QuotaError.NetworkError => "网络请求失败，请检查网络",
            QuotaError.HttpError => "服务器返回错误",
            QuotaError.InvalidResponse => "返回数据解析失败",
            _ => "未知错误"
        };
    }
}
