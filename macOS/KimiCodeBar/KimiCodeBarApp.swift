import SwiftUI
import AppKit
import UserNotifications

// MARK: - 主题

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case dark
    case light

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .dark: return "月之暗面"
        case .light: return "月之亮面"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        }
    }
}

@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var theme: AppTheme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: "appTheme")
        }
    }

    private init() {
        let rawValue = UserDefaults.standard.string(forKey: "appTheme") ?? ""
        theme = AppTheme(rawValue: rawValue) ?? .system
    }
}

@main
struct KimiCodeBarApp: App {
    @StateObject private var themeManager = ThemeManager.shared

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        NSApplication.shared.appearance = ThemeManager.shared.theme.nsAppearance
    }

    var body: some Scene {
        MenuBarExtra {
            KimiMenu()
                .onChange(of: themeManager.theme) { _, newTheme in
                    NSApplication.shared.appearance = newTheme.nsAppearance
                }
        } label: {
            KimiLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - 配色

private func dynamicColor(light: NSColor, dark: NSColor) -> Color {
    Color(NSColor(name: nil, dynamicProvider: { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? dark : light
    }))
}

extension ShapeStyle where Self == Color {
    static var kimiPanelBackground: Color {
        dynamicColor(
            light: NSColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 0.78),
            dark: NSColor(red: 0.06, green: 0.08, blue: 0.13, alpha: 1.0)
        )
    }

    static var kimiCardBackground: Color {
        dynamicColor(
            light: NSColor(white: 0.99, alpha: 0.88),
            dark: NSColor(red: 0.11, green: 0.14, blue: 0.21, alpha: 1.0)
        )
    }

    static var kimiBlue: Color { Color(red: 0.23, green: 0.51, blue: 0.96) }

    static var kimiTextPrimary: Color {
        dynamicColor(
            light: NSColor(white: 0.12, alpha: 1.0),
            dark: NSColor(white: 1.0, alpha: 1.0)
        )
    }

    static var kimiTextSecondary: Color {
        dynamicColor(
            light: NSColor(white: 0.35, alpha: 1.0),
            dark: NSColor(white: 1.0, alpha: 0.55)
        )
    }

    static var kimiTextTertiary: Color {
        dynamicColor(
            light: NSColor(white: 0.50, alpha: 1.0),
            dark: NSColor(white: 1.0, alpha: 0.40)
        )
    }
}

// MARK: - 菜单栏图标

struct KimiLabel: View {
    @StateObject private var model = KimiCodeBarModel.shared

    var body: some View {
        if let quota = model.quota {
            Image(nsImage: MenuBarTextRenderer.image(
                weekly: quota.weekly.percentage,
                fiveHour: quota.fiveHour.percentage
            ))
        } else {
            Text(model.text)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
    }
}

private func percentageText(_ percentage: Int) -> String {
    // 100% 时去掉数字和百分号之间的细空格，避免菜单栏宽度不够被截断
    percentage == 100 ? "\(percentage)%" : "\(percentage)\u{2009}%"
}

private func percentageFont(for percentage: Int) -> Font {
    .system(size: 10, weight: .medium, design: .default)
}

@MainActor
enum MenuBarTextRenderer {
    static func image(weekly: Int, fiveHour: Int) -> NSImage {
        // 菜单栏图标始终使用固定的浅色文字，不跟随主题变化
        let textColor = Color(red: 0.886, green: 0.910, blue: 0.961)

        let content = VStack(alignment: .trailing, spacing: -1) {
            HStack(spacing: 2) {
                Text("7D")
                    .font(.system(size: 10, weight: .medium, design: .default))
                    .monospacedDigit()
                    .frame(width: 16, alignment: .leading)
                Text(percentageText(weekly))
                    .font(percentageFont(for: weekly))
                    .monospacedDigit()
                    .frame(width: 30, alignment: .trailing)
            }
            HStack(spacing: 2) {
                Text("5H")
                    .font(.system(size: 10, weight: .medium, design: .default))
                    .monospacedDigit()
                    .frame(width: 16, alignment: .leading)
                Text(percentageText(fiveHour))
                    .font(percentageFont(for: fiveHour))
                    .monospacedDigit()
                    .frame(width: 30, alignment: .trailing)
            }
        }
        .foregroundStyle(textColor)
        .frame(width: 48, height: 20, alignment: .trailing)

        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0

        guard let nsImage = renderer.nsImage else {
            return NSImage(size: NSSize(width: 56, height: 22))
        }
        nsImage.isTemplate = false
        return nsImage
    }
}

// MARK: - Kimi Code 图标（复刻 web 认证页 logo，含眨眼 + 左右看动画）

struct AnimatedKimiCodeLogo: View {
    var width: CGFloat = 44

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            KimiCodeLogo(
                width: width,
                lookOffset: lookOffset(at: t),
                blinkScale: blinkScale(at: t)
            )
        }
    }

    private func lookOffset(at t: TimeInterval) -> CGFloat {
        let c = t.truncatingRemainder(dividingBy: 2) / 2
        let amplitude: CGFloat = 5
        switch c {
        case 0.00..<0.15: return (c / 0.15) * amplitude
        case 0.15..<0.30: return amplitude
        case 0.30..<0.45: return amplitude - ((c - 0.30) / 0.15) * (amplitude * 2)
        case 0.45..<0.60: return -amplitude
        case 0.60..<0.75: return -amplitude + ((c - 0.60) / 0.15) * amplitude
        default: return 0
        }
    }

    private func blinkScale(at t: TimeInterval) -> CGFloat {
        let c = t.truncatingRemainder(dividingBy: 2.5) / 2.5
        switch c {
        case 0.80..<0.85: return 1 - (c - 0.80) / 0.05 * 0.88
        case 0.85..<0.95: return 0.12
        case 0.95..<1.0: return 0.12 + (c - 0.95) / 0.05 * 0.88
        default: return 1
        }
    }
}

