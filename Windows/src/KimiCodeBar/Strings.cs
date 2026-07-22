using Windows.ApplicationModel.Resources;

namespace KimiCodeBar;

/// <summary>
/// 资源字符串访问助手。集中从 <c>Resources/Strings.resw</c> 读取用户可见文案（v1 仅中文值），
/// 供 XAML 通过 <c>{x:Bind local:Strings.Get('Key')}</c> 使用，避免硬编码。
/// </summary>
public static class Strings
{
    private static readonly ResourceLoader Loader = new ResourceLoader();

    /// <summary>获取指定 key 的资源字符串；缺失时返回 key 本身以便排查。</summary>
    public static string Get(string key)
    {
        var value = Loader.GetString(key);
        return string.IsNullOrEmpty(value) ? key : value;
    }
}
