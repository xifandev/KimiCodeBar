using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using KimiCodeBar.Core.Models;

namespace KimiCodeBar.Tray;

/// <summary>
/// 托盘图标位图渲染器（仿 macOS MenuBarTextRenderer）。
/// 用 <see cref="System.Drawing.Bitmap"/> 绘制 "7D xx% / 5H xx%" 文本位图；
/// 无数据时绘制 "Kimi" 字样。配色取自文档第 8 节（KimiBlue 等）。
/// </summary>
public sealed class TrayIconRenderer
{
    // 文档第 8 节配色。
    private static readonly Color KimiBlue = Color.FromArgb(0xFF, 0x3B, 0x82, 0xF5);
    private static readonly Color MenuText = Color.FromArgb(0xFF, 0xE2, 0xE9, 0xF6);

    private const int Width = 56;
    private const int Height = 22;

    /// <summary>绘制有数据时的用量图标（7D / 5H 两行百分比）。</summary>
    public Bitmap Draw(QuotaDetail weekly, QuotaDetail fiveHour)
    {
        var bitmap = new Bitmap(Width, Height);
        using var g = Graphics.FromImage(bitmap);
        ConfigureGraphics(g);

        using var font = new Font("Segoe UI", 10, FontStyle.Regular);
        using var brush = new SolidBrush(MenuText);

        DrawLine(g, font, brush, "7D", weekly.Percentage, y: 2);
        DrawLine(g, font, brush, "5H", fiveHour.Percentage, y: 12);

        return bitmap;
    }

    /// <summary>绘制无数据时的默认图标（"Kimi"）。</summary>
    public Bitmap DrawDefault()
    {
        var bitmap = new Bitmap(Width, Height);
        using var g = Graphics.FromImage(bitmap);
        ConfigureGraphics(g);

        using var font = new Font("Segoe UI", 11, FontStyle.Bold);
        using var brush = new SolidBrush(KimiBlue);
        var size = g.MeasureString("Kimi", font);
        g.DrawString("Kimi", font, brush, new PointF((Width - size.Width) / 2, (Height - size.Height) / 2));
        return bitmap;
    }

    private static void ConfigureGraphics(Graphics g)
    {
        g.Clear(Color.Transparent);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.AntiAlias;
        g.CompositingQuality = CompositingQuality.HighQuality;
    }

    private static void DrawLine(Graphics g, Font font, Brush brush, string label, int percentage, int y)
    {
        g.DrawString(label, font, brush, new PointF(0, y));

        var text = $"{percentage}%";
        var size = g.MeasureString(text, font);
        g.DrawString(text, font, brush, new PointF(Width - size.Width, y));
    }
}
