import Foundation

// MARK: - 账号平台

/// 账号所属平台。
/// 扩展新平台时的接入点：
/// 1. 这里加 case 并填 displayName / iconName / logoImageName / supportedAuthMethods；
/// 2. KimiCodeBarModel.refreshAllAccounts 中按 provider 分派对应平台的配额服务
///    （kimi → service.fetchQuota，deepseek → deepseekService.fetchBalance）；
/// 3. 设置页账号行与面板卡片按 provider 渲染。
/// 4. WorkBuddy 走 KimiAccount 统一体系，积分由 refreshWorkBuddyAccounts() 独立刷新。
enum AccountProvider: String, Codable, CaseIterable, Identifiable {
    case kimi
    case deepseek
    case workbuddy

    var id: String { rawValue }

    /// 品牌名，不做本地化
    var displayName: String {
        switch self {
        case .kimi: return "Kimi Code"
        case .deepseek: return "DeepSeek"
        case .workbuddy: return "WorkBuddy"
        }
    }

    var iconName: String {
        switch self {
        case .kimi: return "k.circle"
        case .deepseek: return "d.circle"
        case .workbuddy: return "w.circle"
        }
    }

    /// 账号行头像 / 平台卡 / 弹窗引用的官方品牌 logo（Assets.xcassets）。
    /// Kimi logo 自带 light/dark 双版，深浅模式自动切换。
    /// DeepSeek logo 品牌蓝在两种背景下都可见，单版本即可。
    /// WorkBuddy logo 紫色两种背景下都可见，单版本即可。
    var logoImageName: String {
        switch self {
        case .kimi: return "kimi-logo"
        case .deepseek: return "deepseek-logo"
        case .workbuddy: return "workbuddy-logo"
        }
    }

    /// 该平台支持的登录方式
    var supportedAuthMethods: [AuthMethod] {
        switch self {
        case .kimi: return [.oauth, .apiKey]
        case .deepseek: return [.apiKey]
        case .workbuddy: return [.localRead]
        }
    }
}

/// 账号登录方式
enum AuthMethod {
    case oauth
    case apiKey
    /// 本地文件读取（WorkBuddy：从 auth 文件读取，无需用户输入任何东西）
    case localRead
}

/// 账号数据拉取结果：按平台区分，避免 KimiQuota 与 DeepSeekBalance 强行统一抽象。
/// refreshAllAccounts 的 task group 用它汇总各账号拉取结果。
enum AccountFetchResult: Sendable {
    case kimi(KimiQuota)
    case deepseek(DeepSeekBalance)
    case workbuddy(WorkBuddyCredits)
}

// MARK: - 账号凭证

/// 账号凭证：OAuth token 对（可刷新、可写入 CLI）或 API Key（静态密钥，直接当 Bearer token 用）。
enum AccountCredential: Codable, Equatable {
    case oauth(KimiOAuthToken)
    case apiKey(String)
    case workbuddy(WorkBuddyCredential)
}

/// WorkBuddy 账号凭证：token 对 + 快照 + 签到日期。
/// 与 Kimi OAuth / DeepSeek API Key 并列，作为 AccountCredential 的一个 case。
struct WorkBuddyCredential: Codable, Equatable {
    /// WorkBuddy 用户 ID（用于 auth 文件读写、API 调用）
    var uid: String
    /// 客户端昵称（别名 alias 为空时的回退显示名）
    var nickname: String
    var accessToken: String
    var refreshToken: String
    var domain: String
    /// auth 文件里完整的 account 块原始 JSON（切换账号时整体写回）
    var accountSnapshot: Data?
    /// auth 文件里完整的 auth 块原始 JSON
    var authSnapshot: Data?
    /// 最近签到日期（北京时间 yyyy-MM-dd），nil 表示今日未签到
    var lastCheckinDate: String?

    var isApiKeyMode: Bool { accessToken.hasPrefix("ck_") }
    var hasSnapshot: Bool { accountSnapshot != nil && authSnapshot != nil }
}

