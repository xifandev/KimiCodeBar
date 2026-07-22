using System;
using System.Drawing;
using KimiCodeBar.Core.Models;
using WinUIEx;

namespace KimiCodeBar.Tray;

/// <summary>
/// 系统托盘管理器（App 层）。
/// 使用 WinUIEx <see cref="NotifyIcon"/> 驻留托盘，悬停 tooltip 显示用量，
/// 点击拉起主面板（<see cref="PanelRequested"/> 事件）。图标由 <see cref="TrayIconRenderer"/> 绘制。
/// </summary>
public sealed class TrayIconManager : IDisposable
{
    private readonly NotifyIcon _notifyIcon;
    private readonly TrayIconRenderer _renderer;
    private Icon? _currentIcon;

    /// <summary>用户点击托盘图标请求显示面板时触发。</summary>
    public event EventHandler? PanelRequested;

    public TrayIconManager(TrayIconRenderer renderer)
    {
        _renderer = renderer;

        _notifyIcon = new NotifyIcon
        {
            Text = "KimiCodeBar"
        };

        _notifyIcon.LeftClick += (_, _) => PanelRequested?.Invoke(this, EventArgs.Empty);
        _notifyIcon.RightClick += (_, _) => PanelRequested?.Invoke(this, EventArgs.Empty);

        SetQuota(null);
        _notifyIcon.Visible = true;
    }

    /// <summary>
    /// 更新托盘图标与 tooltip。有数据时绘制 7D/5H 百分比，无数据显示 "Kimi"。
    /// </summary>
    public void SetQuota(KimiQuota? quota)
    {
        var bitmap = quota is null
            ? _renderer.DrawDefault()
            : _renderer.Draw(quota.Weekly, quota.FiveHour);

        ReplaceIcon(bitmap);
        bitmap.Dispose();

        _notifyIcon.Text = quota is null
            ? "KimiCodeBar"
            : $"本周 {quota.Weekly.Percentage}% · 5小时 {quota.FiveHour.Percentage}%";
    }

    private void ReplaceIcon(Bitmap bitmap)
    {
        // 注：Icon.FromHandle 创建的图标不拥有底层 GDI 句柄，
        // 这里统一由 _currentIcon 管理并在替换 / 释放时销毁，避免泄漏。
        IntPtr hIcon = bitmap.GetHicon();
        var icon = Icon.FromHandle(hIcon);

        _currentIcon?.Dispose();
        _currentIcon = icon;
        _notifyIcon.Icon = icon;
    }

    /// <inheritdoc/>
    public void Dispose()
    {
        _notifyIcon.Visible = false;
        _currentIcon?.Dispose();
        _currentIcon = null;
        _notifyIcon.Dispose();
        GC.SuppressFinalize(this);
    }
}
