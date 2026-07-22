using KimiCodeBar.Core.Models;

namespace KimiCodeBar.Core.Services;

/// <summary>
/// Kimi Web 本地服务管理接口（由 App 层的 <c>KimiWebManager</c> 实现）。
/// 启动 / 停止 / 重启 <c>kimi web</c>，并通过端口探测判定运行状态。
/// </summary>
public interface IKimiWebManager
{
    /// <summary>启动 Kimi Web 服务。</summary>
    Task StartAsync();

    /// <summary>停止 Kimi Web 服务（含子进程树）。</summary>
    Task StopAsync();

    /// <summary>重启 Kimi Web 服务。</summary>
    Task RestartAsync();

    /// <summary>探测本地端口，返回当前服务状态。</summary>
    Task<KimiServerState> ProbeAsync();

    /// <summary>
    /// 获取已安装的 Kimi CLI 版本（用于更新比较与面板展示）。
    /// 探测失败返回 null。
    /// </summary>
    Task<string?> GetInstalledVersionAsync();
}
