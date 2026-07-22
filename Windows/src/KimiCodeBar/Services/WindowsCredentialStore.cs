using System.Security.Cryptography;
using System.Text;
using KimiCodeBar.Core;
using KimiCodeBar.Core.Services;
using Windows.Security.Credentials;

namespace KimiCodeBar.Services;

/// <summary>
/// Windows 凭据存储（App 层实现）。
/// 主选 <see cref="PasswordVault"/>（写入 Windows 凭据管理器，与 CLI 隔离）；
/// 若打包沙箱限制 PasswordVault，回退 DPAPI（ProtectedData，用户级）写入本地文件。
/// 通过 <see cref="ICredentialStore"/> 抽象，便于替换与单测。
/// </summary>
public sealed class WindowsCredentialStore : ICredentialStore
{
    private readonly PasswordVault? _vault;

    public WindowsCredentialStore()
    {
        // PasswordVault 在某些环境下构造会抛异常，捕获后回退 DPAPI。
        try
        {
            _vault = new PasswordVault();
        }
        catch
        {
            _vault = null;
        }
    }

    /// <inheritdoc/>
    public void Save(string key, string secret)
    {
        if (_vault is not null)
        {
            try
            {
                // 先删除已有凭据，避免重复。
                try
                {
                    var existing = _vault.Retrieve(Constants.CredentialResourceName, key);
                    _vault.Remove(existing);
                }
                catch
                {
                    // 不存在时忽略。
                }

                _vault.Add(new PasswordCredential(Constants.CredentialResourceName, key, secret));
                return;
            }
            catch
            {
                // 回退 DPAPI。
            }
        }

        DpapiSave(key, secret);
    }

    /// <inheritdoc/>
    public string? Load(string key)
    {
        if (_vault is not null)
        {
            try
            {
                var credential = _vault.Retrieve(Constants.CredentialResourceName, key);
                return credential?.Password;
            }
            catch
            {
                // 回退 DPAPI。
            }
        }

        return DpapiLoad(key);
    }

    /// <inheritdoc/>
    public void Delete(string key)
    {
        if (_vault is not null)
        {
            try
            {
                var credential = _vault.Retrieve(Constants.CredentialResourceName, key);
                _vault.Remove(credential);
            }
            catch
            {
                // 忽略。
            }
        }

        try
        {
            DpapiDelete(key);
        }
        catch
        {
            // 忽略。
        }
    }

    // ===================== DPAPI 回退实现 =====================

    private static string DpapiPath(string key)
    {
        var dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "KimiCodeBar",
            "credentials");
        return Path.Combine(dir, key + ".bin");
    }

    private static void DpapiSave(string key, string secret)
    {
        var bytes = ProtectedData.Protect(
            Encoding.UTF8.GetBytes(secret), null, DataProtectionScope.CurrentUser);
        var path = DpapiPath(key);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, bytes);
    }

    private static string? DpapiLoad(string key)
    {
        var path = DpapiPath(key);
        if (!File.Exists(path))
        {
            return null;
        }

        var bytes = ProtectedData.Unprotect(
            File.ReadAllBytes(path), null, DataProtectionScope.CurrentUser);
        return Encoding.UTF8.GetString(bytes);
    }

    private static void DpapiDelete(string key)
    {
        var path = DpapiPath(key);
        if (File.Exists(path))
        {
            File.Delete(path);
        }
    }
}
