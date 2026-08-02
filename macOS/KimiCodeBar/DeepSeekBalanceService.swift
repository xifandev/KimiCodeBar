import Foundation

// MARK: - DeepSeek 余额

/// DeepSeek 账户余额：预充值按量付费模型，核心数据是剩余余额（区别于 Kimi 的订阅额度模型）。
/// 余额拆分为「赠送余额」与「充值余额」两部分，DeepSeek 退款/扣费优先消耗赠送余额。
struct DeepSeekBalance: Equatable {
    /// 账户是否可用（欠费时为 false，API 调用会被拒绝）
    let isAvailable: Bool
    /// 货币代码（CNY / USD），用于决定展示符号
    let currency: String
    /// 总余额（元）
    let totalBalance: Double
    /// 赠送余额（元）
    let grantedBalance: Double
    /// 充值余额（元）
    let toppedUpBalance: Double

    /// 余额展示文本：两位小数，不带货币符号（菜单栏用，符号由鲸鱼图标暗示）
    var balanceText: String {
        String(format: "%.2f", totalBalance)
    }

    /// 带货币符号的余额（面板卡片用）
    var balanceWithSymbol: String {
        let symbol = currency == "CNY" ? "¥" : "$"
        return "\(symbol)\(balanceText)"
    }
}

// MARK: - DeepSeek 余额服务

/// 查询 DeepSeek 账户余额：GET https://api.deepseek.com/user/balance
/// 认证方式：Authorization: Bearer <api_key>（DeepSeek 仅支持 API Key，无 OAuth）
final class DeepSeekBalanceService {
    /// DeepSeek 控制台（充值入口）
    static let consoleURL = URL(string: "https://platform.deepseek.com/usage")!

    /// 查询余额。返回 .success 表示 Key 有效；401/403 按「登录失效」处理（调用方转 unauthorized）。
    func fetchBalance(apiKey: String) async -> Result<DeepSeekBalance, QuotaError> {
        guard !apiKey.isEmpty else {
            return .failure(.invalidKeyFormat)
        }

        guard let url = URL(string: "https://api.deepseek.com/user/balance") else {
            return .failure(.invalidURL)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }

            if http.statusCode != 200 {
                let message = KimiCodeBarQuotaService.extractErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
                return .failure(.httpError(statusCode: http.statusCode, message: message))
            }

            guard let balance = parse(data) else {
                return .failure(.invalidResponse)
            }
            return .success(balance)
        } catch {
            return .failure(.networkError(error.localizedDescription))
        }
    }

    private func parse(_ data: Data) -> DeepSeekBalance? {
        struct Response: Codable {
            struct BalanceInfo: Codable {
                let currency: String?
                let totalBalance: String?
                let grantedBalance: String?
                let toppedUpBalance: String?

                enum CodingKeys: String, CodingKey {
                    case currency
                    case totalBalance = "total_balance"
                    case grantedBalance = "granted_balance"
                    case toppedUpBalance = "topped_up_balance"
                }
            }
            let isAvailable: Bool?
            let balanceInfos: [BalanceInfo]?

            enum CodingKeys: String, CodingKey {
                case isAvailable = "is_available"
                case balanceInfos = "balance_infos"
            }
        }

        guard let resp = try? JSONDecoder().decode(Response.self, from: data) else {
            return nil
        }

        let info = resp.balanceInfos?.first
        let currency = info?.currency ?? "CNY"
        let total = Double(info?.totalBalance ?? "0") ?? 0
        let granted = Double(info?.grantedBalance ?? "0") ?? 0
        let toppedUp = Double(info?.toppedUpBalance ?? "0") ?? 0

        return DeepSeekBalance(
            isAvailable: resp.isAvailable ?? true,
            currency: currency,
            totalBalance: total,
            grantedBalance: granted,
            toppedUpBalance: toppedUp
        )
    }
}
