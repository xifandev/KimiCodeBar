import Foundation
import Combine
import Security
import CommonCrypto
import CoreFoundation

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

    func fetchCredits(credential: QoderCredential) async throws -> QoderCredits {
        let token = try accessToken(from: credential.authSnapshot)
        let payload = try await requestJSON(path: "/api/v2/quota/usage", token: token)
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
            let token = try accessToken(from: credential.authSnapshot)
            let campaignsPayload = try await requestJSON(
                path: "/sash/api/v1/me/campaigns?clientType=10",
                token: token
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
                    path: "/sash/api/v1/me/campaigns/\(escapedID)/claim",
                    token: token,
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

    // MARK: - 登录态解密

    private func accessToken(from snapshot: Data) throws -> String {
        let plaintext = try decryptSafeStorage(snapshot)
        guard let object = try? JSONSerialization.jsonObject(with: plaintext) else {
            throw QoderError.unsupportedAuthFormat
        }
        let tokenKeys = ["accessToken", "access_token", "jobToken", "job_token", "token"]
        guard let token = findString(in: object, matching: tokenKeys), !token.isEmpty else {
            throw QoderError.missingToken
        }
        return token
    }

    private func decryptSafeStorage(_ encrypted: Data) throws -> Data {
        guard encrypted.count > 3, String(data: encrypted.prefix(3), encoding: .ascii) == "v10" else {
            throw QoderError.unsupportedAuthFormat
        }
        let key = try safeStorageAESKey()

        let ciphertext = Data(encrypted.dropFirst(3))
        guard !ciphertext.isEmpty, ciphertext.count % kCCBlockSizeAES128 == 0 else {
            throw QoderError.unsupportedAuthFormat
        }
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
        guard status == kCCSuccess else { throw QoderError.unsupportedAuthFormat }
        output.removeSubrange(outputCount..<output.count)
        return output
    }

    private func safeStorageAESKey() throws -> [UInt8] {
        keyLock.lock()
        defer { keyLock.unlock() }
        if let cachedAESKey { return cachedAESKey }
        guard let password = keychainPassword() else { throw QoderError.keychainUnavailable }
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let derivationStatus = password.withUnsafeBytes { passwordBytes in
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
        guard derivationStatus == kCCSuccess else { throw QoderError.unsupportedAuthFormat }
        cachedAESKey = key
        return key
    }

    /// 只查询 Qoder CN Electron safeStorage 的精确 Keychain 项，不枚举其他应用凭据。
    private func keychainPassword() -> Data? {
        let candidates: [(service: String, account: String?)] = [
            (service: " Safe Storage", account: nil),
            (service: " Safe Storage", account: "Qoder CN"),
            (service: "Safe Storage", account: "Qoder CN"),
            (service: "Qoder CN Safe Storage", account: "Qoder CN"),
            (service: "Chromium Safe Storage", account: "Qoder CN")
        ]
        for candidate in candidates {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: candidate.service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            if let account = candidate.account { query[kSecAttrAccount as String] = account }
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data, !data.isEmpty { return data }
        }
        return nil
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

    private func requestJSON(path: String, token: String, method: String = "GET") async throws -> [String: Any] {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { throw QoderError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("10", forHTTPHeaderField: "Cosy-ClientType")
        request.setValue("0.5.6", forHTTPHeaderField: "Cosy-Version")
        request.setValue("macos", forHTTPHeaderField: "Cosy-MachineOS")
        request.setValue("Qoder", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method == "POST" { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

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