struct KimiCodeLogo: View {
    var width: CGFloat = 44
    var lookOffset: CGFloat = 0
    var blinkScale: CGFloat = 1

    var body: some View {
        let scale = width / 32
        let height = width * 22 / 32

        Canvas { context, _ in
            let rect = CGRect(x: scale, y: scale, width: 30 * scale, height: 20 * scale)
            let bodyPath = RoundedRectangle(cornerRadius: 6 * scale).path(in: rect)
            context.fill(bodyPath, with: .color(.kimiBlue))

            context.blendMode = .destinationOut

            let eyeHeight = 8 * scale * blinkScale
            let eyeY = (11 * scale) - (eyeHeight / 2)

            let eye1 = CGRect(
                x: (11.8 + lookOffset) * scale,
                y: eyeY,
                width: 2.8 * scale,
                height: eyeHeight
            )
            let eye2 = CGRect(
                x: (17.4 + lookOffset) * scale,
                y: eyeY,
                width: 2.8 * scale,
                height: eyeHeight
            )
            context.fill(
                RoundedRectangle(cornerRadius: 1.4 * scale).path(in: eye1),
                with: .color(.white)
            )
            context.fill(
                RoundedRectangle(cornerRadius: 1.4 * scale).path(in: eye2),
                with: .color(.white)
            )
        }
        .frame(width: width, height: height)
        .shadow(color: Color.kimiBlue.opacity(0.35), radius: 8, x: 0, y: 3)
    }
}

// MARK: - 主面板

struct KimiMenu: View {
    @StateObject private var model = KimiCodeBarModel.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var showSettings = false
    @State private var showUpdateAlert = false
    @State private var showAppUpdateAlert = false
    @State private var showUpdateLog = false
    @State private var isHoveredUpdateLog = false

    private let consoleURL = URL(string: "https://www.kimi.com/code/console")!
    private let githubURL = URL(string: "https://github.com/xifandev/KimiCodeBar")!

    var body: some View {
        VStack(spacing: 14) {
            // Header
            HStack(spacing: 12) {
                AnimatedKimiCodeLogo(width: 44)

                Text("KimiCodeBar")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.kimiTextPrimary)

                Spacer()

                CommunityButton(url: githubURL)
            }

            // 用量卡片
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    UsageCard(
                        title: "本周用量",
                        subtitle: nil,
                        percentage: model.quota?.weekly.percentage ?? 0,
                        reset: model.quota?.weekly.timeUntilReset ?? "--",
                        color: .kimiBlue,
                        isLoading: model.isLoading
                    )

                    UsageCard(
                        title: "5小时用量",
                        subtitle: nil,
                        percentage: model.quota?.fiveHour.percentage ?? 0,
                        reset: model.quota?.fiveHour.timeUntilReset ?? "--",
                        color: .orange,
                        isLoading: model.isLoading
                    )
                }

                // 临时屏蔽测试：月度用量数据待验证
                /*
                CompactQuotaBar(
                    title: "月度用量",
                    badge: "测试",
                    used: model.quota?.totalQuota.used ?? 0,
                    limit: model.quota?.totalQuota.limit ?? 0,
                    color: .purple,
                    isLoading: model.isLoading
                )
                */

