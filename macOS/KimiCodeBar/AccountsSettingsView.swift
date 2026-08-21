import SwiftUI
import UniformTypeIdentifiers

// MARK: - 账号设置页

/// 设置窗口「账号管理」页：统一管理全部账号（列表 / 设主 / 重命名 / 删除 / 重新授权 / 添加账号）。
/// Kimi / DeepSeek / WorkBuddy 账号不分组，每个账号一张独立卡片。
/// 添加账号统一走「添加账号」弹窗选择平台。
/// 数据全部来自 KimiCodeBarModel.shared（统一账号管理数据层）。
struct AccountsSettingsView: View {
    @StateObject private var model = KimiCodeBarModel.shared
    @StateObject private var languageManager = LanguageManager.shared

    // 重命名弹窗状态
    @State private var renamingAccount: KimiAccount?
    @State private var renameText = ""
    @State private var showRenameAlert = false

    // 删除确认弹窗状态
    @State private var accountPendingDeletion: KimiAccount?
    @State private var showDeleteConfirm = false

    // CLI 切换确认弹窗状态
    @State private var cliSwitchTarget: KimiAccount?
    @State private var cliSwitchWarnings: [String] = []
    @State private var showCliSwitchConfirm = false
    @State private var cliSwitchError: String?

    // 添加账号：弹窗触发（弹窗内部自管平台选择 / API Key 表单 / 提交状态）
    @State private var showAddAccountSheet = false

    // 修改 API Key 弹窗状态
    @State private var editingKeyAccount: KimiAccount?
    @State private var editKeyInput = ""
    @State private var showEditKeyAlert = false
    @State private var editKeyError: String?

    // 拖拽排序状态：正在拖拽的账号 ID（用于被拖卡片降透明度 + 落点重置）
    @State private var draggingAccountID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 顶部标题 + 添加账号按钮
                HStack(spacing: 16) {
                    LText("账号管理")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.kimiTextPrimary)

                    Spacer()

