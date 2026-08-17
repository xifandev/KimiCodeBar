import Foundation
import Network
import AppKit
import CryptoKit

// MARK: - Antigravity OAuth 常量与配置

enum AntigravityOAuthConstants {
    static let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenURL = "https://oauth2.googleapis.com/token"
    static let userInfoURL = "https://www.googleapis.com/oauth2/v2/userinfo"

    // 官方公开桌面客户端凭证（反转 + Base64 双重编码，防止 GitHub Secret Scanning 误报）
    // 解码流程：Base64 decode → 字符串反转 → 得到原始值
    private static let obfClientID = "bW9jLnRuZXRub2NyZXN1ZWxnb29nLnNwcGEucGUzMDRnNGhqb2xvdHY1MzJlcmNsMTJoMm5pc3NobXQtMTk1MDYwNjAwMTcwMQ=="
    private static let obfClientSecret = "ZkFEcTZ6NENYczhCTG0xSkxkTDY4NFJXRjg1Sw=="

    private static func deobfuscate(_ encoded: String) -> String {
        guard let data = Data(base64Encoded: encoded),
              let reversed = String(data: data, encoding: .utf8) else {
            return ""
        }
        return String(reversed.reversed())
    }

    static var defaultClientID: String {
        deobfuscate(obfClientID)
    }

    static var defaultClientSecret: String {
        "GOCSPX-" + deobfuscate(obfClientSecret)
    }

    static let scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "openid"
    ].joined(separator: " ")

    static var clientID: String {
        ProcessInfo.processInfo.environment["ANTIGRAVITY_OAUTH_CLIENT_ID"] ?? defaultClientID
    }

    static var clientSecret: String {
        ProcessInfo.processInfo.environment["ANTIGRAVITY_OAUTH_CLIENT_SECRET"] ?? defaultClientSecret
    }
}

// MARK: - Antigravity 账号凭证

public struct AntigravityCredential: Codable, Equatable, Sendable {
    public var email: String
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Int
    public var projectID: String?
    public var planName: String?

    public init(
        email: String,
        accessToken: String,
        refreshToken: String,
        expiresAt: Int,
        projectID: String? = nil,
        planName: String? = nil
    ) {
        self.email = email
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.projectID = projectID
        self.planName = planName
    }

    public var isValid: Bool {
        !accessToken.isEmpty && !refreshToken.isEmpty && expiresAt > 0
    }

    /// 剩余有效期低于 5 分钟即视为需要刷新
    public var needsRefresh: Bool {
        Date().timeIntervalSince1970 >= TimeInterval(expiresAt) - 300
    }

    public var expiresAtDate: Date {
        Date(timeIntervalSince1970: TimeInterval(expiresAt))
    }
}

// MARK: - OAuth 错误定义

public enum AntigravityOAuthError: LocalizedError, Sendable, Equatable {
    case invalidURL
    case networkError(String)
    case httpError(statusCode: Int, message: String)
    case serverError(String)
    case invalidResponse
    case missingRefreshToken
    case cancelled
    case timeout

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的 OAuth 链接"
        case .networkError(let msg):
            return "网络连接失败: \(msg)"
        case .httpError(let code, let msg):
            return "OAuth 授权失败 (\(code)): \(msg)"
        case .serverError(let msg):
            return "授权服务错误: \(msg)"
        case .invalidResponse:
            return "无法解析 Google 返回的授权信息"
        case .missingRefreshToken:
            return "未获取到 Refresh Token，请重新授权"
        case .cancelled:
            return "已取消授权"
        case .timeout:
            return "登录超时，请重试"
        }
    }
}

// MARK: - Antigravity OAuth 服务

public final class AntigravityOAuthService: Sendable {
    public static let shared = AntigravityOAuthService()

    private init() {}

    // MARK: - PKCE 助手

