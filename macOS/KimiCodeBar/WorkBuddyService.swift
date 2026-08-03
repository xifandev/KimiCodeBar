import Foundation
import AppKit

// MARK: - WorkBuddy 账号模型

/// WorkBuddy 账号：从本地 auth 文件读取，包含 token 对 + 完整快照（用于切换时写回）。
struct WorkBuddyAccount: Codable, Identifiable, Equatable {
    var id: String { uid }
    var nickname: String
    var uid: String
    var accessToken: String
    var refreshToken: String
    var domain: String

    /// auth 文件里完整的 account 块原始 JSON（含 uin/phoneNumber/deployStatus 等）。
    /// 切换账号时整体写回，避免字段丢失。老数据无此字段时为 nil。
    var accountSnapshot: Data?
    /// auth 文件里完整的 auth 块原始 JSON（含 expiresAt/refreshExpiresAt/tokenType 等）。
    var authSnapshot: Data?

    var isApiKeyMode: Bool { accessToken.hasPrefix("ck_") }
    var hasSnapshot: Bool { accountSnapshot != nil && authSnapshot != nil }
}

// MARK: - WorkBuddy 积分

/// WorkBuddy 积分查询结果：剩余积分 + 套餐名（如"免费版"/"付费版"）。
struct WorkBuddyCredits: Equatable {
    let remaining: Double
    let tier: String

    /// 积分展示文本：截断到一位小数（不四舍五入），整数则不显示小数
    var remainingText: String {
        let truncated = floor(remaining * 10) / 10
        if truncated == Double(Int(truncated)) {
            return "\(Int(truncated))"
        }
        return String(format: "%.1f", truncated)
    }
}

// MARK: - WorkBuddy 服务

/// WorkBuddy 集成服务：
/// 1. 从本地 auth 文件读取当前登录账号（添加账号入口）
/// 2. 调 API 查积分
/// 3. 切换账号（写快照回 auth 文件）
/// 4. 启动 / 重启 WorkBuddy 客户端
///
/// auth 文件路径：~/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info
/// 账号存储路径：~/.kimi-code-bar/workbuddy-accounts.json（与 Kimi/DeepSeek 账号隔离）
final class WorkBuddyService {
    static let shared = WorkBuddyService()

    /// WorkBuddy auth 文件（CodeBuddyExtension 写入的登录态）
    let authFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info")

    /// 本地账号存储目录（与 KimiCodeBar 主账号体系隔离，避免 Codable 冲突）
    private let storeDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code-bar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let storeFileURL: URL?
    private let session: URLSession
    private let baseURL = "https://copilot.tencent.com"
    private let refreshURL = "https://www.codebuddy.cn/auth/realms/copilot/protocol/openid-connect/token"

    private init() {
        storeFileURL = storeDir.appendingPathComponent("workbuddy-accounts.json")
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.connectionProxyDictionary = [:]  // 禁用系统代理，直连
        session = URLSession(configuration: config)
    }

    // MARK: - 账号存储

    /// 读取本地存储的 WorkBuddy 账号列表
    func loadAccounts() -> [WorkBuddyAccount] {
        guard let url = storeFileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([WorkBuddyAccount].self, from: data) else {
            return []
        }
        return decoded
    }

