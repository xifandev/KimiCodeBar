using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using KimiCodeBar.Core;
using KimiCodeBar.Core.Models;
using KimiCodeBar.Core.Services;
using KimiCodeBar.Services;

namespace KimiCodeBar.ViewModels;

/// <summary>
/// 设置窗口视图模型。聚合 API Key、主题、开机自启三项设置，
/// 经 <see cref="ICredentialStore"/> / <see cref="ILaunchAtLogin"/> / <see cref="ThemeManager"/> 持久化。
/// </summary>
public sealed partial class SettingsViewModel : ObservableObject
{
    private readonly ICredentialStore _credentialStore;
    private readonly ILaunchAtLogin _launchAtLogin;
    private readonly ThemeManager _themeManager;

    /// <summary>API Key（写入凭据存储）。</summary>
    [ObservableProperty]
    private string _apiKey = string.Empty;

    /// <summary>主题设置（系统 / 深 / 浅）。</summary>
    [ObservableProperty]
    private AppTheme _themeSetting = AppTheme.System;

    /// <summary>是否开机自启。</summary>
    [ObservableProperty]
    private bool _launchAtLogin;

    public SettingsViewModel(ICredentialStore credentialStore, ILaunchAtLogin launchAtLogin, ThemeManager themeManager)
    {
        _credentialStore = credentialStore;
        _launchAtLogin = launchAtLogin;
        _themeManager = themeManager;
        Load();
    }

    /// <summary>保存设置：写入 API Key、开机自启、主题。</summary>
    [RelayCommand]
    private void Save()
    {
        if (!string.IsNullOrWhiteSpace(ApiKey))
        {
            _credentialStore.Save(Constants.CredentialApiKey, ApiKey.Trim());
        }
        else
        {
            _credentialStore.Delete(Constants.CredentialApiKey);
        }

        _launchAtLogin.SetEnabled(LaunchAtLogin);
        _themeManager.Theme = ThemeSetting;
    }

    private void Load()
    {
        ApiKey = _credentialStore.Load(Constants.CredentialApiKey) ?? string.Empty;
        LaunchAtLogin = _launchAtLogin.IsEnabled;
        ThemeSetting = _themeManager.Theme;
    }
}
