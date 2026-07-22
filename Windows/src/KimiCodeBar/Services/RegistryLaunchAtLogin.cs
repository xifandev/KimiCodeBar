using Microsoft.Win32;
using KimiCodeBar.Core.Services;

namespace KimiCodeBar.Services;

/// <summary>
/// 开机自启（App 层实现）。操作注册表 Run 键：
/// <c>HKCU\Software\Microsoft\Windows\CurrentVersion\Run</c>。
/// </summary>
public sealed class RegistryLaunchAtLogin : ILaunchAtLogin
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string AppName = "KimiCodeBar";

    /// <inheritdoc/>
    public bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath);
            return key?.GetValue(AppName) is not null;
        }
    }

    /// <inheritdoc/>
    public void SetEnabled(bool enabled)
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, true);
        if (key is null)
        {
            return;
        }

        if (enabled)
        {
            var exePath = Environment.ProcessPath
                          ?? System.Reflection.Assembly.GetExecutingAssembly().Location;
            key.SetValue(AppName, exePath);
        }
        else if (key.GetValue(AppName) is not null)
        {
            key.DeleteValue(AppName);
        }
    }
}
