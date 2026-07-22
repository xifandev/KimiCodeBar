using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace KimiCodeBar.Views.Controls;

/// <summary>
/// 未登录遮罩。覆盖在主面板之上，引导用户设置 API Key（v1 不做 OAuth）。
/// </summary>
public sealed partial class LoginOverlay : UserControl
{
    /// <summary>用户点击"设置 API Key"，应打开设置窗口录入凭据。</summary>
    public event TypedEventHandler<LoginOverlay, object>? ApiKeyRequested;

    /// <summary>用户点击"其他登录方式"（v1 同样导向设置窗口）。</summary>
    public event TypedEventHandler<LoginOverlay, object>? OtherLoginRequested;

    public LoginOverlay()
    {
        InitializeComponent();
    }

    private void OnApiKeyClick(object sender, RoutedEventArgs e) => ApiKeyRequested?.Invoke(this, e);

    private void OnOtherClick(object sender, RoutedEventArgs e) => OtherLoginRequested?.Invoke(this, e);
}
