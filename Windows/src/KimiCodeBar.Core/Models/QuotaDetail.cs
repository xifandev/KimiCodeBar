using System.Globalization;

namespace KimiCodeBar.Core.Models;

/// <summary>
/// 单项用量明细（周 / 5 小时 / 总额度）。
/// 数值字段以"次数"为单位（接口返回字符串形式的整数）。
/// </summary>
public sealed class QuotaDetail
{
    /// <summary>已用次数。</summary>
    public int Used { get; init; }

    /// <summary>总额度（次数）。</summary>
    public int Limit { get; init; }

    /// <summary>剩余次数。</summary>
    public int Remaining { get; init; }

    /// <summary>重置时间（ISO8601，可能为 null）。</summary>
    public DateTimeOffset? ResetTime { get; init; }

    /// <summary>已用百分比（0-100）。</summary>
    public int Percentage { get; init; }

    /// <summary>
    /// 距离重置还有多久，格式如 "3天2小时后重置" / "即将重置"。
    /// 使用不变文化，避免本地化数字格式差异。
    /// </summary>
    public string TimeUntilReset()
    {
        if (ResetTime is null)
        {
            return "未知";
        }

        var now = DateTimeOffset.Now;
        if (ResetTime <= now)
        {
            return "即将重置";
        }

        var span = ResetTime.Value - now;
        var days = (int)span.TotalDays;
        var hours = span.Hours;
        var minutes = span.Minutes;

        if (days > 0)
        {
            return string.Format(CultureInfo.InvariantCulture, "{0}天{1}小时后重置", days, hours);
        }

        if (hours > 0)
        {
            return string.Format(CultureInfo.InvariantCulture, "{0}小时{1}分钟后重置", hours, minutes);
        }

        if (minutes > 0)
        {
            return string.Format(CultureInfo.InvariantCulture, "{0}分钟后重置", minutes);
        }

        return "即将重置";
    }

    /// <summary>
    /// 重置时间的展示文本，格式 MM-dd HH:mm（不变文化）。
    /// </summary>
    public string ResetTimeText()
    {
        if (ResetTime is null)
        {
            return "未知";
        }

        return ResetTime.Value.ToString("MM-dd HH:mm", CultureInfo.InvariantCulture);
    }
}
