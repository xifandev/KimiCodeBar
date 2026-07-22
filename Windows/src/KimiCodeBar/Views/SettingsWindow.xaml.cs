using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using WinUIEx;
using KimiCodeBar.Core.Models;
using KimiCodeBar.ViewModels;

namespace KimiCodeBar.Views;

/// <summary>
/// 设置窗口。提供 API Key 录入（经 <see cref="ICredentialStore"/> 加密存储）、主题与开机自启开关。
/// </summary>
public sealed partial class SettingsWindow : WindowEx
{
    /// <summary>x:Bind 绑定的设置视图模型。</summary>
    public SettingsViewModel ViewModel { get; }

    public SettingsWindow(SettingsViewModel viewModel)
    {
        ViewModel = viewModel;
        InitializeComponent();

        // 主题下拉：枚举值 -> 本地化文案（代码填充，避免额外转换器）。
        ThemeCombo.ItemsSource = new[]
        {
            new ThemeOption(AppTheme.System, "跟随系统"),
            new ThemeOption(AppTheme.Dark, "深色"),
            new ThemeOption(AppTheme.Light, "浅色")
        };
        ThemeCombo.DisplayMemberPath = nameof(ThemeOption.Display);
        ThemeCombo.SelectedItem = ((System.Collections.Generic.IEnumerable<ThemeOption>)ThemeCombo.ItemsSource)
            .FirstOrDefault(o => o.Value == ViewModel.ThemeSetting);
    }

    private void OnSaveClick(object sender, RoutedEventArgs e)
    {
        if (ThemeCombo.SelectedItem is ThemeOption option)
        {
            ViewModel.ThemeSetting = option.Value;
        }

        // ApiKey / LaunchAtLogin 已通过 x:Bind 双向绑定更新。
        ViewModel.SaveCommand.Execute(null);
        Close();
    }

    private void OnCancelClick(object sender, RoutedEventArgs e) => Close();

    private sealed record ThemeOption(AppTheme Value, string Display);
}