                BoosterWalletCard(
                    wallet: model.quota?.boosterWallet,
                    isLoading: model.isLoading
                )
            }

            // 操作按钮卡片
            HStack(spacing: 8) {
                ActionButton(
                    title: "控制台",
                    icon: "arrow.up.forward.square",
                    action: { NSWorkspace.shared.open(consoleURL) }
                )

                ActionButton(
                    title: "刷新",
                    icon: "arrow.clockwise",
                    action: { model.refreshAll() },
                    disabled: model.key.isEmpty || model.isLoading
                )

                ActionButton(
                    title: "设置",
                    icon: "gearshape",
                    action: { showSettings = true }
                )

                ActionButton(
                    title: "退出",
                    icon: "power",
                    action: { NSApplication.shared.terminate(nil) }
                )
            }

            // 版本卡片
            let canShowUpdateLog = model.kimiVersion != "检测中…" && model.kimiVersion != "未检测到"

            HStack(alignment: .center, spacing: 10) {
                Text("KimiCode CLI")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.kimiTextTertiary)

                HStack(spacing: 6) {
                    Text(formatKimiVersion(model.kimiVersion))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.kimiTextSecondary)

                    if canShowUpdateLog {
                        if model.pendingUpdateVersion != nil {
                            Text("发现新版本")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            Text("当前最新")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.kimiTextTertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.kimiTextPrimary.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }

                    if model.isCheckingUpdate {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                    }
                }

                Spacer()

                if canShowUpdateLog {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isHoveredUpdateLog ? .kimiTextSecondary : .kimiTextTertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.kimiCardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.kimiTextPrimary.opacity(canShowUpdateLog && isHoveredUpdateLog ? 0.06 : 0))
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
            .onHover { isHoveredUpdateLog = $0 }
            .cursor(canShowUpdateLog ? .pointingHand : .arrow)
            .onTapGesture {
                if canShowUpdateLog {
                    showUpdateLog = true
                }
            }
            .popover(isPresented: $showUpdateLog, arrowEdge: .bottom) {
                UpdateLogView()
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(
            ZStack {
                Color.kimiPanelBackground
                if colorScheme == .light {
                    Color.clear.background(.ultraThinMaterial)
                }
            }
        )
        .popover(isPresented: $showSettings, arrowEdge: .bottom) {
            SettingsView()
        }
        .popover(isPresented: $showUpdateAlert, arrowEdge: .bottom) {
            UpdateAlertView(
                currentVersion: formatKimiVersion(model.kimiVersion),
                newVersion: model.pendingUpdateVersion ?? "新版",
                releaseNotes: model.pendingReleaseNotes ?? "暂无详细更新说明。",
                onDismiss: {
                    showUpdateAlert = false
                    model.pendingUpdateVersion = nil
                },
                onInstall: {
                    showUpdateAlert = false
                    model.pendingUpdateVersion = nil
                    Task { await installKimiCLIUpdate() }
                }
            )
        }
        .popover(isPresented: $showAppUpdateAlert, arrowEdge: .bottom) {
            AppUpdateAlertView(
                currentVersion: appVersion(),
                newVersion: model.pendingAppUpdateVersion ?? "新版",
                onIgnore: {
                    showAppUpdateAlert = false
                    model.ignoreAppUpdate()
                },
                onViewUpdate: {
                    showAppUpdateAlert = false
                    NSWorkspace.shared.open(URL(string: "https://github.com/xifandev/KimiCodeBar/releases/")!)
                    model.pendingAppUpdateVersion = nil
                }
            )
        }
        .onAppear {
            Task { await model.loadKimiVersion() }
            Task { await model.checkForAppUpdate() }
            if model.key.isEmpty {
                showSettings = true
            } else if model.pendingUpdateVersion != nil {
                showUpdateAlert = true
            }
        }
        .onChange(of: model.pendingAppUpdateVersion) { _, newValue in
            if newValue != nil && model.pendingUpdateVersion == nil && !showSettings {
                showAppUpdateAlert = true
            }
        }
        .onChange(of: showUpdateAlert) { _, isShowing in
            if !isShowing && model.pendingAppUpdateVersion != nil && !showSettings {
                showAppUpdateAlert = true
            }
        }
    }

    private func installKimiCLIUpdate() async {
        // 呼出 Terminal.app 并执行更新命令，让用户在可视化终端里看到进度
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = [
            "-e",
            """
            tell application "Terminal"
                activate
                if not (exists window 1) then
                    do script ""
                end if
                do script "kimi upgrade" in front window
            end tell
            """
        ]
        try? task.run()
    }

    private func formatMembershipLevel(_ level: String) -> String {
        switch level.uppercased() {
        case "LEVEL_FREE": return "免费版"
        case "LEVEL_BASIC": return "基础版"
        case "LEVEL_INTERMEDIATE": return "进阶版"
        case "LEVEL_ADVANCED": return "高级版"
        default:
            let trimmed = level.uppercased().replacingOccurrences(of: "LEVEL_", with: "")
            return trimmed.isEmpty ? "未知" : trimmed
        }
    }

    private func formatKimiVersion(_ version: String) -> String {
        guard version != "未检测到" else { return "未检测到" }
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        if let last = components.last {
            return String(last)
        }
        return version
    }

}

// MARK: - 用量卡片

