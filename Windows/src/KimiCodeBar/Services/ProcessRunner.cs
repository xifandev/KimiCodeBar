using System.Diagnostics;
using System.Management;

namespace KimiCodeBar.Services;

/// <summary>
/// 进程启动 / 停止封装（App 层）。
/// 启动 <c>kimi web</c> 进程（无窗口、重定向输出），停止时递归结束进程树。
/// </summary>
public sealed class ProcessRunner
{
    /// <summary>
    /// 启动进程并返回 <see cref="Process"/> 句柄。
    /// </summary>
    public async Task<Process?> StartAsync(string fileName, string arguments)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = arguments,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };

        Process? process = null;
        try
        {
            process = Process.Start(startInfo);
        }
        catch
        {
            return null;
        }

        if (process is null)
        {
            return null;
        }

        // 给进程一点启动时间，若立即退出则视为启动失败。
        await Task.Delay(500).ConfigureAwait(false);
        if (process.HasExited)
        {
            return null;
        }

        return process;
    }

    /// <summary>
    /// 停止指定 PID 的进程及其全部子进程。
    /// </summary>
    public Task StopTreeAsync(int pid)
    {
        KillProcessTree(pid);
        return Task.CompletedTask;
    }

    private static void KillProcessTree(int pid)
    {
        try
        {
            // 先递归结束子进程。
            using var searcher = new ManagementObjectSearcher(
                $"SELECT ProcessID FROM Win32_Process WHERE ParentProcessID = {pid}");
            foreach (var item in searcher.Get())
            {
                if (item["ProcessID"] is uint childPid)
                {
                    KillProcessTree((int)childPid);
                }
            }

            var process = Process.GetProcessById(pid);
            if (!process.HasExited)
            {
                process.Kill();
            }
        }
        catch
        {
            // 进程已退出或无权限访问，忽略。
        }
    }
}