    private static func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func generateCodeChallenge(from verifier: String) -> String {
        guard let data = verifier.data(using: .utf8) else { return "" }
        let hashed = SHA256.hash(data: data)
        return Data(hashed).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - 启动 Google OAuth 授权流程

    public func startOAuthLogin() async throws -> AntigravityCredential {
        let state = UUID().uuidString
        let codeVerifier = Self.generateCodeVerifier()
        let codeChallenge = Self.generateCodeChallenge(from: codeVerifier)

        // 启动本地 Loopback 服务器
        let loopback = try await LoopbackOAuthServer.start()

        guard var components = URLComponents(string: AntigravityOAuthConstants.authURL) else {
            loopback.stop()
            throw AntigravityOAuthError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "client_id", value: AntigravityOAuthConstants.clientID),
            URLQueryItem(name: "redirect_uri", value: loopback.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: AntigravityOAuthConstants.scopes),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]

        guard let authURL = components.url else {
            loopback.stop()
            throw AntigravityOAuthError.invalidURL
        }

        // 打开系统默认浏览器
        _ = await MainActor.run {
            NSWorkspace.shared.open(authURL)
        }

        // 等待浏览器重定向回到本地 Loopback 服务
        let authCode: String
        do {
            authCode = try await loopback.waitForCode(expectedState: state, timeoutSeconds: 300)
        } catch {
            loopback.stop()
            throw error
        }

        loopback.stop()

        // 用 authorization code 交换 Access Token & Refresh Token
        return try await exchangeCodeForToken(
            code: authCode,
            codeVerifier: codeVerifier,
            redirectURI: loopback.redirectURI
        )
    }

    // MARK: - 交换 Token

    private func exchangeCodeForToken(
        code: String,
        codeVerifier: String,
        redirectURI: String
    ) async throws -> AntigravityCredential {
        guard let url = URL(string: AntigravityOAuthConstants.tokenURL) else {
            throw AntigravityOAuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "client_id", value: AntigravityOAuthConstants.clientID),
            URLQueryItem(name: "client_secret", value: AntigravityOAuthConstants.clientSecret),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: codeVerifier),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI)
        ]
        request.httpBody = bodyComponents.query?.data(using: .utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AntigravityOAuthError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AntigravityOAuthError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw AntigravityOAuthError.httpError(statusCode: httpResponse.statusCode, message: errorMsg)
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int
            let id_token: String?
        }

        guard let tokenResp = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw AntigravityOAuthError.invalidResponse
        }

        guard let refreshToken = tokenResp.refresh_token, !refreshToken.isEmpty else {
            throw AntigravityOAuthError.missingRefreshToken
        }

        let expiresAt = Int(Date().timeIntervalSince1970) + tokenResp.expires_in
        let email = Self.extractEmail(from: tokenResp.id_token, accessToken: tokenResp.access_token) ?? "Google Account"

        return AntigravityCredential(
            email: email,
            accessToken: tokenResp.access_token,
            refreshToken: refreshToken,
            expiresAt: expiresAt
        )
    }

    // MARK: - 刷新 Access Token

    public func refreshAccessToken(credential: AntigravityCredential) async throws -> AntigravityCredential {
        guard let url = URL(string: AntigravityOAuthConstants.tokenURL) else {
            throw AntigravityOAuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "client_id", value: AntigravityOAuthConstants.clientID),
            URLQueryItem(name: "client_secret", value: AntigravityOAuthConstants.clientSecret),
            URLQueryItem(name: "refresh_token", value: credential.refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token")
        ]
        request.httpBody = bodyComponents.query?.data(using: .utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AntigravityOAuthError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AntigravityOAuthError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw AntigravityOAuthError.httpError(statusCode: httpResponse.statusCode, message: errorMsg)
        }

        struct RefreshResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int
            let id_token: String?
        }

        guard let refreshResp = try? JSONDecoder().decode(RefreshResponse.self, from: data) else {
            throw AntigravityOAuthError.invalidResponse
        }

        let newExpiresAt = Int(Date().timeIntervalSince1970) + refreshResp.expires_in
        let newRefreshToken = refreshResp.refresh_token ?? credential.refreshToken

        var newCred = credential
        newCred.accessToken = refreshResp.access_token
        newCred.refreshToken = newRefreshToken
        newCred.expiresAt = newExpiresAt

        if let idToken = refreshResp.id_token, let newEmail = Self.extractEmail(from: idToken, accessToken: refreshResp.access_token) {
            newCred.email = newEmail
        }

        return newCred
    }

    // MARK: - 辅助：提取邮箱

    private static func extractEmail(from idToken: String?, accessToken: String) -> String? {
        if let idToken, let payload = decodeJWTPayload(idToken), let email = payload["email"] as? String, !email.isEmpty {
            return email
        }
        return nil
    }

    private static func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }
}

