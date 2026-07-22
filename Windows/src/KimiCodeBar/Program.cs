using Microsoft.UI.Xaml;

namespace KimiCodeBar;

/// <summary>
/// 应用程序入口点。WinUI 3 标准引导：初始化 COM 包装与调度同步上下文，
/// 再创建 <see cref="App"/>（其 OnLaunched 负责托盘驻留与首次刷新）。
/// </summary>
public static class Program
{
    [System.STAThread]
    public static void Main()
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(_ =>
        {
            var context = new Microsoft.UI.Dispatching.DispatcherQueueSynchronizationContext(
                Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread());
            System.Threading.SynchronizationContext.SetSynchronizationContext(context);
            _ = new App();
        });
    }
}
