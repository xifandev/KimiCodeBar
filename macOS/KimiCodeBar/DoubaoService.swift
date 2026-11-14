import Foundation
import AppKit
import Combine
import Security
import CommonCrypto
import CryptoKit
import LocalAuthentication
import SQLite3

// MARK: - 豆包工作积分

/// 豆包工作签到面板读数（detail 接口一次拿全）。
/// remaining 展示「累计获得额度」（progress.total_amount）——豆包活动面板
/// 没有独立余额字段，签到奖励直接进账号额度池。
struct DoubaoCredits: Equatable, Sendable {
    /// 累计获得的活动额度
    let totalAmount: Int
    let checkedInToday: Bool
    let continuousDays: Int
    /// 今日签到奖励额度（未签时为待领额度）
    let rewardAmount: Int

    var totalText: String { "\(totalAmount)" }
}

enum DoubaoCheckinOutcome: Equatable {
    case claimed(Int)
    case alreadyClaimed
    case noCampaign
    case failed(String)
}

private final class DoubaoNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// 豆包工作本机登录态读取与签到/活动 API。
///
/// 客户端是 Chromium 系 Electron 应用，登录态存于 Chromium Cookies SQLite 库
/// （`~/Library/Application Support/DoubaoWork/Default/Cookies`），cookie 值用
/// Chromium Safe Storage 加密：v10 信封 = AES-128-CBC，密钥 PBKDF2-HMAC-SHA1
/// （钥匙串「DoubaoWork Safe Storage」密码串, salt "saltysalt", 1003 轮），
/// IV 为 16 个空格；Chromium 130+ 明文前 32 字节是 SHA256(host_key) 前缀需剥离。
/// 2026-11-15 本机（DoubaoWork 2.36.19 / Chromium 147）实测全链路可用。
///
/// 账号库仅保存 cookie 密文快照（解密后的会话值只在本进程内存中短暂存在，
/// 绝不写日志或返回 UI）；切账号时密文原样写回 cookie 库，不碰密钥、不重加密。
///
/// 签到接口（CreditDaddy 项目 2026-10 验证，2026-11-15 本机复测 code 0）：
///   POST /alice/ug/campaign/v3/detail/           任务面板（含签到状态与累计额度）
///   POST /alice/ug/campaign/landing/checkin      领取（+200/天，周一翻倍）
/// 纯 cookie 鉴权，无 a_bogus/msToken 签名；服务端幂等（重复领 idempotent:true）。
final class DoubaoService {
    static let shared = DoubaoService()

    private let dataDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/DoubaoWork", isDirectory: true)
    private let baseURL = URL(string: "https://www.doubao.com")!
    private let session: URLSession
    private let keyLock = NSLock()
    private var cachedAESKey: [UInt8]?

    /// 签到所属活动组（pc 端激励任务 v3；签到是其中的 daily_signin 任务）
    private static let campaignGroup = "pc_incentive_task_mvp_v3"
    /// 会话失效业务码（匿名/过期 cookie 返回「登录已过期」）
    private static let loginInvalidCode = 710012001