                    AccountPrimaryButton(
                        title: languageManager.tr("添加账号"),
                        disabled: model.oauthLoginInProgress
                    ) {
                        showAddAccountSheet = true
                    }
                }

                // 授权中 / 授权失败提示
                if model.oauthLoginInProgress, let auth = model.oauthDeviceAuth {
                    SettingsCard {
                        AddAccountAuthorizingView(auth: auth)
                    }
                }

                if let error = model.oauthLoginError {
                    SettingsCard {
                        ErrorMessageView(message: error)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                }

                // 账号列表：Kimi / DeepSeek / WorkBuddy 不分组，每个账号一张独立卡片
                if model.accounts.isEmpty {
                    SettingsCard {
                        emptyState
                    }
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.accounts) { account in
                            SettingsCard {
                                AccountRow(
                                    accountID: account.id,
                                    draggingAccountID: $draggingAccountID,
                                    displayName: model.displayName(for: account),
                                    provider: account.provider,
                                    credential: account.credential,
                                    isPrimary: account.id == model.primaryAccountID,
                                    isCliActive: account.id == model.cliActiveAccountID,
                                    state: model.accountStates[account.id] ?? .idle,
                                    membershipLevel: model.accountQuotas[account.id]?.membershipLevel,
                                    reauthorizeDisabled: model.oauthLoginInProgress,
                                    onSwitchCli: { requestCliSwitch(account) },
                                    onRename: {
                                        renamingAccount = account
                                        if let alias = account.alias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
                                            renameText = alias
                                        } else {
                                            renameText = model.displayName(for: account)
                                        }
                                        showRenameAlert = true
                                    },
                                    onDelete: {
                                        accountPendingDeletion = account
                                        showDeleteConfirm = true
                                    },
                                    onReauthorize: { model.reauthorizeAccount(account.id) },
                                    onEditKey: {
                                        editingKeyAccount = account
                                        editKeyInput = ""
                                        showEditKeyAlert = true
                                    }
                                )
                            }
                            // 拖拽中的源卡片降低透明度，突出「被抓走」的感觉
                            .opacity(draggingAccountID == account.id ? 0.35 : 1)
                            // 每张卡片都是放置目标：拖入时实时把被拖账号挪到目标卡片位置
                            .onDrop(of: [.text], delegate: AccountReorderDropDelegate(
                                targetID: account.id,
                                model: model,
                                draggingAccountID: $draggingAccountID
                            ))
                        }
                    }
                    // 兜底放置区：落在卡片间隙时也正常结束拖拽、重置拖拽状态
                    .onDrop(of: [.text], delegate: AccountReorderDropDelegate(
                        targetID: nil,
                        model: model,
                        draggingAccountID: $draggingAccountID
                    ))
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 44)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.kimiPanelBackground)
        .onAppear { model.refreshCliActiveAccount() }
        .sheet(isPresented: $showAddAccountSheet) {
            AddAccountSheet(
                onOAuthStart: {
                    showAddAccountSheet = false
                    model.startOAuthLogin()
                },
                onDismiss: { showAddAccountSheet = false }
            )
            .environmentObject(model)
        }
        .alert(LanguageManager.tr("重命名账号"), isPresented: $showRenameAlert) {
            TextField(LanguageManager.tr("别名"), text: $renameText)
            Button(LanguageManager.tr("保存")) {
                if let account = renamingAccount {
                    model.renameAccount(account.id, alias: renameText)
                }
            }
            Button(LanguageManager.tr("取消"), role: .cancel) {}
        } message: {
            Text(LanguageManager.tr("为该账号设置一个便于区分的别名，留空则恢复默认名称。"))
        }
        .alert(LanguageManager.tr("删除账号"), isPresented: $showDeleteConfirm) {
            Button(LanguageManager.tr("删除"), role: .destructive) {
                if let account = accountPendingDeletion {
                    model.removeAccount(account.id)
                }
            }
            Button(LanguageManager.tr("取消"), role: .cancel) {}
        } message: {
            if let account = accountPendingDeletion {
                Text(LanguageManager.tr(
                    "确定删除「%1$@」吗？只会删除 Bar 中保存的授权，不影响对应客户端的登录状态。",
                    arguments: [model.displayName(for: account)]
                ))
            }
        }
        .alert(LanguageManager.tr("切换 CLI 账号"), isPresented: $showCliSwitchConfirm) {
            Button(LanguageManager.tr("仍然切换")) {
                if let account = cliSwitchTarget {
                    performCliSwitch(account)
                }
            }
            Button(LanguageManager.tr("取消"), role: .cancel) {}
        } message: {
            if let account = cliSwitchTarget {
                Text(LanguageManager.tr(
                    "将把「%1$@」的凭证写入 Kimi CLI，之后新启动的 CLI 会话将使用该账号。\n\n%2$@",
                    arguments: [model.displayName(for: account), cliSwitchWarnings.joined(separator: "\n\n")]
                ))
            }
        }
        .alert(LanguageManager.tr("切换失败"), isPresented: Binding(
            get: { cliSwitchError != nil },
            set: { if !$0 { cliSwitchError = nil } }
        )) {
            Button(LanguageManager.tr("好"), role: .cancel) {}
        } message: {
            if let cliSwitchError {
                Text(cliSwitchError)
            }
        }
        .alert(LanguageManager.tr("修改 API Key"), isPresented: $showEditKeyAlert) {
            SecureField(editingKeyAccount?.provider == .deepseek ? "sk-..." : "sk-kimi-...", text: $editKeyInput)
            Button(LanguageManager.tr("保存")) {
                if let account = editingKeyAccount {
                    let key = editKeyInput
                    Task {
                        if let error = await model.updateApiKey(for: account.id, key: key) {
                            editKeyError = error
                        }
                    }
                }
            }
            Button(LanguageManager.tr("取消"), role: .cancel) {}
        } message: {
            Text(LanguageManager.tr("输入新的 API Key，验证通过后立即生效。"))
        }
        .alert(LanguageManager.tr("修改失败"), isPresented: Binding(
            get: { editKeyError != nil },
            set: { if !$0 { editKeyError = nil } }
        )) {
            Button(LanguageManager.tr("好"), role: .cancel) {}
        } message: {
            if let editKeyError {
                Text(editKeyError)
            }
        }
    }

    // MARK: CLI 账号切换

    /// 点击「切换账号」：无风险时直接切换；
    /// CLI 现有凭证未保存到 Bar、或有运行中的 CLI 会话时，先弹确认框。
    private func requestCliSwitch(_ account: KimiAccount) {
        var warnings: [String] = []

        let cliToken = CliCredentialsService.loadToken()
        if cliToken != nil,
           CliCredentialsService.matchedAccountID(token: cliToken, in: model.accounts) == nil {
            warnings.append(LanguageManager.tr("CLI 当前登录的账号未保存到 Bar，切换后其凭证将被覆盖，需要重新登录才能恢复。"))
        }

        if CliCredentialsService.isKimiCliRunning() {
            warnings.append(LanguageManager.tr("检测到正在运行的 Kimi Code 会话：切换对它们不生效，且它们刷新登录状态时可能覆盖本次切换，建议先退出。"))
        }

        if warnings.isEmpty {
            performCliSwitch(account)
        } else {
            cliSwitchTarget = account
            cliSwitchWarnings = warnings
            showCliSwitchConfirm = true
        }
    }

    private func performCliSwitch(_ account: KimiAccount) {
        do {
            try model.switchCliAccount(to: account.id)
        } catch {
            cliSwitchError = LanguageManager.tr("无法写入 CLI 凭证文件：%@", arguments: [error.localizedDescription])
        }
    }

    // MARK: 空状态

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.kimiTextTertiary)

            LText("还没有添加账号")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.kimiTextPrimary)

            LText("添加账号后，即可在菜单栏查看各账号的配额使用情况")
                .font(.system(size: 12))
                .foregroundStyle(.kimiTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

// MARK: - 添加账号弹窗

/// 「添加账号」独立弹窗：一页铺开，不分步导航。
/// 上方选平台（当前 Kimi Code / DeepSeek，预留扩展位），下方按平台动态渲染：
/// - Kimi Code：OAuth 授权 / API Key 两种方式卡片，选 API Key 后展开 Key 输入区
/// - DeepSeek：仅 API Key，跳过方式选择直接给 Key 输入区
/// 提交成功或取消都关闭弹窗；OAuth 触发后由父视图接管（弹窗先关闭）。
private struct AddAccountSheet: View {
    /// OAuth 触发：父视图关闭弹窗 + 启动 OAuth 流程
    let onOAuthStart: () -> Void
    /// 取消 / 提交成功后关闭
    let onDismiss: () -> Void

    @EnvironmentObject private var model: KimiCodeBarModel
    @StateObject private var languageManager = LanguageManager.shared

    @State private var selectedProvider: AccountProvider = .kimi
    /// Kimi Code 选中「API Key 登录」方式后展开输入区；DeepSeek 始终展开
    @State private var kimiMethodSelected: AuthMethod? = nil
    @State private var apiKeyInput = ""
    @State private var apiKeyAlias = ""
    @State private var isAddingApiKey = false
    @State private var apiKeyError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题区
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(providerBadgeBackground)

                    Image(selectedProvider.logoImageName)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(5)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    LText("添加账号")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.kimiTextPrimary)

                    LText("选择平台与登录方式")
                        .font(.system(size: 11))
                        .foregroundStyle(.kimiTextSecondary)
                }

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.kimiTextSecondary)
                        .frame(width: 24, height: 24)
                        .background(Color.kimiTextPrimary.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            SettingsCardDivider()

            // 平台选择区
            VStack(alignment: .leading, spacing: 8) {
                LText("选择平台")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.kimiTextSecondary)

                // 2 列网格布局，超过 2 个平台自动换行；当前 3 个 → 2×2，第三格留空
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10)
                    ],
                    spacing: 10
                ) {
                    ForEach(AccountProvider.allCases) { provider in
                        providerCard(provider)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            SettingsCardDivider()

            // 动态内容区：按平台切换
            VStack(alignment: .leading, spacing: 10) {
                Text(dynamicSectionTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.kimiTextSecondary)

                if selectedProvider == .workbuddy {
                    workBuddyAddEntry
                } else if selectedProvider == .deepseek {
                    apiKeyInputArea
                } else if selectedProvider == .antigravity {
                    antigravityAddEntry
                } else {
                    // Kimi Code：方式卡片 + 选中 API Key 时展开输入区
                    VStack(spacing: 8) {
                        ForEach(selectedProvider.supportedAuthMethods, id: \.self) { method in
                            SettingsOptionCard(
                                title: methodTitle(method),
                                subtitle: methodSubtitle(method),
                                iconName: method == .oauth ? "person.badge.key" : "key",
                                isSelected: kimiMethodSelected == method
                            ) {
                                handleKimiMethodTap(method)
                            }
                        }

                        if kimiMethodSelected == .apiKey {
                            apiKeyInputArea
                                .padding(.top, 4)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            if let apiKeyError {
                SettingsCardDivider()
                ErrorMessageView(message: apiKeyError)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
        }
        .frame(width: 440)
        .background(Color.kimiCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: 平台卡片

    private func providerCard(_ provider: AccountProvider) -> some View {
        let isSelected = selectedProvider == provider
        return Button(action: {
            selectedProvider = provider
            // 切换平台时重置 Kimi 的方式选择与错误
            kimiMethodSelected = nil
            apiKeyError = nil
        }) {
            HStack(spacing: 10) {
                Image(provider.logoImageName)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22)
                    .padding(3)
                    .background(
                        Circle().fill(isSelected ? Color.kimiBlue.opacity(0.12) : Color.kimiTextPrimary.opacity(0.06))
                    )

                Text(provider.displayName)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(.kimiTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 4)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? .kimiBlue : .kimiTextTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected
                          ? Color.kimiBlue.opacity(0.08)
                          : Color.kimiTextPrimary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.kimiBlue.opacity(0.5) : Color.kimiTextPrimary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
    }

    // MARK: Kimi 方式处理

    private func handleKimiMethodTap(_ method: AuthMethod) {
        if method == .oauth {
            onOAuthStart()
        } else {
            kimiMethodSelected = .apiKey
            apiKeyError = nil
        }
    }

    private func methodTitle(_ method: AuthMethod) -> String {
        switch method {
        case .oauth: return languageManager.tr("授权登录")
        case .apiKey: return languageManager.tr("API Key 登录")
        case .localRead: return languageManager.tr("读取本地")
        }
    }

    private func methodSubtitle(_ method: AuthMethod) -> String {
        switch method {
        case .oauth: return languageManager.tr("浏览器授权，推荐")
        case .apiKey: return languageManager.tr("手动填写 API Key")
        case .localRead: return languageManager.tr("无需输入，自动读取")
        }
    }

    /// 弹窗标题图标底色：跟随平台品牌色
    private var providerBadgeBackground: Color {
        switch selectedProvider {
        case .kimi:
            return .kimiTextPrimary.opacity(0.08)
        case .deepseek:
            return Color(red: 0.34, green: 0.53, blue: 1.00).opacity(0.10)
        case .workbuddy:
            return Color(red: 0.42, green: 0.30, blue: 1.00).opacity(0.10)
        case .antigravity:
            return Color(red: 0.20, green: 0.60, blue: 0.86).opacity(0.10)
        }
    }

    /// 动态内容区的章节标题
    private var dynamicSectionTitle: String {
        switch selectedProvider {
        case .deepseek: return languageManager.tr("输入 DeepSeek API Key")
        case .workbuddy: return languageManager.tr("选择登录方式")
        case .antigravity: return languageManager.tr("登录 Google 账号")
        case .kimi: return languageManager.tr("选择登录方式")
        }
    }

    // MARK: WorkBuddy 添加入口

    /// WorkBuddy 平台添加入口：从 WorkBuddy 桌面端 auth 文件读取当前登录账号。
    @State private var isReadingWorkBuddy = false

    private var workBuddyAddEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.kimiTextTertiary)
                LText("从 WorkBuddy 桌面端读取")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.kimiTextSecondary)
            }

            LText("需先在 WorkBuddy 客户端登录目标账号，再点下方按钮读取本地登录信息。")
                .font(.system(size: 11))
                .foregroundStyle(.kimiTextTertiary)

            HStack(spacing: 10) {
                Button(action: { submitWorkBuddyAdd() }) {
                    Text(isReadingWorkBuddy ? languageManager.tr("读取中…") : languageManager.tr("读取本地"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.kimiTextSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.kimiTextPrimary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
                .disabled(isReadingWorkBuddy)

                if isReadingWorkBuddy {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Button(action: onDismiss) {
                    Text(languageManager.tr("取消"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.kimiTextSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
                .disabled(isReadingWorkBuddy)
            }

            if let apiKeyError {
                ErrorMessageView(message: apiKeyError)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func submitWorkBuddyAdd() {
        isReadingWorkBuddy = true
        Task {
            // addWorkBuddyAccount 是 MainActor 方法，在 SwiftUI Task 里调用
            let error = await MainActor.run {
                KimiCodeBarModel.shared.addWorkBuddyAccount()
            }
            isReadingWorkBuddy = false
            if let error {
                apiKeyError = error
            } else {
                onDismiss()
            }
        }
    }

    // MARK: Antigravity 添加入口

    @State private var isLoggingInAntigravity = false

    private var antigravityAddEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.kimiTextTertiary)
                LText("点击下方按钮将在默认浏览器中打开 Google 授权页面，授权完成后自动添加该 Antigravity 账号。")
                    .font(.system(size: 12))
                    .foregroundStyle(.kimiTextSecondary)
            }
            .padding(10)
            .background(Color.kimiTextPrimary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 10) {
                AccountPrimaryButton(
                    title: isLoggingInAntigravity ? languageManager.tr("授权中…") : languageManager.tr("使用 Google 登录"),
                    disabled: isLoggingInAntigravity,
                    action: { submitAntigravityOAuth() }
                )

                if isLoggingInAntigravity {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Button(action: onDismiss) {
                    Text(languageManager.tr("取消"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.kimiTextSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
                .disabled(isLoggingInAntigravity)
            }
        }
    }

    private func submitAntigravityOAuth() {
        isLoggingInAntigravity = true
        apiKeyError = nil
        Task {
            let error = await KimiCodeBarModel.shared.startAntigravityOAuthLogin()
            await MainActor.run {
                isLoggingInAntigravity = false
                if let error {
                    apiKeyError = error
                } else {
                    onDismiss()
                }
            }
        }
    }

    // MARK: API Key 输入区

    private var apiKeyInputArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            SecureField(selectedProvider == .kimi ? "sk-kimi-..." : "sk-...", text: $apiKeyInput)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.kimiTextPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.kimiTextPrimary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            TextField(LanguageManager.tr("别名（可选）"), text: $apiKeyAlias)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.kimiTextPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.kimiTextPrimary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 10) {
                AccountPrimaryButton(
                    title: isAddingApiKey ? languageManager.tr("验证中…") : languageManager.tr("确认新增"),
                    disabled: apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAddingApiKey
                ) {
                    submitApiKey()
                }

                if isAddingApiKey {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Button(action: onDismiss) {
                    Text(languageManager.tr("取消"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.kimiTextSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
                .disabled(isAddingApiKey)
            }
        }
    }

    // MARK: 提交

    private func submitApiKey() {
        isAddingApiKey = true
        apiKeyError = nil
        let provider = selectedProvider
        let key = apiKeyInput
        let alias = apiKeyAlias.isEmpty ? nil : apiKeyAlias
        Task {
            let error = await model.addApiKeyAccount(provider: provider, key: key, alias: alias)
            isAddingApiKey = false
            if let error {
                apiKeyError = error
            } else {
                onDismiss()
            }
        }
    }
}

// MARK: - 账号行

private struct AccountRow: View {
    let accountID: UUID
    @Binding var draggingAccountID: UUID?
    let displayName: String
    let provider: AccountProvider
    let credential: AccountCredential
    let isPrimary: Bool
    let isCliActive: Bool
    let state: KimiAccountState
    let membershipLevel: String?
    let reauthorizeDisabled: Bool
    let onSwitchCli: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onReauthorize: () -> Void
    let onEditKey: () -> Void

    @StateObject private var languageManager = LanguageManager.shared
    @State private var isHoveredGrip = false

    /// 是否走 OAuth 流程（可重新授权）：Kimi OAuth、Antigravity OAuth 属于此类。
    /// WorkBuddy 也按 OAuth 展示会员等级标签，但不提供重新授权按钮（仅支持本地读取）。
    /// API Key 账号走「修改 Key」入口，不在此列。
    private var isOAuth: Bool {
        if case .oauth = credential { return true }
        if case .antigravity = credential { return true }
        if case .workbuddy = credential { return true }
        return false
    }

    /// API Key 脱敏展示：长 Key 取首尾各 4 位 + 4 颗星，短 Key 原样显示
    private var maskedApiKey: String? {
        guard case .apiKey(let key) = credential else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 12 else { return trimmed }
        let head = trimmed.prefix(4)
        let tail = trimmed.suffix(4)
        return "\(head)****\(tail)"
    }

    /// 账号头像：渲染对应平台官方 logo（Kimi 文字 logo / DeepSeek 鲸鱼），
    /// 圆角方块底色沿用品牌色微调。
    private var avatar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(avatarBackground)

            Image(provider.logoImageName)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .padding(5)
        }
        .frame(width: 28, height: 28)
    }

    private var avatarBackground: Color {
        switch provider {
        case .kimi:
            return .kimiTextPrimary.opacity(0.08)
        case .deepseek:
            return Color(red: 0.34, green: 0.53, blue: 1.00).opacity(0.10)
        case .workbuddy:
            return Color(red: 0.42, green: 0.30, blue: 1.00).opacity(0.10)
        case .antigravity:
            return Color(red: 0.20, green: 0.60, blue: 0.86).opacity(0.10)
        }
    }

    /// 拖拽抓手：悬停显示抓住光标并提亮，按住即可上下拖动排序。
    /// 拖拽只从抓手发起，卡片内按钮的点击/悬停不受影响。
    private var gripHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(isHoveredGrip ? Color.kimiTextPrimary : Color.kimiTextTertiary)
            .frame(width: 14, height: 28)
            .contentShape(Rectangle())
            .onHover { isHoveredGrip = $0 }
            .cursor(.openHand)
            .help(languageManager.tr("按住拖动排序"))
            .onDrag {
                draggingAccountID = accountID
                return NSItemProvider(object: accountID.uuidString as NSString)
            } preview: {
                // 拖拽预览：跟随鼠标的迷你卡片（平台 logo + 显示名）
                HStack(spacing: 8) {
                    avatar
                    Text(displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.kimiTextPrimary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.kimiCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.kimiTextPrimary.opacity(0.12), lineWidth: 1)
                )
            }
    }

    var body: some View {
        HStack(spacing: 12) {
            gripHandle

            avatar

            // 单行：名称 + 脱敏 Key + 状态标签
            HStack(spacing: 6) {
                Text(displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.kimiTextPrimary)
                    .lineLimit(1)

                // API Key 账号：脱敏 Key 紧跟名称后，不支持显隐切换
                if !isOAuth, let masked = maskedApiKey {
                    Text(masked)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.kimiTextTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if isCliActive {
                    StatusTag(text: languageManager.tr("CLI 使用中"), color: .green)
                }

                // 会员等级体系调整期：API Key 渠道取到的等级不可靠，暂只对 OAuth 账号展示
                if isOAuth, let membershipLevel, !membershipLevel.isEmpty {
                    StatusTag(text: KimiQuota.membershipDisplayName(membershipLevel), color: .purple)
                }

                if case .unauthorized = state {
                    StatusTag(text: languageManager.tr("登录失效"), color: .red)
                }
            }

            Spacer(minLength: 8)

            // 右侧：全部操作按钮
            HStack(spacing: 8) {
                AccountActionButton(
                    title: languageManager.tr("重命名"),
                    action: onRename
                )

                if case .unauthorized = state {
                    // WorkBuddy 不展示重新授权/修改 Key 按钮，token 失效后用户需重新读取本地或删除账号
                    if isOAuth, provider != .workbuddy {
                        AccountActionButton(
                            title: languageManager.tr("重新授权"),
                            color: .kimiBlue,
                            hoveredColor: .kimiBlue,
                            disabled: reauthorizeDisabled,
                            action: onReauthorize
                        )
                    } else if provider != .workbuddy {
                        AccountActionButton(
                            title: languageManager.tr("修改 Key"),
                            color: .kimiBlue,
                            hoveredColor: .kimiBlue,
                            action: onEditKey
                        )
                    }
                } else if isOAuth && provider == .kimi {
                    AccountActionButton(
                        title: languageManager.tr("切换账号"),
                        disabled: isCliActive,
                        action: onSwitchCli
                    )
                    .help(languageManager.tr("将该账号的凭证写入 Kimi CLI，更换 CLI 的登录账号"))
                }

                AccountActionButton(
                    title: languageManager.tr("删除"),
                    destructive: true,
                    action: onDelete
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - 账号拖拽排序

/// 账号卡片放置代理：拖入目标卡片时实时把被拖账号挪到目标位置（带动画），
/// 放下时落盘完成排序。targetID 为 nil 时是卡片间隙的兜底放置区，只负责结束拖拽。
private struct AccountReorderDropDelegate: DropDelegate {
    let targetID: UUID?
    let model: KimiCodeBarModel
    @Binding var draggingAccountID: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    func dropEntered(info: DropInfo) {
        guard let targetID,
              let draggingID = draggingAccountID,
              draggingID != targetID,
              let from = model.accounts.firstIndex(where: { $0.id == draggingID }),
              let to = model.accounts.firstIndex(where: { $0.id == targetID }) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            model.moveAccount(from: from, to: to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingAccountID = nil
        return true
    }
}

// MARK: - 添加账号授权引导

/// 设备授权流程进行中的引导界面：授权码 + 复制 + 复制授权链接 + 取消。
/// 不自动呼出浏览器（浏览器可能登录着其他账号），由用户复制链接后自行选择浏览器打开。
/// 视觉对齐 BasicSettingsView 的 OAuth 授权中区域。
private struct AddAccountAuthorizingView: View {
    let auth: KimiDeviceAuthorization

    @StateObject private var model = KimiCodeBarModel.shared

    @State private var isHoveredCopyCode = false
    @State private var isHoveredCopyLink = false
    @State private var isHoveredOpen = false
    @State private var isCodeCopied = false
    @State private var isLinkCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 状态行
            HStack(spacing: 10) {
                LoadingRing()
                    .frame(width: 16, height: 16)

                LText("等待授权…")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.kimiTextPrimary)

                Spacer()

                CancelChipButton(title: LanguageManager.tr("取消")) {
                    model.cancelOAuthLogin()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            SettingsCardDivider()

            // 授权码行
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    LText("授权码")
                        .font(.system(size: 12))
                        .foregroundStyle(.kimiTextSecondary)

                    Text(auth.userCode)
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(.kimiTextPrimary)
                        .textSelection(.enabled)
                }

                Spacer()

                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(auth.userCode, forType: .string)
                    isCodeCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        isCodeCopied = false
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: isCodeCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                        LText(isCodeCopied ? "已复制" : "复制")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(isHoveredCopyCode ? .kimiTextPrimary : .kimiTextSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(isHoveredCopyCode ? Color.kimiTextPrimary.opacity(0.14) : Color.kimiTextPrimary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
                .onHover { isHoveredCopyCode = $0 }

                if let urlString = auth.displayURL {
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(urlString, forType: .string)
                        isLinkCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            isLinkCopied = false
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: isLinkCopied ? "checkmark" : "link")
                                .font(.system(size: 11, weight: .medium))
                            LText(isLinkCopied ? "已复制" : "复制授权链接")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(isHoveredCopyLink ? .white : .white.opacity(0.9))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(isHoveredCopyLink ? Color.kimiBlue.opacity(0.85) : Color.kimiBlue)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .cursor(.pointingHand)
                    .onHover { isHoveredCopyLink = $0 }

                    if let url = URL(string: urlString) {
                        Button(action: { NSWorkspace.shared.open(url) }) {
                            HStack(spacing: 4) {
                                Image(systemName: "safari")
                                    .font(.system(size: 11, weight: .medium))
                                LText("打开授权页")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(isHoveredOpen ? .kimiTextPrimary : .kimiTextSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(isHoveredOpen ? Color.kimiTextPrimary.opacity(0.14) : Color.kimiTextPrimary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .cursor(.pointingHand)
                        .onHover { isHoveredOpen = $0 }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
    }
}

// MARK: - 取消按钮（小号）

/// 卡片右上角的小号「取消」按钮：悬停高亮 + 手型光标。
private struct CancelChipButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered ? .kimiTextPrimary : .kimiTextSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isHovered ? Color.kimiTextPrimary.opacity(0.14) : Color.kimiTextPrimary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .onHover { isHovered = $0 }
    }
}

// MARK: - 主按钮（蓝色）

private struct AccountPrimaryButton: View {
    let title: String
    var disabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(disabled ? Color.kimiBlue.opacity(0.6) : (isHovered ? Color.kimiBlue.opacity(0.85) : Color.kimiBlue))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .cursor(disabled ? .arrow : .pointingHand)
        .onHover { isHovered = $0 }
    }
}

// MARK: - 行操作按钮

/// 账号行内的小号操作按钮：悬停高亮 + 手型光标；禁用态降低视觉权重并恢复箭头光标。
private struct AccountActionButton: View {
    let title: String
    var color: Color = .kimiTextSecondary
    var hoveredColor: Color = .kimiTextPrimary
    var destructive: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .cursor(disabled ? .arrow : .pointingHand)
        .onHover { isHovered = $0 }
    }

    private var foreground: Color {
        if disabled { return .kimiTextTertiary }
        if destructive { return isHovered ? .red.opacity(0.9) : .red }
        return isHovered ? hoveredColor : color
    }

    private var background: Color {
        if disabled { return Color.kimiTextPrimary.opacity(0.04) }
        if destructive { return isHovered ? Color.red.opacity(0.18) : Color.red.opacity(0.12) }
        return isHovered ? Color.kimiTextPrimary.opacity(0.14) : Color.kimiTextPrimary.opacity(0.08)
    }
}
