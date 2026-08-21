import Foundation
import AppKit
import AuthenticationServices
import CryptoKit

// MARK: - OAuth 常量

/// WorkBuddy OAuth Authorization Code + PKCE 流程常量。
/// 与现有「读取 WorkBuddy 桌面端 auth 文件」方式并列，作为更健壮的添加 / 重新授权入口：
/// 不依赖桌面端切账号、token 失效时可在 Bar 内直接重登一次。
///
/// Keycloak 后台只允许 redirect_uri 白名单（含 https://www.workbuddy.cn/auth/callback），
/// localhost / 自定义 scheme 全被拒（实测 console client 配置严格），所以用
/// ASWebAuthenticationSession 在系统认证窗口中拦截官方 callback URL。
enum WorkBuddyOAuthConstants {
    static let issuer = "https://www.workbuddy.cn/auth/realms/copilot"
    static let authURL = "\(issuer)/protocol/openid-connect/auth"
    static let tokenURL = "\(issuer)/protocol/openid-connect/token"

    /// Keycloak 后台为 console client 配置的 client_id（与 WorkBuddy 桌面端同款）
    static let clientID = "console"

    /// Keycloak 白名单允许的 redirect_uri（不接受 localhost / custom scheme）
    static let redirectURI = "https://www.workbuddy.cn/auth/callback"

    /// scope：openid 拿 id_token，profile/email 拿账号信息，offline_access 拿长效 refresh_token
    static let scopes = "openid profile email offline_access"
}

// MARK: - 错误

enum WorkBuddyOAuthError: LocalizedError, Equatable {
    case invalidURL
    case networkError(String)
    case httpError(statusCode: Int, message: String)
    case invalidResponse
    case missingTokens
    case missingUserInfo
    case cancelled
    case callbackMismatch(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的授权 URL"
        case .networkError(let m):
            return "网络错误：\(m)"
        case .httpError(let code, let m):
            return "授权失败 (HTTP \(code))：\(m)"
        case .invalidResponse:
            return "无法解析 Keycloak 返回的响应"
        case .missingTokens:
            return "未获取到 access_token 或 refresh_token"
        case .missingUserInfo:
            return "无法从 token 中解析账号信息"
        case .cancelled:
            return "已取消授权"
        case .callbackMismatch(let m):
            return m
        }
    }
}

// MARK: - 服务

/// WorkBuddy OAuth 服务：Authorization Code + PKCE 流程。
///
/// 调用 `startOAuthLogin()` → 弹出系统认证窗口 → 用户在 workbuddy.cn 登录 →
/// ASWebAuthenticationSession 拦截 callback URL → 解析 code → 用 code+code_verifier
/// 换 token → 解析 JWT 拿 uid 和 preferred_username → 返回 WorkBuddyCredential。
final class WorkBuddyOAuthService {
    static let shared = WorkBuddyOAuthService()
    private init() {}

    // MARK: - PKCE 助手

    /// 生成 code_verifier：32 字节随机 → Base64URL（无 padding）
    private static func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 从 code_verifier 生成 code_challenge：SHA256 → Base64URL（无 padding）
    private static func generateCodeChallenge(from verifier: String) -> String {
        guard let data = verifier.data(using: .utf8) else { return "" }
        let hashed = SHA256.hash(data: data)
        return Data(hashed).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - 启动 OAuth 授权流程

    /// 启动完整 OAuth 流程，成功返回新的 WorkBuddyCredential。
    /// - 抛出 WorkBuddyOAuthError 表示各类失败原因（取消 / 网络 / 服务端错误等）。
    func startOAuthLogin() async throws -> WorkBuddyCredential {
        let state = UUID().uuidString
        let codeVerifier = Self.generateCodeVerifier()
        let codeChallenge = Self.generateCodeChallenge(from: codeVerifier)

        guard var components = URLComponents(string: WorkBuddyOAuthConstants.authURL) else {
            throw WorkBuddyOAuthError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: WorkBuddyOAuthConstants.clientID),
            URLQueryItem(name: "redirect_uri", value: WorkBuddyOAuthConstants.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: WorkBuddyOAuthConstants.scopes),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // 强制每次重新登录：避免 Keycloak 用上次的 SSO cookie 自动选错账号
            URLQueryItem(name: "prompt", value: "login"),
        ]
        guard let authURL = components.url else {
            throw WorkBuddyOAuthError.invalidURL
        }

        // 在系统认证窗口中打开授权 URL；callbackURLScheme=nil 让 session 接受任何 scheme 跳转
        // （Keycloak 会让浏览器跳到 https://www.workbuddy.cn/auth/callback?code=...&state=...）
        let callbackURL: URL
        do {
            callbackURL = try await WorkBuddyAuthSessionManager.shared.start(
                url: authURL,
                callbackURLScheme: nil
            )
        } catch {
            // 用户关闭窗口 / 取消 → ASWebAuthenticationSessionError.canceledLogin
            throw WorkBuddyOAuthError.cancelled
        }

        // 解析 callback URL 中的 code + state
        guard let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw WorkBuddyOAuthError.callbackMismatch("无法解析回调 URL")
        }
        let queryItems = callbackComponents.queryItems ?? []

        // 优先检查错误响应
        if let errCode = queryItems.first(where: { $0.name == "error" })?.value, !errCode.isEmpty {
            let desc = queryItems.first(where: { $0.name == "error_description" })?.value ?? errCode
            throw WorkBuddyOAuthError.callbackMismatch("授权拒绝：\(desc)")
        }

