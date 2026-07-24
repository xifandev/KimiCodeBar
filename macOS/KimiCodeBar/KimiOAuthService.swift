import Foundation
import AppKit

// MARK: - OAuth 常量

/// 与 Kimi Code CLI 保持一致的 Device Code Flow（RFC 8628）参数。
/// 参考：https://github.com/MoonshotAI/kimi-code 的 packages/oauth 包。
enum KimiOAuthConstants {
    static let host = "https://auth.kimi.com"
    static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    static let deviceGrantType = "urn:ietf:params:oauth:grant-type:device_code"

    static let deviceAuthorizationURL = "\(host)/api/oauth/device_authorization"
    static let tokenURL = "\(host)/api/oauth/token"

    /// 轮询总预算 15 分钟，与 CLI 一致
    static let pollTimeout: TimeInterval = 15 * 60
    /// 默认轮询间隔
    static let defaultPollInterval: TimeInterval = 5
}

// MARK: - OAuth Token

/// 与 Kimi Code CLI 磁盘格式兼容的 token 模型（snake_case）。
/// 存储位置：~/Library/Application Support/KimiCodeBar/credentials.json（Bar 专属，与 CLI 隔离）。
struct KimiOAuthToken: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Int
    var scope: String?
    var tokenType: String?
    var expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case scope
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }

    var isValid: Bool {
        !accessToken.isEmpty && !refreshToken.isEmpty && expiresAt > 0
    }

    /// 剩余有效期低于 5 分钟即视为需要刷新
    var needsRefresh: Bool {
        Date().timeIntervalSince1970 >= TimeInterval(expiresAt) - 300
    }

    var expiresAtDate: Date {
        Date(timeIntervalSince1970: TimeInterval(expiresAt))
    }
}

// MARK: - 设备授权响应

struct KimiDeviceAuthorization: Decodable {
    let userCode: String
    let deviceCode: String
    let verificationURI: String?
    let verificationURIComplete: String?
    let expiresIn: Int?
    let interval: Int?

    enum CodingKeys: String, CodingKey {
        case userCode = "user_code"
        case deviceCode = "device_code"
        case verificationURI = "verification_uri"
        case verificationURIComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }

    var displayURL: String? {
        verificationURIComplete ?? verificationURI
    }
}

// MARK: - OAuth 错误

enum KimiOAuthError: Error, Equatable {
    case invalidURL
    case networkError(String)
    case httpError(statusCode: Int, message: String)
    case invalidResponse
    case authorizationPending
    case slowDown
    case expiredToken
    case accessDenied
    case unauthorized
    case cancelled
    case timeout
}

// MARK: - OAuth 服务

final class KimiOAuthService {

    // MARK: 设备身份头

    /// 与 CLI 一致的 X-Msh-* 设备头。Device ID 复用 ~/.kimi-code/device_id。
    private static func identityHeaders() -> [String: String] {
        var headers: [String: String] = [
            "X-Msh-Platform": "kimi_code_cli",
            "X-Msh-Version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
        ]

        if let deviceID = loadOrCreateDeviceID() {
            headers["X-Msh-Device-Id"] = deviceID
        }

        let hostName = Host.current().localizedName ?? "Mac"
        headers["X-Msh-Device-Name"] = hostName

        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let osVersionString = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        var modelIdentifier = "Mac"
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        if size > 0 {
            var model = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.model", &model, &size, nil, 0)
            modelIdentifier = String(cString: model)
        }
        headers["X-Msh-Device-Model"] = "macOS \(osVersionString) \(modelIdentifier)"
        headers["X-Msh-Os-Version"] = osVersionString

        return headers
    }

    private static func loadOrCreateDeviceID() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code/device_id")

        if let data = try? Data(contentsOf: url),
           let id = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !id.isEmpty {
            return id
        }