struct UsageCard: View {
    let title: String
    let subtitle: String?
    let percentage: Int
    let reset: String
    let color: Color
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题行
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.kimiTextPrimary)

                Spacer()

                if let subtitle = subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.kimiTextTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.kimiTextPrimary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            // 数值
            ZStack(alignment: .leading) {
                if !isLoading {
                    Text("\(percentage)%")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.kimiTextPrimary)
                        .transition(.opacity.animation(.easeInOut(duration: 0.25)))
                }

                if isLoading {
                    LoadingRing()
                        .frame(width: 24, height: 24)
                        .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                }
            }
            .frame(height: 38)
            .animation(.easeInOut(duration: 0.2), value: isLoading)

            // 进度条
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .frame(height: 4)
                        .foregroundStyle(Color.kimiTextPrimary.opacity(0.10))

                    Capsule()
                        .frame(width: proxy.size.width * CGFloat(min(percentage, 100)) / 100, height: 4)
                        .foregroundStyle(color)
                        .shadow(color: color.opacity(0.4), radius: 3, x: 0, y: 1)
                }
            }
            .frame(height: 4)

            // 重置时间
            Text(reset)
                .font(.system(size: 11))
                .foregroundStyle(.kimiTextSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color.kimiCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - 紧凑额度横条

struct CompactQuotaBar: View {
    let title: String
    let badge: String?
    let used: Int
    let limit: Int
    let color: Color
    let isLoading: Bool

    var body: some View {
        let percentage = limit > 0 ? Int(Double(used) / Double(limit) * 100) : 0

        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.kimiTextPrimary)
                .frame(width: 56, alignment: .leading)

            if let badge = badge, !badge.isEmpty {
                Text(badge)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.kimiTextTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.kimiTextPrimary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .frame(height: 4)
                        .foregroundStyle(Color.kimiTextPrimary.opacity(0.10))

                    Capsule()
                        .frame(width: proxy.size.width * CGFloat(min(percentage, 100)) / 100, height: 4)
                        .foregroundStyle(color)
                        .shadow(color: color.opacity(0.4), radius: 2, x: 0, y: 1)
                }
            }
            .frame(height: 4)

            if isLoading {
                LoadingRing()
                    .frame(width: 12, height: 12)
            } else {
                Text("\(percentage)%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.kimiTextSecondary)
                    .frame(width: 32, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.kimiCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - 加油包卡片

struct BoosterWalletCard: View {
    let wallet: BoosterWallet?
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("加油包余额")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.kimiTextPrimary)

                if let wallet = wallet {
                    Text(wallet.isEnabled ? "已启用" : "未启用")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(wallet.isEnabled ? .green : .kimiTextTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((wallet.isEnabled ? Color.green : Color.kimiTextTertiary).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                balanceView

                Spacer()

                if let wallet = wallet, !isLoading {
                    HStack(spacing: 4) {
                        Text("本月消费")
                            .font(.system(size: 11))
                            .foregroundStyle(.kimiTextSecondary)

                        Text(formatCurrency(wallet.monthlyUsedYuan, currency: wallet.currency))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.kimiTextPrimary)
                            .monospacedDigit()

                        Text("/")
                            .font(.system(size: 11))
                            .foregroundStyle(.kimiTextSecondary)

                        Text(limitText(for: wallet))
                            .font(.system(size: 11))
                            .foregroundStyle(.kimiTextSecondary)
                            .monospacedDigit()
                    }
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
                }
            }
            .frame(height: 28)
            .animation(.easeInOut(duration: 0.2), value: isLoading)

            if let wallet = wallet {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .frame(height: 3)
                            .foregroundStyle(Color.kimiTextPrimary.opacity(0.10))

                        let progress = wallet.monthlyChargeLimitYuan > 0
                            ? min(wallet.monthlyUsedYuan / wallet.monthlyChargeLimitYuan, 1.0)
                            : 0
                        Capsule()
                            .frame(width: proxy.size.width * CGFloat(progress), height: 3)
                            .foregroundStyle(wallet.isEnabled ? Color.orange : .kimiTextTertiary)
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.kimiCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var balanceView: some View {
        ZStack(alignment: .leading) {
            if !isLoading, let wallet = wallet {
                Text(formatCurrency(wallet.balanceYuan, currency: wallet.currency))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(wallet.isEnabled ? .kimiTextPrimary : .kimiTextTertiary)
                    .monospacedDigit()
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            }

            if isLoading {
                LoadingRing()
                    .frame(width: 20, height: 20)
                    .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            } else if wallet == nil {
                Text("--")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.kimiTextTertiary)
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            }
        }
    }

    private func limitText(for wallet: BoosterWallet) -> String {
        if wallet.monthlyChargeLimitCents <= 0 {
            return "无限制"
        }
        return formatCurrency(wallet.monthlyChargeLimitYuan, currency: wallet.currency)
    }
}

// MARK: - 操作按钮

struct ActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    var disabled: Bool = false
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))

                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(disabled ? .kimiTextTertiary : (isHovered ? .kimiTextPrimary : .kimiTextSecondary))
            .background(isHovered && !disabled ? Color.kimiTextPrimary.opacity(0.10) : Color.kimiTextPrimary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .cursor(disabled ? .arrow : .pointingHand)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - 链接行

struct LinkRow: View {
    let title: String
    let icon: String?
    let imageName: String?
    let url: URL
    @State private var isHovered = false

    init(title: String, icon: String? = nil, imageName: String? = nil, url: URL) {
        self.title = title
        self.icon = icon
        self.imageName = imageName
        self.url = url
    }

    var body: some View {
        Button(action: { NSWorkspace.shared.open(url) }) {
            HStack(spacing: 6) {
                if let imageName {
                    Image(imageName)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                }

                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isHovered ? Color.kimiBlue : .kimiTextSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isHovered ? Color.kimiBlue.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - 社区版按钮

struct CommunityButton: View {
    let url: URL
    @State private var isHovered = false

    var body: some View {
        Button(action: { NSWorkspace.shared.open(url) }) {
            HStack(spacing: 6) {
                Image("github-icon")
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)

                Text("社区版")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(isHovered ? .kimiTextPrimary : .kimiTextSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.kimiTextPrimary.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isHovered ? Color.kimiTextPrimary.opacity(0.40) : Color.kimiTextPrimary.opacity(0.20), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - 中文更新日志抓取

func fetchLatestChineseChangelog() async -> (version: String, notes: String)? {
    let url = URL(string: "https://moonshotai.github.io/kimi-code/zh/release-notes/changelog.md")!
    var request = URLRequest(url: url)
    request.setValue("KimiCodeBar/1.0", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 20

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return parseChineseChangelog(text)
    } catch {
        return nil
    }
}

func parseChineseChangelog(_ text: String) -> (version: String, notes: String)? {
    let lines = text.components(separatedBy: .newlines)

    // 找到第一个版本标题，例如：## 0.23.5（2026-07-10）
    var startIndex: Int?
    var version: String?

    for (i, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("## ") else { continue }

        let content = String(trimmed.dropFirst(3))
        if let parenRange = content.range(of: "（") {
            version = String(content[..<parenRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        } else {
            version = content
        }
        startIndex = i
        break
    }

    guard let start = startIndex, let ver = version else { return nil }

    // 收集到下一个 ## 标题之前
    var endIndex = lines.count
    for i in (start + 1)..<lines.count {
        let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("## ") {
            endIndex = i
            break
        }
    }

    let sectionLines = Array(lines[start..<endIndex])

    var formatted: [String] = []
    for line in sectionLines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }

        if trimmed.hasPrefix("## ") {
            continue // 跳过版本标题
        } else if trimmed.hasPrefix("### ") {
            continue // 跳过分类大标题
        } else if trimmed.hasPrefix("* ") {
            formatted.append("• " + String(trimmed.dropFirst(2)))
        } else {
            formatted.append(trimmed)
        }
    }

    return (ver, formatted.joined(separator: "\n"))
}

func fetchChineseChangelogEntries(maxCount: Int = 10) async -> [(version: String, notes: String)] {
    let url = URL(string: "https://moonshotai.github.io/kimi-code/zh/release-notes/changelog.md")!
    var request = URLRequest(url: url)
    request.setValue("KimiCodeBar/1.0", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 20

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return []
        }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return parseChineseChangelogEntries(text, maxCount: maxCount)
    } catch {
        return []
    }
}

func parseChineseChangelogEntries(_ text: String, maxCount: Int = 10) -> [(version: String, notes: String)] {
    let lines = text.components(separatedBy: .newlines)

    // 收集所有 ## 版本标题的位置和版本号
    var headings: [(index: Int, version: String)] = []
    for (i, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("## ") else { continue }

        let content = String(trimmed.dropFirst(3))
        let version: String
        if let parenRange = content.range(of: "（") {
            version = String(content[..<parenRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        } else {
            version = content
        }
        headings.append((i, version))
    }

    var entries: [(version: String, notes: String)] = []
    for (idx, heading) in headings.enumerated() {
        let start = heading.index
        let end = idx + 1 < headings.count ? headings[idx + 1].index : lines.count
        let sectionLines = Array(lines[start..<end])

        var formatted: [String] = []
        for line in sectionLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if trimmed.hasPrefix("## ") {
                continue // 跳过版本标题
            } else if trimmed.hasPrefix("### ") {
                continue // 跳过分类大标题
            } else if trimmed.hasPrefix("* ") {
                formatted.append("• " + String(trimmed.dropFirst(2)))
            } else {
                formatted.append(trimmed)
            }
        }

        let notes = formatted.joined(separator: "\n")
        entries.append((heading.version, notes))
        if entries.count >= maxCount { break }
    }

    return entries
}

func normalizeVersion(_ version: String) -> String {
    let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)

    // 优先提取 package@x.x.x 后面的版本号
    if let atRange = trimmed.range(of: "@", options: .backwards) {
        let suffix = String(trimmed[atRange.upperBound...])
        return extractSemver(suffix) ?? suffix
    }

    // 否则从字符串里提取第一个 semver
    return extractSemver(trimmed) ?? trimmed
}

func extractSemver(_ text: String) -> String? {
    let pattern = #"(\d+\.\d+\.\d+(?:\.\d+)?)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, range: range) else { return nil }
    return String(text[Range(match.range, in: text)!])
}

func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
    let left = normalizeVersion(lhs).split(separator: ".").compactMap { Int($0) }
    let right = normalizeVersion(rhs).split(separator: ".").compactMap { Int($0) }

    for i in 0..<max(left.count, right.count) {
        let l = i < left.count ? left[i] : 0
        let r = i < right.count ? right[i] : 0
        if l < r { return .orderedAscending }
        if l > r { return .orderedDescending }
    }
    return .orderedSame
}

private func appVersion() -> String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
}

private func formatCurrency(_ yuan: Double, currency: String) -> String {
    let symbol: String
    switch currency.uppercased() {
    case "CNY": symbol = "¥"
    case "USD": symbol = "$"
    case "EUR": symbol = "€"
    default: symbol = currency.uppercased()
    }
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 2
    let amount = formatter.string(from: NSNumber(value: yuan)) ?? String(format: "%.2f", yuan)
    return "\(symbol)\(amount)"
}

// MARK: - GitHub Release 检查

struct GitHubRelease: Decodable {
    let tagName: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
    }
}

func fetchLatestGitHubRelease(owner: String, repo: String) async -> String? {
    let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
    var request = URLRequest(url: url)
    request.setValue("KimiCodeBar/1.0", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 20

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return nil
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        return normalizeVersion(release.tagName)
    } catch {
        return nil
    }
}

// MARK: - 更新弹窗

struct UpdateAlertView: View {
    let currentVersion: String
    let newVersion: String
    let releaseNotes: String
    let onDismiss: () -> Void
    let onInstall: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏
            Text("新版本的 KimiCode 已经发布")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.kimiTextPrimary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

            // 内容
            VStack(alignment: .leading, spacing: 12) {
                Text("KimiCode \(newVersion) 可供下载，您现在的版本是 \(currentVersion)。要现在下载吗？")
                    .font(.system(size: 13))
                    .foregroundStyle(.kimiTextSecondary)

                VStack(alignment: .leading, spacing: 10) {
                    Text("KimiCode \(newVersion)")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.kimiTextPrimary)

                    Text("更新内容")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.kimiTextPrimary)

                    ScrollView {
                        Text(releaseNotes.isEmpty ? "暂无详细更新说明。" : releaseNotes)
                            .font(.system(size: 12))
                            .foregroundStyle(.kimiTextSecondary)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .center)
                .background(Color.kimiTextPrimary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 24)

            // 底部按钮
            HStack(spacing: 12) {
                Button(action: onDismiss) {
                    Text("稍后再说")
                        .frame(minWidth: 80)
                }
                .buttonStyle(KimiButtonStyle(isProminent: false))
                .cursor(.pointingHand)

                Spacer()

                Button(action: onInstall) {
                    Text("安装更新")
                        .frame(minWidth: 80)
                }
                .buttonStyle(KimiButtonStyle(isProminent: true))
                .cursor(.pointingHand)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(width: 520)
        .background(
            ZStack {
                Color.kimiPanelBackground
                if colorScheme == .light {
                    Color.clear.background(.ultraThinMaterial)
                }
            }
        )
    }
}

// MARK: - App 自身更新提示

struct AppUpdateAlertView: View {
    let currentVersion: String
    let newVersion: String
    let onIgnore: () -> Void
    let onViewUpdate: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏
            Text("发现新版本")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.kimiTextPrimary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

            // 内容
            Text("KimiCodeBar \(newVersion) 已发布，您现在的版本是 \(currentVersion)。")
                .font(.system(size: 13))
                .foregroundStyle(.kimiTextSecondary)
                .padding(.horizontal, 24)

            Spacer(minLength: 24)

            // 底部按钮
            HStack(spacing: 12) {
                Button(action: onIgnore) {
                    Text("忽略本次更新")
                        .frame(minWidth: 80)
                }
                .buttonStyle(KimiButtonStyle(isProminent: false))
                .cursor(.pointingHand)

                Spacer()

                Button(action: onViewUpdate) {
                    Text("查看更新")
                        .frame(minWidth: 80)
                }
                .buttonStyle(KimiButtonStyle(isProminent: true))
                .cursor(.pointingHand)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(width: 360)
        .background(
            ZStack {
                Color.kimiPanelBackground
                if colorScheme == .light {
                    Color.clear.background(.ultraThinMaterial)
                }
            }
        )
    }
}

// MARK: - 更新日志气泡

struct UpdateLogView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [(version: String, notes: String)] = []
    @State private var isLoading = true
    @State private var isHoveredCloseButton = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部标题
            HStack(spacing: 12) {
                Text("近期更新日志")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.kimiTextPrimary)

                Spacer()

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isHoveredCloseButton ? .kimiTextPrimary : .kimiTextSecondary)
                        .frame(width: 24, height: 24)
                        .background(isHoveredCloseButton ? Color.kimiTextPrimary.opacity(0.14) : Color.kimiTextPrimary.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
                .onHover { isHoveredCloseButton = $0 }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            // 优雅分割线
            Divider()
                .background(Color.kimiTextPrimary.opacity(0.10))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else if entries.isEmpty {
                Text("暂无更新记录。")
                    .font(.system(size: 12))
                    .foregroundStyle(.kimiTextSecondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(entries.indices, id: \.self) { index in
                            let entry = entries[index]
                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.version)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.kimiTextPrimary)

                                Text(entry.notes)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.kimiTextSecondary)
                                    .lineSpacing(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .frame(maxHeight: 320)
            }

            Spacer(minLength: 16)
        }
        .frame(width: 320)
        .background(
            ZStack {
                Color.kimiPanelBackground
                if colorScheme == .light {
                    Color.clear.background(.ultraThinMaterial)
                }
            }
        )
        .onAppear {
            load()
        }
    }

    private func load() {
        Task {
            entries = await fetchChineseChangelogEntries(maxCount: 10)
            isLoading = false
        }
    }
}

// MARK: - 设置弹窗

enum SettingField: Hashable {
    case apiKey
    case quotaInterval
    case updateInterval
}

struct SettingsView: View {
    @StateObject private var model = KimiCodeBarModel.shared
    @StateObject private var themeManager = ThemeManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var editingKey = ""
    @State private var isEditingKey = false
    @State private var isHoveredCloseButton = false
    @State private var isHoveredConsoleLink = false
    @State private var quotaIntervalText = "5"
    @State private var updateIntervalText = "30"
    @FocusState private var focusedField: SettingField?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部标题
            HStack(spacing: 12) {
                Text("设置")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.kimiTextPrimary)

                Spacer()

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isHoveredCloseButton ? .kimiTextPrimary : .kimiTextSecondary)
                        .frame(width: 24, height: 24)
                        .background(isHoveredCloseButton ? Color.kimiTextPrimary.opacity(0.14) : Color.kimiTextPrimary.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
                .onHover { isHoveredCloseButton = $0 }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            // 优雅分割线
            Divider()
                .background(Color.kimiTextPrimary.opacity(0.10))
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

            // KMK 配置
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("API Key")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.kimiTextSecondary)

                    Spacer()

                    Button(action: { NSWorkspace.shared.open(URL(string: "https://www.kimi.com/code/console")!) }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10))
                            Text("去控制台获取")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(isHoveredConsoleLink ? .kimiTextPrimary : .kimiTextSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(isHoveredConsoleLink ? Color.kimiTextPrimary.opacity(0.14) : Color.kimiTextPrimary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .cursor(.pointingHand)
                    .onHover { isHoveredConsoleLink = $0 }
                }

                HStack(spacing: 10) {
                    if isEditingKey {
                        SecureField("sk-kimi-...", text: $editingKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                            .focused($focusedField, equals: .apiKey)
                            .onChange(of: editingKey) { _, newValue in
                                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                if trimmed != newValue {
                                    editingKey = trimmed
                                }
                            }
                    } else {
                        Text(maskedKey(model.key))
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(.kimiTextSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.kimiTextPrimary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    Button(action: {
                        if isEditingKey {
                            saveKey()
                        } else {
                            editingKey = model.key
                            isEditingKey = true
                            model.errorMessage = nil
                            focusedField = .apiKey
                        }
                    }) {
                        Text(isEditingKey ? "保存" : "修改")
                    }
                    .buttonStyle(KimiButtonStyle(isProminent: true))
                    .disabled(isEditingKey && editingKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .cursor(isEditingKey && editingKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .arrow : .pointingHand)
                }
                .frame(maxWidth: .infinity)

                if let error = model.errorMessage {
                    ErrorMessageView(message: error)
                }
            }
            .padding(14)
            .background(Color.kimiTextPrimary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 20)

            // 界面配色
            VStack(alignment: .leading, spacing: 8) {
                Text("界面配色")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.kimiTextSecondary)

                Picker("", selection: $themeManager.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(14)
            .background(Color.kimiTextPrimary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 20)
            .padding(.top, 12)

            // 刷新与检查设置
            VStack(alignment: .leading, spacing: 12) {
                Text("间隔设置")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.kimiTextSecondary)

                IntervalSettingRow(
                    title: "额度刷新间隔",
                    value: $quotaIntervalText,
                    focusField: .quotaInterval,
                    focusedField: $focusedField
                )

                IntervalSettingRow(
                    title: "检查更新间隔",
                    value: $updateIntervalText,
                    focusField: .updateInterval,
                    focusedField: $focusedField
                )
            }
            .padding(14)
            .background(Color.kimiTextPrimary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 20)
            .padding(.top, 12)

            // 底部操作按钮
            HStack(spacing: 12) {
                Spacer()

                Button(action: done) {
                    Text("完成")
                }
                .buttonStyle(KimiButtonStyle(isProminent: true))
                .cursor(.pointingHand)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 320)
        .background(
            ZStack {
                Color.kimiPanelBackground
                if colorScheme == .light {
                    Color.clear.background(.ultraThinMaterial)
                }
            }
        )
        .onAppear {
            editingKey = model.key
            isEditingKey = model.key.isEmpty
            quotaIntervalText = intervalText(from: model.quotaRefreshInterval)
            updateIntervalText = intervalText(from: model.updateCheckInterval)

            // 避免设置气泡打开时自动聚焦到输入框
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focusedField = nil
            }
        }
    }

    private func intervalText(from value: Double) -> String {
        let intValue = Int(value)
        return intValue > 0 ? "\(intValue)" : "1"
    }

    private func commitIntervals() {
        let quota = Int(quotaIntervalText) ?? 5
        let update = Int(updateIntervalText) ?? 30
        model.quotaRefreshInterval = Double(max(1, quota))
        model.updateCheckInterval = Double(max(10, update))
        quotaIntervalText = intervalText(from: model.quotaRefreshInterval)
        updateIntervalText = intervalText(from: model.updateCheckInterval)
        model.restartTimers()
    }

    private func saveKey() {
        let trimmed = editingKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("sk-kimi-") else {
            model.errorMessage = "API Key 格式错误，应以 sk-kimi- 开头"
            return
        }
        editingKey = trimmed
        model.key = trimmed
        isEditingKey = false
        commitIntervals()
        model.refresh()

        // 稍等片刻：如果 API 返回正常（无错误），自动关闭设置气泡
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if model.errorMessage == nil {
                dismiss()
            }
        }
    }

    private func done() {
        commitIntervals()
        dismiss()
    }

    private func maskedKey(_ key: String) -> String {
        guard key.count > 8 else { return key }
        let prefix = String(key.prefix(7))
        let suffix = String(key.suffix(5))
        return "\(prefix)...\(suffix)"
    }
}

// MARK: - 组件

struct IntervalSettingRow: View {
    let title: String
    @Binding var value: String
    let focusField: SettingField
    @FocusState.Binding var focusedField: SettingField?

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.kimiTextPrimary)

            Spacer()

            HStack(spacing: 6) {
                TextField("分钟", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .focused($focusedField, equals: focusField)
                    .onChange(of: value) { _, newValue in
                        let filtered = newValue.filter { $0.isNumber }
                        if filtered != newValue {
                            value = filtered
                        }
                    }

                Text("分钟")
                    .font(.system(size: 12))
                    .foregroundStyle(.kimiTextSecondary)
            }
        }
        .padding(.vertical, 6)
    }
}

struct KimiButtonStyle: ButtonStyle {
    let isProminent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isProminent ? Color.kimiBlue : Color.kimiTextPrimary.opacity(0.12))
            )
            .opacity(configuration.isPressed ? 0.75 : 1.0)
    }
}

