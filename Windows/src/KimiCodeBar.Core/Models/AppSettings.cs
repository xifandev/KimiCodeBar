using KimiCodeBar.Core;

namespace KimiCodeBar.Core.Models;

/// <summary>
/// 应用外观主题。
/// </summary>
public enum AppTheme
{
    /// <summary>跟随系统。</summary>
    System,

    /// <summary>深色。</summary>
    Dark,

    /// <summary>浅色。</summary>
    Light
}

/// <summary>
/// 应用设置（可持久化）。
/// </summary>
public sealed class AppSettings
{
    /// <summary>界面主题。</summary>
    public AppTheme Theme { get; set; } = AppTheme.System;

    /// <summary>是否开机自启。</summary>
    public bool LaunchAtLogin { get; set; }

    /// <summary>kimi 可执行文件路径（探测失败时为 null）。</summary>
    public string? KimiExecutablePath { get; set; }

    /// <summary>Kimi Web 监听端口（默认取 Constants.DefaultKimiWebPort）。</summary>
    public int KimiWebPort { get; set; } = Constants.DefaultKimiWebPort;
}