    private func saveAccounts(_ accounts: [WorkBuddyAccount]) {
        guard let url = storeFileURL,
              let data = try? JSONEncoder().encode(accounts) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    // MARK: - 从本地 auth 文件添加账号

    /// 读取当前 WorkBuddy auth 文件，抓取当前登录账号信息并存储。
    /// 成功返回账号，失败返回 nil（auth 文件不存在或格式不符）。
    @discardableResult
    func addCurrentAccount() -> WorkBuddyAccount? {
        guard let data = try? Data(contentsOf: authFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accountInfo = json["account"] as? [String: Any],
              let authInfo = json["auth"] as? [String: Any],
              let uid = accountInfo["uid"] as? String,
              let accessToken = authInfo["accessToken"] as? String,
              let refreshToken = authInfo["refreshToken"] as? String else {
            return nil
        }

        let nickname = (accountInfo["nickname"] as? String) ?? "Unknown"
        let accountSnapshot = try? JSONSerialization.data(withJSONObject: accountInfo, options: [.sortedKeys])
        let authSnapshot = try? JSONSerialization.data(withJSONObject: authInfo, options: [.sortedKeys])

        let newAccount = WorkBuddyAccount(
            nickname: nickname, uid: uid,
            accessToken: accessToken, refreshToken: refreshToken,
            domain: "www.codebuddy.cn",
            accountSnapshot: accountSnapshot, authSnapshot: authSnapshot
        )

        var accounts = loadAccounts()
        if let idx = accounts.firstIndex(where: { $0.uid == uid }) {
            accounts[idx] = newAccount
        } else {
            accounts.append(newAccount)
        }
        saveAccounts(accounts)
        return newAccount
    }

    func removeAccount(uid: String) {
        var accounts = loadAccounts()
        accounts.removeAll { $0.uid == uid }
        saveAccounts(accounts)
    }

    // MARK: - 查积分

    /// 查询指定账号的剩余积分 + 套餐名。失败返回 nil。
    /// Token 快过期时自动刷新。
    func fetchCredits(account: WorkBuddyAccount) async -> WorkBuddyCredits? {
        var working = account

        // Token 快过期 → 自动刷新
        if isTokenExpiringSoon(working.accessToken) {
            if let refreshed = await refreshToken(account: working) {
                working = refreshed
                updateAccount(refreshed)
            } else {
                return nil
            }
        }

        guard let (data, _) = try? await session.data(for: makeRequest(path: "/v2/billing/meter/get-user-resource", account: working)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = (json["code"] as? NSNumber)?.intValue ?? (json["code"] as? Int),
              code == 0 else {
            return nil
        }

        let resp = (json["data"] as? [String: Any])?["Response"] as? [String: Any]
        let d = resp?["Data"] as? [String: Any]
        let accounts = d?["Accounts"] as? [[String: Any]] ?? []

        var total: Double = 0
        var tierName = ""
        for acc in accounts {
            let cycleRemain: Double = {
                if let r = acc["CycleCapacityRemainPrecise"] as? Double { return r }
                if let r = acc["CycleCapacityRemainPrecise"] as? String, let v = Double(r) { return v }
                if let r = acc["CycleCapacityRemain"] as? Double { return r }
                if let r = acc["CycleCapacityRemain"] as? Int { return Double(r) }
                return 0
            }()
            total += cycleRemain
            if tierName.isEmpty, cycleRemain > 0 {
                if let name = acc["PackageName"] as? String, !name.isEmpty {
                    tierName = name
                }
            }
        }
        if tierName.isEmpty {
            for acc in accounts {
                if let name = acc["PackageName"] as? String, !name.isEmpty {
                    tierName = name
                    break
                }
            }
        }

        return WorkBuddyCredits(remaining: total, tier: simplifyTier(tierName))
    }

    // MARK: - 刷新 Token

    func refreshToken(account: WorkBuddyAccount) async -> WorkBuddyAccount? {
        guard !account.refreshToken.isEmpty else { return nil }
        var req = URLRequest(url: URL(string: refreshURL)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "grant_type=refresh_token&refresh_token=\(account.refreshToken)&client_id=console".data(using: .utf8)

        guard let (data, _) = try? await session.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAT = json["access_token"] as? String else {
            return nil
        }
        let newRT = json["refresh_token"] as? String ?? account.refreshToken
        return WorkBuddyAccount(
            nickname: account.nickname, uid: account.uid,
            accessToken: newAT, refreshToken: newRT, domain: account.domain,
            accountSnapshot: account.accountSnapshot, authSnapshot: account.authSnapshot
        )
    }

    private func updateAccount(_ updated: WorkBuddyAccount) {
        var accounts = loadAccounts()
        if let idx = accounts.firstIndex(where: { $0.uid == updated.uid }) {
            accounts[idx] = updated
            saveAccounts(accounts)
        }
    }

    // MARK: - 构建请求

    private func makeRequest(path: String, account: WorkBuddyAccount) -> URLRequest {
        let url = URL(string: baseURL + path)!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        if !account.isApiKeyMode {
            req.setValue(account.uid, forHTTPHeaderField: "X-User-Id")
            req.setValue(account.domain, forHTTPHeaderField: "X-Domain")
            req.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
            req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        }
        req.httpBody = "{}".data(using: .utf8)
        return req
    }

    // MARK: - 读取当前激活账号

    /// 读取 auth 文件里的 account.uid，用于判断哪个账号当前在 WorkBuddy 中登录。
    func currentActiveUID() -> String? {
        guard let data = try? Data(contentsOf: authFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uid = (json["account"] as? [String: Any])?["uid"] as? String else {
            return nil
        }
        return uid
    }

    // MARK: - 启动 / 重启 WorkBuddy

    /// WorkBuddy 进程是否在运行
    func isWorkBuddyRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.tencent.WorkBuddy" || $0.bundleURL?.lastPathComponent == "WorkBuddy.app"
        }
    }

    /// 重启 WorkBuddy 客户端。⚠️ 会断开当前对话。
    /// 旧进程退出 → 延迟 1.2s → 重新启动 → 延迟 0.5s → 回调运行状态。
    func restartWorkBuddy(completion: (@MainActor () -> Void)? = nil) {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.tencent.WorkBuddy" || $0.bundleURL?.lastPathComponent == "WorkBuddy.app"
        }
        for app in apps {
            app.terminate()
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let url = URL(fileURLWithPath: "/Applications/WorkBuddy.app")
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run { completion?() }
        }
    }

    // MARK: - JWT 工具

    private func isTokenExpiringSoon(_ token: String, withinHours hours: Double = 1) -> Bool {
        guard let expiry = tokenExpiryDate(token) else { return true }
        return expiry.timeIntervalSinceNow < hours * 3600
    }

    private func tokenExpiryDate(_ token: String) -> Date? {
        guard let payload = decodeJWTPayload(token),
              let exp = payload["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var s = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        guard let data = Data(base64Encoded: s) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - 套餐名简化

    /// 把 WorkBuddy 的 PackageName 简化为短 tier 标签
    private func simplifyTier(_ packageName: String) -> String {
        if packageName.isEmpty { return "" }
        if packageName.contains("体验") || packageName.contains("裂变") || packageName.contains("个人") {
            return "免费版"
        }
        if packageName.contains("专业") || packageName.contains("Pro") || packageName.contains("付费") {
            return "付费版"
        }
        return packageName.replacingOccurrences(of: "CodeBuddy", with: "")
    }
}
