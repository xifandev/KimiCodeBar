import Foundation
import AppKit
import CryptoKit

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
    private let refreshURL = "https://www.codebuddy.cn/auth/realms/copilot/protocol/openid-connect/token"

    /// WorkBuddy 控制台（用量 / 套餐页），底部「控制台」按钮跳转入口
    static let consoleURL = URL(string: "https://www.workbuddy.cn/profile/plans-usage")!

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.connectionProxyDictionary = [:]  // 禁用系统代理，直连
        session = URLSession(configuration: config)
    }

    // MARK: - At-Rest 加密信封（WorkBuddy 5.6+）

    /// WorkBuddy 5.6 起 auth 文件的敏感字段改为加密信封：
    /// `{"$wbEncrypted": 1, "envelope": "<base64>"}`，envelope 解 base64 后为
    /// `{"suite":1,"keyId":"…","nonce":"…","authTag":"…","ciphertext":"…"}`（AES-256-GCM）。
    /// 密钥不落盘，通过 WorkBuddy 自带的 Electron 运行时调原生绑定取得（见 atRestKey）。
    private struct AtRestEnvelope: Decodable {
        let suite: Int
        let keyId: String
        let nonce: String
        let authTag: String
        let ciphertext: String
    }

    /// SHA256(atRestSecretKey) 派生的 AES-256-GCM 密钥，进程内缓存
    private var cachedAtRestKey: SymmetricKey?

    /// 取 WorkBuddy 的 at-rest 密钥：以 ELECTRON_RUN_AS_NODE 模式跑 WorkBuddy 自带的
    /// Electron 二进制，调原生绑定 electron_browser_workbuddy_storage.loggerGet() 拿到
    /// atRestSecretKey，再做一次 SHA256 得到 AES-256 密钥。WorkBuddy 未安装或官方改版时返回 nil。
    private func atRestKey() -> SymmetricKey? {
        if let cachedAtRestKey { return cachedAtRestKey }
        let js = #"try{process.stdout.write(process._linkedBinding('electron_browser_workbuddy_storage').loggerGet())}catch(e){process.exit(1)}"#
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-atrest-\(UUID().uuidString).js")
        guard let _ = try? js.write(to: scriptURL, atomically: true, encoding: .utf8) else { return nil }
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/Applications/WorkBuddy.app/Contents/MacOS/Electron")
        task.arguments = [scriptURL.path]
        task.environment = [
            "ELECTRON_RUN_AS_NODE": "1",
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/local/bin",
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard let _ = try? task.run() else { return nil }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              let secret = json["atRestSecretKey"] as? String,
              let secretData = secret.data(using: .utf8) else { return nil }

        let key = SymmetricKey(data: SHA256.hash(data: secretData))
        cachedAtRestKey = key
        return key
    }

    /// 字段信封的 AAD（附加认证数据），构造与 WorkBuddy 内部一致：长度前缀 transcript
    private func fieldAAD(keyId: String, suite: Int) -> Data {
        func lengthPrefixed(_ s: String) -> Data {
            let bytes = Data(s.utf8)
            var len = UInt32(bytes.count).bigEndian
            return Data(bytes: &len, count: 4) + bytes
        }
        var aad = Data("WB-AAD\0".utf8)
        aad.append(0x01)
        aad.append(lengthPrefixed("WBEV1"))
        aad.append(lengthPrefixed("sym-v1"))
        var suiteBE = UInt32(suite).bigEndian
        aad.append(Data(bytes: &suiteBE, count: 4))
        aad.append(lengthPrefixed(keyId))
        aad.append(0x02)
        aad.append(0x00)
        aad.append(0x00)
        return aad
    }

    /// 读取 auth 文件里的字段值：5.5.x 及更早是明文字符串，5.6+ 是加密信封，两种都支持。
    func decryptField(_ value: Any?) -> String? {
        if let plain = value as? String { return plain }
        guard let wrapper = value as? [String: Any],
              (wrapper["$wbEncrypted"] as? Int) == 1,
              let envelopeBase64 = wrapper["envelope"] as? String,
              let envelopeData = Data(base64Encoded: envelopeBase64),
              let envelope = try? JSONDecoder().decode(AtRestEnvelope.self, from: envelopeData),
              let key = atRestKey(),
              let nonceData = Data(base64Encoded: envelope.nonce),
              let ciphertext = Data(base64Encoded: envelope.ciphertext),
              let tag = Data(base64Encoded: envelope.authTag),
              let nonce = try? AES.GCM.Nonce(data: nonceData),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag),
              let plainData = try? AES.GCM.open(box, using: key, authenticating: fieldAAD(keyId: envelope.keyId, suite: envelope.suite)) else {
            return nil
        }
        return String(data: plainData, encoding: .utf8)
    }

    /// 当前 auth 文件使用的 keyId（加密写回时与 WorkBuddy 当前密钥保持一致）
    private func currentKeyId() -> String? {
        guard let data = try? Data(contentsOf: authFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = json["auth"] as? [String: Any] else { return nil }
        for field in ["accessToken", "refreshToken"] {
            if let wrapper = auth[field] as? [String: Any],
               let envelopeBase64 = wrapper["envelope"] as? String,
               let envelopeData = Data(base64Encoded: envelopeBase64),
               let envelope = try? JSONDecoder().decode(AtRestEnvelope.self, from: envelopeData) {
                return envelope.keyId
            }
        }
        return nil
    }

    /// 把明文加密成 WorkBuddy 5.6+ 的字段信封；取不到密钥时返回 nil
    private func encryptField(_ plaintext: String) -> [String: Any]? {
        guard let key = atRestKey(), let keyId = currentKeyId(),
              let box = try? AES.GCM.seal(Data(plaintext.utf8), using: key, authenticating: fieldAAD(keyId: keyId, suite: 1)) else {
            return nil
        }
        let envelope: [String: Any] = [
            "suite": 1,
            "keyId": keyId,
            "nonce": box.nonce.withUnsafeBytes { Data($0) }.base64EncodedString(),
            "authTag": box.tag.base64EncodedString(),
            "ciphertext": box.ciphertext.base64EncodedString(),
        ]
        guard let envelopeData = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]) else {
            return nil
        }
        return ["$wbEncrypted": 1, "envelope": envelopeData.base64EncodedString()]
    }

    /// 写回 auth 文件用的字段值：优先加密信封（5.6+），取不到密钥时回退明文（5.5.x 旧版）
    private func fieldValueForWrite(_ plaintext: String) -> Any {
        encryptField(plaintext) ?? plaintext
    }

    // MARK: - 从本地 auth 文件添加账号

    /// 读取当前 WorkBuddy auth 文件，构建一个 KimiAccount（provider=.workbuddy）。
    /// 5.6+ 的加密字段走 decryptField 解密。调用方负责去重后存入 KimiAccountStore。失败返回 nil。
    func addCurrentAccount() -> KimiAccount? {
        guard let data = try? Data(contentsOf: authFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accountInfo = json["account"] as? [String: Any],
              let authInfo = json["auth"] as? [String: Any],
              let uid = accountInfo["uid"] as? String,
              let accessToken = decryptField(authInfo["accessToken"]),
              let refreshToken = decryptField(authInfo["refreshToken"]) else {
            return nil
        }

        let nickname = decryptField(accountInfo["nickname"]) ?? "Unknown"
        let domain = (authInfo["domain"] as? String) ?? "www.codebuddy.cn"
        let accountSnapshot = try? JSONSerialization.data(withJSONObject: accountInfo, options: [.sortedKeys])
        let authSnapshot = try? JSONSerialization.data(withJSONObject: authInfo, options: [.sortedKeys])

        let cred = WorkBuddyCredential(
            uid: uid, nickname: nickname,
            accessToken: accessToken, refreshToken: refreshToken,
            domain: domain,
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
            accountObj["nickname"] = fieldValueForWrite(cred.nickname)
            authObj["accessToken"] = fieldValueForWrite(cred.accessToken)
            authObj["refreshToken"] = fieldValueForWrite(cred.refreshToken)
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
