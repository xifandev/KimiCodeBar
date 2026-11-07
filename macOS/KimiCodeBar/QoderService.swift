import Foundation
import Combine
import Security
import CommonCrypto
import CoreFoundation
import CryptoKit

// MARK: - Qoder CN 积分

struct QoderCredits: Equatable, Sendable {
    let remaining: Double
    let total: Double?

    var remainingText: String { "\(Int(floor(remaining)))" }
}

struct QoderAccountProfile: Equatable {
    let uid: String
    let displayName: String
}

enum QoderCheckinOutcome: Equatable {
    case claimed(Int)
    case alreadyClaimed
    case noCampaign
    case failed(String)
}

private final class QoderNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
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

/// Qoder CN 本机登录态读取与积分/活动 API。
/// auth.v1.dat 使用 Electron safeStorage 加密；账号库仅保存原始加密快照，
/// 解密后的 token 只在本进程内存中短暂存在，绝不写日志或返回 UI。
final class QoderService {
    static let shared = QoderService()

    private let dataDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.qodercn.app.stable", isDirectory: true)
    private let baseURL = URL(string: "https://openapi.qoder.com.cn")!
    private let session: URLSession
    private let keyLock = NSLock()
    private var cachedAESKey: [UInt8]?
    private var jobTokenCache: JobTokenCache?

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: QoderNoRedirectDelegate(), delegateQueue: nil)
    }

    static let consoleURL = URL(string: "https://qoder.cn/")!

    var authFileURL: URL { dataDirectory.appendingPathComponent("auth.v1.dat") }
    var profileOverlayURL: URL { dataDirectory.appendingPathComponent("auth-profile-overlays.v1.dat") }

    /// 读取当前 Qoder CN 登录态的密文快照，并通过账号资料 API 校验/识别 UID。
    func importCurrentAccount() async throws -> (credential: QoderCredential, profile: QoderAccountProfile) {
        guard FileManager.default.fileExists(atPath: authFileURL.path) else {
            throw QoderError.notSignedIn
        }
        let authSnapshot = try readStableFile(authFileURL)
        let overlaySnapshot = FileManager.default.fileExists(atPath: profileOverlayURL.path)
            ? try readStableFile(profileOverlayURL)
            : nil
        let token = try accessToken(from: authSnapshot)
        let profile = try await fetchProfile(token: token)
        let credential = QoderCredential(
            uid: profile.uid,
            authSnapshot: authSnapshot,
            profileOverlaySnapshot: overlaySnapshot,
            personalToken: nil,
            lastCheckinDate: nil
        )
        return (credential, profile)
    }

    /// 用个人访问令牌（PAT）导入账号：先换 jobToken 校验令牌有效性并识别 UID。
    /// PAT 账号不依赖本机客户端登录态与解密链路。
    func importAccount(personalToken pat: String) async throws -> (credential: QoderCredential, profile: QoderAccountProfile) {
        let token = try await jobToken(pat: pat, forceRefresh: true)
        let profile = try await fetchProfile(token: token)
        let credential = QoderCredential(
            uid: profile.uid,
            authSnapshot: Data(),
            profileOverlaySnapshot: nil,
            personalToken: pat,
            lastCheckinDate: nil
        )
        return (credential, profile)
    }

    func fetchCredits(credential: QoderCredential) async throws -> QoderCredits {
        let payload = try await requestJSON(credential: credential, path: "/api/v2/quota/usage")
        guard let values = allNumericFields(in: payload) else {
            throw QoderError.unrecognizedQuota
        }
        let remainingKeys = [
            "remaining", "available", "remain", "remainingcredits", "availablecredits",
            "remainingvalue", "availablevalue", "remainvalue", "remainingamount",
            "availableamount", "remainingquota", "availablequota", "remainingpoints"
        ]
        let totalKeys = ["total", "totalcredits", "quota", "totalquota", "limitvalue", "totalvalue", "totalamount"]
        let remaining = values.first(where: { remainingKeys.contains($0.key.normalized) })?.value
        let total = values.first(where: { totalKeys.contains($0.key.normalized) })?.value
        guard let remaining else { throw QoderError.unrecognizedQuota }
        return QoderCredits(remaining: remaining, total: total)
    }

    /// 查询活动状态后仅领取明确可领的积分福利；不重复领取已完成活动。
    func checkin(credential: QoderCredential) async -> QoderCheckinOutcome {
        do {
            let campaignsPayload = try await requestJSON(
                credential: credential,
                path: "/sash/api/v1/me/campaigns?clientType=10"
            )
            guard let campaigns = campaignsPayload["campaigns"] as? [[String: Any]] else {
                return .noCampaign
            }
            let benefits = campaigns.filter { ($0["actionType"] as? String) == "CLAIM_BENEFIT" }
            guard !benefits.isEmpty else { return .noCampaign }
            let claimable = benefits.filter { ($0["claimStatus"] as? String) == "CLAIMABLE" }
            guard !claimable.isEmpty else { return .alreadyClaimed }

            var claimed = 0
            for campaign in claimable {
                guard let campaignID = campaign["campaignId"] as? String,
                      !campaignID.isEmpty else { continue }
                let pathComponentSet = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
                let escapedID = campaignID.addingPercentEncoding(withAllowedCharacters: pathComponentSet) ?? campaignID
                let result = try await requestJSON(
                    credential: credential,
                    path: "/sash/api/v1/me/campaigns/\(escapedID)/claim",
                    method: "POST"
                )
                let resultAmount = numericValue(result["benefit"] as? [String: Any], keys: ["amount"])
                    ?? numericValue(campaign["benefit"] as? [String: Any], keys: ["amount"])
                    ?? 0
                claimed += Int(resultAmount)
            }
            return claimed > 0 ? .claimed(claimed) : .alreadyClaimed
        } catch let error as QoderError {
            return .failed(error.localizedDescription)
        } catch {
            return .failed(LanguageManager.tr("网络请求失败"))
        }
    }

    // MARK: - PAT 换 jobToken

    private struct JobTokenCache {
        let pat: String
        let token: String
        let expiresAt: Date
    }

    /// PAT 账号取 token：换 jobToken（内存缓存，临期 5 分钟重换）；快照账号解本地密文。
    private func accessToken(for credential: QoderCredential) async throws -> String {
        if let pat = credential.personalToken, !pat.isEmpty {
            return try await jobToken(pat: pat)
        }
        return try accessToken(from: credential.authSnapshot)
    }

    /// 带凭证身份的请求；PAT 账号遇 401/403 自动重换 jobToken 重试一次。
    private func requestJSON(credential: QoderCredential, path: String, method: String = "GET") async throws -> [String: Any] {
        do {
            let token = try await accessToken(for: credential)
            return try await requestJSON(path: path, token: token, method: method)
        } catch QoderError.unauthorized {
            guard let pat = credential.personalToken, !pat.isEmpty else { throw QoderError.unauthorized }
            invalidateJobToken(pat: pat)
            let token = try await jobToken(pat: pat)
            return try await requestJSON(path: path, token: token, method: method)
        }
    }

    /// 官方交换端点：PAT 换短期 jobToken（cosy-clienttype: 5），后续接口仍用 clientType 10。
    private func jobToken(pat: String, forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh {
            keyLock.lock()
            let cached = jobTokenCache
            keyLock.unlock()
            if let cached, cached.pat == pat, cached.expiresAt.timeIntervalSinceNow > 5 * 60 {
                return cached.token
            }
        }
        let payload = try await requestJSON(
            path: "/api/v1/jobToken/exchange",
            token: nil,
            method: "POST",
            body: ["personal_token": pat],
            clientType: "5"
        )
        guard let token = stringValue(payload, keys: Self.tokenKeys), !token.isEmpty else {
            throw QoderError.patInvalid
        }
        let expiresAt: Date
        if let timestamp = numericValue(payload, keys: ["expires_at", "expiresAt", "expireTime"]) {
            expiresAt = timestamp > 1e11
                ? Date(timeIntervalSince1970: timestamp / 1000)
                : Date(timeIntervalSince1970: timestamp)
        } else if let ttl = numericValue(payload, keys: ["expires_in", "expiresIn"]) {
            expiresAt = Date().addingTimeInterval(ttl)
        } else {
            expiresAt = Date().addingTimeInterval(3600)
        }
        keyLock.lock()
        jobTokenCache = JobTokenCache(pat: pat, token: token, expiresAt: expiresAt)
        keyLock.unlock()
        return token
    }

    private func invalidateJobToken(pat: String) {
        keyLock.lock()
        if jobTokenCache?.pat == pat { jobTokenCache = nil }
        keyLock.unlock()
    }

    // MARK: - 登录态解密

    private static let tokenKeys = ["accessToken", "access_token", "jobToken", "job_token", "token"]

    /// 信封版本：v10 为 0.2.x 时期的 PBKDF2 + AES-128-CBC；0.5.x 起客户端改用
    /// AES-256-GCM 且密钥以原始字节存钥匙串（v11 明确声明密钥在系统钥匙环）。
    /// 协议未公开且随客户端版本漂移，因此按「候选密钥 × 密钥派生 × 加密布局」
    /// 逐一尝试，第一个能解出含 token 的合法 JSON 的组合生效。
    private func accessToken(from snapshot: Data) throws -> String {
        guard let prefix = String(data: snapshot.prefix(3), encoding: .ascii),
              prefix == "v10" || prefix == "v11" else {
            throw QoderError.unsupportedAuthFormat
        }
        if let cached = cachedKey(), let token = tokenFromSnapshot(snapshot, key: cached) { return token }
        let passwords = keychainPasswords()
        guard !passwords.isEmpty else { throw QoderError.keychainUnavailable }

        var decryptedOnce = false
        for password in passwords {
            for key in candidateKeys(for: password) {
                guard let plaintext = decryptEnvelope(snapshot, key: key) else { continue }
                decryptedOnce = true
                guard let token = tokenFromPlaintext(plaintext) else { continue }
                cacheKey(key)
                return token
            }
        }
        throw decryptedOnce ? QoderError.missingToken : QoderError.unsupportedAuthFormat
    }

    private func tokenFromSnapshot(_ snapshot: Data, key: [UInt8]) -> String? {
        guard let plaintext = decryptEnvelope(snapshot, key: key) else { return nil }
        return tokenFromPlaintext(plaintext)
    }

    private func tokenFromPlaintext(_ plaintext: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: plaintext) else { return nil }
        guard let token = findString(in: object, matching: Self.tokenKeys), !token.isEmpty else { return nil }
        return token
    }

    private func candidateKeys(for password: Data) -> [[UInt8]] {
        var keys = [derivePBKDF2Key(password)]
        let raw = [UInt8](password)
        if raw.count == kCCKeySizeAES128 || raw.count == kCCKeySizeAES256 { keys.append(raw) }
        return keys
    }

    private func decryptEnvelope(_ snapshot: Data, key: [UInt8]) -> Data? {
        let body = Data(snapshot.dropFirst(3))
        switch key.count {
        case kCCKeySizeAES128: return decryptCBC(body, key: key)
        case kCCKeySizeAES256: return decryptGCM(body, key: key)
        default: return nil
        }
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

    private func decryptGCM(_ blob: Data, key: [UInt8]) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: blob),
              let plaintext = try? AES.GCM.open(box, using: SymmetricKey(data: Data(key))) else { return nil }
        return plaintext
    }

    private func derivePBKDF2Key(_ password: Data) -> [UInt8] {
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

    /// 钥匙串服务名白名单：只查询 Qoder 系客户端的 Safe Storage 项，不枚举其他应用凭据。
    /// 不约束 account：账户命名（如「Qoder CN Key」）随客户端版本漂移，服务名命中即可。
    private static let keychainServices = [
        "Qoder CN Safe Storage",
        "Qoder App Safe Storage",
        "Qoder Safe Storage",
        " Safe Storage",
        "Safe Storage",
        "Chromium Safe Storage"
    ]

    private func keychainPasswords() -> [Data] {
        var passwords: [Data] = []
        for service in Self.keychainServices {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll
            ]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { continue }
            if let one = result as? Data {
                passwords.append(one)
            } else if let many = result as? [Data] {
                passwords.append(contentsOf: many)
            }
        }
        var seen = Set<Data>()
        return passwords.filter { seen.insert($0).inserted }
    }

    private func readStableFile(_ url: URL) throws -> Data {
        let attributesBefore = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributesBefore[.type] as? FileAttributeType) == .typeRegular,
              let size = attributesBefore[.size] as? NSNumber,
              size.intValue > 0, size.intValue <= 1_000_000 else {
            throw QoderError.invalidAuthFile
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let attributesAfter = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributesBefore[.modificationDate] as? Date == attributesAfter[.modificationDate] as? Date,
              data.count == size.intValue else { throw QoderError.authChangedDuringRead }
        return data
    }

    // MARK: - API

    private func fetchProfile(token: String) async throws -> QoderAccountProfile {
        let payload = try await requestJSON(path: "/api/v1/userinfo", token: token)
        let uid = stringValue(payload, keys: ["uid", "userId", "user_id", "id"])
            ?? stringValue(payload["user"] as? [String: Any], keys: ["uid", "userId", "user_id", "id"])
        guard let uid, !uid.isEmpty else { throw QoderError.profileUnavailable }
        let name = stringValue(payload, keys: ["nickname", "name", "email", "username"])
            ?? stringValue(payload["user"] as? [String: Any], keys: ["nickname", "name", "email", "username"])
            ?? "Qoder CN \(uid.suffix(6))"
        return QoderAccountProfile(uid: uid, displayName: name)
    }

    private func requestJSON(
        path: String,
        token: String?,
        method: String = "GET",
        body: [String: Any]? = nil,
        clientType: String = "10"
    ) async throws -> [String: Any] {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { throw QoderError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue(clientType, forHTTPHeaderField: "Cosy-ClientType")
        request.setValue("0.5.6", forHTTPHeaderField: "Cosy-Version")
        request.setValue("macos", forHTTPHeaderField: "Cosy-MachineOS")
        request.setValue("Qoder", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.url?.scheme == "https", http.url?.host == baseURL.host else { throw QoderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw QoderError.unauthorized }
            throw QoderError.httpStatus(http.statusCode)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QoderError.invalidResponse
        }
        return object
    }

    // MARK: - JSON helpers

    private func findString(in value: Any, matching keys: [String]) -> String? {
        if let object = value as? [String: Any] {
            for key in keys {
                if let string = object[key] as? String, !string.isEmpty { return string }
            }
            for child in object.values {
                if let found = findString(in: child, matching: keys) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = findString(in: child, matching: keys) { return found }
            }
        }
        return nil
    }

    private func stringValue(_ object: [String: Any]?, keys: [String]) -> String? {
        guard let object else { return nil }
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private func allNumericFields(in value: Any) -> [(key: String, value: Double)]? {
        var fields: [(String, Double)] = []
        func walk(_ node: Any) {
            if let dictionary = node as? [String: Any] {
                for (key, child) in dictionary {
                    if let number = child as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                        fields.append((key, number.doubleValue))
                    } else if let text = child as? String, let number = Double(text) {
                        fields.append((key, number))
                    } else {
                        walk(child)
                    }
                }
            } else if let array = node as? [Any] {
                array.forEach(walk)
            }
        }
        walk(value)
        return fields.isEmpty ? nil : fields
    }

    private func numericValue(_ dictionary: [String: Any]?, keys: [String]) -> Double? {
        guard let dictionary else { return nil }
        for key in keys {
            if let value = dictionary[key] as? NSNumber { return value.doubleValue }
            if let value = dictionary[key] as? String, let number = Double(value) { return number }
        }
        return nil
    }
}

