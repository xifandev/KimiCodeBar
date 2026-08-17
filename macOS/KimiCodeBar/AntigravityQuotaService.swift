import Foundation

// MARK: - Antigravity 配额桶与配额模型

public struct AntigravityQuotaBucket: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var remainingFraction: Double? // 0.0 ~ 1.0
    public var resetTime: Date?
    public var resetDescription: String?
    public var disabled: Bool

    public init(
        id: String,
        name: String,
        remainingFraction: Double?,
        resetTime: Date?,
        resetDescription: String? = nil,
        disabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.remainingFraction = remainingFraction
        self.resetTime = resetTime
        self.resetDescription = resetDescription
        self.disabled = disabled
    }

    public var remainingPercent: Double {
        guard let remainingFraction else { return 0 }
        return max(0, min(100, remainingFraction * 100))
    }

    public var usedPercent: Double {
        max(0, min(100, 100 - remainingPercent))
    }

    /// 剩余时间格式化（如 "6d 23h", "4h 20m", "15m"）
    public var resetTimeFormatted: String? {
        guard let resetTime else { return resetDescription }
        let now = Date()
        let diff = resetTime.timeIntervalSince(now)
        guard diff > 0 else { return "即将重置" }

        let days = Int(diff) / 86400
        let hours = (Int(diff) % 86400) / 3600
        let minutes = (Int(diff) % 3600) / 60

        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        } else if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        } else {
            return "\(max(1, minutes))m"
        }
    }
}

public struct AntigravityQuota: Equatable, Sendable {
    public var email: String?
    public var planName: String?
    public var projectID: String?
    public var geminiWeekly: AntigravityQuotaBucket?
    public var geminiSession: AntigravityQuotaBucket?
    public var claudeWeekly: AntigravityQuotaBucket?
    public var claudeSession: AntigravityQuotaBucket?
    public var allBuckets: [AntigravityQuotaBucket]
    public var updatedAt: Date

    public init(
        email: String? = nil,
        planName: String? = nil,
        projectID: String? = nil,
        geminiWeekly: AntigravityQuotaBucket? = nil,
        geminiSession: AntigravityQuotaBucket? = nil,
        claudeWeekly: AntigravityQuotaBucket? = nil,
        claudeSession: AntigravityQuotaBucket? = nil,
        allBuckets: [AntigravityQuotaBucket] = [],
        updatedAt: Date = Date()
    ) {
        self.email = email
        self.planName = planName
        self.projectID = projectID
        self.geminiWeekly = geminiWeekly
        self.geminiSession = geminiSession
        self.claudeWeekly = claudeWeekly
        self.claudeSession = claudeSession
        self.allBuckets = allBuckets
        self.updatedAt = updatedAt
    }

    public var hasPoolQuota: Bool {
        geminiWeekly != nil || geminiSession != nil || claudeWeekly != nil || claudeSession != nil
    }
}

// MARK: - 远程配额服务

final class AntigravityQuotaService: Sendable {
    static let shared = AntigravityQuotaService()