// MARK: - 账号模型

/// 一个受监控账号：平台 + 凭证 + 用户别名 + 可选的账号唯一标识（添加时去重用）。
struct KimiAccount: Codable, Equatable, Identifiable {
    var id: UUID
    /// 用户自定义别名；为空时界面回退显示「账号 N」
    var alias: String?
    var provider: AccountProvider
    var credential: AccountCredential
    /// 账号唯一标识（来自 usages 接口 user 对象，如 id/phone/email；取不到为 nil，仅做尽力去重）
    var accountIdentifier: String?

    /// CLI 切换等只认 OAuth token 对的场景使用；API Key 账号为 nil
    var oauthToken: KimiOAuthToken? {
        if case .oauth(let token) = credential { return token }
        return nil
    }

    /// WorkBuddy 凭证便捷访问
    var workBuddyCredential: WorkBuddyCredential? {
        if case .workbuddy(let cred) = credential { return cred }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case id
        case alias
        case provider
        case credential
        case accountIdentifier = "account_identifier"
    }
}

// MARK: - 账号状态

/// 单个账号的配额加载状态
enum KimiAccountState: Equatable {
    /// 尚未加载
    case idle
    /// 加载中
    case loading
    /// 正常（配额已就绪）
    case loaded
    /// 加载失败（网络等原因），附带失败原因
    case failed(String)
    /// 登录失效（refresh_token 被吊销 / API Key 无效等），保留凭证等待用户重新授权或修改 Key
    case unauthorized
}

// MARK: - 账号存储

/// 多账号凭证存储：accounts 数组 + 主账号 ID，持久化到 credentials.json。
/// 所有写操作在锁内串行完成并原子落盘，避免多账号并行刷新 token 时写文件竞争。
///
/// 磁盘格式仅支持当前版本（provider + credential）。旧版格式（顶层 token 字段、
/// 或更早的单 token 文件）解码失败即视为无账号——用户量小且旧版均为单账号，
/// 升级后重新登录即可，不做迁移。
final class KimiAccountStore {
    static let shared = KimiAccountStore()

    /// credentials.json 的磁盘格式（账号数组 + 主账号 ID）
    struct FileFormat: Codable, Equatable {
        var accounts: [KimiAccount]
        var primaryAccountID: UUID?

        enum CodingKeys: String, CodingKey {
            case accounts
            case primaryAccountID = "primary_account_id"
        }
    }

    private let lock = NSLock()
    private var fileFormat: FileFormat

    private init() {
        fileFormat = Self.loadFromDisk() ?? FileFormat(accounts: [], primaryAccountID: nil)
    }

    // MARK: 路径

