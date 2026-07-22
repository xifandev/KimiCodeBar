namespace KimiCodeBar.Core.Models;

/// <summary>
/// Kimi Web 服务运行状态枚举。
/// </summary>
public enum ServerStatus
{
    /// <summary>未知（尚未探测或探测失败）。</summary>
    Unknown,

    /// <summary>运行中。</summary>
    Running,

    /// <summary>已停止。</summary>
    Stopped,

    /// <summary>异常。</summary>
    Error
}

/// <summary>
/// Kimi Web 本地服务状态快照。
/// </summary>
public sealed class KimiServerState
{
    /// <summary>运行状态。</summary>
    public ServerStatus Status { get; init; } = ServerStatus.Unknown;

    /// <summary>已安装 / 运行中的 Kimi CLI 版本。</summary>
    public string Version { get; init; } = string.Empty;

    /// <summary>实际监听端口（探测到时）。</summary>
    public int? Port { get; init; }

    /// <summary>访问地址（探测到时）。</summary>
    public string? Url { get; init; }

    /// <summary>未知状态单例。</summary>
    public static KimiServerState Unknown => new();
}
