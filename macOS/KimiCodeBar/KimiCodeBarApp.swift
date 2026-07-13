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

// MARK: - 窗口可见性探测

/// 监听菜单面板窗口的 key 状态，只在面板打开时让 Logo 动画运行，
/// 避免收起后仍持续刷新。
struct WindowVisibilityDetector: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> WindowVisibilityView {
        let view = WindowVisibilityView()
        view.onChange = { isVisible in
            self.isVisible = isVisible
        }
        return view
    }

    func updateNSView(_ nsView: WindowVisibilityView, context: Context) {}
}

final class WindowVisibilityView: NSView {
    var onChange: ((Bool) -> Void)?
    private var observationTokens: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observe(window: window)
    }

    private func observe(window: NSWindow?) {
        for token in observationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        observationTokens.removeAll()

        guard let window = window else {
            onChange?(false)
            return
        }

        onChange?(window.isKeyWindow || window.isVisible)

        observationTokens = [
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.onChange?(true)
            },
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.onChange?(false)
            }
        ]
    }
}

// MARK: - Kimi Code 图标（复刻 web 认证页 logo，含眨眼 + 左右看动画）

/// 用 Core Animation 直接驱动眼睛动画。
/// 眼睛是独立的 CALayer，GPU 负责移动/缩放，不触发 SwiftUI 视图重算，
/// 因此不会导致整个面板重新合成，CPU 占用极低。
struct AnimatedKimiCodeLogo: View {
    var width: CGFloat = 44
    let isAnimating: Bool

    var body: some View {
        KimiCodeLogoLayerViewWrapper(width: width, isAnimating: isAnimating)
            .frame(width: width, height: width * 22 / 32)
    }
}

struct KimiCodeLogoLayerViewWrapper: NSViewRepresentable {
    let width: CGFloat
    let isAnimating: Bool

    func makeNSView(context: Context) -> KimiCodeLogoLayerView {
        let view = KimiCodeLogoLayerView(frame: NSRect(x: 0, y: 0, width: width, height: width * 22 / 32))
        view.logoWidth = width
        return view
    }

    func updateNSView(_ nsView: KimiCodeLogoLayerView, context: Context) {
        nsView.logoWidth = width
        nsView.setAnimationsPaused(!isAnimating)
    }
}

final class KimiCodeLogoLayerView: NSView {
    var logoWidth: CGFloat = 44 {
        didSet { updateLayout() }
    }

    private let bodyLayer = CAShapeLayer()
    private let leftEyeLayer = CAShapeLayer()
    private let rightEyeLayer = CAShapeLayer()
    private var isPaused = true
    private var scale: CGFloat = 44.0 / 32.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    private func setupLayers() {
        wantsLayer = true

        let kimiBlue = NSColor(red: 0.23, green: 0.51, blue: 0.96, alpha: 1.0)

        bodyLayer.fillColor = kimiBlue.cgColor
        bodyLayer.shadowColor = kimiBlue.withAlphaComponent(0.35).cgColor
        bodyLayer.shadowOpacity = 1
        bodyLayer.shadowRadius = 8
        bodyLayer.shadowOffset = CGSize(width: 0, height: -3)

        updateEyeColors()

        layer?.addSublayer(bodyLayer)
        layer?.addSublayer(leftEyeLayer)
        layer?.addSublayer(rightEyeLayer)

        updateLayout()
    }

