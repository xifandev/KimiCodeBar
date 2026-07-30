import Foundation

// MARK: - 账号模型

/// 一个 Kimi 账号：OAuth token + 用户别名 + 可选的账号唯一标识（添加时去重用）。
struct KimiAccount: Codable, Equatable, Identifiable {
    var id: UUID
    /// 用户自定义别名；为空时界面回退显示「账号 N」
    var alias: String?
    var token: KimiOAuthToken
    /// 账号唯一标识（来自 usages 接口 user 对象，如 id/phone/email；取不到为 nil，仅做尽力去重）
    var accountIdentifier: String?

    enum CodingKeys: String, CodingKey {
        case id
        case alias
        case token
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
    /// 登录失效（refresh_token 被吊销等），保留凭证等待用户重新授权
    case unauthorized
}

// MARK: - 账号存储

/// 多账号凭证存储：accounts 数组 + 主账号 ID，持久化到 credentials.json。
/// 旧版单 token 格式读取时自动迁移为一个账号并设为主账号。
/// 所有写操作在锁内串行完成并原子落盘，避免多账号并行刷新 token 时写文件竞争。
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
        let loaded = Self.loadFromDisk()
        fileFormat = loaded?.format ?? FileFormat(accounts: [], primaryAccountID: nil)
        // 旧格式迁移成功，立即以新格式落盘
        if loaded?.migrated == true {
            saveLocked()
        }
    }

    // MARK: 路径

    /// Bar 专属的凭证存储路径（与旧单 token 文件相同）。
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

    /// 从磁盘重读（含旧格式迁移），覆盖内存状态。
    /// 用于刷新周期开始时同步其他 Bar 实例的写入。
    func reload() {
        guard let loaded = Self.loadFromDisk() else { return }
        lock.lock()
        fileFormat = loaded.format
        if loaded.migrated {
            saveLocked()
        }
        lock.unlock()
    }

    /// 直接从磁盘读取单个账号（不动内存状态）。
    /// 用于「刷新 token 前再读一次磁盘」的防御逻辑（按账号维度）。
    func freshAccount(id: UUID) -> KimiAccount? {
        Self.loadFromDisk()?.format.accounts.first(where: { $0.id == id })
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

    func updateToken(id: UUID, token: KimiOAuthToken) {
        mutate { format in
            guard let index = format.accounts.firstIndex(where: { $0.id == id }) else { return }
            format.accounts[index].token = token
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

    /// 从磁盘加载。返回 nil 表示文件不存在或两种格式都解析失败。
    private static func loadFromDisk() -> (format: FileFormat, migrated: Bool)? {
        let url = credentialsFileURL()
        guard let data = try? Data(contentsOf: url) else { return nil }

        let decoder = JSONDecoder()
        // 新格式：账号数组 + 主账号 ID
        if let format = try? decoder.decode(FileFormat.self, from: data) {
            return (format, false)
        }
        // 旧格式：单个 token，自动迁移为一个账号并设为主账号
        if let token = try? decoder.decode(KimiOAuthToken.self, from: data), token.isValid {
            let account = KimiAccount(id: UUID(), alias: nil, token: token, accountIdentifier: nil)
            return (FileFormat(accounts: [account], primaryAccountID: account.id), true)
        }
        return nil
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
