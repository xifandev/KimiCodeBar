using KimiCodeBar.Core.Exceptions;
using KimiCodeBar.Core.Models;

namespace KimiCodeBar.Core.Services;

/// <summary>
/// 用量查询服务接口（由 App 层的 <c>QuotaService</c> 实现）。
/// </summary>
public interface IQuotaService
{
    /// <summary>
    /// 使用 Bearer token（API Key 或 OAuth token）查询用量。
    /// </summary>
    /// <param name="token">Authorization: Bearer 携带的 token。</param>
    /// <returns>成功返回 <see cref="KimiQuota"/>，失败返回 <see cref="QuotaError"/>。</returns>
    Task<Result<KimiQuota, QuotaError>> FetchQuotaAsync(string token);
}