    private func updateEyeColors() {
        let eyeColor = NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(red: 0x18 / 255.0, green: 0x18 / 255.0, blue: 0x17 / 255.0, alpha: 1.0)
                : NSColor.white
        })
        leftEyeLayer.fillColor = eyeColor.cgColor
        rightEyeLayer.fillColor = eyeColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateEyeColors()
    }

    private var currentLookOffset: CGFloat = 0
    private var lookIndex = 0
    private var lookTimer: Timer?

    private func updateLayout() {
        scale = logoWidth / 32
        let bodyRect = CGRect(x: scale, y: scale, width: 30 * scale, height: 20 * scale)

        bodyLayer.path = NSBezierPath(
            roundedRect: bodyRect,
            xRadius: 6 * scale,
            yRadius: 6 * scale
        ).cgPath

        let eyeWidth: CGFloat = 2.8 * scale
        let eyeHeight: CGFloat = 8 * scale
        let cornerRadius: CGFloat = 1.4 * scale
        let eyeY: CGFloat = 11 * scale - eyeHeight / 2

        let eyePath = NSBezierPath(
            roundedRect: CGRect(origin: .zero, size: CGSize(width: eyeWidth, height: eyeHeight)),
            xRadius: cornerRadius,
            yRadius: cornerRadius
        ).cgPath

        leftEyeLayer.path = eyePath
        rightEyeLayer.path = eyePath

        leftEyeLayer.frame = CGRect(x: 11.8 * scale, y: eyeY, width: eyeWidth, height: eyeHeight)
        rightEyeLayer.frame = CGRect(x: 17.4 * scale, y: eyeY, width: eyeWidth, height: eyeHeight)

        addBlinkAnimation()
        if !isPaused {
            startRandomLooking()
        }
    }

    private func addBlinkAnimation() {
        leftEyeLayer.removeAnimation(forKey: "blink")
        rightEyeLayer.removeAnimation(forKey: "blink")

        // 眨眼：闭眼 0.08s、停留 0.04s、睁眼 0.08s，每 3 秒一次。
        let close = CABasicAnimation(keyPath: "transform.scale.y")
        close.fromValue = 1
        close.toValue = 0.12
        close.duration = 0.08
        close.beginTime = 0

        let hold = CABasicAnimation(keyPath: "transform.scale.y")
        hold.fromValue = 0.12
        hold.toValue = 0.12
        hold.duration = 0.04
        hold.beginTime = 0.08

        let open = CABasicAnimation(keyPath: "transform.scale.y")
        open.fromValue = 0.12
        open.toValue = 1
        open.duration = 0.08
        open.beginTime = 0.12

        let blink = CAAnimationGroup()
        blink.animations = [close, hold, open]
        blink.duration = 3.0
        blink.repeatCount = .infinity
        blink.isRemovedOnCompletion = false
        blink.timeOffset = Double.random(in: 0..<3.0)

        leftEyeLayer.add(blink, forKey: "blink")
        rightEyeLayer.add(blink, forKey: "blink")
    }

    private func startRandomLooking() {
        lookTimer?.invalidate()
        leftEyeLayer.removeAnimation(forKey: "look")
        rightEyeLayer.removeAnimation(forKey: "look")
        currentLookOffset = 0
        lookIndex = 0
        scheduleNextLook(initial: true)
    }

    private func scheduleNextLook(initial: Bool = false) {
        let pause = initial ? 0 : Double.random(in: 1.0...3.0)
        lookTimer = Timer.scheduledTimer(withTimeInterval: pause, repeats: false) { [weak self] _ in
            self?.performNextLook()
        }
    }

    private func performNextLook() {
        let amplitude = 5 * scale
        let targets: [CGFloat] = [amplitude, 0, -amplitude, 0]
        let nextTarget = targets[lookIndex % targets.count]
        lookIndex += 1

        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = currentLookOffset
        animation.toValue = nextTarget
        animation.duration = 0.3
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.currentLookOffset = nextTarget
            self?.scheduleNextLook()
        }
        leftEyeLayer.add(animation, forKey: "look")
        rightEyeLayer.add(animation, forKey: "look")
        CATransaction.commit()
    }

    func setAnimationsPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused {
            lookTimer?.invalidate()
            lookTimer = nil
            pauseLayerAnimations()
        } else {
            resumeLayerAnimations()
            startRandomLooking()
        }
    }

    private func pauseLayerAnimations() {
        let pausedTime = leftEyeLayer.convertTime(CACurrentMediaTime(), from: nil)
        leftEyeLayer.speed = 0
        leftEyeLayer.timeOffset = pausedTime
        rightEyeLayer.speed = 0
        rightEyeLayer.timeOffset = pausedTime
    }

    private func resumeLayerAnimations() {
        let pausedTime = leftEyeLayer.timeOffset
        leftEyeLayer.speed = 1
        leftEyeLayer.timeOffset = 0
        leftEyeLayer.beginTime = 0
        let timeSincePause = leftEyeLayer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
        leftEyeLayer.beginTime = timeSincePause

        rightEyeLayer.speed = 1
        rightEyeLayer.timeOffset = 0
        rightEyeLayer.beginTime = timeSincePause
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
    @State private var showUpdateErrorPopover = false
    @State private var isHoveredUpdateLog = false
    @State private var isHoveredUpdateError = false
    @State private var isMenuVisible = false

    private let consoleURL = URL(string: "https://www.kimi.com/code/console")!
    private let githubURL = URL(string: "https://github.com/xifandev/KimiCodeBar")!

    var body: some View {
        VStack(spacing: 14) {
            // Header
            HStack(spacing: 12) {
                AnimatedKimiCodeLogo(width: 44, isAnimating: isMenuVisible)

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
                        if model.pendingUpdateVersion != nil || model.hasCachedKimiUpdate {
                            Text("发现新版本")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else if model.updateErrorMessage != nil && !model.updateErrorMessage!.isEmpty {
                            Text("检查更新失败")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(isHoveredUpdateError ? .red.opacity(0.9) : .red)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(isHoveredUpdateError ? Color.red.opacity(0.18) : Color.red.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .contentShape(Rectangle())
                                .cursor(.pointingHand)
                                .onHover { isHoveredUpdateError = $0 }
                                .onTapGesture {
                                    showUpdateErrorPopover = true
                                }
                                .popover(isPresented: $showUpdateErrorPopover, arrowEdge: .bottom) {
                                    UpdateErrorPopoverView(errorMessage: model.updateErrorMessage ?? "")
                                }
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
                    if model.hasCachedKimiUpdate || model.pendingUpdateVersion != nil {
                        showUpdateAlert = true
                    } else {
                        showUpdateLog = true
                    }
                }
            }
            .popover(isPresented: $showUpdateLog, arrowEdge: .bottom) {
                UpdateLogView()
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(Color.kimiPanelBackground)
        .background(WindowVisibilityDetector(isVisible: $isMenuVisible))
        .popover(isPresented: $showSettings, arrowEdge: .bottom) {
            SettingsView()
        }
        .popover(isPresented: $showUpdateAlert, arrowEdge: .trailing) {
            UpdateAlertView(
                currentVersion: formatKimiVersion(model.kimiVersion),
                newVersion: model.pendingUpdateVersion ?? "新版",
                onDismiss: {
                    showUpdateAlert = false
                    model.pendingUpdateVersion = nil
                    // 一小时后再次提醒
                    model.snoozedKimiUpdateUntil = Date().timeIntervalSince1970 + 3600
                },
                onInstall: {
                    showUpdateAlert = false
                    model.pendingUpdateVersion = nil
                    Task { await installKimiCLIUpdate() }
                }
            )
        }
        .popover(isPresented: $showAppUpdateAlert, arrowEdge: .trailing) {
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
            model.checkCachedKimiUpdate()
            if model.key.isEmpty {
                showSettings = true
            } else if model.pendingUpdateVersion != nil {
                showUpdateAlert = true
            }

            Task {
                await model.loadKimiVersion()
                await model.checkForKimiCLIUpdate()
                await model.checkForAppUpdate()

                if model.pendingAppUpdateVersion != nil && model.pendingUpdateVersion == nil && !showSettings {
                    showAppUpdateAlert = true
                }
            }
        }
        .onChange(of: isMenuVisible) { _, visible in
            if visible {
                model.checkCachedKimiUpdate()
                if model.key.isEmpty {
                    showSettings = true
                } else if model.pendingUpdateVersion != nil {
                    showUpdateAlert = true
                }

                Task {
                    await model.loadKimiVersion()
                    await model.checkForKimiCLIUpdate()
                    await model.checkForAppUpdate()

                    if model.pendingAppUpdateVersion != nil && model.pendingUpdateVersion == nil && !showSettings {
                        showAppUpdateAlert = true
                    }
                }
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
                do script "kimi upgrade"
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

func fetchLatestKimiVersion() async -> (version: String?, error: String?) {
    let url = URL(string: "https://moonshotai.github.io/kimi-code/zh/release-notes/changelog.md")!

    // 先尝试 Range 请求，只拿前 4KB 快速解析版本号
    var rangeRequest = URLRequest(url: url)
    rangeRequest.setValue("KimiCodeBar/1.0", forHTTPHeaderField: "User-Agent")
    rangeRequest.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
    rangeRequest.timeoutInterval = 10

    do {
        let (data, response) = try await URLSession.shared.data(for: rangeRequest)
        if let httpResponse = response as? HTTPURLResponse,
           (httpResponse.statusCode == 200 || httpResponse.statusCode == 206),
           let text = String(data: data, encoding: .utf8),
           let version = parseChineseChangelog(text)?.version {
            return (version, nil)
        }
        // Range 请求成功但没能解析出版本号，继续回退到完整请求
    } catch {
        // Range 请求失败，继续回退到完整请求
    }

    // 回退：下载完整日志并解析版本号
    var fullRequest = URLRequest(url: url)
    fullRequest.setValue("KimiCodeBar/1.0", forHTTPHeaderField: "User-Agent")
    fullRequest.timeoutInterval = 20

    do {
        let (data, response) = try await URLSession.shared.data(for: fullRequest)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            return (nil, "版本接口返回异常状态码：\(statusCode)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return (nil, "版本接口返回内容无法解析")
        }
        guard let version = parseChineseChangelog(text)?.version else {
            return (nil, "版本接口返回内容中未找到版本号")
        }
        return (version, nil)
    } catch {
        return (nil, "版本接口请求失败：\(error.localizedDescription)")
    }
}

func fetchLatestChineseChangelog() async -> (value: (version: String, notes: String)?, error: String?) {
    let url = URL(string: "https://moonshotai.github.io/kimi-code/zh/release-notes/changelog.md")!
    var request = URLRequest(url: url)
    request.setValue("KimiCodeBar/1.0", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 20

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            return (nil, "日志接口返回异常状态码：\(statusCode)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return (nil, "日志接口返回内容无法解析")
        }
        guard let result = parseChineseChangelog(text) else {
            return (nil, "日志接口返回内容中未找到版本信息")
        }
        return (result, nil)
    } catch {
        return (nil, "日志接口请求失败：\(error.localizedDescription)")
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

func fetchLatestGitHubRelease(owner: String, repo: String) async -> (version: String?, error: String?) {
    let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
    var request = URLRequest(url: url)
    request.setValue("KimiCodeBar/1.0", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 20

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            return (nil, "GitHub Release 接口返回异常状态码：\(statusCode)")
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        return (normalizeVersion(release.tagName), nil)
    } catch let decodingError as DecodingError {
        return (nil, "GitHub Release 接口返回数据解析失败：\(decodingError.localizedDescription)")
    } catch {
        return (nil, "GitHub Release 接口请求失败：\(error.localizedDescription)")
    }
}

// MARK: - 更新弹窗

struct UpdateAlertView: View {
    let currentVersion: String
    let newVersion: String
    let onDismiss: () -> Void
    let onInstall: () -> Void
    @StateObject private var model = KimiCodeBarModel.shared
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
                        if model.pendingReleaseNotes == nil || model.pendingReleaseNotes!.isEmpty {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.7)
                                Text("正在加载更新内容…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.kimiTextSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 20)
                        } else {
                            Text(model.pendingReleaseNotes!)
                                .font(.system(size: 12))
                                .foregroundStyle(.kimiTextSecondary)
                                .lineSpacing(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
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
        .frame(width: 400)
        .background(Color.kimiPanelBackground)
        .onAppear {
            Task {
                await model.loadKimiReleaseNotesIfNeeded()
            }
        }
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
        .background(Color.kimiPanelBackground)
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
        .background(Color.kimiPanelBackground)
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

// MARK: - 更新错误提示气泡

struct UpdateErrorPopoverView: View {
    let errorMessage: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var isHoveredCloseButton = false
    @State private var isHoveredCopyButton = false
    @State private var isHoveredIssueButton = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部标题
            HStack(spacing: 12) {
                Text("检查更新失败")
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

            // 错误信息
            ScrollView {
                Text(errorMessage)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.kimiTextSecondary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            .padding(.horizontal, 16)

            // 操作按钮
            HStack(spacing: 10) {
                Button(action: {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(errorMessage, forType: .string)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                        Text("复制错误信息")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(isHoveredCopyButton ? .kimiTextPrimary : .kimiTextSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(isHoveredCopyButton ? Color.kimiTextPrimary.opacity(0.14) : Color.kimiTextPrimary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
                .onHover { isHoveredCopyButton = $0 }

                Button(action: {
                    let body = "## 检查更新接口错误反馈\n\n错误信息：\n```\n\(errorMessage)\n```\n\n请补充以下信息：\n- 当前 KimiCodeBar 版本：\(appVersion())\n- 当前网络环境：\n- 问题描述：\n"
                    var components = URLComponents(string: "https://github.com/xifandev/KimiCodeBar/issues/new")!
                    components.queryItems = [
                        URLQueryItem(name: "title", value: "检查更新接口错误反馈"),
                        URLQueryItem(name: "body", value: body)
                    ]
                    if let url = components.url {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.bubble")
                            .font(.system(size: 10))
                        Text("去 GitHub 反馈")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(isHoveredIssueButton ? .kimiTextPrimary : .kimiTextSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(isHoveredIssueButton ? Color.kimiTextPrimary.opacity(0.14) : Color.kimiTextPrimary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
                .onHover { isHoveredIssueButton = $0 }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .frame(width: 320)
        .background(Color.kimiPanelBackground)
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
        .background(Color.kimiPanelBackground)
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
    @AppStorage("cachedKimiLatestVersion") var cachedKimiLatestVersion: String = ""
    @AppStorage("cachedKimiReleaseNotes") var cachedKimiReleaseNotes: String = ""
    @AppStorage("snoozedKimiUpdateUntil") var snoozedKimiUpdateUntil: Double = 0

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

    var hasCachedKimiUpdate: Bool {
        guard !cachedKimiLatestVersion.isEmpty, kimiVersion != "未检测到", kimiVersion != "检测中…" else { return false }
        return compareVersions(normalizeVersion(kimiVersion), normalizeVersion(cachedKimiLatestVersion)) == .orderedAscending
    }

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
        }

        let current = await detectKimiCLIVersion()

        await MainActor.run {
            kimiVersion = current
        }

        guard current != "未检测到" else {
            await MainActor.run {
                isCheckingUpdate = false
            }
            return
        }

        let (latest, _) = await fetchLatestKimiVersion()
        guard let latest = latest else {
            await MainActor.run {
                isCheckingUpdate = false
            }
            return
        }

        await MainActor.run {
            cachedKimiLatestVersion = latest
            isCheckingUpdate = false

            let currentNormalized = normalizeVersion(current)
            let latestNormalized = normalizeVersion(latest)

            if compareVersions(currentNormalized, latestNormalized) == .orderedAscending {
                // 如果还在"稍后提醒"的延迟期内，不设置 pendingUpdateVersion，也不发通知
                let now = Date().timeIntervalSince1970
                guard now >= snoozedKimiUpdateUntil else {
                    return
                }

                // 避免重复通知：只有首次发现该版本时才发送通知
                if pendingUpdateVersion != latest {
                    pendingUpdateVersion = latest
                    pendingReleaseNotes = cachedKimiReleaseNotes.isEmpty ? nil : cachedKimiReleaseNotes
                    snoozedKimiUpdateUntil = 0
                    sendUpdateNotification(version: latest)
                }
            } else {
                // 本地已经是最新版，清空延迟记录
                snoozedKimiUpdateUntil = 0
            }
        }
    }

    func checkCachedKimiUpdate() {
        guard !cachedKimiLatestVersion.isEmpty else { return }

        let currentNormalized = normalizeVersion(kimiVersion)
        let cachedNormalized = normalizeVersion(cachedKimiLatestVersion)

        guard !currentNormalized.isEmpty, !cachedNormalized.isEmpty else { return }

        if compareVersions(currentNormalized, cachedNormalized) == .orderedAscending {
            // 如果还在延迟提醒期内，不弹窗
            let now = Date().timeIntervalSince1970
            guard now >= snoozedKimiUpdateUntil else { return }

            if pendingUpdateVersion != cachedKimiLatestVersion {
                pendingUpdateVersion = cachedKimiLatestVersion
                pendingReleaseNotes = cachedKimiReleaseNotes.isEmpty ? nil : cachedKimiReleaseNotes
                // 再次弹出时清空延迟记录
                snoozedKimiUpdateUntil = 0
            }
        } else {
            // 本地已经是最新版，清空延迟记录
            snoozedKimiUpdateUntil = 0
        }
    }

    func loadKimiReleaseNotesIfNeeded() async {
        guard pendingReleaseNotes == nil || pendingReleaseNotes!.isEmpty else { return }

        let (changelog, _) = await fetchLatestChineseChangelog()
        await MainActor.run {
            if let changelog = changelog {
                pendingReleaseNotes = changelog.notes
                cachedKimiReleaseNotes = changelog.notes
            }
        }
    }

    func checkForAppUpdate() async {
        let (latest, _) = await fetchLatestGitHubRelease(owner: "xifandev", repo: "KimiCodeBar")
        guard let latest = latest else { return }

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
