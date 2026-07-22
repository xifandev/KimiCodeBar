using System.Text;
using KimiCodeBar.Core.Models;
using KimiCodeBar.Core.Services;
using Xunit;

namespace KimiCodeBar.Core.Tests;

/// <summary>
/// 用量解析边界测试，覆盖 Mac 已知行为：
/// 余额 1e-8、proto3 缺省布尔、5H 取 duration==300、百分比、重置时间。
/// </summary>
public class QuotaParserTests
{
    private static readonly string SampleJson = """
    {
      "usage": {
        "limit": "100",
        "used": "30",
        "remaining": "70",
        "resetTime": "2027-01-10T12:00:00.000+08:00"
      },
      "limits": [
        { "window": { "duration": 86400 }, "detail": { "limit": "100", "used": "30" } },
        { "window": { "duration": 300 }, "detail": { "limit": "50", "used": "10", "remaining": "40", "resetTime": "2027-01-05T08:00:00.000+08:00" } }
      ],
      "totalQuota": { "limit": "500", "remaining": "300" },
      "user": { "membership": { "level": "LEVEL_FREE" } },
      "boosterWallet": {
        "status": "STATUS_ACTIVE",
        "balance": { "amountLeft": "315250700" },
        "monthlyChargeLimit": { "currency": "CNY", "priceInCents": "9900" },
        "monthlyUsed": { "currency": "CNY", "priceInCents": "1200" },
        "topupLimit": { "currency": "CNY", "priceInCents": "50000" }
      }
    }
    """;

    private static KimiQuota ParseSample() =>
        QuotaParser.Parse(Encoding.UTF8.GetBytes(SampleJson));

    [Fact]
    public void Parse_WeeklyPercentage_ComputedFromUsedOverLimit()
    {
        var quota = ParseSample();
        Assert.Equal(100, quota.Weekly.Limit);
        Assert.Equal(30, quota.Weekly.Used);
        Assert.Equal(70, quota.Weekly.Remaining);
        Assert.Equal(30, quota.Weekly.Percentage);
    }

    [Fact]
    public void Parse_FiveHour_SelectedByDuration300()
    {
        var quota = ParseSample();
        Assert.Equal(50, quota.FiveHour.Limit);
        Assert.Equal(10, quota.FiveHour.Used);
        Assert.Equal(40, quota.FiveHour.Remaining);
        Assert.Equal(20, quota.FiveHour.Percentage);
    }

    [Fact]
    public void Parse_FiveHour_MissingDuration300_YieldsZero()
    {
        const string json = """
        {
          "usage": { "limit": "100", "used": "30" },
          "limits": [ { "window": { "duration": 86400 }, "detail": { "limit": "100", "used": "30" } } ]
        }
        """;
        var quota = QuotaParser.Parse(Encoding.UTF8.GetBytes(json));
        Assert.Equal(0, quota.FiveHour.Percentage);
        Assert.Equal(0, quota.FiveHour.Limit);
    }

    [Fact]
    public void Parse_BalanceYuan_UsesAmountLeftDividedBy1e8()
    {
        var quota = ParseSample();
        Assert.NotNull(quota.BoosterWallet);
        // 315250700 / 1e8 = 3.152507
        Assert.Equal(3.152507, quota.BoosterWallet!.BalanceYuan, 6);
        Assert.True(quota.BoosterWallet.IsEnabled);
    }

    [Fact]
    public void Parse_Proto3OmittedBool_DefaultsMonthlyLimitDisabledFalse()
    {
        var quota = ParseSample();
        Assert.NotNull(quota.BoosterWallet);
        // 样本未包含 monthlyChargeLimitEnabled，应缺省为 false。
        Assert.False(quota.BoosterWallet!.MonthlyChargeLimitEnabled);
        Assert.Equal(9900, quota.BoosterWallet.MonthlyChargeLimitCents);
        Assert.Equal(1200, quota.BoosterWallet.MonthlyUsedCents);
        Assert.Equal(50000, quota.BoosterWallet.TopupLimitCents);
    }

    [Fact]
    public void Parse_DisabledWallet_BalanceIsZeroEvenIfAmountLeftPresent()
    {
        const string json = """
        {
          "boosterWallet": {
            "status": "STATUS_DISABLED",
            "balance": { "amountLeft": "7500000000" },
            "monthlyChargeLimitEnabled": true,
            "monthlyChargeLimit": { "currency": "CNY", "priceInCents": "9900" }
          }
        }
        """;
        var quota = QuotaParser.Parse(Encoding.UTF8.GetBytes(json));
        Assert.NotNull(quota.BoosterWallet);
        Assert.False(quota.BoosterWallet!.IsEnabled);
        // 未启用时真实余额显示 ¥0（接口可能返回月度上限相关值，需忽略）。
        Assert.Equal(0, quota.BoosterWallet.BalanceYuan);
        // 但显式 true 的开关仍应被尊重。
        Assert.True(quota.BoosterWallet.MonthlyChargeLimitEnabled);
    }

    [Fact]
    public void Parse_StatusEnabled_AliasTreatedAsEnabled()
    {
        const string json = """{ "boosterWallet": { "status": "STATUS_ENABLED" } }""";
        var quota = QuotaParser.Parse(Encoding.UTF8.GetBytes(json));
        Assert.True(quota.BoosterWallet!.IsEnabled);
    }

    [Fact]
    public void Parse_ResetTime_ParsedAndFormatted()
    {
        var quota = ParseSample();
        Assert.NotNull(quota.Weekly.ResetTime);
        // 重置时间文本固定格式 MM-dd HH:mm。
        Assert.Matches(@"^\d{2}-\d{2} \d{2}:\d{2}$", quota.Weekly.ResetTimeText());
        Assert.Contains("后重置", quota.Weekly.TimeUntilReset());
    }

    [Fact]
    public void Parse_InvalidJson_ReturnsEmptyQuota()
    {
        var quota = QuotaParser.Parse(Encoding.UTF8.GetBytes("not json at all"));
        Assert.NotNull(quota);
        Assert.Equal(0, quota.Weekly.Percentage);
        Assert.Equal(0, quota.FiveHour.Percentage);
    }
}