struct StatusTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

struct LoadingRing: View {
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .foregroundStyle(Color.kimiTextPrimary.opacity(0.7))
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

struct ErrorMessageView: View {
    let message: String
    @State private var isHoveredCopy = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
                .padding(.top, 2)

            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.orange.opacity(0.9))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(isHoveredCopy ? .kimiTextPrimary : .kimiTextSecondary)
            .help("复制错误信息")
            .cursor(.pointingHand)
            .onHover { isHoveredCopy = $0 }
            .padding(.top, 2)
        }
        .padding(8)
        .background(Color.orange.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 工具扩展

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { hovering in
            if hovering {
                cursor.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}

// MARK: - 数据模型

@MainActor
final class KimiCodeBarModel: ObservableObject {
    static let shared = KimiCodeBarModel()

    @AppStorage("kimiApiKey") var key = ""
    @AppStorage("quotaRefreshInterval") var quotaRefreshInterval: Double = 5
    @AppStorage("updateCheckInterval") var updateCheckInterval: Double = 30
    @AppStorage("ignoredAppUpdateVersion") var ignoredAppUpdateVersion: String = ""

    @Published var text = "-- · --"
    @Published var quota: KimiQuota?
    @Published var errorMessage: String?
    @Published var isLoading = false

    @Published var kimiVersion: String = "检测中…"
    @Published var isCheckingUpdate: Bool = false
    @Published var pendingUpdateVersion: String?
    @Published var pendingReleaseNotes: String?
    @Published var updateErrorMessage: String?

    @Published var pendingAppUpdateVersion: String?

    private let service = KimiCodeBarQuotaService()
    private var timer: Timer?
    private var updateTimer: Timer?

    init() {
        refresh()
        Task { await loadKimiVersion() }
        startQuotaTimer()
        startUpdateTimer()
    }

    func startQuotaTimer() {
        timer?.invalidate()
        let interval = max(1.0, quotaRefreshInterval) * 60
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
        timer?.tolerance = interval * 0.1
    }

    func startUpdateTimer() {
        updateTimer?.invalidate()
        let interval = max(10.0, updateCheckInterval) * 60
        updateTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in await self.checkForKimiCLIUpdate() }
        }
        updateTimer?.tolerance = interval * 0.1
    }

    func restartTimers() {
        startQuotaTimer()
        startUpdateTimer()
    }

    func refresh() {
        guard !key.isEmpty else {
            text = "未配置"
            quota = nil
            errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil
        let startTime = Date()

        Task {
            let result = await service.fetchQuota(key: key)

            let elapsed = Date().timeIntervalSince(startTime)
            let remaining = max(0, 0.5 - elapsed)
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }

            await MainActor.run {
                self.isLoading = false
                switch result {
                case .success(let quota):
                    self.quota = quota
                    self.text = "周 \(quota.weekly.percentage)% · 5h \(quota.fiveHour.percentage)%"
                    self.errorMessage = nil
                case .failure(let error):
                    if self.quota == nil {
                        self.text = "--"
                    }
                    self.errorMessage = errorDescription(error)
                }
            }
        }
    }

    func refreshAll() {
        refresh()
        Task {
            await checkForKimiCLIUpdate()
            await checkForAppUpdate()
        }
    }

    func loadKimiVersion() async {
        let version = await detectKimiCLIVersion()
        await MainActor.run {
            kimiVersion = version
        }
    }

    func checkForKimiCLIUpdate() async {
        guard !isCheckingUpdate else { return }
        await MainActor.run {
            isCheckingUpdate = true
            updateErrorMessage = nil
        }

        async let currentVersionTask = detectKimiCLIVersion()
        async let changelogTask = fetchLatestChineseChangelog()

        let current = await currentVersionTask
        let changelog = await changelogTask

        await MainActor.run {
            kimiVersion = current
            isCheckingUpdate = false

            guard current != "未检测到" else {
                updateErrorMessage = "未检测到 Kimi CLI"
                return
            }

            guard let changelog = changelog else {
                updateErrorMessage = "无法获取中文更新日志"
                return
            }

            let latest = normalizeVersion(changelog.version)
            let currentNormalized = normalizeVersion(current)

            if compareVersions(currentNormalized, latest) == .orderedAscending {
                // 避免重复通知：只有首次发现该版本时才发送通知
                if pendingUpdateVersion != latest {
                    pendingUpdateVersion = latest
                    pendingReleaseNotes = changelog.notes
                    sendUpdateNotification(version: latest)
                }
            }
        }
    }

    func checkForAppUpdate() async {
        guard let latest = await fetchLatestGitHubRelease(owner: "xifandev", repo: "KimiCodeBar") else { return }

        let current = normalizeVersion(appVersion())

        guard compareVersions(current, latest) == .orderedAscending else { return }
        guard latest != ignoredAppUpdateVersion else { return }

        await MainActor.run {
            pendingAppUpdateVersion = latest
        }
    }

    func ignoreAppUpdate() {
        if let version = pendingAppUpdateVersion {
            ignoredAppUpdateVersion = version
        }
        pendingAppUpdateVersion = nil
    }

    private func sendUpdateNotification(version: String) {
        let content = UNMutableNotificationContent()
        content.title = "KimiCode 有新版本"
        content.body = "KimiCode \(version) 已发布，点击更新。"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "kimi-code-update-\(version)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func detectKimiCLIVersion() async -> String {
        let result = await runKimiCommand(arguments: ["--version"])
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty || output.contains("No such file") ? "未检测到" : output
    }

    private func runKimiCommand(arguments: [String]) async -> (output: String, exitCode: Int32) {
        return await Task.detached(priority: .utility) {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let candidates = [
                "kimi",
                "\(home)/.kimi-code/bin/kimi",
                "\(home)/.kimi/bin/kimi",
                "/usr/local/bin/kimi",
                "/opt/homebrew/bin/kimi"
            ]

            for kimiPath in candidates {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/bash")
                let argsString = arguments.map { "\($0)" }.joined(separator: " ")
                task.arguments = ["-lc", "\(kimiPath) \(argsString)"]

                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = pipe

                do {
                    try task.run()
                    task.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

                    if task.terminationStatus == 0 {
                        return (trimmed, 0)
                    }

                    let lower = trimmed.lowercased()
                    if lower.contains("no such file") || lower.contains("command not found") || lower.contains("permission denied") {
                        continue
                    }

                    return (trimmed, task.terminationStatus)
                } catch {
                    continue
                }
            }
            return ("", -1)
        }.value
    }

    private func errorDescription(_ error: QuotaError) -> String {
        switch error {
        case .invalidKeyFormat:
            return "API Key 格式错误，应以 sk-kimi- 开头"
        case .invalidURL:
            return "请求地址无效"
        case .networkError(let msg):
            return "网络错误：\(msg)"
        case .httpError(let code, let msg):
            return "Kimi API 返回错误（\(code)）：\(msg)"
        case .invalidResponse:
            return "无法解析 API 返回数据"
        }
    }
}
