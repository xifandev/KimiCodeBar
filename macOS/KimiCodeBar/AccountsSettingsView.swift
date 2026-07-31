import SwiftUI

// MARK: - 账号设置页

/// 设置窗口「多账号」页：管理多账号（列表 / 设主 / 重命名 / 删除 / 重新授权 / 添加账号）。
/// 数据全部来自 KimiCodeBarModel.shared（Phase 1 多账号数据层）。
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

    /// 是否展示「添加账号」卡片：
    /// 有账号、授权流程进行中、或授权失败有待展示的错误时展示。
    private var showsAddAccountCard: Bool {
        !model.accounts.isEmpty || model.oauthLoginInProgress || model.oauthLoginError != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LText("多账号")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.kimiTextPrimary)

                // 账号列表
                SettingsCard(title: languageManager.tr("账号列表")) {
                    if model.accounts.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.accounts) { account in
                                AccountRow(
                                    displayName: model.displayName(for: account),
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
                                    onReauthorize: { model.reauthorizeAccount(account.id) }
                                )

                                if account.id != model.accounts.last?.id {
                                    SettingsCardDivider()
                                }
                            }
                        }
                        .padding(.vertical, 4)
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

                // 说明文案
                LText("账号用于在 Bar 中查看配额；「切换账号」会把该账号的凭证写入 Kimi CLI，更换 CLI 的登录账号。")
                    .font(.system(size: 12))
                    .foregroundStyle(.kimiTextSecondary)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 24)
            .padding(.top, 44)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.kimiPanelBackground)
        .onAppear { model.refreshCliActiveAccount() }
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
                model.startOAuthLogin()
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

                LText("通过浏览器授权添加一个 Kimi 账号")
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
                    model.startOAuthLogin()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

// MARK: - 账号行

private struct AccountRow: View {
    let displayName: String
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

    @StateObject private var languageManager = LanguageManager.shared

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.kimiTextPrimary)
                        .lineLimit(1)

                    if isPrimary {
                        StatusTag(text: languageManager.tr("主账号"), color: .kimiBlue)
                    }

                    if isCliActive {
                        StatusTag(text: languageManager.tr("CLI 使用中"), color: .green)
                    }

                    if let membershipLevel, !membershipLevel.isEmpty {
                        StatusTag(text: membershipLevel, color: .purple)
                    }

                    if case .unauthorized = state {
                        StatusTag(text: languageManager.tr("登录失效"), color: .red)
                    }
                }

                statusLine
            }

            Spacer()

            HStack(spacing: 8) {
                if case .unauthorized = state {
                    AccountActionButton(
                        title: languageManager.tr("重新授权"),
                        color: .kimiBlue,
                        hoveredColor: .kimiBlue,
                        disabled: reauthorizeDisabled,
                        action: onReauthorize
                    )
                } else {
                    AccountActionButton(
                        title: languageManager.tr("切换账号"),
                        disabled: isCliActive,
                        action: onSwitchCli
                    )
                    .help(languageManager.tr("将该账号的凭证写入 Kimi CLI，更换 CLI 的登录账号"))
                }

                AccountActionButton(
                    title: languageManager.tr("设为主账号"),
                    disabled: isPrimary,
                    action: onSetPrimary
                )

                AccountActionButton(
                    title: languageManager.tr("重命名"),
                    action: onRename
                )

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

/// 设备授权流程进行中的引导界面：授权码 + 复制 + 打开授权页 + 取消。
/// 视觉对齐 BasicSettingsView 的 OAuth 授权中区域。
private struct AddAccountAuthorizingView: View {
    let auth: KimiDeviceAuthorization

    @StateObject private var model = KimiCodeBarModel.shared

    @State private var isHoveredCancel = false
    @State private var isHoveredCopyCode = false
    @State private var isHoveredReopen = false
    @State private var isCodeCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 状态行
            HStack(spacing: 10) {
                LoadingRing()
                    .frame(width: 16, height: 16)

                LText("等待浏览器授权…")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.kimiTextPrimary)

                Spacer()

                Button(action: { model.cancelOAuthLogin() }) {
                    LText("取消")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isHoveredCancel ? .kimiTextPrimary : .kimiTextSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(isHoveredCancel ? Color.kimiTextPrimary.opacity(0.14) : Color.kimiTextPrimary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
                .onHover { isHoveredCancel = $0 }
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

                if let urlString = auth.displayURL, let url = URL(string: urlString) {
                    Button(action: { NSWorkspace.shared.open(url) }) {
                        HStack(spacing: 4) {
                            Image(systemName: "safari")
                                .font(.system(size: 11, weight: .medium))
                            LText("打开授权页")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(isHoveredReopen ? .white : .white.opacity(0.9))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(isHoveredReopen ? Color.kimiBlue.opacity(0.85) : Color.kimiBlue)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .cursor(.pointingHand)
                    .onHover { isHoveredReopen = $0 }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
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
