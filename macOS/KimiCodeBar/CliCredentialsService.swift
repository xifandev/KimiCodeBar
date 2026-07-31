import Foundation

// MARK: - CLI 凭证服务

/// Kimi Code CLI 凭证文件（~/.kimi-code/credentials/kimi-code.json）的读写。
///
/// 凭证隔离原则的唯一例外（见 CONTEXT.md「切换账号」）：
/// - 写入仅发生在用户主动「切换账号」的瞬间，此后 Bar 与 CLI 各自独立、不再同步；
/// - 读取仅用于账号列表展示「CLI 使用中」标签，以及切换前检测 CLI 现有凭证是否已保存到 Bar。
enum CliCredentialsService {

    /// CLI 凭证文件路径（CLI 单账号，凭证名固定为 kimi-code.json）。
    /// 注意：GUI 应用通常拿不到 shell 里的 KIMI_CODE_HOME，这里按默认路径处理。
    static func credentialsFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code/credentials/kimi-code.json")
    }

    /// 读取 CLI 当前凭证；文件不存在或解析失败返回 nil。
    /// CLI 的 expires_at 可能是小数时间戳，按 Double 解码后取整兼容。
    static func loadToken() -> KimiOAuthToken? {
        struct FileToken: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresAt: Double
            let scope: String?
            let tokenType: String?
            let expiresIn: Int?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case expiresAt = "expires_at"
                case scope
                case tokenType = "token_type"
                case expiresIn = "expires_in"
            }
        }

        guard let data = try? Data(contentsOf: credentialsFileURL()),
              let file = try? JSONDecoder().decode(FileToken.self, from: data) else {
            return nil
        }

        return KimiOAuthToken(
            accessToken: file.accessToken,
            refreshToken: file.refreshToken ?? "",
            expiresAt: Int(file.expiresAt),
            scope: file.scope,
            tokenType: file.tokenType,
            expiresIn: file.expiresIn
        )
    }

    /// 在账号列表中查找与 CLI 凭证匹配的账号：优先比对 refresh_token，其次 access_token。
    /// CLI 轮换 token 后两边不再一致，返回 nil（「CLI 使用中」标签随之消失，符合预期）。
    static func matchedAccountID(token: KimiOAuthToken?, in accounts: [KimiAccount]) -> UUID? {
        guard let token else { return nil }
        if !token.refreshToken.isEmpty,
           let match = accounts.first(where: { $0.token.refreshToken == token.refreshToken }) {
            return match.id
        }
        return accounts.first(where: { $0.token.accessToken == token.accessToken })?.id
    }

    /// 把账号 token 原子写入 CLI 凭证文件（目录 0700 / 文件 0600，tmp + replace）。
    /// 临时文件落盘后即设 0600，再替换到位，避免凭证以默认 umask 权限暴露。
    /// 写失败抛错并清理临时文件，由调用方提示用户。
    static func writeToken(_ token: KimiOAuthToken) throws {
        let url = credentialsFileURL()
        let directory = url.deletingLastPathComponent()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(token)

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // createDirectory 不会修正已存在目录的权限，显式补齐
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let tempURL = directory.appendingPathComponent(".\(url.lastPathComponent).tmp.\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try data.write(to: tempURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)

            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    /// 是否有正在运行的 Kimi Code CLI 进程（TUI / kimi web 等）。
    /// 按进程名小写 kimi 前缀匹配；Bar 自身进程名为 KimiCodeBar（大写 K），不会误匹配。
    static func isKimiCliRunning() -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "comm="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return false }
        return output.split(separator: "\n").contains { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("kimi")
        }
    }
}