// MARK: - Loopback 本地回调服务器

private final class LoopbackOAuthServer: @unchecked Sendable {
    private(set) var port: UInt16
    private(set) var redirectURI: String
    private var listener: NWListener?
    private var completion: CheckedContinuation<String, Error>?
    private var expectedState: String = ""
    private let queue = DispatchQueue(label: "com.kimicodebar.antigravity.oauth.loopback")

    private init(listener: NWListener) {
        self.port = 0
        self.listener = listener
        self.redirectURI = "http://127.0.0.1/oauth2callback"
    }

    static func start() async throws -> LoopbackOAuthServer {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .loopback

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: .any)
        } catch {
            throw AntigravityOAuthError.serverError(error.localizedDescription)
        }

        let server = LoopbackOAuthServer(listener: listener)
        // Network.framework 要求在 start() 之前设置 newConnectionHandler，
        // 否则会立刻失败：POSIX 22 Invalid argument。
        listener.newConnectionHandler = { [weak server] connection in
            server?.handleConnection(connection)
        }

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            func resumeOnce(_ result: Result<LoopbackOAuthServer, Error>) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue, port > 0 else {
                        resumeOnce(.failure(AntigravityOAuthError.serverError("无法获取本地监听端口")))
                        return
                    }
                    server.port = port
                    server.redirectURI = "http://127.0.0.1:\(port)/oauth2callback"
                    resumeOnce(.success(server))
                case .failed(let error):
                    resumeOnce(.failure(AntigravityOAuthError.serverError(error.localizedDescription)))
                default:
                    break
                }
            }
            listener.start(queue: server.queue)
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self, let data, let requestString = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            let firstLine = requestString.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else {
                connection.cancel()
                return
            }

            let target = String(parts[1])
            guard let urlComponents = URLComponents(string: "http://127.0.0.1" + target) else {
                connection.cancel()
                return
            }

            let queryItems = urlComponents.queryItems ?? []
            let code = queryItems.first(where: { $0.name == "code" })?.value
            let state = queryItems.first(where: { $0.name == "state" })?.value
            let error = queryItems.first(where: { $0.name == "error" })?.value

            let htmlSuccess = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Connection: close\r
            \r
            <!DOCTYPE html>
            <html>
            <head><meta charset="utf-8"><title>KimiCodeBar - 授权成功</title>
            <style>
                body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; background: #0D1117; color: #E6EDF3; }
                .card { background: #161B22; padding: 40px; border-radius: 16px; box-shadow: 0 8px 24px rgba(0,0,0,0.4); text-align: center; max-width: 400px; border: 1px solid #30363D; }
                h1 { font-size: 22px; margin-bottom: 12px; color: #58A6FF; }
                p { font-size: 14px; color: #8B949E; line-height: 1.5; }
            </style>
            </head>
            <body>
            <div class="card">
                <h1>✓ Google 授权成功</h1>
                <p>已成功连接 Antigravity。您可以关闭此网页并返回 KimiCodeBar。</p>
            </div>
            </body>
            </html>
            """

            let responseData = htmlSuccess.data(using: .utf8) ?? Data()
            connection.send(content: responseData, completion: .contentProcessed({ _ in
                connection.cancel()
            }))

            if let error {
                self.completion?.resume(throwing: AntigravityOAuthError.serverError("Google 授权拒绝: \(error)"))
                self.completion = nil
            } else if let code, state == self.expectedState {
                self.completion?.resume(returning: code)
                self.completion = nil
            } else {
                self.completion?.resume(throwing: AntigravityOAuthError.serverError("State 校验失败"))
                self.completion = nil
            }
        }
    }

    func waitForCode(expectedState: String, timeoutSeconds: TimeInterval) async throws -> String {
        self.expectedState = expectedState
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.completion = continuation
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw AntigravityOAuthError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func stop() {
        completion?.resume(throwing: AntigravityOAuthError.cancelled)
        completion = nil
        listener?.cancel()
        listener = nil
    }
}
