using KimiCodeBar.Core.Services;
using Xunit;

namespace KimiCodeBar.Core.Tests;

/// <summary>
/// 中文 changelog 解析测试，覆盖 "## 0.23.5（2026-07-10）" 段解析与列表项转换。
/// </summary>
public class ChangelogParserTests
{
    private const string SampleChangelog = """
    # Kimi Code 更新日志

    ## 0.23.5（2026-07-10）

    * 修复了若干已知问题
    * 优化了用量展示性能

    ### 已知问题

    * 部分环境下面板偶发闪烁

    ## 0.23.0（2026-06-20）

    * 新增 5 小时用量统计
    * 支持深色模式

    ## 0.22.0（2026-05-01）

    * 初始版本
    """;

    [Fact]
    public void Parse_FirstEntry_HasCorrectVersion()
    {
        var entry = ChangelogParser.Parse(SampleChangelog);
        Assert.NotNull(entry);
        Assert.Equal("0.23.5", entry!.Version);
    }

    [Fact]
    public void Parse_FirstEntry_StripsDateAndConvertsBulletPoints()
    {
        var entry = ChangelogParser.Parse(SampleChangelog);
        Assert.NotNull(entry);
        // 版本标题与分类标题（###）被跳过；* 转为 •。
        Assert.DoesNotContain("（2026-07-10）", entry!.Notes);
        Assert.DoesNotContain("### 已知问题", entry.Notes);
        Assert.Contains("• 修复了若干已知问题", entry.Notes);
        Assert.Contains("• 优化了用量展示性能", entry.Notes);
        // 分类内的列表项也应被转换。
        Assert.Contains("• 部分环境下面板偶发闪烁", entry.Notes);
    }

    [Fact]
    public void ParseEntries_ReturnsMultipleVersionsInOrder()
    {
        var entries = ChangelogParser.ParseEntries(SampleChangelog, 10);
        Assert.Equal(3, entries.Count);
        Assert.Equal("0.23.5", entries[0].Version);
        Assert.Equal("0.23.0", entries[1].Version);
        Assert.Equal("0.22.0", entries[2].Version);
    }

    [Fact]
    public void ParseEntries_RespectsMax()
    {
        var entries = ChangelogParser.ParseEntries(SampleChangelog, 2);
        Assert.Equal(2, entries.Count);
        Assert.Equal("0.23.5", entries[0].Version);
        Assert.Equal("0.23.0", entries[1].Version);
    }

    [Fact]
    public void FetchNotes_MatchesByNormalizedVersion()
    {
        var notes = ChangelogParser.FetchNotes(SampleChangelog, "v0.23.0");
        Assert.NotNull(notes);
        Assert.Contains("新增 5 小时用量统计", notes);
    }

    [Fact]
    public void Parse_EmptyText_ReturnsNull()
    {
        Assert.Null(ChangelogParser.Parse(string.Empty));
    }
}
