using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace KimiCodeBar.Views.Controls;

/// <summary>
/// 自定义操作按钮（仿 macOS ActionButton）。
/// 垂直布局：图标（Glyph 或 TextIcon）+ 标题；悬停显示手型光标并高亮反馈（见 App.xaml 默认样式）。
/// </summary>
public sealed class ActionButton : Button
{
    private static readonly InputCursor HandCursor = InputSystemCursor.Create(InputSystemCursorShape.Hand);
    private static readonly InputCursor ArrowCursor = InputSystemCursor.Create(InputSystemCursorShape.Arrow);

    /// <summary>按钮标题。</summary>
    public static readonly DependencyProperty TitleProperty =
        DependencyProperty.Register(nameof(Title), typeof(string), typeof(ActionButton), new PropertyMetadata(string.Empty));

    /// <summary>Segoe Fluent 图标（Glyph）。与 TextIcon 互斥。</summary>
    public static readonly DependencyProperty GlyphProperty =
        DependencyProperty.Register(nameof(Glyph), typeof(string), typeof(ActionButton), new PropertyMetadata(null, OnGlyphChanged));

    /// <summary>文本图标（如 "KIMI"）。与 Glyph 互斥。</summary>
    public static readonly DependencyProperty TextIconProperty =
        DependencyProperty.Register(nameof(TextIcon), typeof(string), typeof(ActionButton), new PropertyMetadata(null, OnTextIconChanged));

    /// <summary>Glyph 可见性（由 Glyph 是否存在推导）。</summary>
    public static readonly DependencyProperty GlyphVisibilityProperty =
        DependencyProperty.Register(nameof(GlyphVisibility), typeof(Visibility), typeof(ActionButton), new PropertyMetadata(Visibility.Collapsed));

    /// <summary>TextIcon 可见性（由 TextIcon 是否存在推导）。</summary>
    public static readonly DependencyProperty TextIconVisibilityProperty =
        DependencyProperty.Register(nameof(TextIconVisibility), typeof(Visibility), typeof(ActionButton), new PropertyMetadata(Visibility.Collapsed));

    public string Title
    {
        get => (string)GetValue(TitleProperty);
        set => SetValue(TitleProperty, value);
    }

    public string? Glyph
    {
        get => (string?)GetValue(GlyphProperty);
        set => SetValue(GlyphProperty, value);
    }

    public string? TextIcon
    {
        get => (string?)GetValue(TextIconProperty);
        set => SetValue(TextIconProperty, value);
    }

    public Visibility GlyphVisibility
    {
        get => (Visibility)GetValue(GlyphVisibilityProperty);
        set => SetValue(GlyphVisibilityProperty, value);
    }

    public Visibility TextIconVisibility
    {
        get => (Visibility)GetValue(TextIconVisibilityProperty);
        set => SetValue(TextIconVisibilityProperty, value);
    }

    public ActionButton()
    {
        this.DefaultStyleKey = typeof(ActionButton);
        UpdateIconVisibility();

        // 悬停手型光标，移出恢复箭头。
        PointerEntered += (_, _) => ProtectedCursor = HandCursor;
        PointerExited += (_, _) => ProtectedCursor = ArrowCursor;
    }

    private static void OnGlyphChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((ActionButton)d).UpdateIconVisibility();

    private static void OnTextIconChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((ActionButton)d).UpdateIconVisibility();

    private void UpdateIconVisibility()
    {
        GlyphVisibility = string.IsNullOrEmpty(Glyph) ? Visibility.Collapsed : Visibility.Visible;
        TextIconVisibility = string.IsNullOrEmpty(TextIcon) ? Visibility.Collapsed : Visibility.Visible;
    }
}