    /// 客户端指纹：与豆包桌面版 webview 同款 UA + 平台参数。
    /// 裸 UA 打活动接口会被服务端判「请求非法」，必须带完整桌面版形状。
    private static let clientUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) DoubaoDesktop/2.36.19 Chrome/147.0.7727.149 Safari/537.36"

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: DoubaoNoRedirectDelegate(), delegateQueue: nil)
    }

    static let consoleURL = URL(string: "https://www.doubao.com/chat/")!

    var cookiesFileURL: URL {
        dataDirectory.appendingPathComponent("Default/Cookies")
    }

    /// 客户端是否已安装
    var isClientInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/DoubaoWork.app/Contents/Info.plist")
    }

    // MARK: - cookie 库读取

    /// cookie 行快照（密文原样保存，可跨账号写回）
    struct CookieRow: Codable, Equatable {
        let host: String
        let name: String
        let path: String
        let encryptedValue: Data
        let expiresUTC: Int64
        let isSecure: Bool
        let isHTTPOnly: Bool
    }

    /// 读取 doubao.com 相关 cookie 行密文快照。
    /// 客户端运行时 Cookies 库被 Chromium 持有，先复制到临时文件再读。
    private func readCookieRows() throws -> [CookieRow] {
        let source = cookiesFileURL
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw DoubaoError.notSignedIn
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kimicodebar-doubao-cookies-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        do {
            try FileManager.default.copyItem(at: source, to: tempURL)
        } catch {
            throw DoubaoError.cookieReadFailed
        }
        var rows: [CookieRow] = []
        var db: OpaquePointer?
        guard sqlite3_open_v2(tempURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw DoubaoError.cookieReadFailed
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT host_key, name, path, encrypted_value, expires_utc, is_secure, is_httponly FROM cookies WHERE host_key LIKE '%doubao.com%'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DoubaoError.cookieReadFailed
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let hostPtr = sqlite3_column_text(stmt, 0),
                  let namePtr = sqlite3_column_text(stmt, 1),
                  let pathPtr = sqlite3_column_text(stmt, 2) else { continue }
            let blobSize = sqlite3_column_bytes(stmt, 3)
            guard blobSize > 3, let blobPtr = sqlite3_column_blob(stmt, 3) else { continue }
            let encrypted = Data(bytes: blobPtr, count: Int(blobSize))
            rows.append(CookieRow(
                host: String(cString: hostPtr),
                name: String(cString: namePtr),
                path: String(cString: pathPtr),
                encryptedValue: encrypted,
                expiresUTC: sqlite3_column_int64(stmt, 4),
                isSecure: sqlite3_column_int(stmt, 5) != 0,
                isHTTPOnly: sqlite3_column_int(stmt, 6) != 0
            ))
        }
        guard !rows.isEmpty else { throw DoubaoError.notSignedIn }
        return rows
    }

    // MARK: - 登录态解密

    /// 钥匙串服务名白名单：只查询豆包系客户端的 Safe Storage 项。
    /// 豆包工作（DoubaoWork）与豆包（Doubao）是两个独立客户端，各有自己的条目；
    /// 豆包工作的 cookie 用哪个条目加密随版本可能漂移，按序尝试。
    private static let keychainServices = [
        "DoubaoWork Safe Storage",
        "DoubaoWork App Safe Storage",
        "Doubao Safe Storage",
        "Chromium Safe Storage"
    ]

    private func keychainPasswords() -> [Data] {
        var passwords: [Data] = []
        // 同 Qoder：传 LAContext 以便钥匙串锁定时唤起系统授权 UI
        let authContext = LAContext()
        authContext.localizedReason = LanguageManager.tr("读取豆包登录凭据需要访问钥匙串")
        for service in Self.keychainServices {
            // 注意：不能用 kSecMatchLimitAll（实测返回 -50 errSecParam）
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecUseAuthenticationContext as String: authContext
            ]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let password = result as? Data else { continue }
            passwords.append(password)
        }
        var seen = Set<Data>()
        return passwords.filter { seen.insert($0).inserted }
    }

    private func deriveKey(_ password: Data) -> [UInt8] {
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        _ = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBufferPointer { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.bindMemory(to: Int8.self).baseAddress,
                    password.count,
                    saltBytes.baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1003,
                    &key,
                    key.count
                )
            }
        }
        return key
    }

    private func decryptCBC(_ ciphertext: Data, key: [UInt8]) -> Data? {
        guard !ciphertext.isEmpty, ciphertext.count % kCCBlockSizeAES128 == 0 else { return nil }
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: ciphertext.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var outputCount = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            ciphertext.withUnsafeBytes { ciphertextBytes in
                iv.withUnsafeBytes { ivBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        key,
                        key.count,
                        ivBytes.baseAddress,
                        ciphertextBytes.baseAddress,
                        ciphertext.count,
                        outputBytes.baseAddress,
                        outputCapacity,
                        &outputCount
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        output.removeSubrange(outputCount..<output.count)
        return output
    }

    private func cachedKey() -> [UInt8]? {
        keyLock.lock()
        defer { keyLock.unlock() }
        return cachedAESKey
    }

    private func cacheKey(_ key: [UInt8]) {
        keyLock.lock()
        defer { keyLock.unlock() }
        cachedAESKey = key
    }

    /// 解密单个 cookie 值：v10 信封 + CBC；Chromium 130+ 明文前 32 字节为
    /// SHA256(host_key) 前缀，命中则剥离（剥不了就原样返回，兼容旧格式）。
    private func decryptCookieValue(_ row: CookieRow, key: [UInt8]) -> String? {
        guard let prefix = String(data: row.encryptedValue.prefix(3), encoding: .ascii),
              prefix == "v10" else { return nil }
        guard var plaintext = decryptCBC(row.encryptedValue.dropFirst(3), key: key) else { return nil }
        if plaintext.count > 32 {
            let hostHash = Data(SHA256.hash(data: Data(row.host.utf8)))
            if plaintext.prefix(32) == hostHash {
                plaintext = plaintext.dropFirst(32)
            }
        }
        return String(data: plaintext, encoding: .utf8)
    }

    /// 拿解密 AES 密钥：优先缓存，否则按钥匙串白名单逐个尝试（用 sessionid 试解）。
    private func resolveAESKey(rows: [CookieRow]) throws -> [UInt8] {
        guard let probe = rows.first(where: { $0.name == "sessionid" }) ?? rows.first else {
            throw DoubaoError.notSignedIn
        }
        if let cached = cachedKey(), decryptCookieValue(probe, key: cached) != nil { return cached }
        let passwords = keychainPasswords()
        guard !passwords.isEmpty else { throw DoubaoError.keychainUnavailable }
        for password in passwords {
            let key = deriveKey(password)
            if decryptCookieValue(probe, key: key) != nil {
                cacheKey(key)
                return key
            }
        }
        throw DoubaoError.unsupportedAuthFormat
    }

    /// 解密全部 cookie 行，拼出 Cookie 请求头与 uid。
    private func decryptedSession(from rows: [CookieRow]) throws -> (header: String, uid: String) {
        let key = try resolveAESKey(rows: rows)
        var pairs: [String] = []
        var uid = ""
        var hasSession = false
        for row in rows {
            guard let value = decryptCookieValue(row, key: key) else { continue }
            pairs.append("\(row.name)=\(value)")
            if row.name == "uid_tt" { uid = value }
            if row.name == "sessionid" { hasSession = true }
        }
        guard hasSession else { throw DoubaoError.notSignedIn }
        return (pairs.joined(separator: "; "), uid)
    }

    // MARK: - 导入 / 当前账号

    /// 读取当前豆包工作登录态的 cookie 密文快照，并通过 detail 接口校验登录有效。
    func importCurrentAccount() async throws -> (credential: DoubaoCredential, displayName: String) {
        let rows = try readCookieRows()
        let (_, uid) = try decryptedSession(from: rows)
        guard !uid.isEmpty else { throw DoubaoError.profileUnavailable }
        let snapshot = try JSONEncoder().encode(rows)
        let credential = DoubaoCredential(
            uid: uid,
            nickname: "",
            cookiesSnapshot: snapshot,
            lastCheckinDate: nil
        )
        // 校验 cookie 确实可用（顺带拿面板读数）；失败说明登录态已过期
        _ = try await fetchCredits(credential: credential)
        return (credential, "豆包账号-\(uid.suffix(6))")
    }

    /// 当前豆包工作客户端登录账号的 UID（解密 cookie 本地识别，不联网）。
    /// 用于面板「当前」标签；解密失败（未登录 / 格式变化）返回 nil。
    func currentActiveUID() -> String? {
        guard let rows = try? readCookieRows(),
              let session = try? decryptedSession(from: rows) else { return nil }
        return session.uid.isEmpty ? nil : session.uid
    }

    // MARK: - 切换账号（写回 cookie 库）

    /// 将指定账号的 cookie 密文快照写回客户端 Cookies 库，使下次启动豆包工作
    /// 使用该账号。快照是密文，写回不碰密钥。客户端持有库锁时可能失败，
    /// 调用方负责在切换前后终止/重启客户端。
    @discardableResult
    func switchTo(account: KimiAccount) -> Bool {
        guard let cred = account.doubaoCredential, !cred.cookiesSnapshot.isEmpty,
              let rows = try? JSONDecoder().decode([CookieRow].self, from: cred.cookiesSnapshot),
              !rows.isEmpty else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(cookiesFileURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return false }
        var ok = sqlite3_exec(db, "DELETE FROM cookies WHERE host_key LIKE '%doubao.com%'", nil, nil, nil) == SQLITE_OK
        if ok {
            var stmt: OpaquePointer?
            let sql = "INSERT INTO cookies (creation_utc, host_key, top_frame_site_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, last_access_utc, has_expires, is_persistent, priority, samesite, source_scheme, source_port, last_update_utc, source_type, has_cross_site_ancestor) VALUES (0, ?, '', ?, '', ?, ?, ?, ?, ?, 0, 1, 1, 1, 0, -1, -1, 0, 0, 0)"
            ok = sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK
            if ok {
                for row in rows {
                    sqlite3_bind_text(stmt, 1, row.host, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 2, row.name, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 3, row.path, -1, SQLITE_TRANSIENT)
                    _ = row.encryptedValue.withUnsafeBytes { bytes in
                        sqlite3_bind_blob(stmt, 4, bytes.baseAddress, Int32(row.encryptedValue.count), SQLITE_TRANSIENT)
                    }
                    sqlite3_bind_int64(stmt, 5, row.expiresUTC)
                    sqlite3_bind_int(stmt, 6, row.isSecure ? 1 : 0)
                    sqlite3_bind_int(stmt, 7, row.isHTTPOnly ? 1 : 0)
                    if sqlite3_step(stmt) != SQLITE_DONE { ok = false; break }
                    sqlite3_reset(stmt)
                }
            }
            sqlite3_finalize(stmt)
        }
        guard sqlite3_exec(db, ok ? "COMMIT" : "ROLLBACK", nil, nil, nil) == SQLITE_OK, ok else { return false }
        return true
    }

    // MARK: - 客户端进程

    func isDoubaoRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.work.pc.doubao" || $0.bundleURL?.lastPathComponent == "DoubaoWork.app"
        }
    }

    func restartDoubao(completion: (@MainActor () -> Void)? = nil) {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.work.pc.doubao" || $0.bundleURL?.lastPathComponent == "DoubaoWork.app"
        }
        for app in apps { app.terminate() }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let url = URL(fileURLWithPath: "/Applications/DoubaoWork.app")
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run { completion?() }
        }
    }

    // MARK: - API

    /// 按 uid 派生稳定设备标识（每号恒定，账号间互异；与 CreditDaddy 同款算法）
    private func deviceIDs(for uid: String) -> (webID: String, teaUUID: String) {
        let seed = Data(SHA256.hash(data: Data("doubao-dev:\(uid.isEmpty ? "anonymous" : uid)".utf8)))
        let webID = "76" + seed.prefix(8).map { String(Int($0) % 10) }.joined()
        let tea = seed.dropFirst(8).prefix(8).map { String(Int($0) % 10) }.joined()
        return (webID, tea.padding(toLength: 16, withPad: "7", startingAt: 0))
    }

    private func apiURL(path: String, uid: String) -> URL? {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        let ids = deviceIDs(for: uid)
        components?.queryItems = [
            ("version_code", "20800"), ("language", "zh"),
            ("device_platform", "web"), ("doubao_device_platform", "web"),
            ("aid", "497858"), ("real_aid", "497858"),
            ("pkg_type", "release_version"), ("pc_version", "2.36.19"),
            ("doubao_pc_version", "5.72.66"), ("samantha_web", "1"),
            ("web_platform", "desktop"), ("use-olympus-account", "1"),
            ("web_tab_id", "0"),
            ("web_id", ids.webID), ("tea_uuid", ids.teaUUID),
            ("device_id", ""), ("region", ""), ("sys_region", "")
        ].map { URLQueryItem(name: $0.0, value: $0.1) }
        return components?.url
    }

    private func postCampaign(path: String, body: [String: Any], credential: DoubaoCredential) async throws -> [String: Any] {
        guard let rows = try? JSONDecoder().decode([CookieRow].self, from: credential.cookiesSnapshot) else {
            throw DoubaoError.missingSnapshot
        }
        let session = try decryptedSession(from: rows)
        guard let url = apiURL(path: path, uid: credential.uid) else { throw DoubaoError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(session.header, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://www.doubao.com/pc/agent-explore", forHTTPHeaderField: "Referer")
        request.setValue("https://www.doubao.com", forHTTPHeaderField: "Origin")
        request.setValue(Self.clientUA, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.url?.scheme == "https", http.url?.host == baseURL.host else { throw DoubaoError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw DoubaoError.unauthorized }
            throw DoubaoError.httpStatus(http.statusCode)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DoubaoError.invalidResponse
        }
        if let code = object["code"] as? Int, code == Self.loginInvalidCode {
            throw DoubaoError.unauthorized
        }
        return object
    }

    /// 拉取签到面板读数（签到状态 + 连签天数 + 累计额度）。
    func fetchCredits(credential: DoubaoCredential) async throws -> DoubaoCredits {
        let payload = try await postCampaign(
            path: "/alice/ug/campaign/v3/detail/",
            body: ["campaign_group_code": Self.campaignGroup],
            credential: credential
        )
        guard (payload["code"] as? Int) == 0,
              let data = payload["data"] as? [String: Any] else {
            throw DoubaoError.invalidResponse
        }
        let tasks = data["tasks"] as? [[String: Any]] ?? []
        let signin = tasks.first(where: { ($0["task_kind"] as? String) == "daily_signin" })
        let checkin = signin?["daily_checkin"] as? [String: Any]
        let reward = checkin?["reward"] as? [String: Any]
        let progress = data["progress"] as? [String: Any]
        return DoubaoCredits(
            totalAmount: intValue(progress, keys: ["total_amount"]) ?? 0,
            checkedInToday: (checkin?["checked_in_today"] as? Bool) ?? false,
            continuousDays: intValue(checkin, keys: ["continuous_days"]) ?? 0,
            rewardAmount: intValue(reward, keys: ["reward_amount"]) ?? 0
        )
    }

    /// 每日签到：先查状态，未签才 claim。服务端幂等：重复领 code 0 + idempotent:true。
    func checkin(credential: DoubaoCredential) async -> DoubaoCheckinOutcome {
        do {
            let status = try await fetchCredits(credential: credential)
            if status.checkedInToday { return .alreadyClaimed }
            let payload = try await postCampaign(
                path: "/alice/ug/campaign/landing/checkin",
                body: ["campaign_group_code": Self.campaignGroup],
                credential: credential
            )
            guard (payload["code"] as? Int) == 0 else {
                return .failed(LanguageManager.tr("签到接口返回异常"))
            }
            let data = payload["data"] as? [String: Any]
            if (data?["idempotent"] as? Bool) == true { return .alreadyClaimed }
            let amount = intValue(data, keys: ["reward_amount", "amount"]) ?? status.rewardAmount
            return amount > 0 ? .claimed(amount) : .alreadyClaimed
        } catch let error as DoubaoError {
            if case .unauthorized = error { return .failed(error.localizedDescription) }
            return .failed(error.localizedDescription)
        } catch {
            return .failed(LanguageManager.tr("网络请求失败"))
        }
    }

    private func intValue(_ dictionary: [String: Any]?, keys: [String]) -> Int? {
        guard let dictionary else { return nil }
        for key in keys {
            if let value = dictionary[key] as? NSNumber,
               CFGetTypeID(value) != CFBooleanGetTypeID() { return value.intValue }
            if let text = dictionary[key] as? String, let number = Int(text) { return number }
        }
        return nil
    }
}

private enum DoubaoError: LocalizedError {
    case notSignedIn
    case keychainUnavailable
    case cookieReadFailed
    case unsupportedAuthFormat
    case profileUnavailable
    case missingSnapshot
    case unauthorized
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return LanguageManager.tr("未检测到豆包工作本地登录态")
        case .keychainUnavailable: return LanguageManager.tr("无法访问豆包工作的 macOS 安全存储项")
        case .cookieReadFailed: return LanguageManager.tr("豆包工作登录文件读取失败")
        case .unsupportedAuthFormat: return LanguageManager.tr("豆包工作登录文件格式暂不兼容")
        case .profileUnavailable: return LanguageManager.tr("无法从豆包工作登录态识别用户")
        case .missingSnapshot: return LanguageManager.tr("豆包工作账号快照缺失")
        case .unauthorized: return LanguageManager.tr("豆包工作登录凭据已失效，请在客户端重新登录后再读取")
        case .invalidResponse: return LanguageManager.tr("豆包工作接口响应格式异常")
        case .httpStatus(let code): return LanguageManager.tr("豆包工作接口返回 HTTP %@", arguments: [String(code)])
        }
    }
}

