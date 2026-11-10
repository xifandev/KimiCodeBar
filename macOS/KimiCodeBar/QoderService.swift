import Foundation
import AppKit
import Combine
import Security
import CommonCrypto
import CoreFoundation
import CryptoKit
import LocalAuthentication

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
            lastCheckinDate: nil
        )
        return (credential, profile)
    }

    // MARK: - 切换账号（写 auth 文件）

    /// 当前 Qoder CN 客户端登录账号的 UID（解密 auth.v1.dat 本地识别，不联网）。
    /// 用于面板「当前」标签；解密失败（未登录 / 格式变化）返回 nil。
    func currentActiveUID() -> String? {
        guard FileManager.default.fileExists(atPath: authFileURL.path),
              let snapshot = try? readStableFile(authFileURL) else { return nil }
        return uid(from: snapshot)
    }

    /// 将指定账号的加密快照原样写回 auth 文件 + profile overlay，使下次启动 Qoder CN
    /// 使用该账号。快照是 safeStorage 密文，写回不碰密钥、不重加密。
    /// 账号无 auth 快照时返回 false。
    @discardableResult
    func switchTo(account: KimiAccount) -> Bool {
        guard let cred = account.qoderCredential, !cred.authSnapshot.isEmpty else { return false }
        backupAuthFiles()
        do {
            try cred.authSnapshot.write(to: authFileURL, options: .atomic)
            if let overlay = cred.profileOverlaySnapshot, !overlay.isEmpty {
                try overlay.write(to: profileOverlayURL, options: .atomic)
            } else {
                // 目标账号无 profile overlay 快照：移除当前 overlay，避免残留上一账号的资料
                try? FileManager.default.removeItem(at: profileOverlayURL)
            }
            return true
        } catch {
            return false
        }
    }

    func isQoderRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.qodercn.app" || $0.bundleURL?.lastPathComponent == "Qoder CN.app"
        }
    }

    func restartQoder(completion: (@MainActor () -> Void)? = nil) {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.qodercn.app" || $0.bundleURL?.lastPathComponent == "Qoder CN.app"
        }
        for app in apps { app.terminate() }
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let url = URL(fileURLWithPath: "/Applications/Qoder CN.app")
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run { completion?() }
        }
    }

    private func backupAuthFiles() {
        let backupDir = dataDirectory.appendingPathComponent("auth-backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        try? FileManager.default.copyItem(
            at: authFileURL,
            to: backupDir.appendingPathComponent("auth.v1.\(ts).dat")
        )
        if FileManager.default.fileExists(atPath: profileOverlayURL.path) {
            try? FileManager.default.copyItem(
                at: profileOverlayURL,
                to: backupDir.appendingPathComponent("auth-profile-overlays.v1.\(ts).dat")
            )
        }
    }

    func fetchCredits(credential: QoderCredential) async throws -> QoderCredits {
        let payload = try await requestJSON(credential: credential, path: "/api/v2/quota/usage")
        if let bucketed = bucketedCredits(in: payload) { return bucketed }
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

    /// 官方 /usage 视图的合计口径：套餐内额度（userQuota）、个人资源包
    /// （addOnQuota，签到奖励入此桶）、组织资源包（orgResourcePackage）三桶求和。
    /// 只取第一个 remaining 会漏掉资源包，菜单栏显示比实际可用少。
    private func bucketedCredits(in payload: [String: Any]) -> QoderCredits? {
        var remaining = 0.0
        var total = 0.0
        var seenBucket = false
        for key in ["userQuota", "addOnQuota", "orgResourcePackage"] {
            guard let block = payload[key] as? [String: Any] else { continue }
            if let available = block["available"] as? NSNumber,
               CFGetTypeID(available) == CFBooleanGetTypeID(),
               !available.boolValue { continue }
            guard let blockRemaining = numericValue(block, keys: ["remaining"]) else { continue }
            seenBucket = true
            remaining += blockRemaining
            let used = numericValue(block, keys: ["used"]) ?? 0
            total += numericValue(block, keys: ["total", "cap"]) ?? blockRemaining + used
        }
        guard seenBucket else { return nil }
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

    /// 带凭证身份的请求：解本地密文取 token 后调用底层 requestJSON。
    private func requestJSON(credential: QoderCredential, path: String, method: String = "GET") async throws -> [String: Any] {
        let token = try accessToken(from: credential.authSnapshot)
        return try await requestJSON(path: path, token: token, method: method)
    }

    // MARK: - 登录态解密

    private static let tokenKeys = ["accessToken", "access_token", "jobToken", "job_token", "token"]

    /// 信封版本：Electron safeStorage 在 macOS 上统一用 "v10" + AES-128-CBC，
    /// 密钥 = PBKDF2-HMAC-SHA1(钥匙串密码串, "saltysalt", 1003 轮, 16 字节)，
    /// IV 为 16 个空格（0x20）。2026-11 实测当前 Qoder CN 客户端仍走 v10 布局，
    /// 只是钥匙串服务名从「Qoder CN Safe Storage」换成了「Qoder CN App Safe Storage」。
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

    /// 从 auth 快照密文解密并提取 UID（本地，不联网），用于「当前账号」判断。
    /// 与 accessToken(from:) 同一套解密链，只是最后提取 UID 而非 token。
    private func uid(from snapshot: Data) -> String? {
        guard let prefix = String(data: snapshot.prefix(3), encoding: .ascii),
              prefix == "v10" || prefix == "v11" else { return nil }
        if let cached = cachedKey(), let uid = uidFromSnapshot(snapshot, key: cached) { return uid }
        let passwords = keychainPasswords()
        guard !passwords.isEmpty else { return nil }
        for password in passwords {
            for key in candidateKeys(for: password) {
                guard let plaintext = decryptEnvelope(snapshot, key: key) else { continue }
                guard let uid = uidFromPlaintext(plaintext), !uid.isEmpty else { continue }
                cacheKey(key)
                return uid
            }
        }
        return nil
    }

    private func uidFromSnapshot(_ snapshot: Data, key: [UInt8]) -> String? {
        guard let plaintext = decryptEnvelope(snapshot, key: key) else { return nil }
        return uidFromPlaintext(plaintext)
    }

    private func uidFromPlaintext(_ plaintext: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: plaintext) else { return nil }
        guard let uid = findString(in: object, matching: ["uid", "userId", "user_id"]), !uid.isEmpty else { return nil }
        return uid
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
        "Qoder CN App Safe Storage",
        "Qoder CN Safe Storage",
        "Qoder App Safe Storage",
        "Qoder Safe Storage",
        " Safe Storage",
        "Safe Storage",
        "Chromium Safe Storage"
    ]

    private func keychainPasswords() -> [Data] {
        var passwords: [Data] = []
        // 钥匙串锁定时，SecItemCopyMatching 默认直接返回错误而不弹解锁框；
        // 传入 LAContext 让系统在需要时唤起「输入 Mac 密码解锁钥匙串」的授权 UI，
        // 否则用户点「读取本机」会静默失败，体验上像是没反应。
        let authContext = LAContext()
        authContext.localizedReason = LanguageManager.tr("读取 Qoder CN 登录凭据需要访问钥匙串")
        for service in Self.keychainServices {
            // 注意：不能用 kSecMatchLimitAll —— 在本机实测会让 SecItemCopyMatching
            // 返回 -50 errSecParam（且不弹授权），导致全部 service 都拿不到密码。
            // Qoder 每个 service 只有一个 item，默认单结果即可。
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
            var succeededIDs = Set<UUID>()
            for (index, account) in qoderAccounts.enumerated() {
                loadingIDs.insert(account.id)
                do {
                    guard let credential = KimiAccountStore.shared.freshAccount(id: account.id)?.qoderCredential else {
                        throw QoderManagerError.missingCredential
                    }
                    let value = try await QoderService.shared.fetchCredits(credential: credential)
                    credits[account.id] = value
                    succeededIDs.insert(account.id)
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
            KimiCodeBarModel.shared.applyCreditsAutoSort(for: .qoderCN, succeeded: succeededIDs)
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
