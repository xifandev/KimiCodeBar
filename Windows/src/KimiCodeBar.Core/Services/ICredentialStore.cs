namespace KimiCodeBar.Core.Services;

/// <summary>
/// 凭据存储接口（由 App 层的 <c>WindowsCredentialStore</c> 实现）。
/// v1 仅存储 API Key，经 Windows 凭据管理器 / DPAPI 加密。
/// </summary>
public interface ICredentialStore
{
    /// <summary>保存凭据（key 已存在则覆盖）。</summary>
    void Save(string key, string secret);

    /// <summary>读取凭据，不存在返回 null。</summary>
    string? Load(string key);

    /// <summary>删除凭据（不存在时忽略）。</summary>
    void Delete(string key);
}
