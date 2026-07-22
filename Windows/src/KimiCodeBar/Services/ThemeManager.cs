using System;
using Microsoft.UI.Xaml;
using Microsoft.Win32;
using KimiCodeBar.Core.Models;

namespace KimiCodeBar.Services;

/// <summary>
/// 主题管理器（App 层）。
/// 维护 <see cref="AppTheme"/>（系统 / 深 / 浅），并在主题变化时通知订阅方。
/// "跟随系统" 通过读取注册表 <c>SystemUsesLightTheme</c> 探测当前系统外观。
/// </summary>
public sealed class ThemeManager
{
    /// <summary>主题变化事件。</summary>
    public event EventHandler? ThemeChanged;

    private AppTheme _theme = AppTheme.System;

    /// <summary>当前主题设置。</summary>
    public AppTheme Theme
    {
        get => _theme;
        set
        {
            if (_theme == value)
            {
                return;
            }

            _theme = value;
            ThemeChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>将当前主题应用到某个 XAML 元素（通常为主窗口根内容）。</summary>
    public void ApplyTo(FrameworkElement element)
    {
        if (element is null)
        {
            return;
        }

        element.RequestedTheme = CurrentElementTheme;
    }

    /// <summary>计算当前应生效的 <see cref="ElementTheme"/>。</summary>
    public ElementTheme CurrentElementTheme =>
        _theme switch
        {
            AppTheme.Dark => ElementTheme.Dark,
            AppTheme.Light => ElementTheme.Light,
            _ => DetectSystemTheme()
        };

    /// <summary>从注册表探测系统当前明暗主题。</summary>
    private static ElementTheme DetectSystemTheme()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            if (key?.GetValue("SystemUsesLightTheme") is int value)
            {
                return value == 0 ? ElementTheme.Dark : ElementTheme.Light;
            }
        }
        catch
        {
            // 忽略，回退浅色。
        }

        return ElementTheme.Light;
    }
}
