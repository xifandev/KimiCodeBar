using System;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using KimiCodeBar.Core.ViewModels;
using KimiCodeBar.Host;
using KimiCodeBar.Tray;
using KimiCodeBar.Views;

namespace KimiCodeBar;

/// <summary>
/// 应用程序入口。v1 仅驻留系统托盘，无主窗口。
/// 启动流程：构建 DI 容器 -> 构造 MainViewModel -> 初始化托盘 -> 首次刷新（用量 + Kimi Web 探测 + 更新检查）。
/// </summary>
public partial class App : Application
{
    /// <summary>全局依赖注入容器。</summary>
    public IServiceProvider Services { get; private set; } = null!;

    private TrayIconManager _tray = null!;
    private MainViewModel _viewModel = null!;
    private MainPanelWindow? _panel;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(Microsoft.UI.Xaml.LaunchActivatedEventArgs args)
    {
        // 1. 构建 DI 容器并注册所有服务（Singleton）。
        Services = ServiceRegistration.Build();

        // 2. 构造编排中枢 MainViewModel。
        _viewModel = Services.GetRequiredService<MainViewModel>();
        _viewModel.CurrentAppVersion = GetAppVersion();

        // 3. 初始化托盘图标（驻留 + 点击拉起面板）。
        _tray = Services.GetRequiredService<TrayIconManager>();
        _tray.PanelRequested += (_, _) => ShowPanel();
        _tray.SetQuota(_viewModel.Quota);

        // 4. 首次刷新（用量 + Kimi Web 探测 + 更新检查）。
        _ = InitializeAsync();
    }

    /// <summary>首次启动的后台刷新，不阻塞托盘显示。</summary>
    private async Task InitializeAsync()
    {
        try
        {
            // 先探测并加载 Kimi CLI 版本，供后续更新比较使用。
            await _viewModel.LoadKimiVersionAsync();
            // 再统一刷新：用量 + 服务器探测 + 更新检查。
            await _viewModel.RefreshAllAsync();
            this.DispatcherQueue.TryEnqueue(() => _tray.SetQuota(_viewModel.Quota));
        }
        catch
        {
            // 首次刷新失败不应阻止托盘驻留，详细错误已写入 ViewModel 调试日志。
        }
    }

    /// <summary>拉起（或激活已存在的）主面板，定位到托盘上方。</summary>
    private void ShowPanel()
    {
        _panel ??= new MainPanelWindow(_viewModel, Services);
        _panel.ShowNearTray();
    }

    /// <summary>读取当前应用版本（打包环境取 Package，非打包回退到程序集版本）。</summary>
    private static string GetAppVersion()
    {
        try
        {
            var version = Windows.ApplicationModel.Package.Current?.Id?.Version;
            if (version is not null)
            {
                return $"{version.Major}.{version.Minor}.{version.Build}";
            }
        }
        catch
        {
            // 非打包（SelfHost）环境下 Package.Current 可能为 null，忽略。
        }

        var asm = System.Reflection.Assembly.GetExecutingAssembly().GetName().Version;
        return asm is null ? "0.0.0" : $"{asm.Major}.{asm.Minor}.{asm.Build}";
    }
}
