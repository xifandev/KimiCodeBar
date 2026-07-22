using System.Diagnostics;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using KimiCodeBar.Core;
using KimiCodeBar.Core.Exceptions;
using KimiCodeBar.Core.Models;
using KimiCodeBar.Core.Services;

namespace KimiCodeBar.Core.ViewModels;

/// <summary>
/// 编排中枢（对应 macOS 的 KimiCodeBarModel）。
/// 聚合用量 / Kimi Web 状态 / 加载态 / 凭据态 / 版本与更新信息，并暴露命令。
/// 不引用任何 WinRT / WinUI，便于在 macOS 用 xUnit 验证。
/// </summary>
public sealed partial class MainViewModel : ObservableObject
{
    private readonly IQuotaService _quotaService;
    private readonly IKimiWebManager _kimiWeb;
    private readonly ICredentialStore _credentialStore;
    private readonly IUpdateService _updateService;

    /// <summary>当前已安装的 App 版本（由 App 启动时注入，用于更新比较）。</summary>
    public string CurrentAppVersion { get; set; } = "0.0.0";

    [ObservableProperty]
    private KimiQuota _quota = new();

    [ObservableProperty]
    private KimiServerState _serverState = new();

    [ObservableProperty]
    private bool _isLoading;

    [ObservableProperty]
    private bool _hasCredential;

    [ObservableProperty]
    private string _kimiVersion = "未检测到";

    [ObservableProperty]
    private string? _pendingCliUpdate;

    [ObservableProperty]
    private string? _pendingAppUpdate;

    [ObservableProperty]
    private string? _updateErrorMessage;

    /// <summary>命令：统一刷新（用量 + 服务器探测 + 更新检查）。</summary>
    public IAsyncRelayCommand RefreshAllCommand { get; }

    /// <summary>命令：仅刷新用量。</summary>
    public IAsyncRelayCommand RefreshQuotaCommand { get; }

    /// <summary>命令：打开 Kimi Web 页面。</summary>
    public IAsyncRelayCommand OpenKimiWebCommand { get; }

    /// <summary>命令：启动 Kimi Web 服务。</summary>
    public IAsyncRelayCommand StartKimiServerCommand { get; }

    /// <summary>命令：停止 Kimi Web 服务。</summary>
    public IAsyncRelayCommand StopKimiServerCommand { get; }

    /// <summary>命令：重启 Kimi Web 服务。</summary>
    public IAsyncRelayCommand RestartKimiServerCommand { get; }

    /// <summary>命令：加载已安装的 Kimi CLI 版本。</summary>
    public IAsyncRelayCommand LoadKimiVersionCommand { get; }

    /// <summary>命令：检查更新。</summary>
    public IAsyncRelayCommand CheckForUpdatesCommand { get; }

    public MainViewModel(
        IQuotaService quotaService,
        IKimiWebManager kimiWeb,
        ICredentialStore credentialStore,
        IUpdateService updateService)
    {
        _quotaService = quotaService;
        _kimiWeb = kimiWeb;
        _credentialStore = credentialStore;
        _updateService = updateService;

        // 构造时即读取凭据状态（同步）。
        HasCredential = !string.IsNullOrEmpty(_credentialStore.Load(Constants.CredentialApiKey));

        RefreshAllCommand = new AsyncRelayCommand(
            RefreshAllAsync, () => HasCredential && !IsLoading);
        RefreshQuotaCommand = new AsyncRelayCommand(
            RefreshQuotaAsync, () => HasCredential && !IsLoading);
        OpenKimiWebCommand = new AsyncRelayCommand(
            OpenKimiWebAsync, () => ServerState.Status == ServerStatus.Running);
        StartKimiServerCommand = new AsyncRelayCommand(
            StartKimiServerAsync, () => ServerState.Status != ServerStatus.Running && !IsLoading);
        StopKimiServerCommand = new AsyncRelayCommand(
            StopKimiServerAsync, () => ServerState.Status == ServerStatus.Running && !IsLoading);
        RestartKimiServerCommand = new AsyncRelayCommand(
            RestartKimiServerAsync, () => ServerState.Status == ServerStatus.Running && !IsLoading);
        LoadKimiVersionCommand = new AsyncRelayCommand(LoadKimiVersionAsync);
        CheckForUpdatesCommand = new AsyncRelayCommand(CheckForUpdatesAsync);
    }

    // 状态变化后刷新相关命令的可用态。
    partial void OnIsLoadingChanged(bool value)
    {
        RefreshAllCommand.NotifyCanExecuteChanged();
        RefreshQuotaCommand.NotifyCanExecuteChanged();
        StartKimiServerCommand.NotifyCanExecuteChanged();
        StopKimiServerCommand.NotifyCanExecuteChanged();
        RestartKimiServerCommand.NotifyCanExecuteChanged();
    }

    partial void OnHasCredentialChanged(bool value)
    {
        RefreshAllCommand.NotifyCanExecuteChanged();
        RefreshQuotaCommand.NotifyCanExecuteChanged();
    }