private extension String {
    var normalized: String { lowercased().filter(\.isLetter).lowercased() }
}

private enum QoderError: LocalizedError {
    case notSignedIn
    case keychainUnavailable
    case invalidAuthFile
    case authChangedDuringRead
    case unsupportedAuthFormat
    case missingToken
    case unauthorized
    case patInvalid
    case profileUnavailable
    case unrecognizedQuota
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return LanguageManager.tr("未检测到 Qoder CN 本地登录态")
        case .keychainUnavailable: return LanguageManager.tr("无法访问 Qoder CN 的 macOS 安全存储项")
        case .invalidAuthFile: return LanguageManager.tr("Qoder CN 登录文件无效或过大")
        case .authChangedDuringRead: return LanguageManager.tr("Qoder CN 登录文件正在变化，请稍后重试")
        case .unsupportedAuthFormat: return LanguageManager.tr("Qoder CN 登录文件格式暂不兼容")
        case .missingToken: return LanguageManager.tr("Qoder CN 登录态中未找到访问凭据")
        case .unauthorized: return LanguageManager.tr("Qoder CN 登录凭据已失效，请在客户端重新登录后再读取")
        case .patInvalid: return LanguageManager.tr("PAT 无效或已过期，请在 qoder.cn 重新创建后再添加")
        case .profileUnavailable: return LanguageManager.tr("无法从 Qoder CN 账号资料接口识别用户")
        case .unrecognizedQuota: return LanguageManager.tr("Qoder CN 用量接口返回了未识别的积分结构")
        case .invalidResponse: return LanguageManager.tr("Qoder CN 接口响应格式异常")
        case .httpStatus(let code): return LanguageManager.tr("Qoder CN 接口返回 HTTP %@", arguments: [String(code)])
        }
    }
}


