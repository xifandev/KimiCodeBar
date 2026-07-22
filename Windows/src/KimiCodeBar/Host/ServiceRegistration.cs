using System;
using Microsoft.Extensions.DependencyInjection;
using KimiCodeBar.Core;
using KimiCodeBar.Core.Services;
using KimiCodeBar.Core.ViewModels;
using KimiCodeBar.Services;
using KimiCodeBar.Tray;
using KimiCodeBar.ViewModels;

namespace KimiCodeBar.Host;

/// <summary>
/// 依赖注入接线。所有 Windows 专属实现以 Singleton 注册，
/// 纯逻辑接口（Core 定义）在此绑定到 App 实现。
/// </summary>
public static class ServiceRegistration
{
    /// <summary>构建并配置 <see cref="IServiceProvider"/>。</summary>
    public static IServiceProvider Build()
    {
        var services = new ServiceCollection();

        // 共享 HttpClient（Kimi API 基址 + 超时 + User-Agent）。
        services.AddSingleton(_ => new HttpClient
        {
            BaseAddress = new Uri(Constants.KimiApiBase),
            Timeout = TimeSpan.FromSeconds(Constants.HttpTimeoutSeconds)
        });

        // Core 服务接口 -> App 实现。
        services.AddSingleton<IQuotaService, QuotaService>();
        services.AddSingleton<IKimiWebManager, KimiWebManager>();
        services.AddSingleton<ICredentialStore, WindowsCredentialStore>();
        services.AddSingleton<IUpdateService, UpdateService>();
        services.AddSingleton<ILaunchAtLogin, RegistryLaunchAtLogin>();

        // App 服务（被上述实现依赖）。
        services.AddSingleton<ProcessRunner>();
        services.AddSingleton<PortProbeService>();
        services.AddSingleton<ThemeManager>();
        services.AddSingleton<TrayIconRenderer>();
        services.AddSingleton<TrayIconManager>();

        // 视图模型。
        services.AddSingleton<MainViewModel>();
        services.AddSingleton<SettingsViewModel>();

        return services.BuildServiceProvider();
    }
}
