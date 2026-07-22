using System.Globalization;
using System.Text.Json;
using KimiCodeBar.Core.Models;

namespace KimiCodeBar.Core.Services;

/// <summary>
/// 用量 JSON 解析器（纯逻辑，零外部依赖）。
/// 1:1 移植自 macOS <c>KimiCodeBarQuotaService.parse/makeDetail</c>：
/// 处理余额单位 1e-8、proto3 缺省布尔、5H 取 duration==300、百分比与重置时间计算。
/// </summary>
public static class QuotaParser
{
    private const string StatusActive = "STATUS_ACTIVE";
    private const string StatusEnabled = "STATUS_ENABLED";

    /// <summary>余额真实单位换算：amountLeft 以 1e-8 元计（如 315250700 = ¥3.15）。</summary>
    private const double BalanceUnit = 100_000_000.0;

    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNameCaseInsensitive = true
    };

    /// <summary>
    /// 解析用量响应字节（UTF-8 JSON）为 <see cref="KimiQuota"/>。
    /// 解析失败返回空结构（各明细零值），调用方应视为"无数据"。
    /// </summary>
    public static KimiQuota Parse(ReadOnlySpan<byte> json)
    {
        Response? response = null;
        try
        {
            response = JsonSerializer.Deserialize<Response>(json, Options);
        }
        catch (JsonException)
        {
            return Empty();
        }

        if (response is null)
        {
            return Empty();
        }

        // 周用量：usage 段（window.duration 不存在 / 非 300）。
        var weekly = MakeDetail(response.Usage?.Limit, response.Usage?.Used, response.Usage?.Remaining, response.Usage?.ResetTime);

        // 5 小时用量：limits 中 window.duration == 300 的那一项。
        var fiveHour = new QuotaDetail();
        var fiveHourLimit = response.Limits?.FirstOrDefault(l => l.Window?.Duration == 300);
        if (fiveHourLimit is not null)
        {
            fiveHour = MakeDetail(
                fiveHourLimit.Detail?.Limit,
                fiveHourLimit.Detail?.Used,
                fiveHourLimit.Detail?.Remaining,
                fiveHourLimit.Detail?.ResetTime);
        }

        // 总额度。
        var totalQuota = MakeDetail(response.TotalQuota?.Limit, null, response.TotalQuota?.Remaining, null);

        var membershipLevel = response.User?.Membership?.Level;
        var boosterWallet = MakeBoosterWallet(response.BoosterWallet);

        return new KimiQuota
        {
            Weekly = weekly,
            FiveHour = fiveHour,
            TotalQuota = totalQuota,
            MembershipLevel = membershipLevel,
            BoosterWallet = boosterWallet
        };
    }

    /// <summary>构造单条用量明细（与 Swift makeDetail 一一对应）。</summary>
    private static QuotaDetail MakeDetail(string? limit, string? used, string? remaining, string? resetTime)
    {
        var li = ParseInt(limit);

        int us;
        if (used is not null && int.TryParse(used, NumberStyles.Integer, CultureInfo.InvariantCulture, out var usedValue))
        {
            us = usedValue;
        }
        else if (remaining is not null && int.TryParse(remaining, NumberStyles.Integer, CultureInfo.InvariantCulture, out var remainingValue))
        {
            us = Math.Max(0, li - remainingValue);
        }
        else
        {
            us = 0;
        }

        var re = Math.Max(0, li - us);
        var pct = li > 0 ? (int)(us / (double)li * 100) : 0;

        return new QuotaDetail
        {
            Used = us,
            Limit = li,
            Remaining = re,
            ResetTime = ParseDate(resetTime),
            Percentage = pct
        };
    }

    /// <summary>构造加油包钱包（处理余额 1e-8 与 proto3 缺省布尔）。</summary>
    private static BoosterWallet? MakeBoosterWallet(BoosterWalletRaw? raw)
    {
        if (raw is null)
        {
            return null;
        }

        var status = raw.Status ?? "STATUS_UNKNOWN";
        var upper = status.ToUpperInvariant();
        var isEnabled = upper == StatusActive || upper == StatusEnabled;

        // 货币优先级：月度上限 > 已消费 > 充值上限 > 默认 CNY。
        var currency = raw.MonthlyChargeLimit?.Currency
                       ?? raw.MonthlyUsed?.Currency
                       ?? raw.TopupLimit?.Currency
                       ?? "CNY";

        var monthlyChargeLimitCents = ParseInt(raw.MonthlyChargeLimit?.PriceInCents);
        var monthlyUsedCents = ParseInt(raw.MonthlyUsed?.PriceInCents);

        // 真实余额：仅当加油包启用且接口返回 amountLeft 时读取；否则显示 ¥0。
        // 未启用时接口可能返回"月度上限 - 月度消费"相关值（如 ¥75）而非真实余额。
        double balanceYuan;
        if (isEnabled
            && raw.Balance?.AmountLeft is not null
            && double.TryParse(raw.Balance.AmountLeft, NumberStyles.Float, CultureInfo.InvariantCulture, out var amountLeft))
        {
            balanceYuan = Math.Max(0, amountLeft / BalanceUnit);
        }
        else
        {
            balanceYuan = 0;
        }

        return new BoosterWallet
        {
            Status = status,
            IsEnabled = isEnabled,
            Currency = currency,
            BalanceYuan = balanceYuan,
            // proto3 JSON 中 false 会被省略，缺省即"未启用月度上限"。
            MonthlyChargeLimitEnabled = raw.MonthlyChargeLimitEnabled ?? false,
            MonthlyChargeLimitCents = monthlyChargeLimitCents,
            MonthlyUsedCents = monthlyUsedCents,
            TopupLimitCents = ParseInt(raw.TopupLimit?.PriceInCents)
        };
    }

    /// <summary>解析 ISO8601 含毫秒的日期；失败返回 null。</summary>
    private static DateTimeOffset? ParseDate(string? s)
    {
        if (string.IsNullOrEmpty(s))
        {
            return null;
        }

        if (DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.None, out var dto))
        {
            return dto;
        }

        // 兜底：yyyy-MM-dd'T'HH:mm:ss.SSSZ
        if (DateTimeOffset.TryParseExact(
                s, "yyyy-MM-dd'T'HH:mm:ss.SSSzzz", CultureInfo.InvariantCulture, DateTimeStyles.None, out var exact))
        {
            return exact;
        }

        return null;
    }

    /// <summary>安全解析整数字符串，失败返回 0。</summary>
    private static int ParseInt(string? s) =>
        int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var v) ? v : 0;

    /// <summary>解析失败时的空结果。</summary>
    private static KimiQuota Empty() => new()
    {
        Weekly = new QuotaDetail(),
        FiveHour = new QuotaDetail(),
        TotalQuota = new QuotaDetail()
    };

    // ===================== JSON 映射模型（camelCase 大小写不敏感匹配） =====================