        let id = UUID().uuidString
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(id.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return id
        } catch {
            return nil
        }
    }

    // MARK: 网络请求

    private static func postForm(
        url: URL,
        parameters: [String: String],
        extraHeaders: [String: String] = [:]
    ) async -> Result<(Data, HTTPURLResponse), KimiOAuthError> {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        for (key, value) in identityHeaders().merging(extraHeaders, uniquingKeysWith: { $1 }) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let body = parameters
            .map { "\($0.key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        request.httpBody = Data(body.utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            return .success((data, http))
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.networkError(error.localizedDescription))
        }
    }

    // MARK: 设备授权请求

    func requestDeviceAuthorization() async -> Result<KimiDeviceAuthorization, KimiOAuthError> {
        guard let url = URL(string: KimiOAuthConstants.deviceAuthorizationURL) else {
            return .failure(.invalidURL)
        }

        let result = await Self.postForm(
            url: url,
            parameters: ["client_id": KimiOAuthConstants.clientID]
        )

        switch result {
        case .failure(let error):
            return .failure(error)
        case .success(let (data, http)):
            if http.statusCode != 200 {
                let message = Self.extractErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
                return .failure(.httpError(statusCode: http.statusCode, message: message))
            }

            do {
                let auth = try JSONDecoder().decode(KimiDeviceAuthorization.self, from: data)
                guard !auth.userCode.isEmpty, !auth.deviceCode.isEmpty else {
                    return .failure(.invalidResponse)
                }
                return .success(auth)
            } catch {
                return .failure(.invalidResponse)
            }
        }
    }

    // MARK: 轮询换取 Token

    /// 在浏览器授权期间持续轮询，直到用户完成授权、超时或取消。
    func pollDeviceToken(
        deviceCode: String,
        initialInterval: TimeInterval = KimiOAuthConstants.defaultPollInterval,
        timeout: TimeInterval = KimiOAuthConstants.pollTimeout
    ) async -> Result<KimiOAuthToken, KimiOAuthError> {
        guard let url = URL(string: KimiOAuthConstants.tokenURL) else {
            return .failure(.invalidURL)
        }

        let deadline = Date().addingTimeInterval(timeout)
        var interval = max(1, initialInterval)

        while Date() < deadline {
            if Task.isCancelled {
                return .failure(.cancelled)
            }

            let result = await Self.postForm(
                url: url,
                parameters: [
                    "client_id": KimiOAuthConstants.clientID,
                    "device_code": deviceCode,
                    "grant_type": KimiOAuthConstants.deviceGrantType,
                ]
            )

            switch result {
            case .failure(let error):
                return .failure(error)
            case .success(let (data, http)):
                if http.statusCode == 200 {
                    do {
                        let token = try Self.tokenFromResponse(data)
                        return .success(token)
                    } catch {
                        return .failure(.invalidResponse)
                    }
                }

                let errorCode = Self.extractErrorCode(from: data)
                switch errorCode {
                case "authorization_pending":
                    break
                case "slow_down":
                    interval += 5
                case "expired_token":
                    return .failure(.expiredToken)
                case "access_denied":
                    return .failure(.accessDenied)
                default:
                    let message = Self.extractErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
                    return .failure(.httpError(statusCode: http.statusCode, message: message))
                }
            }

            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                return .failure(.cancelled)
            }
        }

        return .failure(.timeout)
    }

    // MARK: 刷新 Token

    func refreshAccessToken(_ token: KimiOAuthToken) async -> Result<KimiOAuthToken, KimiOAuthError> {
        guard let url = URL(string: KimiOAuthConstants.tokenURL) else {
            return .failure(.invalidURL)
        }

        let result = await Self.postForm(
            url: url,
            parameters: [
                "client_id": KimiOAuthConstants.clientID,
                "grant_type": "refresh_token",
                "refresh_token": token.refreshToken,
            ]
        )

        switch result {
        case .failure(let error):
            return .failure(error)
        case .success(let (data, http)):
            if http.statusCode == 401 || http.statusCode == 403 {
                return .failure(.unauthorized)
            }
            if http.statusCode != 200 {
                let errorCode = Self.extractErrorCode(from: data)
                if errorCode == "invalid_grant" {
                    return .failure(.unauthorized)
                }
                let message = Self.extractErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
                return .failure(.httpError(statusCode: http.statusCode, message: message))
            }

            do {
                // 服务端刷新时可能不返回新 refresh_token，此时沿用旧的
                let newToken = try Self.tokenFromResponse(data, fallbackRefreshToken: token.refreshToken)
                return .success(newToken)
            } catch {
                return .failure(.invalidResponse)
            }
        }
    }

    // MARK: Token 持久化

    /// Bar 专属的 token 存储路径。
    /// 注意：刻意与 KimiCode CLI 的 ~/.kimi-code/credentials/kimi-code.json 隔离，
    /// Bar 的授权、刷新、退出登录都只操作本文件，绝不读写 CLI 的凭证，
    /// 避免因 refresh_token 服务端轮换导致 CLI 凭证失效。
    static func credentialsFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("KimiCodeBar/credentials.json")
    }

    /// 从磁盘读取 Bar 自己的 token
    static func loadStoredToken() -> KimiOAuthToken? {
        let url = credentialsFileURL()
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let token = try? JSONDecoder().decode(KimiOAuthToken.self, from: data) else { return nil }
        return token.isValid ? token : nil
    }

    /// 原子写入 token 文件：目录 0700，文件 0600
    @discardableResult
    static func saveToken(_ token: KimiOAuthToken) -> Bool {
        let url = credentialsFileURL()
        let directory = url.deletingLastPathComponent()

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(token)

            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )

            let tempURL = directory.appendingPathComponent(".\(url.lastPathComponent).tmp.\(ProcessInfo.processInfo.processIdentifier)")
            try data.write(to: tempURL, options: .atomic)

            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: url)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    static func clearToken() {
        let url = credentialsFileURL()
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: 私有解析

    /// 解析 token 响应。登录时响应必含全部字段；刷新时服务端可能省略
    /// refresh_token，由 fallbackRefreshToken 传入旧值兜底。
    private static func tokenFromResponse(_ data: Data, fallbackRefreshToken: String? = nil) throws -> KimiOAuthToken {
        struct TokenResponse: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresIn: Int
            let scope: String?
            let tokenType: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
                case scope
                case tokenType = "token_type"
            }
        }

        let resp = try JSONDecoder().decode(TokenResponse.self, from: data)
        let refreshToken = resp.refreshToken ?? fallbackRefreshToken ?? ""
        guard !resp.accessToken.isEmpty, !refreshToken.isEmpty, resp.expiresIn > 0 else {
            throw KimiOAuthError.invalidResponse
        }

        let expiresAt = Int(Date().timeIntervalSince1970) + resp.expiresIn
        return KimiOAuthToken(
            accessToken: resp.accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            scope: resp.scope,
            tokenType: resp.tokenType,
            expiresIn: resp.expiresIn
        )
    }

    private static func extractErrorCode(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["error"] as? String
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let msg = json["error_description"] as? String { return msg }
            if let msg = json["message"] as? String { return msg }
            if let detail = json["detail"] as? String { return detail }
            if let err = json["error"] as? String { return err }
        }
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text
        }
        return nil
    }
}
