using System.Globalization;
using KimiCodeBar.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace KimiCodeBar.Views.Controls;

/// <summary>
/// 加油包余额卡片。展示真实余额（元）、启用状态、本月消费 / 上限与月度消费进度条。
/// 未开通时显示 "--"。
/// </summary>
public sealed partial class BoosterWalletCard : UserControl
{
    /// <summary>加油包数据（null 表示未开通）。</summary>
    public static readonly DependencyProperty WalletProperty =
        DependencyProperty.Register(nameof(Wallet), typeof(BoosterWallet), typeof(BoosterWalletCard), new PropertyMetadata(null, OnWalletChanged));

    /// <summary>加载态。</summary>
    public static readonly DependencyProperty IsLoadingProperty =
        DependencyProperty.Register(nameof(IsLoading), typeof(bool), typeof(BoosterWalletCard), new PropertyMetadata(false, OnIsLoadingChanged));

    public BoosterWallet? Wallet
    {
        get => (BoosterWallet?)GetValue(WalletProperty);
        set => SetValue(WalletProperty, value);
    }

    public bool IsLoading
    {
        get => (bool)GetValue(IsLoadingProperty);
        set => SetValue(IsLoadingProperty, value);
    }

    private double _progress;

    public BoosterWalletCard()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            if (MonthlyFill.Parent is FrameworkElement parent)
            {
                parent.SizeChanged += (_, _) => UpdateFillWidth(_progress);
            }
        };
        RenderWallet();
    }

    private static void OnWalletChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((BoosterWalletCard)d).RenderWallet();

    private static void OnIsLoadingChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((BoosterWalletCard)d).RenderWallet();

    private void RenderWallet()
    {
        var wallet = IsLoading ? null : Wallet;

        if (wallet is null)
        {
            BalanceText.Text = "--";
            BalanceText.Foreground = GetThemeBrush("TextTertiaryBrush", Microsoft.UI.Colors.Gray);
            Badge.Visibility = Visibility.Collapsed;
            MonthlyRow.Visibility = Visibility.Collapsed;
            MonthlyFill.Width = 0;
            return;
        }

        BalanceText.Text = FormatCurrency(wallet.BalanceYuan, wallet.Currency);
        BalanceText.Foreground = wallet.IsEnabled
            ? GetThemeBrush("TextPrimaryBrush", Microsoft.UI.Colors.White)
            : GetThemeBrush("TextTertiaryBrush", Microsoft.UI.Colors.Gray);

        BadgeText.Text = wallet.IsEnabled ? "已启用" : "未启用";
        Badge.Background = GetThemeBrush("TextPrimaryBrush", Microsoft.UI.Colors.White);
        Badge.Opacity = wallet.IsEnabled ? 0.12 : 0.08;
        Badge.Foreground = wallet.IsEnabled
            ? new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Green)
            : GetThemeBrush("TextTertiaryBrush", Microsoft.UI.Colors.Gray);
        Badge.Visibility = Visibility.Visible;

        MonthlyUsedText.Text = FormatCurrency(wallet.MonthlyUsedYuan, wallet.Currency);
        MonthlyLimitText.Text = wallet.MonthlyChargeLimitEnabled && wallet.MonthlyChargeLimitCents > 0
            ? FormatCurrency(wallet.MonthlyChargeLimitYuan, wallet.Currency)
            : "无限制";
        MonthlyRow.Visibility = Visibility.Visible;

        var progress = wallet.MonthlyChargeLimitEnabled && wallet.MonthlyChargeLimitYuan > 0
            ? Math.Min(wallet.MonthlyUsedYuan / wallet.MonthlyChargeLimitYuan, 1.0)
            : 0;
        _progress = progress;

        MonthlyFill.Fill = wallet.IsEnabled
            ? new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Orange)
            : GetThemeBrush("TextTertiaryBrush", Microsoft.UI.Colors.Gray);
        UpdateFillWidth(progress);
    }

    private void UpdateFillWidth(double progress)
    {
        // 进度条宽度依赖容器实际宽度，监听 SizeChanged 更新。
        if (MonthlyFill.Parent is FrameworkElement parent)
        {
            MonthlyFill.Width = parent.ActualWidth * progress;
        }
    }

    private static string FormatCurrency(double yuan, string currency)
    {
        var symbol = currency.ToUpperInvariant() switch
        {
            "CNY" => "¥",
            "USD" => "$",
            "EUR" => "€",
            _ => currency.ToUpperInvariant()
        };

        var formatted = yuan.ToString("N2", CultureInfo.InvariantCulture);
        return $"{symbol}{formatted}";
    }

    /// <summary>
    /// 安全读取主题画刷。主题字典中的画刷不会直接出现在根 <c>Resources</c> 中，
    /// 直接强转可能为 null；此处回退到静态画刷，避免 NRE / 无效强转崩溃。
    /// </summary>
    private static Microsoft.UI.Xaml.Media.Brush GetThemeBrush(string key, Microsoft.UI.Color fallback) =>
        Application.Current.Resources[key] is Microsoft.UI.Xaml.Media.Brush b
            ? b
            : new Microsoft.UI.Xaml.Media.SolidColorBrush(fallback);
}