        // State 校验防 CSRF
        let returnedState = queryItems.first(where: { $0.name == "state" })?.value
        guard returnedState == state else {
            throw WorkBuddyOAuthError.callbackMismatch("State 校验失败")
        }

        guard let code = queryItems.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw WorkBuddyOAuthError.callbackMismatch("回调中缺少 code 参数")
        }

        return try await exchangeCodeForToken(code: code, codeVerifier: codeVerifier)
    }

    // MARK: - 用 code 换 token

    private func exchangeCodeForToken(code: String, codeVerifier: String) async throws -> WorkBuddyCredential {
        guard let url = URL(string: WorkBuddyOAuthConstants.tokenURL) else {
            throw WorkBuddyOAuthError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "client_id", value: WorkBuddyOAuthConstants.clientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: codeVerifier),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "redirect_uri", value: WorkBuddyOAuthConstants.redirectURI),
        ]
        request.httpBody = bodyComponents.query?.data(using: .utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw WorkBuddyOAuthError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw WorkBuddyOAuthError.invalidResponse
        }
        if http.statusCode != 200 {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw WorkBuddyOAuthError.httpError(statusCode: http.statusCode, message: msg)
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int
            let id_token: String?
            let scope: String?
            let token_type: String?
        }

        guard let resp = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw WorkBuddyOAuthError.invalidResponse
        }
        guard !resp.access_token.isEmpty,
              let refreshToken = resp.refresh_token, !refreshToken.isEmpty else {
            throw WorkBuddyOAuthError.missingTokens
        }

        // 解析 access_token JWT 拿 sub（= uid）和 preferred_username（= 账号名 / 手机号）
        guard let payload = Self.decodeJWTPayload(resp.access_token),
              let sub = payload["sub"] as? String, !sub.isEmpty else {
            throw WorkBuddyOAuthError.missingUserInfo
        }
        let preferredUsername = (payload["preferred_username"] as? String) ?? sub

        // expires_at 不存到 WorkBuddyCredential（无此字段），用 access_token JWT 自己的 exp 判断
        return WorkBuddyCredential(
            uid: sub,
            nickname: preferredUsername,
            accessToken: resp.access_token,
            refreshToken: refreshToken,
            domain: "www.workbuddy.cn",
            // 浏览器登录拿不到 account/auth 快照，签到和切换走 token 直调 API 即可
            accountSnapshot: nil,
            authSnapshot: nil,
            lastCheckinDate: nil
        )
    }

    // MARK: - JWT 工具

    /// 解码 JWT 的 payload（第二段），不验签（OAuth 流程已通过 HTTPS + state 保证完整性）
    static func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
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

    /// 从 access_token JWT 拿 exp（Unix 秒），用于判断是否要刷新
    static func tokenExpiry(_ token: String) -> Date? {
        guard let payload = decodeJWTPayload(token),
              let exp = payload["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

// MARK: - ASWebAuthenticationSession 管理

/// 管理 ASWebAuthenticationSession 的生命周期：
/// session 和 presentationContextProvider 必须**比 session.start() 活得久**，
/// 否则会被自动释放导致窗口立刻关闭。统一存到单例的强引用上，completionHandler 触发后释放。
@MainActor
final class WorkBuddyAuthSessionManager {
    static let shared = WorkBuddyAuthSessionManager()
    private init() {}

    private var session: ASWebAuthenticationSession?
    private var provider: WorkBuddyAuthPresentationProvider?

    /// 启动 session 等待回调 URL。callbackURLScheme=nil 时接受任何 scheme 的跳转
    /// （Keycloak 会让浏览器跳到 https://www.workbuddy.cn/auth/callback?code=...&state=...）。
    func start(url: URL, callbackURLScheme: String?) async throws -> URL {
        // 取消上一个未结束的 session（避免并发调用）
        cancel()

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let provider = WorkBuddyAuthPresentationProvider()
            self.provider = provider

            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackURLScheme) { [weak self] callbackURL, error in
                // completionHandler 在主线程触发；session 内部已 strong-retain 到 self.session，
                // 这里通过 self.session = nil 让其释放
                Task { @MainActor in
                    self?.session = nil
                    self?.provider = nil
                }
                if let error {
                    continuation.resume(throwing: error)
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: WorkBuddyOAuthError.cancelled)
                }
            }
            session.presentationContextProvider = provider
            // 使用私密浏览：不共享系统 Safari 的 cookie，确保用户每次能选要登录的账号
            session.prefersEphemeralWebBrowserSession = true
            self.session = session

            // start 返回 false 通常是已有 session 在跑 / 上下文无效
            if !session.start() {
                self.session = nil
                self.provider = nil
                continuation.resume(throwing: WorkBuddyOAuthError.cancelled)
            }
        }
    }

    /// 主动取消（用于窗口手动关闭 / App 退出）
    func cancel() {
        session?.cancel()
        session = nil
        provider = nil
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

@MainActor
private final class WorkBuddyAuthPresentationProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // 优先用设置窗口（如果有且可见），否则用任意可见窗口，最后兜底新建空 anchor
        if let settingsWindow = NSApp.windows.first(where: {
            $0.title.contains(LanguageManager.tr("账号管理"))
                || $0.title.contains(LanguageManager.tr("基本设置"))
        }), settingsWindow.isVisible {
            return settingsWindow
        }
        return NSApp.windows.first(where: { $0.isVisible }) ?? ASPresentationAnchor()
    }
}
