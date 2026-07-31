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
    let balanceYuan: Double
    let monthlyChargeLimitEnabled: Bool
    let monthlyChargeLimitCents: Int
    let monthlyUsedCents: Int
    let topupLimitCents: Int

    var monthlyChargeLimitYuan: Double { Double(monthlyChargeLimitCents) / 100.0 }
    var monthlyUsedYuan: Double { Double(monthlyUsedCents) / 100.0 }
    var topupLimitYuan: Double { Double(topupLimitCents) / 100.0 }
}

struct KimiQuota: Equatable {
    let weekly: QuotaDetail
    let fiveHour: QuotaDetail
    let totalQuota: QuotaDetail
    let membershipLevel: String?
    let boosterWallet: BoosterWallet?
    /// 账号唯一标识（user 对象中的 id/phone/email，取第一个非空值；都没有则为 nil）。
    /// 仅用于多账号添加时的尽力去重，界面不展示。
    let userIdentifier: String?

    /// 会员等级显示名：API 返回 LEVEL_* 枚举，映射为 Kimi 官方会员名称（音乐速度术语，不做本地化）。
    /// 未知等级回退为去掉 LEVEL_ 前缀的原始值，避免官方新增等级时显示错误名称。
    static func membershipDisplayName(_ level: String) -> String {
        switch level.uppercased() {
        case "LEVEL_FREE": return "Free"
        case "LEVEL_BASIC": return "Adagio"
        case "LEVEL_STANDARD": return "Moderato"
        case "LEVEL_INTERMEDIATE": return "Allegretto"
        case "LEVEL_ADVANCED": return "Allegro"
        case "LEVEL_PREMIUM": return "Vivace"
        default:
            let trimmed = level.uppercased().replacingOccurrences(of: "LEVEL_", with: "")
            return trimmed.isEmpty ? LanguageManager.tr("未知") : trimmed
        }
    }
}

/// 宽松字符串解析：兼容服务端把标识字段以数字形式返回的情况
private struct LenientString: Codable {
    let value: String?

    init(value: String?) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else if let double = try? container.decode(Double.self) {
            value = String(double)
        } else {
            value = nil
        }
    }
}

final class KimiCodeBarQuotaService {
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// 查询配额。token 可以是 API Key（sk-kimi- 前缀）或 OAuth access token，
    /// 两者均以同样的 `Authorization: Bearer` 头携带，服务端不做区分。
    func fetchQuota(token: String) async -> Result<KimiQuota, QuotaError> {
        guard !token.isEmpty else {
            return .failure(.invalidKeyFormat)
        }

        guard let url = URL(string: "https://api.kimi.com/coding/v1/usages") else {
            return .failure(.invalidURL)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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

    func fetchDisplayText(token: String) async -> String {
        let result = await fetchQuota(token: token)
        switch result {
        case .success(let quota):
            return LanguageManager.tr("周%1$d%% 5h %2$d%%", arguments: [quota.weekly.percentage, quota.fiveHour.percentage])
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
                // 账号唯一标识候选字段，宽松解析（服务端可能以数字形式返回 id）
                let id: LenientString?
                let phone: LenientString?
                let email: LenientString?
            }
            struct BoosterWallet: Codable {
                struct Money: Codable {
                    let currency: String?
                    let priceInCents: String?
                }
                struct Balance: Codable {
                    let amount: String?
                    let amountLeft: String?
                    let unit: String?
                }
                let status: String?
                let balance: Balance?
                let monthlyChargeLimitEnabled: Bool?
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
            let upperStatus = status.uppercased()
            let isEnabled = upperStatus == "STATUS_ACTIVE" || upperStatus == "STATUS_ENABLED"
            let currency = raw.monthlyChargeLimit?.currency
                ?? raw.monthlyUsed?.currency
                ?? raw.topupLimit?.currency
                ?? "CNY"
            let monthlyChargeLimitCents = Int(raw.monthlyChargeLimit?.priceInCents ?? "0") ?? 0
            let monthlyUsedCents = Int(raw.monthlyUsed?.priceInCents ?? "0") ?? 0
            // 真实余额来自 balance.amountLeft，单位为 1e-8 元（如 315250700 = ¥3.15）。
            // 仅在加油包处于启用状态时才读取该字段——未启用时接口可能返回一个与
            // 「月度上限 - 月度消费」相关的值（例如 ¥75），而非用户真正的钱包余额，
            // 此时应显示 ¥0。同时，接口未返回该字段时也不做估算。
            let balanceYuan: Double
            if isEnabled, let amountLeft = raw.balance?.amountLeft, let v = Double(amountLeft) {
                balanceYuan = max(0, v / 100_000_000.0)
            } else {
                balanceYuan = 0
            }
            return BoosterWallet(
                status: status,
                isEnabled: isEnabled,
                currency: currency,
                balanceYuan: balanceYuan,
                // proto3 JSON 中 false 会被省略，缺省即未启用月度上限（网页端显示「无限制」）
                monthlyChargeLimitEnabled: raw.monthlyChargeLimitEnabled ?? false,
                monthlyChargeLimitCents: monthlyChargeLimitCents,
                monthlyUsedCents: monthlyUsedCents,
                topupLimitCents: Int(raw.topupLimit?.priceInCents ?? "0") ?? 0
            )
        }()

        return KimiQuota(
            weekly: weekly,
            fiveHour: fiveHour,
            totalQuota: totalQuota,
            membershipLevel: membershipLevel,
            boosterWallet: boosterWallet,
            userIdentifier: [resp.user?.id?.value, resp.user?.phone?.value, resp.user?.email?.value]
                .compactMap { $0 }
                .first(where: { !$0.isEmpty })
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
        guard let resetTime = resetTime else { return LanguageManager.tr("未知") }
        let now = Date()
        if resetTime <= now {
            return LanguageManager.tr("即将重置")
        }
        let components = Calendar.current.dateComponents([.day, .hour, .minute], from: now, to: resetTime)
        if let day = components.day, day > 0 {
            return LanguageManager.tr("%1$d天%2$d小时后重置", arguments: [day, components.hour ?? 0])
        }
        if let hour = components.hour, hour > 0 {
            return LanguageManager.tr("%1$d小时%2$d分钟后重置", arguments: [hour, components.minute ?? 0])
        }
        if let minute = components.minute, minute > 0 {
            return LanguageManager.tr("%d分钟后重置", arguments: [minute])
        }
        return LanguageManager.tr("即将重置")
    }

    var resetTimeText: String {
        guard let resetTime = resetTime else { return LanguageManager.tr("未知") }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: resetTime)
    }
}
