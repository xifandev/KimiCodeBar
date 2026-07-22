using KimiCodeBar.Core.Models;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace KimiCodeBar.Views.Controls;

/// <summary>
/// Kimi Web 服务卡片。展示运行状态与版本，提供打开 / 启动 / 停止 / 重启操作。
/// 操作通过事件上抛给主面板（由 MainViewModel 处理）。
/// </summary>
public sealed partial class KimiServerCard : UserControl
{
    /// <summary>服务状态。</summary>
    public static readonly DependencyProperty StateProperty =
        DependencyProperty.Register(nameof(State), typeof(KimiServerState), typeof(KimiServerCard), new PropertyMetadata(null, OnStateChanged));

    /// <summary>请求打开 Kimi Web 页面。</summary>
    public event TypedEventHandler<KimiServerCard, object>? OpenWebRequested;

    /// <summary>请求启动服务。</summary>
    public event TypedEventHandler<KimiServerCard, object>? StartRequested;

    /// <summary>请求停止服务。</summary>
    public event TypedEventHandler<KimiServerCard, object>? StopRequested;

    /// <summary>请求重启服务。</summary>
    public event TypedEventHandler<KimiServerCard, object>? RestartRequested;

    public KimiServerState State
    {
        get => (KimiServerState)GetValue(StateProperty);
        set => SetValue(StateProperty, value);
    }

    public KimiServerCard()
    {
        InitializeComponent();
        // 悬停手型光标。
        var hand = InputSystemCursor.Create(InputSystemCursorShape.Hand);
        OpenButton.ProtectedCursor = hand;
        ToggleButton.ProtectedCursor = hand;
        RestartButton.ProtectedCursor = hand;
        RenderState();
    }

    private static void OnStateChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((KimiServerCard)d).RenderState();

    private void RenderState()
    {
        var state = State;
        if (state is null)
        {
            state = new KimiServerState();
        }

        var isRunning = state.Status == ServerStatus.Running;

        // 状态徽标配色。
        var (badgeBrush, statusText) = state.Status switch
        {
            ServerStatus.Running => (new SolidColorBrush(Microsoft.UI.Colors.Green), "运行中"),
            ServerStatus.Stopped => (new SolidColorBrush(Microsoft.UI.Colors.Red), "已停止"),
            ServerStatus.Error => (new SolidColorBrush(Microsoft.UI.Colors.Red), "异常"),
            _ => ((Brush)Application.Current.Resources["TextTertiaryBrush"], "检测中")
        };

        StatusText.Text = statusText;
        StatusBadge.Background = badgeBrush;
        StatusBadge.Opacity = 0.12;
        StatusText.Foreground = badgeBrush;

        VersionText.Text = string.IsNullOrEmpty(state.Version) ? string.Empty : state.Version;

        // 切换按钮文案：运行中显示"停止"，否则"启动"。
        ToggleButton.Content = isRunning ? "停止" : "启动";

        OpenButton.IsEnabled = isRunning;
        RestartButton.IsEnabled = isRunning;
    }

    private void OnOpenClick(object sender, RoutedEventArgs e) => OpenWebRequested?.Invoke(this, e);

    private void OnToggleClick(object sender, RoutedEventArgs e)
    {
        if (State.Status == ServerStatus.Running)
        {
            StopRequested?.Invoke(this, e);
        }
        else
        {
            StartRequested?.Invoke(this, e);
        }
    }

    private void OnRestartClick(object sender, RoutedEventArgs e) => RestartRequested?.Invoke(this, e);
}
