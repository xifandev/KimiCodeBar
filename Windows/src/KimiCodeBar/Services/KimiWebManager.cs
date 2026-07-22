using System.Diagnostics;
using KimiCodeBar.Core;
using KimiCodeBar.Core.Models;
using KimiCodeBar.Core.Services;

namespace KimiCodeBar.Services;

/// <summary>
/// Kimi Web 本地服务管理器（App 层实现）。
/// 串联 <see cref="ProcessRunner"/> 与 <see cref="PortProbeService"/>：
/// 启动 / 停止 / 重启 <c>kimi web</c> 进程，并通过端口探测判定运行状态。
/// </summary>
public sealed class KimiWebManager : IKimiWebManager
{
    private readonly ProcessRunner _runner;
    private readonly PortProbeService _probe;
    private Process? _process;
    private readonly string _kimiPath;

    public KimiWebManager(ProcessRunner runner, PortProbeService probe)
    {
        _runner = runner;
        _probe = probe;
        _kimiPath = FindKimiPath();
    }

    /// <inheritdoc/>
    public async Task StartAsync()
    {
        // 已在运行则忽略。
        if (_process is { HasExited: false })
        {
            return;
        }

        // 端口已被占用（可能由其它方式启动），视为已启动。
        var existingPort = await _probe.ProbeAsync().ConfigureAwait(false);
        if (existingPort is not null)
        {
            return;
        }

        _process = await _runner.StartAsync(_kimiPath, Constants.KimiWebCommand).ConfigureAwait(false);
    }

    /// <inheritdoc/>
    public async Task StopAsync()
    {
        if (_process is { HasExited: false })
        {
            await _runner.StopTreeAsync(_process.Id).ConfigureAwait(false);
        }

        _process = null;
    }

    /// <inheritdoc/>
    public async Task RestartAsync()
    {
        await StopAsync().ConfigureAwait(false);
        // 给端口释放一点时间。
        await Task.Delay(500).ConfigureAwait(false);
        await StartAsync().ConfigureAwait(false);
    }

    /// <inheritdoc/>
    public async Task<KimiServerState> ProbeAsync()
    {
        var port = await _probe.ProbeAsync().ConfigureAwait(false);
        if (port is null)
        {
            return new KimiServerState { Status = ServerStatus.Stopped };
        }

        var version = await GetInstalledVersionAsync().ConfigureAwait(false);
        return new KimiServerState
        {
            Status = ServerStatus.Running,
            Port = port,
            Url = $"http://127.0.0.1:{port}/",
            Version = version ?? string.Empty
        };
    }

    /// <inheritdoc/>
    public async Task<string?> GetInstalledVersionAsync()
    {
        try
        {
            var startInfo = new ProcessStartInfo(_kimiPath, "--version")
            {
                RedirectStandardOutput = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            using var process = Process.Start(startInfo);
            if (process is null)
            {
                return null;
            }

            var output = await process.StandardOutput.ReadToEndAsync().ConfigureAwait(false);
            await process.WaitForExitAsync().ConfigureAwait(false);
            return output.Trim();
        }
        catch
        {
            return null;
        }
    }

    /// <summary>
    /// 探测 kimi 可执行文件路径（Windows 候选路径 + PATH 回退）。
    /// 详见文档 UNCLEAR 第 3 条。
    /// </summary>
    private static string FindKimiPath()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var localApp = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

        var candidates = new[]
        {
            Path.Combine(home, @".kimi-code\bin\kimi.exe"),
            Path.Combine(home, @".kimi\bin\kimi.exe"),
            Path.Combine(localApp, @"kimi-code\bin\kimi.exe"),
            @"C:\Program Files\kimi\kimi.exe"
        };

        foreach (var candidate in candidates)
        {
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        // 回退到 PATH 中的 kimi.exe（由系统解析）。
        return "kimi.exe";
    }
}
