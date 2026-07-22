namespace KimiCodeBar.Core.Models;

/// <summary>
/// 加油包钱包信息。余额单位换算集中在解析阶段完成（amountLeft / 1e-8 元）。
/// </summary>
public sealed class BoosterWallet
{
    /// <summary>原始状态字符串（如 STATUS_ACTIVE）。</summary>
    public string Status { get; init; } = string.Empty;

    /// <summary>是否启用（STATUS_ACTIVE / STATUS_ENABLED 视为启用）。</summary>
    public bool IsEnabled { get; init; }

    /// <summary>货币代码（CNY / USD / EUR 等）。</summary>
    public string Currency { get; init; } = "CNY";

    /// <summary>真实余额（元）。未启用时恒为 0。</summary>
    public double BalanceYuan { get; init; }

    /// <summary>月度消费上限是否启用（proto3 缺省布尔 -> false）。</summary>
    public bool MonthlyChargeLimitEnabled { get; init; }

    /// <summary>月度消费上限（分）。</summary>
    public int MonthlyChargeLimitCents { get; init; }

    /// <summary>本月已消费（分）。</summary>
    public int MonthlyUsedCents { get; init; }

    /// <summary>充值上限（分）。</summary>
    public int TopupLimitCents { get; init; }

    /// <summary>月度消费上限（元）。</summary>
    public double MonthlyChargeLimitYuan => MonthlyChargeLimitCents / 100.0;

    /// <summary>本月已消费（元）。</summary>
    public double MonthlyUsedYuan => MonthlyUsedCents / 100.0;

    /// <summary>充值上限（元）。</summary>
    public double TopupLimitYuan => TopupLimitCents / 100.0;
}
