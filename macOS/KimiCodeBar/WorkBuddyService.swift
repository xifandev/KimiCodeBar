import Foundation
import AppKit

// MARK: - WorkBuddy 积分

/// WorkBuddy 积分查询结果：剩余积分 + 套餐名（如"免费版"/"付费版"）。
struct WorkBuddyCredits: Equatable {
    let remaining: Double
    let tier: String

    /// 积分展示文本：截断到整数（不四舍五入），不显示小数
    var remainingText: String {
        "\(Int(floor(remaining)))"
    }
}

/// fetchCredits 的返回类型，区分三种情况让 UI 给出对应状态提示：
/// - success：积分正常返回
/// - unauthorized：服务端 SSO session 失效（HTTP 401/403），需走 OAuth 重新登录
/// - failed：网络错误 / 响应解析失败等，附带错误描述
enum WorkBuddyFetchOutcome: Equatable {
    case success(WorkBuddyCredits)
    case unauthorized
    case failed(String)
}

// MARK: - WorkBuddy 服务

/// WorkBuddy 集成服务：
/// 1. 从本地 auth 文件读取当前登录账号（添加账号入口）
/// 2. 调 API 查积分 + 每日签到
/// 3. 切换账号（写快照回 auth 文件）
/// 4. 启动 / 重启 WorkBuddy 客户端
///
/// 账号数据统一存储在 KimiAccountStore（credentials.json），
/// 本服务只负责 WorkBuddy 特有的 API 调用和 auth 文件操作。
///
/// auth 文件路径：~/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info
final class WorkBuddyService {
    static let shared = WorkBuddyService()

    /// WorkBuddy auth 文件（CodeBuddyExtension 写入的登录态）
    let authFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info")

    private let session: URLSession
    private let baseURL = "https://copilot.tencent.com"
    private let refreshURL = "https://www.workbuddy.cn/auth/realms/copilot/protocol/openid-connect/token"

