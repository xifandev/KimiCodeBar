import SwiftUI

// MARK: - 账号设置页

/// 设置窗口「账号管理」页：统一管理全部账号（列表 / 设主 / 重命名 / 删除 / 重新授权 / 添加账号）。
/// 添加账号支持两种方式：浏览器授权登录（OAuth）与 API Key 登录，用户自选。
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

    /// 是否展示「添加账号」卡片：
    /// 有账号、授权流程进行中、或授权失败有待展示的错误时展示。
    /// 平台 / Key 表单全部移到 sheet 内，主面板不再承担表单态。
    private var showsAddAccountCard: Bool {
        !model.accounts.isEmpty || model.oauthLoginInProgress || model.oauthLoginError != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LText("账号管理")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.kimiTextPrimary)

                // 账号列表：每个账号一张独立卡片
                if model.accounts.isEmpty {
                    SettingsCard {
                        emptyState
                    }
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.accounts) { account in
                            SettingsCard {
                                AccountRow(
                                    displayName: model.displayName(for: account),
                                    credential: account.credential,
                                    isPrimary: account.id == model.primaryAccountID,
                                    isCliActive: account.id == model.cliActiveAccountID,
                                    state: model.accountStates[account.id] ?? .idle,
                                    membershipLevel: model.accountQuotas[account.id]?.membershipLevel,
                                    reauthorizeDisabled: model.oauthLoginInProgress,
                                    onSetPrimary: { model.setPrimaryAccount(account.id) },
                                    onSwitchCli: { requestCliSwitch(account) },
                                    onRename: {
                                        renamingAccount = account
                                        renameText = account.alias ?? ""
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
                        }
                    }
                }

                // 添加账号 / 授权引导
                if showsAddAccountCard {
                    SettingsCard {
                        VStack(alignment: .leading, spacing: 0) {
                            if model.oauthLoginInProgress, let auth = model.oauthDeviceAuth {
                                AddAccountAuthorizingView(auth: auth)
                            } else {
                                addAccountRow
                            }

                            if let error = model.oauthLoginError {
                                SettingsCardDivider()
                                ErrorMessageView(message: error)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                            }
                        }
                    }
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
                    // 空白别名 = 清除别名，恢复默认「账号 N」
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
                    "确定删除「%1$@」吗？只会删除 Bar 中保存的授权，不影响 Kimi CLI 的登录状态。",
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

            AccountPrimaryButton(
                title: languageManager.tr("添加账号"),
                disabled: model.oauthLoginInProgress
            ) {
                showAddAccountSheet = true
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: 添加账号入口行

    private var addAccountRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.badge.plus")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.kimiTextTertiary)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                LText("添加账号")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.kimiTextPrimary)

                LText("授权登录或 API Key 登录")
                    .font(.system(size: 12))
                    .foregroundStyle(.kimiTextSecondary)
            }

            Spacer()

            if model.oauthLoginInProgress {
                // 已发起授权、等待设备授权码返回中
                ProgressView()
                    .controlSize(.small)
            } else {
                AccountPrimaryButton(title: languageManager.tr("添加账号")) {
                    showAddAccountSheet = true
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
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
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.kimiBlue)
                    .frame(width: 28, height: 28)
                    .background(Color.kimiBlue.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

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

                HStack(spacing: 10) {
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
                LText(selectedProvider == .deepseek ? "输入 DeepSeek API Key" : "选择登录方式")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.kimiTextSecondary)

                if selectedProvider == .deepseek {
                    apiKeyInputArea
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
                Image(systemName: provider.iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSelected ? .kimiBlue : .kimiTextSecondary)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(isSelected ? Color.kimiBlue.opacity(0.12) : Color.kimiTextPrimary.opacity(0.06))
                    )

                Text(provider.displayName)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(.kimiTextPrimary)

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
        }
    }

    private func methodSubtitle(_ method: AuthMethod) -> String {
        switch method {
        case .oauth: return languageManager.tr("浏览器授权，推荐")
        case .apiKey: return languageManager.tr("手动填写 API Key")
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
    let displayName: String
    let credential: AccountCredential
    let isPrimary: Bool
    let isCliActive: Bool
    let state: KimiAccountState
    let membershipLevel: String?
    let reauthorizeDisabled: Bool
    let onSetPrimary: () -> Void
    let onSwitchCli: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onReauthorize: () -> Void
    let onEditKey: () -> Void

    @StateObject private var languageManager = LanguageManager.shared

    /// API Key 账号不能写入 CLI 凭证（CLI 只认 access/refresh token 对），不显示「切换账号」。
    private var isOAuth: Bool {
        if case .oauth = credential { return true }
        return false
    }

    /// 账号头像：OAuth 人像、API Key 钥匙，圆角方块底色跟随凭证类型
    private var avatar: some View {
        Image(systemName: isOAuth ? "person.fill" : "key.fill")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isOAuth ? Color.kimiBlue : Color.kimiTextSecondary)
            .frame(width: 28, height: 28)
            .background((isOAuth ? Color.kimiBlue : Color.kimiTextSecondary).opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    var body: some View {
        HStack(spacing: 14) {
            avatar

            VStack(alignment: .leading, spacing: 0) {
                // 上部：账号名称 + 状态标签
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.kimiTextPrimary)
                            .lineLimit(1)

                        if isPrimary {
                            StatusTag(text: languageManager.tr("主账号"), color: .kimiBlue)
                        }

                        if !isOAuth {
                            StatusTag(text: "API Key", color: .kimiTextSecondary)
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

                    statusLine
                }
                .padding(.bottom, 12)

                // 分隔线：与账号名左对齐（SettingsCardDivider 自带 16pt 左缩进，此处不用）
                Divider()
                    .background(Color.kimiTextPrimary.opacity(0.08))

                // 下部：全部操作按钮横排展开
                HStack(spacing: 8) {
                    AccountActionButton(
                        title: languageManager.tr("设为主账号"),
                        disabled: isPrimary,
                        action: onSetPrimary
                    )

                    AccountActionButton(
                        title: languageManager.tr("重命名"),
                        action: onRename
                    )

                    if case .unauthorized = state {
                        if isOAuth {
                            AccountActionButton(
                                title: languageManager.tr("重新授权"),
                                color: .kimiBlue,
                                hoveredColor: .kimiBlue,
                                disabled: reauthorizeDisabled,
                                action: onReauthorize
                            )
                        } else {
                            AccountActionButton(
                                title: languageManager.tr("修改 Key"),
                                color: .kimiBlue,
                                hoveredColor: .kimiBlue,
                                action: onEditKey
                            )
                        }
                    } else if isOAuth {
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
                .padding(.top, 12)
            }
        }
        .padding(16)
    }

    // MARK: 状态行

    @ViewBuilder
    private var statusLine: some View {
        switch state {
        case .loading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)

                LText("加载中…")
                    .font(.system(size: 11))
                    .foregroundStyle(.kimiTextSecondary)
            }
        case .failed(let message):
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.orange.opacity(0.9))
                .lineLimit(1)
        default:
            EmptyView()
        }
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
