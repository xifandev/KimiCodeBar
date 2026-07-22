using System;
using System.Diagnostics;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using WinUIEx;
using KimiCodeBar.Core;
using KimiCodeBar.Core.Models;
using KimiCodeBar.Core.ViewModels;
using KimiCodeBar.Services;
using KimiCodeBar.ViewModels;
using KimiCodeBar;
using Microsoft.UI.Input;
using KimiCodeBar.Views.Controls;

namespace KimiCodeBar.Views;

/// <summary>
/// 主面板窗口（仿 macOS KimiMenu）。无边框弹出窗，定位到托盘上方，
/// 展示用量 / 加油包 / Kimi Web / 操作按钮 / 版本与更新信息；无凭据时叠加登录遮罩。
/// </summary>
public sealed partial class MainPanelWindow : WindowEx
{
    private readonly IServiceProvider _services;
    private readonly ThemeManager _themeManager;

    /// <summary>x:Bind 绑定的编排中枢。</summary>
    public MainViewModel ViewModel { get; }

    public MainPanelWindow(MainViewModel viewModel, IServiceProvider services)
    {
        ViewModel = viewModel;
        _services = services;
        _themeManager = services.GetRequiredService<ThemeManager>();

        InitializeComponent();

        // 服务卡片操作 -> ViewModel。
        ServerCard.OpenWebRequested += async (_, _) => await ViewModel.OpenKimiWebAsync();
        ServerCard.StartRequested += async (_, _) => await ViewModel.StartKimiServerAsync();
        ServerCard.StopRequested += async (_, _) => await ViewModel.StopKimiServerAsync();
        ServerCard.RestartRequested += async (_, _) => await ViewModel.RestartKimiServerAsync();

        // 登录遮罩 -> 打开设置录入 API Key。
        LoginOverlayControl.ApiKeyRequested += (_, _) => OpenSettings();
        LoginOverlayControl.OtherLoginRequested += (_, _) => OpenSettings();

        // 版本行点击 -> 打开对应链接（Tapped 处理器在 XAML 中绑定）。

        // 版本徽标随状态更新。
        ViewModel.PropertyChanged += OnViewModelPropertyChanged;

        // 主题应用。
        _themeManager.ThemeChanged += (_, _) => _themeManager.ApplyTo((FrameworkElement)Content);
        _themeManager.ApplyTo((FrameworkElement)Content);

        // 可点击区域悬停手型光标（规范：可点击即显示手型）。
        CommunityButton.ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.Hand);
        CliRow.ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.Hand);
        AppRow.ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.Hand);

        UpdateLoginOverlay();
        UpdateVersionBadges();
    }

    /// <summary>拉起面板并定位到托盘上方（主屏右下角）。</summary>
    public void ShowNearTray()
    {
        var area = DisplayArea.Primary;
        var work = area.WorkArea;
        var width = (int)Width;
        var height = (int)Height;

        MoveAndResize(
            Math.Max(0, (int)(work.Width - width - 16)),
            Math.Max(0, (int)(work.Height - height - 16)),
            width,
            height);

        _themeManager.ApplyTo((FrameworkElement)Content);
        Show();
        Activate();
    }

    // ===================== 事件处理 =====================

    private void OnViewModelPropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(MainViewModel.HasCredential)
            or nameof(MainViewModel.KimiVersion)
            or nameof(MainViewModel.PendingCliUpdate)
            or nameof(MainViewModel.PendingAppUpdate)
            or nameof(MainViewModel.CurrentAppVersion)
            or nameof(MainViewModel.UpdateErrorMessage))
        {
            UpdateLoginOverlay();
            UpdateVersionBadges();
        }
    }

    private void UpdateLoginOverlay()
    {
        LoginOverlayControl.Visibility = ViewModel.HasCredential ? Visibility.Collapsed : Visibility.Visible;
    }

    private void UpdateVersionBadges()
    {
        // CLI 版本行
        CliVersionText.Text = ViewModel.KimiVersion;
        if (!string.IsNullOrEmpty(ViewModel.UpdateErrorMessage))
        {
            SetBadge(CliBadge, CliBadgeText, Strings.Get("UpdateCheckFailed"), Microsoft.UI.Colors.Red);
        }
        else if (!string.IsNullOrEmpty(ViewModel.PendingCliUpdate))
        {
            SetBadge(CliBadge, CliBadgeText, Strings.Get("NewVersionFound"), Microsoft.UI.Colors.Orange);
        }
        else
        {
            SetBadge(CliBadge, CliBadgeText, Strings.Get("LatestVersion"), Microsoft.UI.Colors.Gray);
        }

        // App 版本行
        AppVersionText.Text = ViewModel.CurrentAppVersion;
        if (!string.IsNullOrEmpty(ViewModel.PendingAppUpdate))
        {
            SetBadge(AppBadge, AppBadgeText, Strings.Get("NewVersionFound"), Microsoft.UI.Colors.Orange);
        }
        else
        {
            SetBadge(AppBadge, AppBadgeText, Strings.Get("LatestVersion"), Microsoft.UI.Colors.Gray);
        }
    }

    private static void SetBadge(Border badge, TextBlock text, string label, Microsoft.UI.Color color)
    {
        text.Text = label;
        text.Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(color);
        badge.Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(color) { Opacity = 0.12 };
        badge.Visibility = Visibility.Visible;
    }

    private void OnCommunityClick(object sender, RoutedEventArgs e) =>
        OpenUrl("https://github.com/xifandev/KimiCodeBar");

    private void OnConsoleClick(object sender, RoutedEventArgs e) => OpenUrl(Constants.ConsoleUrl);

    private void OnSettingsClick(object sender, RoutedEventArgs e) => OpenSettings();

    private void OnExitClick(object sender, RoutedEventArgs e) => Application.Current.Exit();

    private void OnCliRowTapped(object sender, TappedRoutedEventArgs e) => OpenUrl(Constants.ChangelogUrl);

    private void OnAppRowTapped(object sender, TappedRoutedEventArgs e) => OpenUrl(Constants.ReleasePageUrl);

    private void OpenSettings()
    {
        var settingsVm = _services.GetService<SettingsViewModel>();
        var settingsWindow = new SettingsWindow(settingsVm ?? new SettingsViewModel(
            _services.GetRequiredService<ICredentialStore>(),
            _services.GetRequiredService<ILaunchAtLogin>(),
            _themeManager));
        settingsWindow.Activate();
    }

    private void OpenUrl(string url)
    {
        try
        {
            var startInfo = new ProcessStartInfo(url) { UseShellExecute = true };
            Process.Start(startInfo);
        }
        catch
        {
            // 忽略：打包环境可能受限。
        }
    }
}