/// 豆包工作独立刷新轨道：不阻塞 Kimi / WorkBuddy / Qoder 的刷新。
@MainActor
final class DoubaoAccountManager: ObservableObject {
    static let shared = DoubaoAccountManager()

    @Published private(set) var credits: [UUID: DoubaoCredits] = [:]
    @Published private(set) var loadingIDs: Set<UUID> = []
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var checkinErrors: [UUID: String] = [:]

    private var isRefreshing = false
    private var checkinTask: Task<Void, Never>?

    private init() {}

    func refresh() {
        guard !isRefreshing else { return }
        let doubaoAccounts = KimiAccountStore.shared.freshAccounts().filter { $0.provider == .doubaoWork }
        let ids = Set(doubaoAccounts.map(\.id))
        credits = credits.filter { ids.contains($0.key) }
        errors = errors.filter { ids.contains($0.key) }
        checkinErrors = checkinErrors.filter { ids.contains($0.key) }
        guard !doubaoAccounts.isEmpty else { return }
        isRefreshing = true

        Task { @MainActor in
            defer {
                isRefreshing = false
                startCheckinChain()
            }
            var succeededIDs = Set<UUID>()
            for (index, account) in doubaoAccounts.enumerated() {
                loadingIDs.insert(account.id)
                do {
                    guard let credential = KimiAccountStore.shared.freshAccount(id: account.id)?.doubaoCredential else {
                        throw DoubaoManagerError.missingCredential
                    }
                    let value = try await DoubaoService.shared.fetchCredits(credential: credential)
                    credits[account.id] = value
                    succeededIDs.insert(account.id)
                    errors.removeValue(forKey: account.id)
                    // detail 面板是最新签到状态，直接同步签到日期（防重复 claim）
                    if value.checkedInToday {
                        KimiAccountStore.shared.updateDoubaoCheckinDate(id: account.id, date: Self.todayString())
                    }
                } catch {
                    errors[account.id] = error.localizedDescription
                }
                loadingIDs.remove(account.id)
                if index < doubaoAccounts.count - 1 {
                    let delay = Double.random(in: 3...10)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
            KimiCodeBarModel.shared.applyCreditsAutoSort(for: .doubaoWork, succeeded: succeededIDs)
        }
    }

    private func startCheckinChain() {
        guard checkinTask == nil else { return }
        checkinTask = Task { @MainActor in
            defer { checkinTask = nil }
            var attemptedThisPass = Set<UUID>()
            while !Task.isCancelled {
                let today = Self.todayString()
                let pending = KimiAccountStore.shared.freshAccounts().filter {
                    $0.provider == .doubaoWork && $0.doubaoCredential?.lastCheckinDate != today
                        && !attemptedThisPass.contains($0.id)
                }
                guard let account = pending.first, let credential = account.doubaoCredential else { return }
                attemptedThisPass.insert(account.id)
                switch await DoubaoService.shared.checkin(credential: credential) {
                case .claimed, .alreadyClaimed:
                    KimiAccountStore.shared.updateDoubaoCheckinDate(id: account.id, date: today)
                    checkinErrors.removeValue(forKey: account.id)
                case .noCampaign:
                    checkinErrors.removeValue(forKey: account.id)
                case .failed(let message):
                    checkinErrors[account.id] = message
                }
                let remaining = KimiAccountStore.shared.freshAccounts().filter {
                    $0.provider == .doubaoWork && $0.doubaoCredential?.lastCheckinDate != today
                        && !attemptedThisPass.contains($0.id)
                }
                guard !remaining.isEmpty else { return }
                let delay = Double.random(in: 3...10) * 60
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private static func todayString() -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        let components = calendar.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

private enum DoubaoManagerError: LocalizedError {
    case missingCredential
    var errorDescription: String? { LanguageManager.tr("豆包工作账号快照缺失") }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