/// Qoder CN 独立刷新轨道：不阻塞 Kimi / WorkBuddy / Antigravity 的刷新。
@MainActor
final class QoderAccountManager: ObservableObject {
    static let shared = QoderAccountManager()

    @Published private(set) var credits: [UUID: QoderCredits] = [:]
    @Published private(set) var loadingIDs: Set<UUID> = []
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var checkinErrors: [UUID: String] = [:]

    private var isRefreshing = false
    private var checkinTask: Task<Void, Never>?

    private init() {}

    func refresh() {
        guard !isRefreshing else { return }
        let qoderAccounts = KimiAccountStore.shared.freshAccounts().filter { $0.provider == .qoderCN }
        let ids = Set(qoderAccounts.map(\.id))
        credits = credits.filter { ids.contains($0.key) }
        errors = errors.filter { ids.contains($0.key) }
        checkinErrors = checkinErrors.filter { ids.contains($0.key) }
        guard !qoderAccounts.isEmpty else { return }
        isRefreshing = true

        Task { @MainActor in
            defer {
                isRefreshing = false
                startCheckinChain()
            }
            for (index, account) in qoderAccounts.enumerated() {
                loadingIDs.insert(account.id)
                do {
                    guard let credential = KimiAccountStore.shared.freshAccount(id: account.id)?.qoderCredential else {
                        throw QoderManagerError.missingCredential
                    }
                    let value = try await QoderService.shared.fetchCredits(credential: credential)
                    credits[account.id] = value
                    errors.removeValue(forKey: account.id)
                } catch {
                    errors[account.id] = error.localizedDescription
                }
                loadingIDs.remove(account.id)
                if index < qoderAccounts.count - 1 {
                    let delay = Double.random(in: 3...10)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
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
                    $0.provider == .qoderCN && $0.qoderCredential?.lastCheckinDate != today
                        && !attemptedThisPass.contains($0.id)
                }
                guard let account = pending.first, let credential = account.qoderCredential else { return }
                attemptedThisPass.insert(account.id)
                switch await QoderService.shared.checkin(credential: credential) {
                case .claimed, .alreadyClaimed:
                    KimiAccountStore.shared.updateQoderCheckinDate(id: account.id, date: today)
                    checkinErrors.removeValue(forKey: account.id)
                case .noCampaign:
                    checkinErrors.removeValue(forKey: account.id)
                case .failed(let message):
                    checkinErrors[account.id] = message
                }
                let remaining = KimiAccountStore.shared.freshAccounts().filter {
                    $0.provider == .qoderCN && $0.qoderCredential?.lastCheckinDate != today
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

private enum QoderManagerError: LocalizedError {
    case missingCredential
    var errorDescription: String? { LanguageManager.tr("Qoder CN 账号快照缺失") }
}
