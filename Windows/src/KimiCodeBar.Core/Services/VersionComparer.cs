using System.Text.RegularExpressions;

namespace KimiCodeBar.Core.Services;

/// <summary>
/// 版本号比较（纯逻辑）。
/// 1:1 移植自 macOS <c>normalizeVersion</c> / <c>compareVersions</c>：
/// 去 v / 提取 package@x.x.x 后的版本号 / 按点分段补齐后逐段比较。
/// </summary>
public static class VersionComparer
{
    // 匹配主版本号（如 0.23.5 或 0.23.5.1）。
    private static readonly Regex SemverRegex = new(@"(\d+\.\d+\.\d+(?:\.\d+)?)", RegexOptions.Compiled);

    /// <summary>
    /// 规范化版本号：去除首尾空白，优先提取 <c>package@x.x.x</c> 之后的版本，
    /// 否则从字符串中提取第一个 semver。提取失败返回原字符串。
    /// </summary>
    public static string Normalize(string version)
    {
        var trimmed = version.Trim();

        // 优先提取 package@x.x.x 之后的版本号。
        var atIndex = trimmed.LastIndexOf('@');
        if (atIndex >= 0)
        {
            var suffix = trimmed[(atIndex + 1)..];
            return ExtractSemver(suffix) ?? suffix;
        }

        return ExtractSemver(trimmed) ?? trimmed;
    }

    /// <summary>比较两个版本：a&gt;b 返回 1，a&lt;b 返回 -1，相等返回 0。</summary>
    public static int Compare(string a, string b)
    {
        var left = SplitVersion(Normalize(a));
        var right = SplitVersion(Normalize(b));

        for (var i = 0; i < Math.Max(left.Count, right.Count); i++)
        {
            var l = i < left.Count ? left[i] : 0;
            var r = i < right.Count ? right[i] : 0;
            if (l < r)
            {
                return -1;
            }

            if (l > r)
            {
                return 1;
            }
        }

        return 0;
    }

    /// <summary>判断 <paramref name="latest"/> 是否比 <paramref name="current"/> 更新。</summary>
    public static bool IsNewer(string latest, string current) => Compare(latest, current) > 0;

    /// <summary>将规范化后的版本号按点分段为整型列表（无法解析的段按 0 处理）。</summary>
    private static List<int> SplitVersion(string version) =>
        version.Split('.').Select(seg => int.TryParse(seg, out var n) ? n : 0).ToList();

    /// <summary>从文本中提取第一个 semver（如 "0.23.5"）。</summary>
    private static string? ExtractSemver(string text)
    {
        var match = SemverRegex.Match(text);
        return match.Success ? match.Value : null;
    }
}