    partial void OnServerStateChanged(KimiServerState value)
    {
        OpenKimiWebCommand.NotifyCanExecuteChanged();
        StartKimiServerCommand.NotifyCanExecuteChanged();
        StopKimiServerCommand.NotifyCanExecuteChanged();
        RestartKimiServerCommand.NotifyCanExecuteChanged();
    }

    /// <summary>统一刷新：用量 + 服务器探测 + 更新检查（并发执行）。</summary>
    public async Task RefreshAllAsync()
    {
        await Task.WhenAll(RefreshQuotaAsync(), ProbeAndUpdateServerAsync(), CheckForUpdatesAsync())
            .ConfigureAwait(true);
    }

    /// <summary>刷新用量（无凭据时清空并直接返回）。</summary>
    public async Task RefreshQuotaAsync()
    {
        var token = _credentialStore.Load(Constants.CredentialApiKey);
        HasCredential = !string.IsNullOrEmpty(token);
        if (!HasCredential)
        {
            Quota = new KimiQuota();
            return;
        }

        IsLoading = true;
        try
        {
            var result = await _quotaService.FetchQuotaAsync(token!).ConfigureAwait(true);
            if (result.IsSuccess)
            {
                Quota = result.Value!;
                UpdateErrorMessage = null;
            }
            else
            {
                UpdateErrorMessage = result.Error!.ToFriendlyMessage();
            }
        }
        finally
        {
            IsLoading = false;
        }
    }

    /// <summary>打开 Kimi Web 页面（默认浏览器）。</summary>
    public async Task OpenKimiWebAsync()
    {
        var url = ServerState.Url ?? $"http://127.0.0.1:{Constants.DefaultKimiWebPort}/";
        try
        {
            var startInfo = new ProcessStartInfo(url) { UseShellExecute = true };
            Process.Start(startInfo);
        }
        catch
        {
            // 打包环境可能受限；UI 层可兜底提示。
        }

        await Task.CompletedTask.ConfigureAwait(true);
    }

    /// <summary>启动 Kimi Web 并刷新状态。</summary>
    public async Task StartKimiServerAsync()
    {
        IsLoading = true;
        try
        {
            await _kimiWeb.StartAsync().ConfigureAwait(true);
            await ProbeAndUpdateServerAsync().ConfigureAwait(true);
        }
        finally
        {
            IsLoading = false;
        }
    }

    /// <summary>停止 Kimi Web 并刷新状态。</summary>
    public async Task StopKimiServerAsync()
    {
        IsLoading = true;
        try
        {
            await _kimiWeb.StopAsync().ConfigureAwait(true);
            await ProbeAndUpdateServerAsync().ConfigureAwait(true);
        }
        finally
        {
            IsLoading = false;
        }
    }

    /// <summary>重启 Kimi Web 并刷新状态。</summary>
    public async Task RestartKimiServerAsync()
    {
        IsLoading = true;
        try
        {
            await _kimiWeb.RestartAsync().ConfigureAwait(true);
            await ProbeAndUpdateServerAsync().ConfigureAwait(true);
        }
        finally
        {
            IsLoading = false;
        }
    }

    /// <summary>加载已安装的 Kimi CLI 版本。</summary>
    public async Task LoadKimiVersionAsync()
    {
        try
        {
            var version = await _kimiWeb.GetInstalledVersionAsync().ConfigureAwait(true);
            KimiVersion = string.IsNullOrEmpty(version) ? "未检测到" : version;
        }
        catch
        {
            KimiVersion = "未检测到";
        }
    }

    /// <summary>检查更新：CLI 与 App 分别比较当前版本。</summary>
    public async Task CheckForUpdatesAsync()
    {
        try
        {
            var cli = await _updateService.FetchLatestCliVersionAsync().ConfigureAwait(true);
            if (cli.Version is not null && VersionComparer.IsNewer(cli.Version, KimiVersion))
            {
                PendingCliUpdate = cli.Version;
            }
            else
            {
                PendingCliUpdate = null;
            }

            var app = await _updateService.FetchLatestAppReleaseAsync().ConfigureAwait(true);
            if (app.Version is not null && VersionComparer.IsNewer(app.Version, CurrentAppVersion))
            {
                PendingAppUpdate = app.Version;
            }
            else
            {
                PendingAppUpdate = null;
            }

            if (cli.Error is not null || app.Error is not null)
            {
                UpdateErrorMessage = "检查更新失败";
            }
        }
        catch
        {
            UpdateErrorMessage = "检查更新失败";
        }
    }

    /// <summary>探测 Kimi Web 状态并更新 <see cref="ServerState"/>。</summary>
    private async Task ProbeAndUpdateServerAsync()
    {
        try
        {
            ServerState = await _kimiWeb.ProbeAsync().ConfigureAwait(true);
        }
        catch
        {
            ServerState = new KimiServerState { Status = ServerStatus.Error };
        }
    }
}
