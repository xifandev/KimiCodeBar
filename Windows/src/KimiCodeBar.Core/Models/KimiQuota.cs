using KimiCodeBar.Core.Models;

namespace KimiCodeBar.Core.Models;

/// <summary>
/// Kimi 用量聚合结果，对应一次 <c>/coding/v1/usages</c> 响应的完整解析。
/// </summary>
public sealed class KimiQuota
{
    /// <summary>本周用量。</summary>
    public QuotaDetail Weekly { get; init; } = new();

    /// <summary>5 小时用量。</summary>
    public QuotaDetail FiveHour { get; init; } = new();

    /// <summary>总额度。</summary>
    public QuotaDetail TotalQuota { get; init; } = new();

    /// <summary>会员等级（如 LEVEL_FREE）。</summary>
    public string? MembershipLevel { get; init; }

    /// <summary>加油包钱包（未开通时为 null）。</summary>
    public BoosterWallet? BoosterWallet { get; init; }
}