    /// Bar 专属的凭证存储路径。
    /// 注意：刻意与 KimiCode CLI 的 ~/.kimi-code/credentials/kimi-code.json 隔离，
    /// Bar 的授权、刷新、删除账号都只操作本文件，绝不读写 CLI 的凭证，
    /// 避免因 refresh_token 服务端轮换导致 CLI 凭证失效。
    static func credentialsFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("KimiCodeBar/credentials.json")
    }

    // MARK: 读取

    /// 当前内存中的账号快照
    var snapshot: FileFormat {
        lock.lock()
        defer { lock.unlock() }
        return fileFormat
    }

    func account(id: UUID) -> KimiAccount? {
        snapshot.accounts.first(where: { $0.id == id })
    }

    /// 从磁盘重读，覆盖内存状态。
    /// 用于刷新周期开始时同步其他 Bar 实例的写入。
    func reload() {
        guard let format = Self.loadFromDisk() else { return }
        lock.lock()
        fileFormat = format
        lock.unlock()
    }

    /// 直接从磁盘读取单个账号（不动内存状态）。
    /// 用于「刷新 token 前再读一次磁盘」的防御逻辑（按账号维度）。
    func freshAccount(id: UUID) -> KimiAccount? {
        Self.loadFromDisk()?.accounts.first(where: { $0.id == id })
    }

    // MARK: 写入（全部串行 + 原子落盘）

    func addAccount(_ account: KimiAccount) {
        mutate { $0.accounts.append(account) }
    }

    /// 删除账号；若删除的是主账号，仅清空主账号 ID，顺延策略由调用方决定
    func removeAccount(id: UUID) {
        mutate {
            $0.accounts.removeAll(where: { $0.id == id })
            if $0.primaryAccountID == id {
                $0.primaryAccountID = nil
            }
        }
    }

    /// 更新 OAuth 账号的 token（重新授权 / 刷新 token 后落盘）
    func updateOAuthToken(id: UUID, token: KimiOAuthToken) {
        mutate { format in
            guard let index = format.accounts.firstIndex(where: { $0.id == id }) else { return }
            format.accounts[index].credential = .oauth(token)
        }
    }

    /// 更新 API Key 账号的密钥（修改 Key 后落盘）
    func updateApiKey(id: UUID, key: String) {
        mutate { format in
            guard let index = format.accounts.firstIndex(where: { $0.id == id }) else { return }
            format.accounts[index].credential = .apiKey(key)
        }
    }

    /// 更新 WorkBuddy 账号的凭证（token 刷新后落盘）
    func updateWorkBuddyCredential(id: UUID, credential: WorkBuddyCredential) {
        mutate { format in
            guard let index = format.accounts.firstIndex(where: { $0.id == id }) else { return }
            format.accounts[index].credential = .workbuddy(credential)
        }
    }

    /// 更新 WorkBuddy 账号的签到日期
    func updateWorkBuddyCheckinDate(id: UUID, date: String) {
        mutate { format in
            guard let index = format.accounts.firstIndex(where: { $0.id == id }),
                  case .workbuddy(var cred) = format.accounts[index].credential else { return }
            cred.lastCheckinDate = date
            format.accounts[index].credential = .workbuddy(cred)
        }
    }

    func updateAccountIdentifier(id: UUID, identifier: String?) {
        mutate { format in
            guard let index = format.accounts.firstIndex(where: { $0.id == id }) else { return }
            format.accounts[index].accountIdentifier = identifier
        }
    }

    func setAlias(id: UUID, alias: String?) {
        mutate { format in
            guard let index = format.accounts.firstIndex(where: { $0.id == id }) else { return }
            format.accounts[index].alias = alias
        }
    }

    func setPrimaryAccount(_ id: UUID?) {
        mutate { $0.primaryAccountID = id }
    }

    /// 主账号兜底：主账号 ID 为空或已不存在时，顺延为第一个账号；无账号时清空
    func ensurePrimaryAccount() {
        lock.lock()
        let before = fileFormat
        if fileFormat.accounts.isEmpty {
            fileFormat.primaryAccountID = nil
        } else {
            let valid = fileFormat.primaryAccountID.flatMap { pid in
                fileFormat.accounts.contains(where: { $0.id == pid }) ? pid : nil
            }
            if valid == nil {
                fileFormat.primaryAccountID = fileFormat.accounts.first?.id
            }
        }
        if fileFormat != before {
            saveLocked()
        }
        lock.unlock()
    }

    // MARK: 私有

    /// 串行化所有写操作：修改内存状态后立即原子落盘
    private func mutate(_ body: (inout FileFormat) -> Void) {
        lock.lock()
        body(&fileFormat)
        saveLocked()
        lock.unlock()
    }

    /// 从磁盘加载。返回 nil 表示文件不存在或格式不是当前版本（旧格式按无账号处理）。
    private static func loadFromDisk() -> FileFormat? {
        let url = credentialsFileURL()
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FileFormat.self, from: data)
    }

    /// 原子写入：目录 0700，文件 0600。调用前必须已持有 lock（init 除外）。
    private func saveLocked() {
        let url = Self.credentialsFileURL()
        let directory = url.deletingLastPathComponent()

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(fileFormat)

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
        } catch {
            // 落盘失败不致命：内存状态已更新，下次写入会重试
        }
    }
}