    private static let quotaSummaryPaths = [
        "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
        "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
    ]
    private static let loadCodeAssistPaths = [
        "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist",
        "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    ]

    private init() {}

    /// 获取 Antigravity 配额（必须先解析 Cloud AI Companion 项目，否则会假报每个模型 100%）
    func fetchQuota(
        accessToken: String,
        cachedEmail: String? = nil,
        cachedProjectID: String? = nil
    ) async -> Result<AntigravityQuota, QuotaError> {
        var projectID = cachedProjectID.flatMap { $0.isEmpty ? nil : $0 }
        var planName: String?

        if projectID == nil {
            let project = await loadProject(accessToken: accessToken)
            projectID = project.id
            planName = project.planName
        }

        guard let projectID else {
            return .failure(.networkError("无法获取 Antigravity 项目信息"))
        }

        var lastError: QuotaError = .invalidResponse
        for urlString in Self.quotaSummaryPaths {
            switch await postJSON(
                urlString: urlString,
                accessToken: accessToken,
                body: ["project": projectID]
            ) {
            case .failure(let error):
                lastError = error
                if case .httpError(let status, _) = error, status == 401 || status == 403 {
                    return .failure(error)
                }
            case .success(let data):
                do {
                    var quota = try Self.parseQuotaSummary(data: data)
                    if quota.email == nil {
                        quota.email = cachedEmail
                    }
                    if quota.planName == nil || quota.planName?.isEmpty == true {
                        quota.planName = planName
                    }
                    quota.projectID = projectID
                    if quota.hasPoolQuota {
                        return .success(quota)
                    }
                    lastError = .invalidResponse
                } catch {
                    lastError = .invalidResponse
                }
            }
        }

        return .failure(lastError)
    }

    // MARK: - loadCodeAssist

    private func loadProject(accessToken: String) async -> (id: String?, planName: String?) {
        let body: [String: Any] = ["metadata": ["ideType": "ANTIGRAVITY"]]
        for urlString in Self.loadCodeAssistPaths {
            switch await postJSON(urlString: urlString, accessToken: accessToken, body: body) {
            case .failure:
                continue
            case .success(let data):
                guard let json = Self.jsonObject(data) else { continue }
                let root = Self.unwrap(json)
                let projectValue = root["cloudaicompanionProject"] ?? root["cloudaicompanion_project"] ?? root["project"]
                let id = Self.stringValue(projectValue)
                    ?? Self.stringValue((projectValue as? [String: Any])?["id"])
                    ?? Self.stringValue((projectValue as? [String: Any])?["name"])
                let paid = root["paidTier"] as? [String: Any] ?? root["paid_tier"] as? [String: Any]
                let current = root["currentTier"] as? [String: Any] ?? root["current_tier"] as? [String: Any]
                let plan = Self.stringValue(paid?["name"])
                    ?? Self.stringValue(paid?["id"])
                    ?? Self.stringValue(current?["name"])
                    ?? Self.stringValue(current?["id"])
                if let id, !id.isEmpty {
                    return (id, plan)
                }
            }
        }
        return (nil, nil)
    }

    private func postJSON(
        urlString: String,
        accessToken: String,
        body: [String: Any]
    ) async -> Result<Data, QuotaError> {
        guard let url = URL(string: urlString) else {
            return .failure(.invalidURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("antigravity", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .failure(.networkError(error.localizedDescription))
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            return .failure(.invalidResponse)
        }

        if httpResponse.statusCode != 200 {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            return .failure(.httpError(statusCode: httpResponse.statusCode, message: errorMsg))
        }

        return .success(data)
    }

    // MARK: - 响应解析

    private static func parseQuotaSummary(data: Data) throws -> AntigravityQuota {
        guard let json = jsonObject(data) else {
            throw NSError(domain: "AntigravityQuota", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法解析 JSON 根节点"])
        }
        let root = unwrap(json)

        let userTier = stringValue(root["userTier"]) ?? stringValue(root["tier"]) ?? stringValue(root["plan"])
        let tierDisplayName = stringValue(root["tierDisplayName"]) ?? stringValue(root["tier_display_name"]) ?? userTier
        let email = stringValue(root["email"]) ?? stringValue(root["userEmail"])

        let groups = root["groups"] as? [[String: Any]] ?? []
        var allBuckets: [AntigravityQuotaBucket] = []
        var geminiWeekly: AntigravityQuotaBucket?
        var geminiSession: AntigravityQuotaBucket?
        var claudeWeekly: AntigravityQuotaBucket?
        var claudeSession: AntigravityQuotaBucket?

        for group in groups {
            let groupName = (stringValue(group["displayName"]) ?? stringValue(group["name"]) ?? "").lowercased()
            let buckets = group["buckets"] as? [[String: Any]] ?? []

            for bucketDict in buckets {
                let bucket = parseBucket(bucketDict)
                allBuckets.append(bucket)

                let blob = (
                    groupName + " " +
                    bucket.id.lowercased() + " " +
                    bucket.name.lowercased()
                )
                let family = quotaFamily(from: blob)
                let period = quotaPeriod(from: blob, window: stringValue(bucketDict["window"]))

                switch (family, period) {
                case (.gemini, .weekly):
                    geminiWeekly = bucket
                case (.gemini, .session):
                    geminiSession = bucket
                case (.claude, .weekly):
                    claudeWeekly = bucket
                case (.claude, .session):
                    claudeSession = bucket
                default:
                    break
                }
            }
        }

        // 没解析出共享池时：按模型族取最差剩余值，绝不把每个模型铺到面板上
        if geminiWeekly == nil && geminiSession == nil && claudeWeekly == nil && claudeSession == nil {
            let gemini = allBuckets.filter { quotaFamily(from: $0.name + " " + $0.id) == .gemini }
            let claude = allBuckets.filter { quotaFamily(from: $0.name + " " + $0.id) == .claude }
            geminiSession = worstBucket(in: gemini)
            claudeSession = worstBucket(in: claude)
        }

        return AntigravityQuota(
            email: email,
            planName: tierDisplayName,
            geminiWeekly: geminiWeekly,
            geminiSession: geminiSession,
            claudeWeekly: claudeWeekly,
            claudeSession: claudeSession,
            allBuckets: allBuckets,
            updatedAt: Date()
        )
    }

    private enum QuotaFamily { case gemini, claude }
    private enum QuotaPeriod { case weekly, session }

    private static func quotaFamily(from text: String) -> QuotaFamily? {
        let lower = text.lowercased()
        if lower.contains("gemini") { return .gemini }
        if lower.contains("claude") || lower.contains("gpt") || lower.contains("3p-") || lower.contains("oss") {
            return .claude
        }
        return nil
    }

    private static func quotaPeriod(from text: String, window: String?) -> QuotaPeriod? {
        let blob = ((window ?? "") + " " + text).lowercased()
        if blob.contains("weekly") || blob.contains("week") || blob.contains("7d") { return .weekly }
        if blob.contains("session") || blob.contains("5h") || blob.contains("5-hour") || blob.contains("five") {
            return .session
        }
        return nil
    }

    private static func worstBucket(in buckets: [AntigravityQuotaBucket]) -> AntigravityQuotaBucket? {
        buckets.min { lhs, rhs in
            (lhs.remainingFraction ?? 1) < (rhs.remainingFraction ?? 1)
        }
    }

    private static func parseBucket(_ dict: [String: Any]) -> AntigravityQuotaBucket {
        let bucketId = stringValue(dict["bucketId"]) ?? stringValue(dict["id"]) ?? UUID().uuidString
        let displayName = stringValue(dict["displayName"])
            ?? stringValue(dict["display_name"])
            ?? bucketId
        let remaining = parseFraction(dict["remainingFraction"])
            ?? parseFraction(dict["remaining_fraction"])
            ?? parseFraction(dict["remaining"])
        let disabled = (dict["disabled"] as? Bool) ?? false
        let resetTime = parseDate(stringValue(dict["resetTime"]) ?? stringValue(dict["reset_time"]))
        let description = stringValue(dict["description"])

        return AntigravityQuotaBucket(
            id: bucketId,
            name: displayName,
            remainingFraction: remaining,
            resetTime: resetTime,
            resetDescription: description,
            disabled: disabled
        )
    }

    private static func parseFraction(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            let fraction = number.doubleValue
            return (0...1).contains(fraction) ? fraction : nil
        }
        if let text = value as? String, let fraction = Double(text), (0...1).contains(fraction) {
            return fraction
        }
        if let dict = value as? [String: Any] {
            return parseFraction(dict["remainingFraction"]) ?? parseFraction(dict["remaining_fraction"])
        }
        return nil
    }

    private static func parseDate(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func unwrap(_ json: [String: Any]) -> [String: Any] {
        for key in ["response", "userQuotaSummary", "quotaSummary", "data", "result"] {
            if let nested = json[key] as? [String: Any] {
                return unwrap(nested)
            }
        }
        return json
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        return nil
    }
}