    /// WorkBuddy 控制台（用量 / 套餐页），底部「控制台」按钮跳转入口
    static let consoleURL = URL(string: "https://www.workbuddy.cn/profile/plans-usage")!

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.connectionProxyDictionary = [:]  // 禁用系统代理，直连
        session = URLSession(configuration: config)
    }

    // MARK: - 从本地 auth 文件添加账号

    /// 读取当前 WorkBuddy auth 文件，构建一个 KimiAccount（provider=.workbuddy）。
    /// 调用方负责去重后存入 KimiAccountStore。失败返回 nil。
    func addCurrentAccount() -> KimiAccount? {
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

        let cred = WorkBuddyCredential(
            uid: uid, nickname: nickname,
            accessToken: accessToken, refreshToken: refreshToken,
            domain: "www.workbuddy.cn",
            accountSnapshot: accountSnapshot, authSnapshot: authSnapshot,
            lastCheckinDate: nil
        )
        return KimiAccount(
            id: UUID(), alias: nil, provider: .workbuddy,
            credential: .workbuddy(cred), accountIdentifier: uid
        )
    }

    // MARK: - 迁移旧格式

    /// 旧 workbuddy-accounts.json 的格式（迁移用）
    private struct OldWorkBuddyAccount: Codable {
        var nickname: String
        var uid: String
        var accessToken: String
        var refreshToken: String
        var domain: String
        var alias: String?
        var lastCheckinDate: String?
        var accountSnapshot: Data?
        var authSnapshot: Data?
    }

    /// 迁移旧 workbuddy-accounts.json → KimiAccountStore。
    /// 已迁移过的（accountIdentifier 匹配）跳过，迁移后重命名旧文件。
    static func migrateOldAccounts() {
        let oldFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code-bar/workbuddy-accounts.json")
        guard FileManager.default.fileExists(atPath: oldFile.path),
              let data = try? Data(contentsOf: oldFile),
              let oldAccounts = try? JSONDecoder().decode([OldWorkBuddyAccount].self, from: data),
              !oldAccounts.isEmpty else { return }

        let store = KimiAccountStore.shared
        for old in oldAccounts {
            // 已迁移则跳过
            if store.snapshot.accounts.contains(where: { $0.accountIdentifier == old.uid }) { continue }
            let cred = WorkBuddyCredential(
                uid: old.uid, nickname: old.nickname,
                accessToken: old.accessToken, refreshToken: old.refreshToken,
                domain: old.domain,
                accountSnapshot: old.accountSnapshot, authSnapshot: old.authSnapshot,
                lastCheckinDate: old.lastCheckinDate
            )
            store.addAccount(KimiAccount(
                id: UUID(), alias: old.alias, provider: .workbuddy,
                credential: .workbuddy(cred), accountIdentifier: old.uid
            ))
        }
        store.ensurePrimaryAccount()
        // 重命名旧文件防止重复迁移
        let migrated = oldFile.appendingPathExtension("migrated")
        try? FileManager.default.moveItem(at: oldFile, to: migrated)
    }

    // MARK: - 每日签到

    /// 今日日期字符串（北京时间 yyyy-MM-dd）
    static func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.string(from: Date())
    }

    /// 每日签到（幂等）。Token 快过期时自动刷新。
    /// 返回 (success, already)：success=true 表示签到成功或今日已签到，already=true 表示今日已签过。
    func checkin(account: KimiAccount) async -> (success: Bool, already: Bool) {
        guard var cred = account.workBuddyCredential else { return (false, false) }
        if isTokenExpiringSoon(cred.accessToken) {
            if let refreshed = await refreshToken(cred: cred) {
                cred = refreshed
                KimiAccountStore.shared.updateWorkBuddyCredential(id: account.id, credential: refreshed)
            }
        }

        guard let (data, _) = try? await session.data(for: makeRequest(path: "/v2/billing/meter/daily-checkin", cred: cred)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (false, false)
        }

        let code = (json["code"] as? NSNumber)?.intValue ?? (json["code"] as? Int) ?? -1
        let msg = (json["msg"] as? String) ?? ""

        if code == 0 { return (true, false) }
        if code == 10001 { return (true, true) }
        let lowerMsg = msg.lowercased()
        if lowerMsg.contains("already") || msg.contains("已签") || msg.contains("已领") || msg.contains("今日已") {
            return (true, true)
        }
        return (false, false)
    }

    // MARK: - 查积分

    /// 查询指定账号的剩余积分 + 套餐名。
    /// 返回 WorkBuddyFetchOutcome 让调用方区分 401 失效 / 网络错误 / 正常成功三种状态。
    /// Token 快过期时自动刷新（refresh_token grant 在 console client 上禁用，
    /// 实际很少触发；服务端 SSO session 失效时返回 .unauthorized 让 UI 引导重登）。
    func fetchCredits(account: KimiAccount) async -> WorkBuddyFetchOutcome {
        guard var cred = account.workBuddyCredential else {
            return .failed("账号凭证缺失")
        }

        if isTokenExpiringSoon(cred.accessToken) {
            if let refreshed = await refreshToken(cred: cred) {
                cred = refreshed
                KimiAccountStore.shared.updateWorkBuddyCredential(id: account.id, credential: refreshed)
            } else {
                // refresh_token grant 被 Keycloak 后台禁用，refresh 必然失败；
                // 这种情况按 unauthorized 处理（实际更可能是 access_token 已被服务端吊销）
                return .unauthorized
            }
        }

        let request = makeRequest(path: "/v2/billing/meter/get-user-resource", cred: cred)
        let data: Data
        let http: HTTPURLResponse
        do {
            let (rawData, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failed("服务端响应格式异常")
            }
            data = rawData
            http = httpResponse
        } catch {
            return .failed("网络错误：\(error.localizedDescription)")
        }

        // 401/403 = SSO session 失效（access_token JWT 没过期但服务端 session 表里查不到 sid）
        if http.statusCode == 401 || http.statusCode == 403 {
            return .unauthorized
        }
        if http.statusCode != 200 {
            return .failed("HTTP \(http.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = (json["code"] as? NSNumber)?.intValue ?? (json["code"] as? Int) else {
            return .failed("响应解析失败")
        }
        if code != 0 {
            let msg = (json["msg"] as? String) ?? "code=\(code)"
            return .failed("服务端错误：\(msg)")
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

        return .success(WorkBuddyCredits(remaining: total, tier: simplifyTier(tierName)))
    }

    // MARK: - 刷新 Token

    func refreshToken(cred: WorkBuddyCredential) async -> WorkBuddyCredential? {
        guard !cred.refreshToken.isEmpty else { return nil }
        var req = URLRequest(url: URL(string: refreshURL)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "grant_type=refresh_token&refresh_token=\(cred.refreshToken)&client_id=console".data(using: .utf8)

        guard let (data, _) = try? await session.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAT = json["access_token"] as? String else {
            return nil
        }
        let newRT = json["refresh_token"] as? String ?? cred.refreshToken
        var refreshed = cred
        refreshed.accessToken = newAT
        refreshed.refreshToken = newRT
        return refreshed
    }

    // MARK: - 构建请求

    private func makeRequest(path: String, cred: WorkBuddyCredential) -> URLRequest {
        let url = URL(string: baseURL + path)!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(cred.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        if !cred.isApiKeyMode {
            req.setValue(cred.uid, forHTTPHeaderField: "X-User-Id")
            req.setValue(cred.domain, forHTTPHeaderField: "X-Domain")
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

    // MARK: - 切换账号（写 auth 文件）

    /// 将指定账号的 token 对 + 快照写回 auth 文件，使下次启动 WorkBuddy 时使用该账号。
    /// 逻辑迁移自 wbSwitch 项目。返回是否成功写入。
    @discardableResult
    func switchTo(account: KimiAccount) -> Bool {
        guard let cred = account.workBuddyCredential else { return false }

        guard var curJson = readAuthJSONWithRetry() else { return false }

        // 若目标账号已是当前账号，无需切换
        if let curUid = (curJson["account"] as? [String: Any])?["uid"] as? String, curUid == cred.uid {
            return true
        }

        var accountObj: [String: Any]
        var authObj: [String: Any]

        if let accountData = cred.accountSnapshot,
           let authData = cred.authSnapshot,
           let snapAccount = try? JSONSerialization.jsonObject(with: accountData) as? [String: Any],
           let snapAuth = try? JSONSerialization.jsonObject(with: authData) as? [String: Any] {
            accountObj = snapAccount
            authObj = snapAuth
        } else {
            accountObj = (curJson["account"] as? [String: Any]) ?? [:]
            authObj = (curJson["auth"] as? [String: Any]) ?? [:]
            accountObj["uid"] = cred.uid
            accountObj["nickname"] = cred.nickname
            authObj["accessToken"] = cred.accessToken
            authObj["refreshToken"] = cred.refreshToken
            authObj["domain"] = cred.domain
            if authObj["tokenType"] == nil {
                authObj["tokenType"] = "Bearer"
            }
        }

        backupAuthFile()

        curJson["account"] = accountObj
        curJson["auth"] = authObj

        guard let newData = try? JSONSerialization.data(withJSONObject: curJson, options: [.prettyPrinted]) else {
            return false
        }
        do {
            try newData.write(to: authFileURL, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    private func readAuthJSONWithRetry() -> [String: Any]? {
        for attempt in 0..<3 {
            if let data = try? Data(contentsOf: authFileURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return json
            }
            if attempt < 2 {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        return nil
    }

    private func backupAuthFile() {
        let backupDir = authFileURL.deletingLastPathComponent()
            .appendingPathComponent("auth-backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupURL = backupDir.appendingPathComponent("workbuddy-desktop.\(ts).info")
        try? FileManager.default.copyItem(at: authFileURL, to: backupURL)
    }

    // MARK: - 启动 / 重启 WorkBuddy

    func isWorkBuddyRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.tencent.WorkBuddy" || $0.bundleURL?.lastPathComponent == "WorkBuddy.app"
        }
    }

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
