using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace KimiCodeBar.Views.Controls;

/// <summary>
/// 用量卡片（本周 / 5 小时）。仿 macOS UsageCard：
/// 标题 + 大号百分比 + 自定义进度条 + 重置时间。支持加载态显示 ProgressRing。
/// </summary>
public sealed partial class UsageCard : UserControl
{
    /// <summary>卡片标题（如"本周用量"）。</summary>
    public static readonly DependencyProperty TitleProperty =
        DependencyProperty.Register(nameof(Title), typeof(string), typeof(UsageCard), new PropertyMetadata(string.Empty));

    /// <summary>副标题（可选徽标）。</summary>
    public static readonly DependencyProperty SubtitleProperty =
        DependencyProperty.Register(nameof(Subtitle), typeof(string), typeof(UsageCard), new PropertyMetadata(string.Empty, OnSubtitleChanged));

    /// <summary>已用百分比（0-100）。</summary>
    public static readonly DependencyProperty PercentageProperty =
        DependencyProperty.Register(nameof(Percentage), typeof(int), typeof(UsageCard), new PropertyMetadata(0, OnPercentageChanged));

    /// <summary>重置时间文本。</summary>
    public static readonly DependencyProperty ResetTextProperty =
        DependencyProperty.Register(nameof(ResetText), typeof(string), typeof(UsageCard), new PropertyMetadata(string.Empty, OnResetTextChanged));

    /// <summary>进度条强调色（本周为 KimiBlue，5 小时为橙色）。</summary>
    public static readonly DependencyProperty AccentColorProperty =
        DependencyProperty.Register(nameof(AccentColor), typeof(Brush), typeof(UsageCard), new PropertyMetadata(null));

    /// <summary>加载态（显示 ProgressRing 并隐藏百分比）。</summary>
    public static readonly DependencyProperty IsLoadingProperty =
        DependencyProperty.Register(nameof(IsLoading), typeof(bool), typeof(UsageCard), new PropertyMetadata(false, OnIsLoadingChanged));

    private static readonly PercentToWidthConverter Converter = new();

    public string Title
    {
        get => (string)GetValue(TitleProperty);
        set => SetValue(TitleProperty, value);
    }

    public string Subtitle
    {
        get => (string)GetValue(SubtitleProperty);
        set => SetValue(SubtitleProperty, value);
    }

    public int Percentage
    {
        get => (int)GetValue(PercentageProperty);
        set => SetValue(PercentageProperty, value);
    }

    public string ResetText
    {
        get => (string)GetValue(ResetTextProperty);
        set => SetValue(ResetTextProperty, value);
    }

    public Brush? AccentColor
    {
        get => (Brush?)GetValue(AccentColorProperty);
        set => SetValue(AccentColorProperty, value);
    }

    public bool IsLoading
    {
        get => (bool)GetValue(IsLoadingProperty);
        set => SetValue(IsLoadingProperty, value);
    }

    public UsageCard()
    {
        InitializeComponent();
        UpdateBar();
        ApplyLoadingState();
    }

    private static void OnPercentageChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((UsageCard)d).UpdateBar();

    private static void OnResetTextChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((UsageCard)d).ResetTextBlock.Text = (string)e.NewValue;

    private static void OnSubtitleChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((UsageCard)d).UpdateSubtitle();

    private static void OnIsLoadingChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((UsageCard)d).ApplyLoadingState();

    private void UpdateBar()
    {
        PercentageText.Text = $"{Percentage}%";

        var fill = (GridLength)Converter.Convert(Percentage, typeof(GridLength), "fill", null);
        var rest = (GridLength)Converter.Convert(Percentage, typeof(GridLength), "rest", null);
        FillColumn.Width = fill;
        RestColumn.Width = rest;
    }

    private void UpdateSubtitle()
    {
        var hasSubtitle = !string.IsNullOrEmpty(Subtitle);
        SubtitleText.Text = Subtitle;
        SubtitleText.Visibility = hasSubtitle ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ApplyLoadingState()
    {
        PercentageText.Visibility = IsLoading ? Visibility.Collapsed : Visibility.Visible;
        LoadingRing.Visibility = IsLoading ? Visibility.Visible : Visibility.Collapsed;
        LoadingRing.IsActive = IsLoading;
    }
}