#pragma warning disable CA1812 // 内部类型仅由反序列化使用
    private sealed class Response
    {
        public Usage? Usage { get; set; }
        public List<Limit>? Limits { get; set; }
        public TotalQuota? TotalQuota { get; set; }
        public User? User { get; set; }
        public BoosterWalletRaw? BoosterWallet { get; set; }
    }

    private sealed class Usage
    {
        public string? Limit { get; set; }
        public string? Used { get; set; }
        public string? Remaining { get; set; }
        public string? ResetTime { get; set; }
    }

    private sealed class Limit
    {
        public Window? Window { get; set; }
        public Detail? Detail { get; set; }
    }

    private sealed class Window
    {
        public int Duration { get; set; }
    }

    private sealed class Detail
    {
        public string? Limit { get; set; }
        public string? Used { get; set; }
        public string? Remaining { get; set; }
        public string? ResetTime { get; set; }
    }

    private sealed class TotalQuota
    {
        public string? Limit { get; set; }
        public string? Remaining { get; set; }
    }

    private sealed class User
    {
        public Membership? Membership { get; set; }
    }

    private sealed class Membership
    {
        public string? Level { get; set; }
    }

    private sealed class BoosterWalletRaw
    {
        public string? Status { get; set; }
        public Balance? Balance { get; set; }
        public bool? MonthlyChargeLimitEnabled { get; set; }
        public Money? MonthlyChargeLimit { get; set; }
        public Money? MonthlyUsed { get; set; }
        public Money? TopupLimit { get; set; }
    }

    private sealed class Balance
    {
        public string? Amount { get; set; }
        public string? AmountLeft { get; set; }
        public string? Unit { get; set; }
    }

    private sealed class Money
    {
        public string? Currency { get; set; }
        public string? PriceInCents { get; set; }
    }
#pragma warning restore CA1812
}
