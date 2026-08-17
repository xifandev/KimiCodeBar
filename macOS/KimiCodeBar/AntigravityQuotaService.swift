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
    public var geminiWeekly: AntigravityQuotaBucket?
    public var geminiSession: AntigravityQuotaBucket?
    public var claudeWeekly: AntigravityQuotaBucket?
    public var claudeSession: AntigravityQuotaBucket?
    public var allBuckets: [AntigravityQuotaBucket]
    public var updatedAt: Date

    public init(
        email: String? = nil,
        planName: String? = nil,
        geminiWeekly: AntigravityQuotaBucket? = nil,
        geminiSession: AntigravityQuotaBucket? = nil,
        claudeWeekly: AntigravityQuotaBucket? = nil,
        claudeSession: AntigravityQuotaBucket? = nil,
        allBuckets: [AntigravityQuotaBucket] = [],
        updatedAt: Date = Date()
    ) {
        self.email = email
        self.planName = planName
        self.geminiWeekly = geminiWeekly
        self.geminiSession = geminiSession
        self.claudeWeekly = claudeWeekly
        self.claudeSession = claudeSession
        self.allBuckets = allBuckets
        self.updatedAt = updatedAt
    }
}

// MARK: - 远程配额服务

final class AntigravityQuotaService: Sendable {
    static let shared = AntigravityQuotaService()

    private static let baseURL = "https://cloudcode-pa.googleapis.com"
    private static let quotaSummaryURL = "\(baseURL)/v1internal:retrieveUserQuotaSummary"
    private static let loadCodeAssistURL = "\(baseURL)/v1internal:loadCodeAssist"

    private init() {}

    /// 获取 Antigravity 配额
    func fetchQuota(accessToken: String, cachedEmail: String? = nil) async -> Result<AntigravityQuota, QuotaError> {
        guard let url = URL(string: Self.quotaSummaryURL) else {
            return .failure(.invalidURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("antigravity", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data("{}".utf8)
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

        // 解析配额
        do {
            var quota = try Self.parseQuotaSummary(data: data)
            if quota.email == nil {
                quota.email = cachedEmail
            }
            return .success(quota)
        } catch {
            return .failure(.invalidResponse)
        }
    }

    // MARK: - 响应解析

    private static func parseQuotaSummary(data: Data) throws -> AntigravityQuota {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "AntigravityQuota", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法解析 JSON 根节点"])
        }

        let userTier = json["userTier"] as? String ?? json["tier"] as? String ?? json["plan"] as? String
        let tierDisplayName = json["tierDisplayName"] as? String ?? userTier ?? "Antigravity Starter Quota"
        let email = json["email"] as? String ?? json["userEmail"] as? String

        var allBuckets: [AntigravityQuotaBucket] = []
        var geminiWeekly: AntigravityQuotaBucket?
        var geminiSession: AntigravityQuotaBucket?
        var claudeWeekly: AntigravityQuotaBucket?
        var claudeSession: AntigravityQuotaBucket?

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // groups 结构
        if let groups = json["groups"] as? [[String: Any]] {
            for group in groups {
                let groupName = (group["displayName"] as? String ?? group["name"] as? String ?? "").lowercased()
                let buckets = group["buckets"] as? [[String: Any]] ?? []

                for bucketDict in buckets {
                    let bucketId = bucketDict["bucketId"] as? String ?? bucketDict["id"] as? String ?? UUID().uuidString
                    let bucketDisplayName = bucketDict["displayName"] as? String ?? bucketId
                    let remainingFraction = bucketDict["remainingFraction"] as? Double
                    let disabled = bucketDict["disabled"] as? Bool ?? false
                    
                    var resetTime: Date? = nil
                    if let resetTimeStr = bucketDict["resetTime"] as? String {
                        resetTime = isoFormatter.date(from: resetTimeStr) ?? ISO8601DateFormatter().date(from: resetTimeStr)
                    }

                    let bucket = AntigravityQuotaBucket(
                        id: bucketId,
                        name: bucketDisplayName,
                        remainingFraction: remainingFraction,
                        resetTime: resetTime,
                        disabled: disabled
                    )
                    allBuckets.append(bucket)

                    let lowerName = (bucketDisplayName + " " + bucketId).lowercased()
                    let isWeekly = lowerName.contains("weekly") || lowerName.contains("week") || lowerName.contains("7d")
                    let isSession = lowerName.contains("session") || lowerName.contains("5h") || lowerName.contains("5-hour")

                    if groupName.contains("gemini") {
                        if isWeekly {
                            geminiWeekly = bucket
                        } else if isSession {
                            geminiSession = bucket
                        } else if geminiWeekly == nil {
                            geminiWeekly = bucket
                        }
                    } else if groupName.contains("claude") || groupName.contains("gpt") {
                        if isWeekly {
                            claudeWeekly = bucket
                        } else if isSession {
                            claudeSession = bucket
                        } else if claudeWeekly == nil {
                            claudeWeekly = bucket
                        }
                    }
                }
            }
        }

        // 兜底：直接平铺 buckets
        if allBuckets.isEmpty, let rawBuckets = json["buckets"] as? [[String: Any]] {
            for bucketDict in rawBuckets {
                let bucketId = bucketDict["bucketId"] as? String ?? bucketDict["id"] as? String ?? UUID().uuidString
                let bucketDisplayName = bucketDict["displayName"] as? String ?? bucketId
                let remainingFraction = bucketDict["remainingFraction"] as? Double
                let disabled = bucketDict["disabled"] as? Bool ?? false
                var resetTime: Date? = nil
                if let resetTimeStr = bucketDict["resetTime"] as? String {
                    resetTime = isoFormatter.date(from: resetTimeStr) ?? ISO8601DateFormatter().date(from: resetTimeStr)
                }

                let bucket = AntigravityQuotaBucket(
                    id: bucketId,
                    name: bucketDisplayName,
                    remainingFraction: remainingFraction,
                    resetTime: resetTime,
                    disabled: disabled
                )
                allBuckets.append(bucket)

                let lower = (bucketDisplayName + " " + bucketId).lowercased()
                if lower.contains("gemini") {
                    geminiWeekly = bucket
                } else if lower.contains("claude") || lower.contains("gpt") {
                    claudeWeekly = bucket
                }
            }
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
}
