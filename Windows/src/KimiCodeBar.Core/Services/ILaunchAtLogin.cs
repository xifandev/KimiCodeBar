namespace KimiCodeBar.Core.Services;

/// <summary>
/// 开机自启接口（由 App 层的 <c>RegistryLaunchAtLogin</c> 实现，操作注册表 Run 键）。
/// </summary>
public interface ILaunchAtLogin
{
    /// <summary>当前是否启用开机自启。</summary>
    bool IsEnabled { get; }

    /// <summary>设置开机自启开关。</summary>
    void SetEnabled(bool enabled);
}
