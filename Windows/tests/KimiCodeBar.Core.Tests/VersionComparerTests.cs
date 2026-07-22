using KimiCodeBar.Core.Services;
using Xunit;

namespace KimiCodeBar.Core.Tests;

/// <summary>
/// 版本比较测试，覆盖 normalize（去 v / package@x.x.x）与 IsNewer 语义。
/// </summary>
public class VersionComparerTests
{
    [Theory]
    [InlineData("v0.28.0", "0.28.0")]
    [InlineData("V0.28.0", "0.28.0")]
    [InlineData("0.28.0", "0.28.0")]
    [InlineData("kimi@0.30.0", "0.30.0")]
    [InlineData("package@1.2.3", "1.2.3")]
    [InlineData("release-0.23.5", "0.23.5")]
    public void Normalize_RemovesPrefixAndExtractsSemver(string input, string expected)
    {
        Assert.Equal(expected, VersionComparer.Normalize(input));
    }

    [Theory]
    [InlineData("0.24.0", "0.23.5", true)]
    [InlineData("0.23.5", "0.23.5", false)]
    [InlineData("0.23.4", "0.23.5", false)]
    [InlineData("1.0.0", "0.99.9", true)]
    [InlineData("0.23.5", "0.23.5.1", false)]
    [InlineData("0.23.5.2", "0.23.5.1", true)]
    [InlineData("v0.28.0", "0.27.9", true)]
    [InlineData("kimi@0.30.0", "0.29.0", true)]
    public void IsNewer_ComparesCorrectly(string latest, string current, bool expected)
    {
        Assert.Equal(expected, VersionComparer.IsNewer(latest, current));
    }

    [Fact]
    public void Compare_ReturnsZeroForEqual()
    {
        Assert.Equal(0, VersionComparer.Compare("0.23.5", "v0.23.5"));
    }
}
