using System.Globalization;
using KimiCodeBar.Core.Services;

namespace KimiCodeBar.Core.Services;

/// <summary>
/// 单条 changelog 条目（版本号 + 格式化后的 notes）。
/// </summary>
public sealed class ChangelogEntry
{
    /// <summary>版本号（如 0.23.5）。</summary>
    public string Version { get; init; } = string.Empty;

    /// <summary>格式化后的更新说明（每行一条，以换行分隔）。</summary>
    public string Notes { get; init; } = string.Empty;
}

/// <summary>
/// 中文 changelog 解析器（纯逻辑）。
/// 1:1 移植自 macOS <c>parseChineseChangelog</c> / <c>parseChineseChangelogEntries</c>：
/// 解析 <c>## 版本（日期）</c> 段到 notes，并将 <c>* </c> 列表项转换为 <c>• </c>。
/// </summary>
public static class ChangelogParser
{
    /// <summary>解析第一篇（最新）版本条目。</summary>
    public static ChangelogEntry? Parse(string text) => ParseEntries(text, 1).FirstOrDefault();

    /// <summary>解析前 <paramref name="max"/> 篇版本条目。</summary>
    public static List<ChangelogEntry> ParseEntries(string text, int max)
    {
        if (string.IsNullOrEmpty(text))
        {
            return new List<ChangelogEntry>();
        }

        // 统一换行符后按行拆分。
        var lines = text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');

        // 收集所有 ## 版本标题的位置与版本号。
        var headings = new List<(int Index, string Version)>();
        for (var i = 0; i < lines.Length; i++)
        {
            var trimmed = lines[i].Trim();
            if (!trimmed.StartsWith("## ", StringComparison.Ordinal))
            {
                continue;
            }

            var content = trimmed.Substring(3);
            var version = ExtractVersion(content);
            headings.Add((i, version));
        }

        var entries = new List<ChangelogEntry>();
        for (var h = 0; h < headings.Count; h++)
        {
            var start = headings[h].Index;
            var end = h + 1 < headings.Count ? headings[h + 1].Index : lines.Length;

            var formatted = new List<string>();
            for (var i = start; i < end; i++)
            {
                var line = lines[i].Trim();
                if (line.Length == 0)
                {
                    continue;
                }

                if (line.StartsWith("## ", StringComparison.Ordinal))
                {
                    continue; // 跳过版本标题
                }

                if (line.StartsWith("### ", StringComparison.Ordinal))
                {
                    continue; // 跳过分类大标题
                }

                if (line.StartsWith("* ", StringComparison.Ordinal))
                {
                    formatted.Add("• " + line.Substring(2));
                }
                else
                {
                    formatted.Add(line);
                }
            }

            entries.Add(new ChangelogEntry
            {
                Version = headings[h].Version,
                Notes = string.Join("\n", formatted)
            });

            if (entries.Count >= max)
            {
                break;
            }
        }

        return entries;
    }

    /// <summary>
    /// 从 changelog 文本中抓取指定版本的 release notes。
    /// 版本号会先做 <see cref="VersionComparer.Normalize"/>，因此 "0.28.0" 与 "v0.28.0" 都能匹配。
    /// </summary>
    public static string? FetchNotes(string text, string version)
    {
        var target = VersionComparer.Normalize(version);
        return ParseEntries(text, int.MaxValue)
            .FirstOrDefault(e => VersionComparer.Normalize(e.Version) == target)?.Notes;
    }

    /// <summary>从 "## 0.23.5（2026-07-10）" 中提取版本号（去除括号日期）。</summary>
    private static string ExtractVersion(string content)
    {
        var parenIndex = content.IndexOf('（');
        var version = parenIndex >= 0 ? content.Substring(0, parenIndex) : content;
        return version.Trim();
    }
}
