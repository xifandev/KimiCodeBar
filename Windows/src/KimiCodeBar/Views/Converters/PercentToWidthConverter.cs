using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;

namespace KimiCodeBar.Views.Converters;

/// <summary>
/// 将百分比（0-100）转换为进度条两列的 <see cref="GridLength"/>（Star 单位）。
/// parameter 为 "fill" 时返回已用列宽度，否则返回剩余列宽度。
/// 用于用量卡自定义进度条（ColumnDefinition.Width 非依赖属性，故在 code-behind 应用）。
/// </summary>
public sealed class PercentToWidthConverter : IValueConverter
{
    /// <inheritdoc/>
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var pct = System.Convert.ToDouble(value);
        pct = Math.Clamp(pct, 0, 100);

        var isFill = string.Equals(parameter as string, "fill", System.StringComparison.OrdinalIgnoreCase);
        var length = isFill ? pct : (100 - pct);

        return new GridLength(length, GridUnitType.Star);
    }

    /// <inheritdoc/>
    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        throw new System.NotSupportedException();
    }
}
