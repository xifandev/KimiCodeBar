import Foundation

enum QuotaError: Error, Equatable {
    case invalidKeyFormat
    case invalidURL
    case networkError(String)
    case httpError(statusCode: Int, message: String)
    case invalidResponse
}

struct QuotaDetail: Equatable {
    let used: Int
    let limit: Int
    let remaining: Int
    let resetTime: Date?
    let percentage: Int
}

struct BoosterWallet: Equatable {
    let status: String
    let isEnabled: Bool
    let currency: String
    let monthlyChargeLimitCents: Int
    let monthlyUsedCents: Int
    let topupLimitCents: Int

    var monthlyChargeLimitYuan: Double { Double(monthlyChargeLimitCents) / 100.0 }
    var monthlyUsedYuan: Double { Double(monthlyUsedCents) / 100.0 }
    var topupLimitYuan: Double { Double(topupLimitCents) / 100.0 }
    var balanceYuan: Double { max(0, monthlyChargeLimitYuan - monthlyUsedYuan) }
}

struct KimiQuota: Equatable {
    let weekly: QuotaDetail
    let fiveHour: QuotaDetail
    let totalQuota: QuotaDetail
    let membershipLevel: String?
    let boosterWallet: BoosterWallet?
}

final class KimiCodeBarQuotaService {
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func fetchQuota(key: String) async -> Result<KimiQuota, QuotaError> {
        guard key.hasPrefix("sk-kimi-") else {
            return .failure(.invalidKeyFormat)
        }

        guard let url = URL(string: "https://api.kimi.com/coding/v1/usages") else {
            return .failure(.invalidURL)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }

            if http.statusCode != 200 {
                let message = Self.extractErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
                return .failure(.httpError(statusCode: http.statusCode, message: message))
            }

            guard let quota = parse(data) else {
                return .failure(.invalidResponse)
            }
            return .success(quota)
        } catch {
            return .failure(.networkError(error.localizedDescription))
        }
    }

    func fetchDisplayText(key: String) async -> String {
        let result = await fetchQuota(key: key)
        switch result {
        case .success(let quota):
            return "周\(quota.weekly.percentage)% 5h \(quota.fiveHour.percentage)%"
        case .failure:
            return "--"
        }
    }

    static func extractErrorMessage(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let msg = json["error"] as? String { return msg }
            if let msg = json["message"] as? String { return msg }
            if let detail = json["detail"] as? String { return detail }
            if let err = json["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
        }
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text
        }
        return nil
    }

    private func parse(_ data: Data) -> KimiQuota? {
        struct Response: Codable {
            struct Usage: Codable {
                let limit: String?
                let used: String?
                let remaining: String?
                let resetTime: String?
            }
            struct Limit: Codable {
                struct Window: Codable { let duration: Int }
                struct Detail: Codable {
                    let limit: String?
                    let used: String?
                    let remaining: String?
                    let resetTime: String?
                }
                let window: Window
                let detail: Detail
            }
            struct TotalQuota: Codable {
                let limit: String?
                let remaining: String?
            }
            struct User: Codable {
                struct Membership: Codable {
                    let level: String?
                }
                let membership: Membership?
            }
            struct BoosterWallet: Codable {
                struct Money: Codable {
                    let currency: String?
                    let priceInCents: String?
                }
                let status: String?
                let monthlyChargeLimit: Money?
                let monthlyUsed: Money?
                let topupLimit: Money?
            }
            let usage: Usage?
            let limits: [Limit]?
            let totalQuota: TotalQuota?
            let user: User?
            let boosterWallet: BoosterWallet?
        }

        guard let resp = try? JSONDecoder().decode(Response.self, from: data) else {
            return nil
        }

        let weekly = makeDetail(
            limit: resp.usage?.limit,
            used: resp.usage?.used,
            remaining: resp.usage?.remaining,
            resetTime: resp.usage?.resetTime
        )

        var fiveHour = QuotaDetail(used: 0, limit: 0, remaining: 0, resetTime: nil, percentage: 0)
        if let limit = resp.limits?.first(where: { $0.window.duration == 300 }) {
            fiveHour = makeDetail(
                limit: limit.detail.limit,
                used: limit.detail.used,
                remaining: limit.detail.remaining,
                resetTime: limit.detail.resetTime
            )
        }

        let totalQuota = makeDetail(
            limit: resp.totalQuota?.limit,
            used: nil,
            remaining: resp.totalQuota?.remaining,
            resetTime: nil
        )

        let membershipLevel = resp.user?.membership?.level

        let boosterWallet: BoosterWallet? = {
            guard let raw = resp.boosterWallet else { return nil }
            let status = raw.status ?? "STATUS_UNKNOWN"
            let isEnabled = status.uppercased() == "STATUS_ENABLED"
            let currency = raw.monthlyChargeLimit?.currency
                ?? raw.monthlyUsed?.currency
                ?? raw.topupLimit?.currency
                ?? "CNY"
            return BoosterWallet(
                status: status,
                isEnabled: isEnabled,
                currency: currency,
                monthlyChargeLimitCents: Int(raw.monthlyChargeLimit?.priceInCents ?? "0") ?? 0,
                monthlyUsedCents: Int(raw.monthlyUsed?.priceInCents ?? "0") ?? 0,
                topupLimitCents: Int(raw.topupLimit?.priceInCents ?? "0") ?? 0
            )
        }()

        return KimiQuota(
            weekly: weekly,
            fiveHour: fiveHour,
            totalQuota: totalQuota,
            membershipLevel: membershipLevel,
            boosterWallet: boosterWallet
        )
    }

    private func makeDetail(limit: String?, used: String?, remaining: String?, resetTime: String?) -> QuotaDetail {
        let li = Int(limit ?? "0") ?? 0
        let us: Int
        if let used = used, let v = Int(used) {
            us = v
        } else if let remaining = remaining, let v = Int(remaining) {
            us = max(0, li - v)
        } else {
            us = 0
        }
        let re = max(0, li - us)
        let pct = li > 0 ? Int(Double(us) / Double(li) * 100) : 0
        return QuotaDetail(used: us, limit: li, remaining: re, resetTime: parseDate(resetTime), percentage: pct)
    }

    private func parseDate(_ string: String?) -> Date? {
        guard let string = string else { return nil }
        if let date = isoFormatter.date(from: string) {
            return date
        }
        let fallback = DateFormatter()
        fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return fallback.date(from: string)
    }
}

extension QuotaDetail {
    var timeUntilReset: String {
        guard let resetTime = resetTime else { return "未知" }
        let now = Date()
        if resetTime <= now {
            return "即将重置"
        }
        let components = Calendar.current.dateComponents([.day, .hour, .minute], from: now, to: resetTime)
        if let day = components.day, day > 0 {
            return "\(day)天\(components.hour ?? 0)小时后重置"
        }
        if let hour = components.hour, hour > 0 {
            return "\(hour)小时\(components.minute ?? 0)分钟后重置"
        }
        if let minute = components.minute, minute > 0 {
            return "\(minute)分钟后重置"
        }
        return "即将重置"
    }

    var resetTimeText: String {
        guard let resetTime = resetTime else { return "未知" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: resetTime)
    }
}
