import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications
import Darwin

// MARK: - 主题

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case dark
    case light

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return LanguageManager.tr("跟随系统")
        case .dark: return LanguageManager.tr("月之暗面")
        case .light: return LanguageManager.tr("月之亮面")
        }
    }

    var iconName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .dark: return "moon.fill"
        case .light: return "sun.max.fill"
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
            NSApplication.shared.appearance = theme.nsAppearance
        }
    }

    private init() {
        let rawValue = UserDefaults.standard.string(forKey: "appTheme") ?? ""
        theme = AppTheme(rawValue: rawValue) ?? .system
    }
}

// MARK: - 开机自动启动

/// 基于 SMAppService（macOS 13+ 官方推荐 API）管理登录项，
/// 注册后 App 会在用户登录 macOS 时自动启动。
@MainActor
final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published private(set) var isEnabled: Bool

    private init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// 同步系统侧实际状态（用户可能在系统设置里手动改动了登录项）。
    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // 注册 / 取消失败时保持原状，以系统实际状态为准
        }
        refresh()
    }
}

@main
struct KimiCodeBarApp: App {
    @StateObject private var themeManager = ThemeManager.shared

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        NSApplication.shared.appearance = ThemeManager.shared.theme.nsAppearance
        _ = SparkleUpdater.shared
    }

    var body: some Scene {
        MenuBarExtra {
            KimiMenu()
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
            light: NSColor(red: 0.91, green: 0.91, blue: 0.93, alpha: 1.0),
            dark: NSColor(red: 0.06, green: 0.08, blue: 0.13, alpha: 1.0)
        )
    }

    static var kimiCardBackground: Color {
        dynamicColor(
            light: NSColor(white: 0.99, alpha: 1.0),
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
    @StateObject private var languageManager = LanguageManager.shared

    var body: some View {
        if let quota = model.quota {
            Image(nsImage: MenuBarTextRenderer.image(
                scheme: model.menuBarDisplayScheme,
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

enum MenuBarDisplayScheme: String, CaseIterable, Identifiable {
    case compact
    case kPrefix
    case singleLine

    /// 旧 case，保留以避免已保存偏好崩溃，但不在 UI 中展示。
    case kimiPrefix

    static var allCases: [MenuBarDisplayScheme] {
        [.compact, .kPrefix, .singleLine]
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .compact: return LanguageManager.tr("默认样式")
        case .kPrefix: return LanguageManager.tr("K 前缀")
        case .singleLine: return LanguageManager.tr("单行")
        case .kimiPrefix: return LanguageManager.tr("Kimi 前缀")
        }
    }
}

@MainActor
enum MenuBarTextRenderer {
    private static let textColor = Color(red: 0.886, green: 0.910, blue: 0.961)

    static func image(scheme: MenuBarDisplayScheme, weekly: Int, fiveHour: Int) -> NSImage {
        switch scheme {
        case .compact:
            return compactImage(weekly: weekly, fiveHour: fiveHour)
        case .kPrefix:
            return prefixImage(prefix: "K", weekly: weekly, fiveHour: fiveHour)
        case .kimiPrefix:
            return prefixImage(prefix: "Kimi", weekly: weekly, fiveHour: fiveHour)
        case .singleLine:
            return singleLineImage(weekly: weekly, fiveHour: fiveHour)
        }
    }

    /// 原始紧凑样式：48pt 宽，两行 7D/5H。
    /// 这是用户已经深度微调过的样式，原封不动保留。
    private static func compactImage(weekly: Int, fiveHour: Int) -> NSImage {
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

        return render(content)
    }

    /// 前缀样式：K / Kimi 作为左侧大字号前缀，右侧上下两行百分比。
    private static func prefixImage(prefix: String, weekly: Int, fiveHour: Int) -> NSImage {
        let prefixWidth: CGFloat = prefix == "K" ? 14 : 38
        let percentageWidth: CGFloat = 36
        let totalWidth: CGFloat = prefixWidth + 3 + percentageWidth

        let content = HStack(alignment: .center, spacing: 3) {
            Text(prefix)
                .font(.system(size: 20, weight: .bold, design: .default))
                .monospacedDigit()
                .frame(width: prefixWidth, height: 20, alignment: .leading)

            VStack(alignment: .trailing, spacing: 0) {
                Text(percentageText(weekly))
                    .font(percentageFont(for: weekly))
                    .monospacedDigit()
                    .frame(width: percentageWidth, alignment: .trailing)
                Text(percentageText(fiveHour))
                    .font(percentageFont(for: fiveHour))
                    .monospacedDigit()
                    .frame(width: percentageWidth, alignment: .trailing)
            }
        }
        .foregroundStyle(textColor)
        .frame(width: totalWidth, height: 20, alignment: .trailing)

        return render(content)
    }

    /// 单行样式：Kimi 84% · 6%
    private static func singleLineImage(weekly: Int, fiveHour: Int) -> NSImage {
        let content = HStack(spacing: 4) {
            Text("Kimi")
                .font(.system(size: 12, weight: .bold, design: .default))
            Text(percentageText(weekly))
                .font(.system(size: 12, weight: .medium, design: .default))
                .monospacedDigit()
            Text("·")
                .font(.system(size: 12, weight: .medium))
            Text(percentageText(fiveHour))
                .font(.system(size: 12, weight: .medium, design: .default))
                .monospacedDigit()
        }
        .foregroundStyle(textColor)
        .frame(height: 20)
        .fixedSize(horizontal: true, vertical: false)

        return render(content)
    }

    private static func render<V: View>(_ content: V) -> NSImage {
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

// MARK: - App 自动更新行（Sparkle）

struct AppUpdateRow: View {
    @StateObject private var model = KimiCodeBarModel.shared
    @StateObject private var languageManager = LanguageManager.shared
    @StateObject private var sparkleUpdater = SparkleUpdater.shared
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("KimiCode Bar")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.kimiTextTertiary)

            Spacer()

            rightContent()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.kimiCardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.kimiTextPrimary.opacity(isHovered ? 0.06 : 0))
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .cursor(.pointingHand)
        .onTapGesture {
            if sparkleUpdater.isUpdateReadyToRestart {
                sparkleUpdater.restartToInstallUpdate()
            } else if sparkleUpdater.isUpdateAvailable || model.pendingAppUpdateVersion != nil {
                sparkleUpdater.showStandardUpdateUI()
            } else {
                openGitHubReleases()
            }
        }
    }

    @ViewBuilder
    private func rightContent() -> some View {
        HStack(spacing: 6) {
            Text(appVersion())
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.kimiTextSecondary)

            if sparkleUpdater.didDownloadFail {
                LText("下载新版本")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else if sparkleUpdater.isUpdateAvailable || model.pendingAppUpdateVersion != nil {
                LText("发现新版本")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                LText("当前最新")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.kimiTextTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.kimiTextPrimary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    private func openGitHubReleases() {
        sparkleUpdater.openGitHubReleases()
    }
}

// MARK: - 主面板

struct KimiMenu: View {
    @StateObject private var model = KimiCodeBarModel.shared
    @StateObject private var languageManager = LanguageManager.shared
    @StateObject private var sparkleUpdater = SparkleUpdater.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHoveredUpdateLog = false
    @State private var isMenuVisible = false
    @State private var showUpdateAlert = false
    @State private var kimiServerOperation: KimiServerOperation = .none
    @State private var isKimiServerRestartHintDismissed = false

    private let consoleURL = URL(string: "https://www.kimi.com/code/console")!
    private let githubURL = URL(string: "https://github.com/xifandev/KimiCodeBar")!

    /// CLI 版本行显示条件：用户开启，或检测到 CLI 新版本时强制显示（无视隐藏设置）
    private var shouldShowKimiVersionRow: Bool {
        model.showKimiVersionRow || model.pendingUpdateVersion != nil || model.hasCachedKimiUpdate
    }

    /// App 版本行显示条件：用户开启，或检测到 App 新版本（含下载失败、待重启）时强制显示（无视隐藏设置）
    private var shouldShowAppUpdateRow: Bool {
        model.showAppUpdateRow || sparkleUpdater.isUpdateAvailable || sparkleUpdater.didDownloadFail
            || sparkleUpdater.isUpdateReadyToRestart || model.pendingAppUpdateVersion != nil
    }

    var body: some View {
        VStack(spacing: 14) {
            // Header
            HStack(spacing: 12) {
                AnimatedKimiCodeLogo(width: 44, isAnimating: isMenuVisible)

                Text("KimiCodeBar")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.kimiTextPrimary)

                Spacer()

                // 检测到 App 新版本时版本行会强制显示（见 shouldShowAppUpdateRow），
                // header 恒定显示社区版按钮，不再替换为「发现更新」（AppUpdateBadgeButton 实现保留备用）
                CommunityButton(url: githubURL)
            }

            // 用量卡片
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    UsageCard(
                        title: languageManager.tr("本周用量"),
                        subtitle: nil,
                        percentage: model.quota?.weekly.percentage ?? 0,
                        reset: model.quota?.weekly.timeUntilReset ?? "--",
                        color: .kimiBlue,
                        isLoading: model.isLoading
                    )

                    UsageCard(
                        title: languageManager.tr("5小时用量"),
                        subtitle: nil,
                        percentage: model.quota?.fiveHour.percentage ?? 0,
                        reset: model.quota?.fiveHour.timeUntilReset ?? "--",
                        color: .orange,
                        isLoading: model.isLoading
                    )
                }

                if model.showBoosterWalletCard {
                    BoosterWalletCard(
                        wallet: model.quota?.boosterWallet,
                        isLoading: model.isLoading
                    )
                }

                // 本机消耗量卡片：扫描本地会话记录（wire.jsonl usage.record）得出 Token 消耗
                if model.showLocalUsageCard {
                    LocalUsageCard()
                }

                // Kimi Web 卡片及重启提示条临时屏蔽（2026-07）：Kimi 官方将 Kimi Web 改为
                // 纯前端展示，且移除了 web kill 等管理命令，启停管理失去意义。
                // KimiServerCard / KimiServerRestartHint / startKimiServer / stopKimiServer
                // 等实现全部保留，恢复时把对应调用加回此处即可。
            }

            // 操作按钮卡片
            HStack(spacing: 8) {
                ActionButton(
                    title: languageManager.tr("控制台"),
                    textIcon: "KIMI",
                    action: {
                        dismissMenuBarPanel()
                        NSWorkspace.shared.open(consoleURL)
                    }
                )

                ActionButton(
                    title: languageManager.tr("刷新"),
                    icon: "arrow.clockwise",
                    action: { model.refreshAll() },
                    disabled: !model.hasCredential || model.isLoading
                )

                ActionButton(
                    title: languageManager.tr("设置"),
                    icon: "gearshape",
                    action: { SettingsWindowManager.shared.show() }
                )
                .keyboardShortcut(",", modifiers: .command)

                ActionButton(
                    title: languageManager.tr("退出"),
                    icon: "power",
                    action: { NSApplication.shared.terminate(nil) }
                )
            }

            // KimiCode CLI 版本行：点击跳转官方更新日志；检测到新版本时无视设置强制显示
            if shouldShowKimiVersionRow {
                HStack(alignment: .center, spacing: 10) {
                    Text("KimiCode CLI")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.kimiTextTertiary)

                    Spacer()

                    HStack(spacing: 6) {
                        Text(formatKimiVersion(model.kimiVersion))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.kimiTextSecondary)

                        if model.updateErrorMessage != nil && !model.updateErrorMessage!.isEmpty {
                            LText("检查更新失败")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.red.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else if model.pendingUpdateVersion != nil || model.hasCachedKimiUpdate {
                            LText("发现新版本")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            LText("当前最新")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.kimiTextTertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.kimiTextPrimary.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.kimiCardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.kimiTextPrimary.opacity(isHoveredUpdateLog ? 0.06 : 0))
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
                .onHover { isHoveredUpdateLog = $0 }
                .cursor(.pointingHand)
                .onTapGesture {
                    if model.pendingUpdateVersion != nil || model.hasCachedKimiUpdate {
                        showUpdateAlert = true
                    } else if let url = URL(string: "https://moonshotai.github.io/kimi-code/zh/release-notes/changelog.html") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            // KimiCodeBar 版本行：点击跳转 GitHub Release；检测到新版本时无视设置强制显示
            if shouldShowAppUpdateRow {
                AppUpdateRow()
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(Color.kimiPanelBackground)
        .overlay {
            if !model.hasCredential {
                LoginOverlayView(isMenuVisible: isMenuVisible)
            }
        }
        .background(WindowVisibilityDetector(isVisible: $isMenuVisible))
        .onAppear {
            model.checkCachedKimiUpdate()
            if model.pendingUpdateVersion != nil {
                showUpdateAlert = true
            }
            Task {
                await model.loadKimiVersion()
                await model.checkForKimiCLIUpdate()
                // 版本已追平（例如刚在外部更新完 CLI），关闭基于过期状态弹出的更新提示
                if model.pendingUpdateVersion == nil {
                    showUpdateAlert = false
                }
            }
        }
        .onChange(of: isMenuVisible) { _, isVisible in
            if isVisible {
                isKimiServerRestartHintDismissed = false
                Task { await model.refreshKimiServerState() }
                // 面板打开立即刷新一次额度，但避免与正在进行的请求并发
                if !model.isLoading {
                    model.refresh(showsLoading: false)
                }
                // 面板打开时探测 App 新版本，只更新状态、不弹窗
                SparkleUpdater.shared.checkForUpdateInformation()
                // 面板打开时扫描一次本机消耗量（后台线程，3 分钟节流）
                KimiLocalUsageService.shared.refreshIfNeeded()
                // 基于缓存快速判断是否需要弹窗
                model.checkCachedKimiUpdate()
                if model.pendingUpdateVersion != nil {
                    showUpdateAlert = true
                }
                // 刷新 KimiCode CLI 版本与更新状态
                Task {
                    await model.loadKimiVersion()
                    await model.checkForKimiCLIUpdate()
                    // 版本已追平（例如刚在外部更新完 CLI），关闭基于过期状态弹出的更新提示
                    if model.pendingUpdateVersion == nil {
                        showUpdateAlert = false
                    }
                }
            }
        }
        .popover(isPresented: $showUpdateAlert, arrowEdge: .trailing) {
            UpdateAlertView(
                currentVersion: formatKimiVersion(model.kimiVersion),
                newVersion: model.pendingUpdateVersion ?? languageManager.tr("新版"),
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

    }

    private func installKimiCLIUpdate() async {
        // 呼出 Terminal.app 并执行更新命令，让用户在可视化终端里看到进度
        dismissMenuBarPanel()
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
        case "LEVEL_FREE": return LanguageManager.tr("免费版")
        case "LEVEL_BASIC": return LanguageManager.tr("基础版")
        case "LEVEL_INTERMEDIATE": return LanguageManager.tr("进阶版")
        case "LEVEL_ADVANCED": return LanguageManager.tr("高级版")
        default:
            let trimmed = level.uppercased().replacingOccurrences(of: "LEVEL_", with: "")
            return trimmed.isEmpty ? LanguageManager.tr("未知") : trimmed
        }
    }

}

private func formatKimiVersion(_ version: String) -> String {
    guard version != LanguageManager.tr("未检测到") else { return LanguageManager.tr("未检测到") }
    let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
    let components = trimmed.split(separator: " ", omittingEmptySubsequences: true)
    if let last = components.last {
        return String(last)
    }
    return version
}

// MARK: - 未登录遮罩

/// 未登录时覆盖在菜单面板上的半透明遮罩，引导用户一键授权登录。
struct LoginOverlayView: View {
    let isMenuVisible: Bool

    @StateObject private var model = KimiCodeBarModel.shared
    @State private var isHoveredLogin = false
    @State private var isHoveredSettings = false
    @State private var isHoveredCancel = false

    var body: some View {
        ZStack {
            Color.kimiPanelBackground.opacity(0.94)

            VStack(spacing: 16) {
                AnimatedKimiCodeLogo(width: 52, isAnimating: isMenuVisible)

                if model.oauthLoginInProgress {
                    authorizingContent
                } else {
                    loginContent
                }
            }
            .padding(24)
        }
    }

    // MARK: 未登录

    private var loginContent: some View {
        VStack(spacing: 16) {
            LText("登录后查看 Kimi 用量")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.kimiTextPrimary)

            Button(action: {
                model.loginMethod = .oauth
                model.startOAuthLogin()
            }) {
                LText("Kimi 登录")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 140)
                    .padding(.vertical, 10)
                    .background(isHoveredLogin ? Color.kimiBlue.opacity(0.85) : Color.kimiBlue)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .onHover { isHoveredLogin = $0 }

            Button(action: { SettingsWindowManager.shared.show() }) {
                LText("其他登录方式")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isHoveredSettings ? .kimiTextPrimary : .kimiTextSecondary)
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .onHover { isHoveredSettings = $0 }
        }
    }

    // MARK: 授权中

    private var authorizingContent: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    LoadingRing()
                        .frame(width: 14, height: 14)

                    LText("等待浏览器授权…")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.kimiTextPrimary)
                }

                if let auth = model.oauthDeviceAuth {
                    LText("授权码 %@", auth.userCode)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.kimiTextSecondary)
                        .textSelection(.enabled)
                }
            }

            Button(action: { model.cancelOAuthLogin() }) {
                LText("取消")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isHoveredCancel ? .kimiTextPrimary : .kimiTextSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(isHoveredCancel ? Color.kimiTextPrimary.opacity(0.14) : Color.kimiTextPrimary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .onHover { isHoveredCancel = $0 }
        }
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
                LText("加油包余额")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.kimiTextPrimary)

                if let wallet = wallet {
                    LText(wallet.isEnabled ? "已启用" : "未启用")
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
                        LText("本月消费")
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

                        let progress = wallet.monthlyChargeLimitEnabled && wallet.monthlyChargeLimitYuan > 0
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
        if !wallet.monthlyChargeLimitEnabled || wallet.monthlyChargeLimitCents <= 0 {
            return LanguageManager.tr("无限制")
        }
        return formatCurrency(wallet.monthlyChargeLimitYuan, currency: wallet.currency)
    }
 }

// MARK: - Kimi Web 重启提示

struct KimiServerRestartHint: View {
    let runningVersion: String
    let installedVersion: String
    let onRestart: () -> Void
    let onDismiss: () -> Void

    @State private var isHoveredRestart = false
    @State private var isHoveredDismiss = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.orange)

            LText("Kimi Web 运行版本 %1$@ 低于已安装版本 %2$@，建议重启服务。", formatKimiVersion(runningVersion), formatKimiVersion(installedVersion))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.kimiTextPrimary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button(action: onRestart) {
                LText("立即重启")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isHoveredRestart ? .white : .white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(isHoveredRestart ? Color.orange.opacity(0.85) : Color.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .onHover { isHoveredRestart = $0 }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isHoveredDismiss ? .kimiTextPrimary : .kimiTextSecondary)
                    .frame(width: 22, height: 22)
                    .background(isHoveredDismiss ? Color.kimiTextPrimary.opacity(0.10) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .onHover { isHoveredDismiss = $0 }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Kimi Web 卡片

struct KimiServerCard: View {
    let state: KimiServerState
    let operation: KimiServerOperation
    let onOpenWeb: () -> Void
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void

    @StateObject private var languageManager = LanguageManager.shared
    @State private var isHoveredOpenWeb = false
    @State private var isHoveredToggle = false
    @State private var isHoveredRestart = false

    private var isLoading: Bool {
        operation != .none
    }

    private var statusColor: Color {
        switch state.status {
        case .running:
            return .green
        case .stopped, .error:
            return .red
        case .unknown:
            return .kimiTextTertiary
        }
    }

    private var statusText: String {
        switch state.status {
        case .running:
            return languageManager.tr("运行中")
        case .stopped:
            return languageManager.tr("已停止")
        case .error:
            return languageManager.tr("异常")
        case .unknown:
            return languageManager.tr("检测中")
        }
    }

    private var toggleTitle: String {
        state.status == .running ? languageManager.tr("停止") : languageManager.tr("启动")
    }

    private var isRunning: Bool {
        state.status == .running
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Kimi Web")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.kimiTextPrimary)

                Text(statusText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            HStack(spacing: 8) {
                Button(action: onOpenWeb) {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.system(size: 13, weight: .medium))

                        LText("打开")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .frame(width: 130)
                    .padding(.vertical, 10)
                    .foregroundStyle(isLoading || !isRunning ? .kimiTextTertiary : (isHoveredOpenWeb ? .kimiTextPrimary : .kimiTextSecondary))
                    .background(isHoveredOpenWeb && !(isLoading || !isRunning) ? Color.kimiTextPrimary.opacity(0.10) : Color.kimiTextPrimary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(isLoading || !isRunning)
                .cursor(isLoading || !isRunning ? .arrow : .pointingHand)
                .onHover { isHoveredOpenWeb = $0 }

                serverActionButton(
                    title: toggleTitle,
                    isHovered: $isHoveredToggle,
                    isLoading: operation == (isRunning ? .stopping : .starting),
                    action: isRunning ? onStop : onStart,
                    disabled: isLoading
                )

                serverActionButton(
                    title: languageManager.tr("重启"),
                    isHovered: $isHoveredRestart,
                    isLoading: operation == .restarting,
                    action: onRestart,
                    disabled: isLoading
                )
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.kimiCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func serverActionButton(
        title: String,
        isHovered: Binding<Bool>,
        isLoading: Bool,
        action: @escaping () -> Void,
        disabled: Bool
    ) -> some View {
        Button(action: action) {
            ZStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .opacity(isLoading ? 0 : 1)

                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(disabled ? .kimiTextTertiary : (isHovered.wrappedValue ? .kimiTextPrimary : .kimiTextSecondary))
            .background(isHovered.wrappedValue && !disabled ? Color.kimiTextPrimary.opacity(0.10) : Color.kimiTextPrimary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .cursor(disabled ? .arrow : .pointingHand)
        .onHover { isHovered.wrappedValue = $0 }
    }
}

// MARK: - 操作按钮

struct ActionButton: View {
    let title: String
    var icon: String? = nil
    var textIcon: String? = nil
    let action: () -> Void
    var disabled: Bool = false
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                if let textIcon {
                    Text(textIcon)
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(width: 34, height: 18, alignment: .center)
                        .multilineTextAlignment(.center)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 18, height: 18, alignment: .center)
                }

                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
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
    let imageSize: CGFloat
    let url: URL
    @State private var isHovered = false

    init(title: String, icon: String? = nil, imageName: String? = nil, imageSize: CGFloat = 14, url: URL) {
        self.title = title
        self.icon = icon
        self.imageName = imageName
        self.imageSize = imageSize
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
                        .frame(width: imageSize, height: imageSize)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: imageSize))
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

// MARK: - 发现更新按钮（备用，当前未引用）

/// 原用于「隐藏版本行且检测到新版本」时在 header 提供更新入口；
/// 2026-07 起检测到新版本会强制显示版本行（见 KimiMenu.shouldShowAppUpdateRow），
/// header 不再需要该替代入口，实现保留备用。
struct AppUpdateBadgeButton: View {
    @StateObject private var sparkleUpdater = SparkleUpdater.shared
    @StateObject private var model = KimiCodeBarModel.shared
    @State private var isHovered = false

    var body: some View {
        Button(action: {
            if sparkleUpdater.isUpdateReadyToRestart {
                sparkleUpdater.restartToInstallUpdate()
            } else if sparkleUpdater.isUpdateAvailable || model.pendingAppUpdateVersion != nil {
                sparkleUpdater.showStandardUpdateUI()
            } else {
                sparkleUpdater.openGitHubReleases()
            }
        }) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)

                LText("发现更新")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(isHovered ? .kimiTextPrimary : .kimiTextSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.orange.opacity(0.15) : Color.orange.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.orange.opacity(isHovered ? 0.50 : 0.30), lineWidth: 1)
            )
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
        Button(action: {
            dismissMenuBarPanel()
            NSWorkspace.shared.open(url)
        }) {
            HStack(spacing: 6) {
                Image("github-icon")
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)

                LText("社区版")
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
            return (nil, LanguageManager.tr("版本接口返回异常状态码：%@", arguments: ["\(statusCode)"]))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return (nil, LanguageManager.tr("版本接口返回内容无法解析"))
        }
        guard let version = parseChineseChangelog(text)?.version else {
            return (nil, LanguageManager.tr("版本接口返回内容中未找到版本号"))
        }
        return (version, nil)
    } catch {
        return (nil, LanguageManager.tr("版本接口请求失败：%@", arguments: [error.localizedDescription]))
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
            return (nil, LanguageManager.tr("日志接口返回异常状态码：%@", arguments: ["\(statusCode)"]))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return (nil, LanguageManager.tr("日志接口返回内容无法解析"))
        }
        guard let result = parseChineseChangelog(text) else {
            return (nil, LanguageManager.tr("日志接口返回内容中未找到版本信息"))
        }
        return (result, nil)
    } catch {
        return (nil, LanguageManager.tr("日志接口请求失败：%@", arguments: [error.localizedDescription]))
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

/// 从中文 changelog 中抓取指定版本的 release notes。
/// 版本号会先做 normalize，因此 "0.28.0" 与 "v0.28.0" 都能匹配。
func fetchKimiReleaseNotes(forVersion version: String) async -> String? {
    let normalizedTarget = normalizeVersion(version)
    let entries = await fetchChineseChangelogEntries(maxCount: 20)
    return entries.first { normalizeVersion($0.version) == normalizedTarget }?.notes
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
            return (nil, LanguageManager.tr("GitHub Release 接口返回异常状态码：%@", arguments: ["\(statusCode)"]))
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        return (normalizeVersion(release.tagName), nil)
    } catch let decodingError as DecodingError {
        return (nil, LanguageManager.tr("GitHub Release 接口返回数据解析失败：%@", arguments: [decodingError.localizedDescription]))
    } catch {
        return (nil, LanguageManager.tr("GitHub Release 接口请求失败：%@", arguments: [error.localizedDescription]))
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
            LText("新版本的 KimiCode 已经发布")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.kimiTextPrimary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

            // 内容
            VStack(alignment: .leading, spacing: 12) {
                LText("KimiCode %1$@ 可供下载，您现在的版本是 %2$@。要现在下载吗？", newVersion, currentVersion)
                    .font(.system(size: 13))
                    .foregroundStyle(.kimiTextSecondary)

                VStack(alignment: .leading, spacing: 10) {
                    Text("KimiCode \(newVersion)")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.kimiTextPrimary)

                    LText("更新内容")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.kimiTextPrimary)

                    ScrollView {
                        if model.pendingReleaseNotes == nil || model.pendingReleaseNotes!.isEmpty {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.7)
                                LText("正在加载更新内容…")
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
                    LText("稍后再说")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.bordered)
                .cursor(.pointingHand)

                Spacer()

                Button(action: onInstall) {
                    LText("安装更新")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .tint(.kimiBlue)
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
            LText("发现新版本")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.kimiTextPrimary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

            // 内容
            LText("KimiCodeBar %1$@ 已发布，您现在的版本是 %2$@。", newVersion, currentVersion)
                .font(.system(size: 13))
                .foregroundStyle(.kimiTextSecondary)
                .padding(.horizontal, 24)

            Spacer(minLength: 24)

            // 底部按钮
            HStack(spacing: 12) {
                Button(action: onIgnore) {
                    LText("忽略本次更新")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.bordered)
                .cursor(.pointingHand)

                Spacer()

                Button(action: onViewUpdate) {
                    LText("查看更新")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .tint(.kimiBlue)
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
                LText("近期更新日志")
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
                LText("暂无更新记录。")
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
                LText("检查更新失败")
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
                        LText("复制错误信息")
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
                    let body = LanguageManager.tr("## 检查更新接口错误反馈\n\n错误信息：\n```\n%1$@\n```\n\n请补充以下信息：\n- 当前 KimiCodeBar 版本：%2$@\n- 当前网络环境：\n- 问题描述：\n", arguments: [errorMessage, appVersion()])
                    var components = URLComponents(string: "https://github.com/xifandev/KimiCodeBar/issues/new")!
                    components.queryItems = [
                        URLQueryItem(name: "title", value: LanguageManager.tr("检查更新接口错误反馈")),
                        URLQueryItem(name: "body", value: body)
                    ]
                    if let url = components.url {
                        dismissMenuBarPanel()
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.bubble")
                            .font(.system(size: 10))
                        LText("去 GitHub 反馈")
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

// MARK: - 菜单栏面板关闭

/// 关闭 MenuBarExtra 弹出的面板窗口（NSPanel 子类）。
/// 跳转外部链接、打开其他窗口等「离开面板」的操作前调用，避免面板残留遮挡。
@MainActor
func dismissMenuBarPanel() {
    for candidate in NSApp.windows where candidate is NSPanel {
        candidate.close()
    }
}

// MARK: - 设置窗口

@MainActor
final class SettingsWindowManager {
    static let shared = SettingsWindowManager()
    private var window: NSWindow?

    private init() {}

    func show() {
        // LSUIElement 应用（无 Dock 图标）在关闭菜单栏面板后会立即失焦，
        // 必须先激活 App 再关面板，否则后续创建的设置窗口无法正确显示——
        // 窗口会成为 key 但不可见，重新打开菜单栏面板时所有鼠标事件
        // 都被这个不可见的 .floating 窗口吞掉，面板完全无法操作。
        NSApp.activate(ignoringOtherApps: true)

        // 菜单栏面板是高层级的 NSPanel 弹层，会压住设置窗口，打开设置前先关掉它
        dismissMenuBarPanel()

        if let window = window {
            // 复用已有窗口：重新居中，防止多显示器/分辨率变化后窗口跑到屏幕外
            window.center()
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 735, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = LanguageManager.tr("KimiCode Bar 设置")
        window.minSize = NSSize(width: 600, height: 520)
        window.collectionBehavior = [.managed, .canJoinAllSpaces]
        window.level = .floating
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(red: 0.06, green: 0.08, blue: 0.13, alpha: 1.0)
                : NSColor(red: 0.91, green: 0.91, blue: 0.93, alpha: 1.0)
        })
        window.center()
        window.contentView = NSHostingView(rootView: SettingsRootView())
        window.isReleasedWhenClosed = false
        self.window = window

        window.makeKeyAndOrderFront(nil)
    }

    /// 语言切换后刷新设置窗口标题
    func refreshTitle() {
        window?.title = LanguageManager.tr("KimiCode Bar 设置")
    }
}

// MARK: - 技能管理

struct SkillInfo: Identifiable {
    let id: String
    let name: String
    let directoryName: String
    let description: String
    let version: String
    let content: String
    let path: String
}

private func skillsDirectoryPath() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/.kimi-code/skills"
}

private func loadSkills() -> [SkillInfo] {
    let dir = skillsDirectoryPath()
    guard FileManager.default.fileExists(atPath: dir) else { return [] }

    do {
        let items = try FileManager.default.contentsOfDirectory(atPath: dir)
        let directories = items
            .map { "\(dir)/\($0)" }
            .filter { FileManager.default.fileExists(atPath: $0) && isDirectory($0) }
            .sorted()

        return directories.compactMap { parseSkill(at: $0) }
    } catch {
        return []
    }
}

private func isDirectory(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
    return isDir.boolValue
}

private func parseSkill(at directoryPath: String) -> SkillInfo? {
    let skillFile = "\(directoryPath)/SKILL.md"
    guard FileManager.default.fileExists(atPath: skillFile) else { return nil }

    guard let data = FileManager.default.contents(atPath: skillFile),
          let content = String(data: data, encoding: .utf8) else { return nil }

    let directoryName = URL(fileURLWithPath: directoryPath).lastPathComponent
    var name = directoryName
    var description = ""
    var version = ""

    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("---") {
        if let endRange = trimmed.range(of: "---", range: trimmed.index(trimmed.startIndex, offsetBy: 3)..<trimmed.endIndex) {
            let frontMatter = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)..<endRange.lowerBound])
            name = parseFrontMatterValue(frontMatter, key: "name") ?? directoryName
            description = parseFrontMatterValue(frontMatter, key: "description") ?? ""
            version = parseNestedFrontMatterValue(frontMatter, outerKey: "metadata", innerKey: "version") ?? ""
        }
    }

    return SkillInfo(
        id: directoryName,
        name: name,
        directoryName: directoryName,
        description: description,
        version: version,
        content: content,
        path: skillFile
    )
}

private func parseFrontMatterValue(_ frontMatter: String, key: String) -> String? {
    let lines = frontMatter.components(separatedBy: .newlines)
    var foundKey = false
    var rawValues: [String] = []

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") { continue }

        if foundKey {
            if trimmed.hasPrefix("-") {
                rawValues.append(trimmed.dropFirst(1).trimmingCharacters(in: .whitespaces))
                continue
            }
            if trimmed.isEmpty || trimmed.contains(":") {
                break
            }
            rawValues.append(line)
            continue
        }

        if trimmed.hasPrefix("\(key):") {
            let remainder = trimmed.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            if remainder == "|" {
                foundKey = true
            } else {
                return remainder.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
    }

    guard !rawValues.isEmpty else { return nil }
    return dedented(rawValues).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func dedented(_ lines: [String]) -> [String] {
    let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    guard !nonEmpty.isEmpty else { return lines }

    let leadingSpaces = nonEmpty.compactMap { line -> Int in
        var count = 0
        for char in line {
            if char == " " { count += 1 } else { break }
        }
        return count
    }

    let minSpaces = leadingSpaces.min() ?? 0
    return lines.map { line in
        guard line.count >= minSpaces else { return line }
        return String(line.dropFirst(minSpaces))
    }
}

private func parseNestedFrontMatterValue(_ frontMatter: String, outerKey: String, innerKey: String) -> String? {
    let lines = frontMatter.components(separatedBy: .newlines)
    var insideOuter = false

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") { continue }

        if trimmed.hasPrefix("\(outerKey):") {
            insideOuter = true
            continue
        }

        if insideOuter {
            if trimmed.hasPrefix("\(innerKey):") {
                let value = trimmed.dropFirst(innerKey.count + 1).trimmingCharacters(in: .whitespaces)
                return value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            if trimmed.contains(":") && !trimmed.hasPrefix("-") && !trimmed.hasPrefix(" ") {
                break
            }
        }
    }

    return nil
}

// MARK: - 设置根视图

enum SettingsPane: String, CaseIterable, Identifiable {
    case basic
    case panelCustom
    case archive
    case skills
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .basic: return LanguageManager.tr("基本设置")
        case .panelCustom: return LanguageManager.tr("面板自定义")
        case .archive: return LanguageManager.tr("自动归档")
        case .skills: return LanguageManager.tr("技能管理")
        case .about: return LanguageManager.tr("关于")
        }
    }

    var icon: String {
        switch self {
        case .basic: return "gear"
        case .panelCustom: return "rectangle.3.group"
        case .archive: return "archivebox"
        case .skills: return "puzzlepiece.extension"
        case .about: return "info.circle"
        }
    }
}

struct SettingsRootView: View {
    @StateObject private var languageManager = LanguageManager.shared
    @State private var selectedPane: SettingsPane = .basic

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(SettingsPane.allCases) { pane in
                        SettingsSidebarItem(
                            pane: pane,
                            isSelected: selectedPane == pane
                        ) {
                            selectedPane = pane
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 16)

                Spacer()
            }
            .frame(width: 180)
            .background(Color.kimiPanelBackground)

            switch selectedPane {
            case .basic:
                BasicSettingsView()
            case .panelCustom:
                PanelCustomSettingsView()
            case .archive:
                ArchiveSettingsView()
            case .skills:
                SkillsSettingsView()
            case .about:
                AboutSettingsView()
            }
        }
        .onChange(of: languageManager.language) { _, _ in
            SettingsWindowManager.shared.refreshTitle()
        }
    }
}

struct SettingsSidebarItem: View {
    let pane: SettingsPane
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: pane.icon)
                .font(.system(size: 15, weight: .regular))
                .frame(width: 22, alignment: .center)
                .foregroundStyle(isSelected ? .white : .kimiTextPrimary)

            Text(pane.title)
                .font(.system(size: 14, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? .white : .kimiTextPrimary)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(backgroundColor)
        )
        .contentShape(Rectangle())
        .cursor(.pointingHand)
        .onHover { isHovered = $0 }
        .onTapGesture(perform: action)
    }

    private var backgroundColor: Color {
        if isSelected {
            return .kimiBlue
        } else if isHovered {
            return Color.kimiTextPrimary.opacity(0.08)
        } else {
            return Color.clear
        }
    }
}

// MARK: - 设置卡片组件

struct SettingsCard<Content: View>: View {
    let title: String?
    let footerText: String?
    let content: Content

    init(title: String? = nil, footerText: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footerText = footerText
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.kimiTextPrimary)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
            }

            content

            if let footerText {
                Text(footerText)
                    .font(.system(size: 12))
                    .foregroundStyle(.kimiTextSecondary)
                    .lineSpacing(2)
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 14)
            }
        }
        .background(Color.kimiCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct SettingsCardRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let trailing: () -> Trailing

    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.kimiTextPrimary)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.kimiTextSecondary)
                }
            }

            Spacer()

            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

struct SettingsCardDivider: View {
    var body: some View {
        Divider()
            .background(Color.kimiTextPrimary.opacity(0.08))
            .padding(.leading, 16)
    }
}

// MARK: - 设置字段焦点

enum APISettingField: Hashable {
    case apiKey
    case quotaInterval
    case updateInterval
}

// MARK: - 设置选项卡片

/// 卡片式单选：图标 + 标题 + 副标题，选中态蓝色描边 + 对勾。
/// 用于登录方式、外观主题等互斥选项的选择。
struct SettingsOptionCard: View {
    let title: String
    let subtitle: String?
    let iconName: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    private var hasSubtitle: Bool {
        if let subtitle = subtitle, !subtitle.isEmpty { return true }
        return false
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isSelected ? .kimiBlue : .kimiTextSecondary)
                    .frame(width: 24, alignment: .center)

                VStack(alignment: .leading, spacing: hasSubtitle ? 2 : 0) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.kimiTextPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    if let subtitle = subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.kimiTextSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                .layoutPriority(0.5)

                Spacer(minLength: 4)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isSelected ? .kimiBlue : .kimiTextTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected
                          ? Color.kimiBlue.opacity(0.10)
                          : (isHovered ? Color.kimiTextPrimary.opacity(0.06) : Color.kimiTextPrimary.opacity(0.03)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.kimiBlue.opacity(0.6) : Color.kimiTextPrimary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .onHover { isHovered = $0 }
    }
}

// MARK: - OAuth 授权登录区域

/// 基本设置中「授权登录」方式对应的凭证管理区域。
/// 三个状态：未授权（去授权按钮）→ 授权中（展示 user_code 轮询）→ 已授权（状态 + 退出）。
struct OAuthLoginSection: View {
    @StateObject private var model = KimiCodeBarModel.shared

    @State private var isHoveredStartLogin = false
    @State private var isHoveredLogout = false
    @State private var isHoveredCancel = false
    @State private var isHoveredCopyCode = false
    @State private var isHoveredReopen = false
    @State private var isCodeCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.oauthLoginInProgress, let auth = model.oauthDeviceAuth {
                authorizingContent(auth)
            } else if model.oauthToken != nil {
                authorizedContent
            } else {
                loginContent
            }

            if let error = model.oauthLoginError {
                SettingsCardDivider()
                ErrorMessageView(message: error)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }

            if let error = model.errorMessage {
                SettingsCardDivider()
                ErrorMessageView(message: error)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
    }

    // MARK: 未授权

    private var loginContent: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.kimiTextTertiary)
                .frame(width: 32, height: 32)

            LText("未授权")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.kimiTextPrimary)

            Spacer()

            Button(action: { model.startOAuthLogin() }) {
                ZStack {
                    LText("去授权")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .opacity(model.oauthLoginInProgress ? 0 : 1)

                    if model.oauthLoginInProgress {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.6)
                            .frame(width: 16, height: 16)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(model.oauthLoginInProgress ? Color.kimiBlue.opacity(0.6) : (isHoveredStartLogin ? Color.kimiBlue.opacity(0.85) : Color.kimiBlue))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(model.oauthLoginInProgress)
            .cursor(model.oauthLoginInProgress ? .arrow : .pointingHand)
            .onHover { isHoveredStartLogin = $0 }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    // MARK: 授权中

    private func authorizingContent(_ auth: KimiDeviceAuthorization) -> some View {
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

    // MARK: 已授权

    private var authorizedContent: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.green)
                .frame(width: 32, height: 32)

            LText("已授权 Kimi 账号")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.kimiTextPrimary)

            Spacer()

            Button(action: { model.logoutOAuth() }) {
                LText("退出登录")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isHoveredLogout ? .red.opacity(0.9) : .red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(isHoveredLogout ? Color.red.opacity(0.18) : Color.red.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .onHover { isHoveredLogout = $0 }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

// MARK: - 基本设置

struct BasicSettingsView: View {
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var model = KimiCodeBarModel.shared
    @StateObject private var launchAtLoginManager = LaunchAtLoginManager.shared
    @StateObject private var languageManager = LanguageManager.shared

    @State private var editingKey = ""
    @State private var isEditingKey = false
    @State private var quotaIntervalText = "5"
    @State private var updateIntervalText = "30"
    @FocusState private var focusedField: APISettingField?

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginManager.isEnabled },
            set: { launchAtLoginManager.setEnabled($0) }
        )
    }

    /// Token 登录方式下的 API Key 管理区域
    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
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
                    LText(isEditingKey ? "保存" : "修改")
                }
                .buttonStyle(.borderedProminent)
                .tint(.kimiBlue)
                .disabled(isEditingKey && editingKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .cursor(isEditingKey && editingKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .arrow : .pointingHand)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            if let error = model.errorMessage {
                SettingsCardDivider()
                ErrorMessageView(message: error)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }

            SettingsCardDivider()
            SettingsCardRow(
                title: languageManager.tr("获取 API Key"),
                subtitle: languageManager.tr("前往 Kimi 控制台创建并复制 API Key。")
            ) {
                LinkRow(
                    title: languageManager.tr("去控制台"),
                    icon: "arrow.up.right",
                    url: URL(string: "https://www.kimi.com/code/console")!
                )
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LText("基本设置")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.kimiTextPrimary)

                // 登录方式（默认授权登录，凭证独立存储，不影响 KimiCode CLI）
                SettingsCard(title: languageManager.tr("登录方式")) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 10) {
                            ForEach(LoginMethod.allCases) { method in
                                SettingsOptionCard(
                                    title: method.displayName,
                                    subtitle: method.subtitle,
                                    iconName: method.iconName,
                                    isSelected: model.loginMethod == method
                                ) {
                                    model.loginMethod = method
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)

                        SettingsCardDivider()

                        if model.loginMethod == .oauth {
                            OAuthLoginSection()
                        } else {
                            apiKeySection
                        }
                    }
                }

                // 外观主题
                SettingsCard(title: languageManager.tr("外观主题")) {
                    HStack(spacing: 10) {
                        ForEach(AppTheme.allCases) { theme in
                            SettingsOptionCard(
                                title: theme.displayName,
                                subtitle: nil,
                                iconName: theme.iconName,
                                isSelected: themeManager.theme == theme
                            ) {
                                themeManager.theme = theme
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                }

                // 语言
                SettingsCard {
                    SettingsCardRow(title: languageManager.tr("语言")) {
                        Picker("", selection: $languageManager.language) {
                            ForEach(AppLanguage.allCases) { language in
                                Text(language.displayName).tag(language)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 220)
                        .cursor(.pointingHand)
                    }
                }

                // 启动
                SettingsCard {
                    SettingsCardRow(title: languageManager.tr("开机自动启动")) {
                        Toggle("", isOn: launchAtLoginBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .cursor(.pointingHand)
                    }
                }

                SettingsCard {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsCardRow(title: languageManager.tr("额度刷新间隔")) {
                            HStack(spacing: 6) {
                                TextField("", text: $quotaIntervalText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 60)
                                    .focused($focusedField, equals: .quotaInterval)
                                    .onChange(of: quotaIntervalText) { _, newValue in
                                        let filtered = newValue.filter { $0.isNumber }
                                        if filtered != newValue {
                                            quotaIntervalText = filtered
                                        }
                                    }

                                LText("分钟")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.kimiTextSecondary)
                            }
                        }

                        SettingsCardDivider()
                        SettingsCardRow(title: languageManager.tr("检查更新间隔")) {
                            HStack(spacing: 6) {
                                TextField("", text: $updateIntervalText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 60)
                                    .focused($focusedField, equals: .updateInterval)
                                    .onChange(of: updateIntervalText) { _, newValue in
                                        let filtered = newValue.filter { $0.isNumber }
                                        if filtered != newValue {
                                            updateIntervalText = filtered
                                        }
                                    }

                                LText("分钟")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.kimiTextSecondary)
                            }
                        }
                    }
                }

                // 菜单栏样式
                SettingsCard(title: languageManager.tr("菜单栏样式")) {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsCardRow(title: languageManager.tr("显示样式")) {
                            Picker("", selection: $model.menuBarDisplayScheme) {
                                ForEach(MenuBarDisplayScheme.allCases) { scheme in
                                    Text(scheme.displayName).tag(scheme)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 180)
                        }

                        SettingsCardDivider()
                        SettingsCardRow(title: languageManager.tr("实时预览")) {
                            if let quota = model.quota {
                                Image(nsImage: MenuBarTextRenderer.image(
                                    scheme: model.menuBarDisplayScheme,
                                    weekly: quota.weekly.percentage,
                                    fiveHour: quota.fiveHour.percentage
                                ))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.black)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            } else {
                                Text("-- · --")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
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
        .onAppear {
            editingKey = model.key
            isEditingKey = model.key.isEmpty
            quotaIntervalText = intervalText(from: model.quotaRefreshInterval)
            updateIntervalText = intervalText(from: model.updateCheckInterval)
            launchAtLoginManager.refresh()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focusedField = nil
            }

            model.refresh(showsLoading: false)
        }
        .onDisappear {
            commitIntervals()
        }
    }

    private func intervalText(from value: Double) -> String {
        let intValue = Int(value)
        return intValue > 0 ? "\(intValue)" : "1"
    }

    private func commitIntervals() {
        let quota = Int(quotaIntervalText) ?? 3
        let update = Int(updateIntervalText) ?? 10
        model.quotaRefreshInterval = Double(max(1, quota))
        model.updateCheckInterval = Double(max(10, update))
        quotaIntervalText = intervalText(from: model.quotaRefreshInterval)
        updateIntervalText = intervalText(from: model.updateCheckInterval)
        model.restartTimers()
    }

    private func saveKey() {
        let trimmed = editingKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("sk-kimi-") else {
            model.errorMessage = LanguageManager.tr("API Key 格式错误，应以 sk-kimi- 开头")
            return
        }
        editingKey = trimmed
        model.key = trimmed
        isEditingKey = false
        commitIntervals()
        model.refresh(showsLoading: false)
    }

    private func maskedKey(_ key: String) -> String {
        guard key.count > 8 else { return key }
        let prefix = String(key.prefix(7))
        let suffix = String(key.suffix(5))
        return "\(prefix)...\(suffix)"
    }
}

// MARK: - 面板自定义

struct PanelCustomSettingsView: View {
    @StateObject private var model = KimiCodeBarModel.shared
    @StateObject private var languageManager = LanguageManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    LText("面板自定义")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.kimiTextPrimary)

                    LText("勾选要在菜单栏面板中显示的内容，取消勾选可隐藏对应卡片。设置即时生效。")
                        .font(.system(size: 13))
                        .foregroundStyle(.kimiTextSecondary)
                }

                SettingsCard {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsCardRow(
                            title: languageManager.tr("加油包余额卡片")
                        ) {
                            Toggle("", isOn: $model.showBoosterWalletCard)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .cursor(.pointingHand)
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            title: languageManager.tr("本机消耗量卡片")
                        ) {
                            Toggle("", isOn: $model.showLocalUsageCard)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .cursor(.pointingHand)
                        }

                        SettingsCardDivider()

                        // 「Kimi Web 卡片」已弃用（2026-07）：官方砍掉 server 服务，
                        // 置灰禁用展示，保留用户历史开关状态但不可操作。
                        SettingsCardRow(
                            title: languageManager.tr("Kimi Web 卡片"),
                            subtitle: languageManager.tr("官方砍掉了 server 服务，临时弃用。")
                        ) {
                            Toggle("", isOn: $model.showKimiServerCard)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .disabled(true)
                        }
                        .opacity(0.5)

                        SettingsCardDivider()

                        SettingsCardRow(
                            title: languageManager.tr("KimiCode CLI 版本号"),
                            subtitle: languageManager.tr("发现新版本时会强制显示")
                        ) {
                            Toggle("", isOn: $model.showKimiVersionRow)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .cursor(.pointingHand)
                        }

                        SettingsCardDivider()

                        SettingsCardRow(
                            title: languageManager.tr("KimiCodeBar 版本行"),
                            subtitle: languageManager.tr("发现新版本时会强制显示")
                        ) {
                            Toggle("", isOn: $model.showAppUpdateRow)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .cursor(.pointingHand)
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
    }
}

// MARK: - 关于

struct AboutSettingsView: View {
    @StateObject private var model = KimiCodeBarModel.shared
    @StateObject private var languageManager = LanguageManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LText("关于")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.kimiTextPrimary)

                // GitHub 开源社区卡片
                GitHubCommunityCard()

                // 特性亮点
                HStack(alignment: .top, spacing: 16) {
                    FeatureHighlightCard(
                        icon: "sparkles",
                        iconColor: .kimiBlue,
                        title: languageManager.tr("量身定制"),
                        description: languageManager.tr("为 Kimi Code 量身设计的用量监控小工具，在菜单栏轻量化运行，限额一目了然。")
                    )

                    FeatureHighlightCard(
                        icon: "lock.shield",
                        iconColor: .green,
                        title: languageManager.tr("隐私安全"),
                        description: languageManager.tr("数据仅本地存储，所有 API 只与 Kimi 官方通信，代码全部开源可审计。")
                    )
                }

                // 应用信息
                SettingsCard {
                    VStack(spacing: 16) {
                        AnimatedKimiCodeLogo(width: 64, isAnimating: true)

                        Text("KimiCodeBar")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.kimiTextPrimary)

                        LText("版本 %@", appVersion())
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)

                        if model.kimiVersion != languageManager.tr("检测中…") && model.kimiVersion != languageManager.tr("未检测到") {
                            Text("KimiCode CLI \(formatKimiVersion(model.kimiVersion))")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 12) {
                            LinkRow(
                                title: "GitHub",
                                imageName: "github-icon",
                                imageSize: 16,
                                url: URL(string: "https://github.com/xifandev/KimiCodeBar")!
                            )
                            LinkRow(
                                title: languageManager.tr("反馈问题"),
                                icon: "exclamationmark.bubble",
                                url: URL(string: "https://github.com/xifandev/KimiCodeBar/issues")!
                            )
                        }
                        .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 44)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.kimiPanelBackground)
    }
}

// MARK: - 技能管理设置

struct SkillsSettingsView: View {
    @State private var skills: [SkillInfo] = []
    @State private var selectedSkill: SkillInfo?
    @State private var displayedSkill: SkillInfo?
    @State private var isLoading = true
    @State private var isLoadingPreview = false
    @State private var isHoveredFinder = false

    var body: some View {
        ZStack {
            Color.kimiPanelBackground

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8)
                    LText("正在加载技能…")
                        .font(.system(size: 12))
                        .foregroundStyle(.kimiTextSecondary)
                }
            } else if skills.isEmpty {
                VStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.kimiTextPrimary.opacity(0.06))
                            .frame(width: 56, height: 56)

                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.kimiTextTertiary)
                    }

                    VStack(spacing: 4) {
                        LText("暂无已安装技能")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.kimiTextSecondary)
                        LText("技能包通常位于 ~/.kimi-code/skills/")
                            .font(.system(size: 11))
                            .foregroundStyle(.kimiTextTertiary)
                    }
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        // 顶部横向技能列表
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 8) {
                                LText("技能管理")
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundStyle(.kimiTextPrimary)

                                Text("\(skills.count)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.kimiTextTertiary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Color.kimiTextPrimary.opacity(0.08))
                                    .clipShape(Capsule())
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 20)
                            .padding(.bottom, 12)

                            ScrollViewReader { proxy in
                                ScrollView(.horizontal, showsIndicators: false) {
                                    LazyHStack(spacing: 10) {
                                        ForEach(skills) { skill in
                                            SkillHorizontalItem(
                                                skill: skill,
                                                isSelected: selectedSkill?.id == skill.id
                                            ) {
                                                selectSkill(skill)
                                                withAnimation {
                                                    proxy.scrollTo(skill.id, anchor: .center)
                                                }
                                            }
                                            .id(skill.id)
                                        }
                                    }
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                        .background(Color.kimiPanelBackground)

                        Divider()
                            .background(Color.kimiTextPrimary.opacity(0.08))

                        // 预览区
                        if isLoadingPreview {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.8)
                                LText("正在加载内容…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.kimiTextSecondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 200)
                        } else if let skill = displayedSkill {
                            skillPreview(skill)
                        } else {
                            VStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(Color.kimiTextPrimary.opacity(0.06))
                                        .frame(width: 56, height: 56)

                                    Image(systemName: "doc.text.magnifyingglass")
                                        .font(.system(size: 24, weight: .medium))
                                        .foregroundStyle(.kimiTextTertiary)
                                }

                                LText("选择上方技能以预览内容")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.kimiTextSecondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 200)
                        }
                    }
                }
            }
        }
        .onAppear {
            loadAndSelect()
        }
    }

    /// 单个技能的预览：顶部信息卡片 + 正文内容卡片
    private func skillPreview(_ skill: SkillInfo) -> some View {
        VStack(spacing: 14) {
            // 信息卡片
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.kimiBlue.opacity(0.14))
                            .frame(width: 48, height: 48)

                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.kimiBlue)
                    }

                    HStack(spacing: 8) {
                        Text(skill.name)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.kimiTextPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if !skill.version.isEmpty {
                            Text("v\(skill.version)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.kimiBlue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.kimiBlue.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .fixedSize()
                        }
                    }
                    .layoutPriority(1)

                    Spacer(minLength: 8)

                    Button(action: { revealSkillInFinder(skill) }) {
                        Image(systemName: "folder")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isHoveredFinder ? .kimiTextPrimary : .kimiTextSecondary)
                            .frame(width: 30, height: 30)
                            .background(isHoveredFinder ? Color.kimiTextPrimary.opacity(0.14) : Color.kimiTextPrimary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help(Text(LanguageManager.tr("在 Finder 中显示")))
                    .cursor(.pointingHand)
                    .onHover { isHoveredFinder = $0 }
                    .fixedSize()
                }

                if !skill.description.isEmpty {
                    Text(skill.description)
                        .font(.system(size: 12))
                        .foregroundStyle(.kimiTextSecondary)
                        .lineSpacing(2)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(skill.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.kimiTextTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.kimiCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // 正文卡片（使用 TextEditor 按需渲染，避免 Text + textSelection 布局全文卡死主线程）
            VStack(alignment: .leading, spacing: 0) {
                TextEditor(text: .constant(skill.content))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.kimiTextSecondary)
                    .scrollContentBackground(.hidden)
                    .background(Color.kimiCardBackground)
                    .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 500)
                    .padding(12)
            }
            .background(Color.kimiCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private func loadAndSelect() {
        // 文件读取放后台线程，避免 onAppear 时同步 I/O 卡住设置窗口
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                loadSkills()
            }.value
            skills = loaded
            isLoading = false
            if displayedSkill == nil, let first = loaded.first {
                selectSkill(first)
            }
        }
    }

    /// 切换选中技能。
    /// 预览区的大段可选中文本渲染开销较大，直接同步切换会卡住主线程一帧，
    /// 这里先展示转圈、延迟一小段时间再替换内容，让界面看起来是「加载中」而不是「卡死」。
    private func selectSkill(_ skill: SkillInfo) {
        guard skill.id != selectedSkill?.id else { return }
        selectedSkill = skill
        isLoadingPreview = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            // 快速连点时只有最后一次选择生效
            guard selectedSkill?.id == skill.id else { return }
            displayedSkill = skill
            isLoadingPreview = false
        }
    }

    private func revealSkillInFinder(_ skill: SkillInfo) {
        let url = URL(fileURLWithPath: skill.path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private struct SkillHorizontalItem: View {
    let skill: SkillInfo
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSelected ? Color.white.opacity(0.22) : Color.kimiBlue.opacity(0.12))
                            .frame(width: 32, height: 32)

                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(isSelected ? .white : .kimiBlue)
                    }

                    Spacer()

                    if !skill.version.isEmpty {
                        Text("v\(skill.version)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(isSelected ? .white.opacity(0.85) : .kimiTextTertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(isSelected ? Color.white.opacity(0.25) : Color.kimiTextPrimary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }

                Text(skill.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : .kimiTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !skill.description.isEmpty {
                    Text(skill.description)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? .white.opacity(0.85) : .kimiTextSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: 150)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(backgroundColor)
            )
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .onHover { isHovered = $0 }
    }

    private var backgroundColor: Color {
        if isSelected {
            return .kimiBlue
        } else if isHovered {
            return Color.kimiTextPrimary.opacity(0.08)
        } else {
            return Color.kimiCardBackground
        }
    }
}

// MARK: - GitHub 社区开源卡片

struct GitHubCommunityCard: View {
    @State private var isHoveredRepo = false
    @State private var isHoveredIssue = false

    private let repoURL = URL(string: "https://github.com/xifandev/KimiCodeBar")!
    private let issuesURL = URL(string: "https://github.com/xifandev/KimiCodeBar/issues")!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 54, height: 54)

                    Image("github-icon")
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 28, height: 28)
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        LText("社区开源版")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)

                        Text("Open Source")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.18))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }

                    LText("KimiCodeBar 完全开源，代码公开透明。欢迎 Star、提交 Issue 或参与共建，让这款工具变得更好。")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 18)

            HStack(spacing: 12) {
                Button(action: { NSWorkspace.shared.open(repoURL) }) {
                    HStack(spacing: 6) {
                        Image("github-icon")
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 14, height: 14)

                        LText("查看仓库")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(isHoveredRepo ? Color.kimiBlue : .white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(isHoveredRepo ? Color.white : Color.white.opacity(0.16))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
                .onHover { isHoveredRepo = $0 }

                Button(action: { NSWorkspace.shared.open(issuesURL) }) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.bubble")
                            .font(.system(size: 13, weight: .semibold))

                        LText("提交反馈")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(isHoveredIssue ? Color.white.opacity(0.24) : Color.white.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.25), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
                .onHover { isHoveredIssue = $0 }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color(red: 0.18, green: 0.38, blue: 0.82),
                            Color(red: 0.35, green: 0.22, blue: 0.72)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .shadow(color: Color.kimiBlue.opacity(0.22), radius: 18, x: 0, y: 8)
    }
}

// MARK: - 特性亮点卡片

struct FeatureHighlightCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(iconColor.opacity(0.12))
                    .frame(width: 40, height: 40)

                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.kimiTextPrimary)

                Text(description)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.kimiTextSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.kimiCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
            .help(Text(LanguageManager.tr("复制错误信息")))
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

// MARK: - 登录方式

enum LoginMethod: String, CaseIterable, Identifiable {
    case oauth
    case token

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .oauth: return LanguageManager.tr("授权登录")
        case .token: return LanguageManager.tr("Token 登录")
        }
    }

    var subtitle: String {
        switch self {
        case .oauth: return LanguageManager.tr("浏览器一键授权")
        case .token: return LanguageManager.tr("手动填写 API Key")
        }
    }

    var iconName: String {
        switch self {
        case .oauth: return "person.badge.key"
        case .token: return "key"
        }
    }
}

// MARK: - 本地服务状态

enum KimiServerStatus: Equatable {
    case unknown
    case running
    case stopped
    case error(String)
}

struct KimiServerState: Equatable {
    var status: KimiServerStatus = .unknown
    var version: String = ""
    var port: Int = 58627
}

enum KimiServerOperation: Equatable {
    case none
    case starting
    case stopping
    case restarting
}

// MARK: - 数据模型

@MainActor
final class KimiCodeBarModel: ObservableObject {
    static let shared = KimiCodeBarModel()

    @AppStorage("kimiApiKey") var key = ""
    @AppStorage("loginMethod") var loginMethod: LoginMethod = .oauth {
        didSet { refresh(showsLoading: false) }
    }
    @AppStorage("quotaRefreshInterval") var quotaRefreshInterval: Double = 3
    @AppStorage("updateCheckInterval") var updateCheckInterval: Double = 10
    @AppStorage("menuBarDisplayScheme") var menuBarDisplayScheme: MenuBarDisplayScheme = .compact
    @AppStorage("ignoredAppUpdateVersion") var ignoredAppUpdateVersion: String = ""
    @AppStorage("cachedKimiLatestVersion") var cachedKimiLatestVersion: String = ""
    @AppStorage("cachedKimiReleaseNotes") var cachedKimiReleaseNotes: String = ""
    @AppStorage("snoozedKimiUpdateUntil") var snoozedKimiUpdateUntil: Double = 0

    // MARK: - 面板自定义（用户控制各卡片是否显示）
    @AppStorage("showBoosterWalletCard") var showBoosterWalletCard: Bool = true
    @AppStorage("showLocalUsageCard") var showLocalUsageCard: Bool = true
    @AppStorage("showKimiServerCard") var showKimiServerCard: Bool = true
    @AppStorage("showKimiVersionRow") var showKimiVersionRow: Bool = false
    @AppStorage("showAppUpdateRow") var showAppUpdateRow: Bool = false

    @Published var text = "-- · --"
    @Published var quota: KimiQuota?
    @Published var errorMessage: String?
    @Published var isLoading = false

    @Published var oauthToken: KimiOAuthToken?
    @Published var oauthDeviceAuth: KimiDeviceAuthorization?
    @Published var oauthLoginInProgress = false
    @Published var oauthLoginError: String?

    @Published var kimiVersion: String = LanguageManager.tr("检测中…")
    @Published var isCheckingUpdate: Bool = false
    @Published var pendingUpdateVersion: String?
    @Published var pendingReleaseNotes: String?
    @Published var updateErrorMessage: String?

    @Published var pendingAppUpdateVersion: String?

    @Published var kimiServerState = KimiServerState()

    var hasCachedKimiUpdate: Bool {
        guard !cachedKimiLatestVersion.isEmpty, kimiVersion != LanguageManager.tr("未检测到"), kimiVersion != LanguageManager.tr("检测中…") else { return false }
        return compareVersions(normalizeVersion(kimiVersion), normalizeVersion(cachedKimiLatestVersion)) == .orderedAscending
    }

    var kimiServerNeedsRestart: Bool {
        guard kimiServerState.status == .running,
              !kimiServerState.version.isEmpty,
              kimiServerState.version != LanguageManager.tr("未检测到"),
              !kimiVersion.isEmpty,
              kimiVersion != LanguageManager.tr("未检测到"),
              kimiVersion != LanguageManager.tr("检测中…")
        else { return false }
        return compareVersions(normalizeVersion(kimiServerState.version), normalizeVersion(kimiVersion)) == .orderedAscending
    }

    private let service = KimiCodeBarQuotaService()
    private let oauthService = KimiOAuthService()
    private var oauthLoginTask: Task<Void, Never>?
    private var timer: Timer?
    private var updateTimer: Timer?

    /// 当前是否已配置可用凭证（决定菜单栏是否提示去设置）
    var hasCredential: Bool {
        switch loginMethod {
        case .token: return !key.isEmpty
        case .oauth: return oauthToken != nil
        }
    }

    init() {
        oauthToken = KimiOAuthService.loadStoredToken()
        refresh(showsLoading: false)
        Task { await loadKimiVersion() }
        startQuotaTimer()
        startUpdateTimer()
        KimiArchiveManager.shared.restartTimer()
    }

    func startQuotaTimer() {
        timer?.invalidate()
        let interval = max(1.0, quotaRefreshInterval) * 60
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in self.refresh(showsLoading: false) }
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

    /// 拉取额度用量。
    /// - Parameter showsLoading: 是否把 isLoading 置 true 触发 UI loading 态。
    ///   仅手动点「刷新」按钮时传 true；后台场景（启动、定时器、面板打开、切登录方式、
    ///   设置窗口 onAppear、saveKey）一律传 false，避免界面无谓闪烁。
    func refresh(showsLoading: Bool = true) {
        if showsLoading {
            isLoading = true
        }
        errorMessage = nil
        let startTime = Date()

        Task {
            guard let bearerToken = await resolveBearerToken() else {
                await MainActor.run {
                    if showsLoading {
                        self.isLoading = false
                    }
                    self.quota = nil
                    self.text = LanguageManager.tr("未登录")
                }
                return
            }

            let result = await service.fetchQuota(token: bearerToken)

            let elapsed = Date().timeIntervalSince(startTime)
            let remaining = max(0, 0.5 - elapsed)
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }

            await MainActor.run {
                if showsLoading {
                    self.isLoading = false
                }
                switch result {
                case .success(let quota):
                    self.quota = quota
                    self.text = LanguageManager.tr("周 %1$d%% · 5h %2$d%%", arguments: [quota.weekly.percentage, quota.fiveHour.percentage])
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

    /// 根据当前登录方式解析 Bearer 凭证。
    /// OAuth 模式下使用 Bar 专属凭证文件（与 CLI 隔离），过期前自动用 refresh_token 换新。
    private func resolveBearerToken() async -> String? {
        switch loginMethod {
        case .token:
            return key.isEmpty ? nil : key
        case .oauth:
            if let fresh = KimiOAuthService.loadStoredToken() {
                oauthToken = fresh
            }
            guard let token = oauthToken, token.isValid else { return nil }

            guard token.needsRefresh else {
                return token.accessToken
            }

            // 刷新前再读一次磁盘：防御其他 Bar 实例刚完成刷新并写入了新凭证
            if let latest = KimiOAuthService.loadStoredToken(),
               latest.accessToken != token.accessToken,
               !latest.needsRefresh {
                oauthToken = latest
                return latest.accessToken
            }

            let result = await oauthService.refreshAccessToken(token)
            switch result {
            case .success(let newToken):
                KimiOAuthService.saveToken(newToken)
                oauthToken = newToken
                return newToken.accessToken
            case .failure(.unauthorized):
                // 若磁盘上已是另一份凭证（其他实例刷新成功），直接沿用而不是误删
                if let latest = KimiOAuthService.loadStoredToken(),
                   latest.accessToken != token.accessToken {
                    oauthToken = latest
                    return latest.accessToken
                }
                // 授权已被吊销，清除本地凭证（仅 Bar 专属文件），等待用户重新授权
                oauthToken = nil
                KimiOAuthService.clearToken()
                return nil
            case .failure:
                // 网络等原因刷新失败，先沿用旧 token 让服务端决定是否拒绝
                return token.accessToken
            }
        }
    }

    // MARK: - OAuth 授权登录

    /// 启动 Device Code Flow：请求设备码 → 打开浏览器 → 后台轮询直至授权完成。
    func startOAuthLogin() {
        oauthLoginTask?.cancel()
        oauthLoginError = nil
        oauthDeviceAuth = nil
        oauthLoginInProgress = true

        oauthLoginTask = Task {
            let result = await oauthService.requestDeviceAuthorization()
            guard !Task.isCancelled else { return }

            let auth: KimiDeviceAuthorization
            switch result {
            case .failure(let error):
                oauthLoginInProgress = false
                oauthLoginError = oauthErrorDescription(error)
                return
            case .success(let value):
                auth = value
                oauthDeviceAuth = auth
                if let urlString = auth.displayURL, let url = URL(string: urlString) {
                    NSWorkspace.shared.open(url)
                }
            }

            let pollResult = await oauthService.pollDeviceToken(
                deviceCode: auth.deviceCode,
                initialInterval: TimeInterval(auth.interval ?? 5)
            )
            guard !Task.isCancelled else { return }

            oauthLoginInProgress = false
            oauthDeviceAuth = nil
            switch pollResult {
            case .success(let token):
                KimiOAuthService.saveToken(token)
                oauthToken = token
                refresh(showsLoading: false)
            case .failure(let error) where error != .cancelled:
                oauthLoginError = oauthErrorDescription(error)
            case .failure:
                break
            }
        }
    }

    func cancelOAuthLogin() {
        oauthLoginTask?.cancel()
        oauthLoginTask = nil
        oauthDeviceAuth = nil
        oauthLoginInProgress = false
    }

    /// 退出授权登录：取消进行中的授权流程并清除本地凭证。
    func logoutOAuth() {
        cancelOAuthLogin()
        oauthLoginError = nil
        oauthToken = nil
        KimiOAuthService.clearToken()
        quota = nil
        text = LanguageManager.tr("未登录")
        errorMessage = nil
    }

    private func oauthErrorDescription(_ error: KimiOAuthError) -> String {
        switch error {
        case .invalidURL:
            return LanguageManager.tr("授权请求地址无效")
        case .networkError(let msg):
            return LanguageManager.tr("网络错误：%@", arguments: [msg])
        case .httpError(let code, let msg):
            return LanguageManager.tr("授权服务返回错误（%1$@）：%2$@", arguments: ["\(code)", msg])
        case .invalidResponse:
            return LanguageManager.tr("无法解析授权服务返回数据")
        case .authorizationPending, .slowDown:
            return LanguageManager.tr("等待授权中")
        case .expiredToken:
            return LanguageManager.tr("授权码已过期，请重新发起授权")
        case .accessDenied:
            return LanguageManager.tr("授权被拒绝")
        case .unauthorized:
            return LanguageManager.tr("授权已失效，请重新登录")
        case .cancelled:
            return LanguageManager.tr("已取消授权")
        case .timeout:
            return LanguageManager.tr("授权超时，请重新发起授权")
        }
    }

    func refreshAll() {
        refresh()
        Task {
            await checkForKimiCLIUpdate()
            await checkForAppUpdate()
            await refreshKimiServerState()
        }
    }

    func refreshKimiServerState() async {
        let state = await detectKimiServerState()
        await MainActor.run {
            self.kimiServerState = state
        }
    }

    func openKimiWeb() {
        let port = kimiServerState.port
        // 使用 --dangerous-bypass-auth 关闭 bearer-token 鉴权，
        // 直接打开本地地址即可，无需再拼接 #token=xxx。
        let urlString = "http://127.0.0.1:\(port)/"

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    func restartKimiServer() async {
        await stopKimiServer()
        await startKimiServer()
    }

    func startKimiServer() async {
        // kimi web 是持续运行的前台命令，Kimi 0.28 起不再提供官方后台服务模式。
        // 通过 Terminal.app 前台运行，让用户直接看到日志与生命周期，避免 launchd 后台环境带来的 WebSocket/流式异常。
        dismissMenuBarPanel()

        // 若已有实例在跑，避免重复打开 Terminal 造成端口冲突
        let currentState = await detectKimiServerState()
        guard currentState.status != .running else {
            await refreshKimiServerState()
            return
        }

        // 使用 .command 文件启动 Terminal，绕过 AppleScript 自动化权限限制，
        // 修复某些环境下 Terminal 窗口弹出但命令未输入的问题。
        guard let commandURL = writeKimiWebCommandFile() else { return }
        NSWorkspace.shared.open(commandURL)

        // 轮询等待 server 起来（最多 10 秒）
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let state = await detectKimiServerState()
            if state.status == .running { break }
        }
        await refreshKimiServerState()
    }

    /// 在 Application Support 目录写入启动脚本并返回其 URL。
    private func writeKimiWebCommandFile() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport.appendingPathComponent("KimiCodeBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let commandURL = dir.appendingPathComponent("start-kimi-web.command")
        let script = "#!/bin/zsh\nkimi web --no-open --dangerous-bypass-auth\n"
        try? script.write(to: commandURL, atomically: true, encoding: .utf8)

        var attributes = [FileAttributeKey: Any]()
        attributes[.posixPermissions] = 0o755
        try? FileManager.default.setAttributes(attributes, ofItemAtPath: commandURL.path)

        return commandURL
    }

    func stopKimiServer() async {
        // 与启动同一机制：写 .command 脚本由 Terminal 执行 pkill。
        // App 内直接 kill 进程在部分环境下不可靠（与启动时 AppleScript 权限问题同理），
        // Terminal 的用户会话环境执行 pkill 与启动路径一致。
        dismissMenuBarPanel()

        // 若服务本来就没在跑，跳过脚本执行，避免无谓弹出 Terminal 窗口
        let currentState = await detectKimiServerState()
        guard currentState.status == .running else {
            await closeKimiWebTerminalWindows()
            await KimiWebLaunchAgentManager.shared.uninstall()
            await refreshKimiServerState()
            return
        }

        guard let commandURL = writeKimiWebStopCommandFile() else { return }
        NSWorkspace.shared.open(commandURL)

        // 轮询等待 server 停止（最多 10 秒）
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let state = await detectKimiServerState()
            if state.status != .running { break }
        }

        // 进程结束后 Terminal 不再提示“终止运行中的进程”，尝试关闭残留窗口（无自动化权限时静默失败，无害）
        await closeKimiWebTerminalWindows()

        // 清理可能残留的旧 LaunchAgent，避免 KeepAlive 反复拉起进程
        await KimiWebLaunchAgentManager.shared.uninstall()

        await refreshKimiServerState()
    }

    /// 在 Application Support 目录写入停止脚本并返回其 URL。
    private func writeKimiWebStopCommandFile() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport.appendingPathComponent("KimiCodeBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let commandURL = dir.appendingPathComponent("stop-kimi-web.command")
        let script = "#!/bin/zsh\npkill -f 'kimi web'\n"
        try? script.write(to: commandURL, atomically: true, encoding: .utf8)

        var attributes = [FileAttributeKey: Any]()
        attributes[.posixPermissions] = 0o755
        try? FileManager.default.setAttributes(attributes, ofItemAtPath: commandURL.path)

        return commandURL
    }

    /// 关闭标题包含启动/停止脚本名的 Terminal 标签页/窗口。
    /// 进程结束后 Terminal 不再提示“终止运行中的进程”，可直接关闭。
    private func closeKimiWebTerminalWindows() async {
        await Task.detached(priority: .utility) {
            let script = """
            tell application "Terminal"
                set targetNames to {"start-kimi-web.command", "stop-kimi-web.command"}
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with targetName in targetNames
                            if name of t contains targetName then
                                close t
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """
            var errorInfo: NSDictionary?
            guard let appleScript = NSAppleScript(source: script) else { return }
            appleScript.executeAndReturnError(&errorInfo)
        }.value
    }

    private func detectKimiServerState() async -> KimiServerState {
        // 直接探测本地端口判定运行状态。
        // Kimi Code 0.28 起 `kimi web ps` 已被移除，不再通过 CLI 判断。
        let port = 58627
        guard let version = await fetchKimiServerVersion(port: port) else {
            return KimiServerState(
                status: .stopped,
                version: LanguageManager.tr("未检测到"),
                port: port
            )
        }

        return KimiServerState(
            status: .running,
            version: version,
            port: port
        )
    }

    /// 探测本地 Kimi Web 服务，返回 server 版本号；端口不可达（服务未运行）时返回 nil
    private func fetchKimiServerVersion(port: Int) async -> String? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/v1/meta") else {
            return nil
        }

        struct MetaResponse: Decodable {
            struct MetaData: Decodable {
                let server_version: String
            }
            let code: Int
            let data: MetaData
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            let meta = try JSONDecoder().decode(MetaResponse.self, from: data)
            let version = meta.data.server_version.trimmingCharacters(in: .whitespacesAndNewlines)
            return version.isEmpty ? LanguageManager.tr("未检测到") : version
        } catch {
            return nil
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

        guard current != LanguageManager.tr("未检测到") else {
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

        let currentNormalized = normalizeVersion(current)
        let latestNormalized = normalizeVersion(latest)
        let hasUpdate = compareVersions(currentNormalized, latestNormalized) == .orderedAscending

        // 检测到有新版本时，按版本号精确抓取对应 release notes，避免缓存与版本不匹配
        let notes = hasUpdate ? await fetchKimiReleaseNotes(forVersion: latest) : nil

        await MainActor.run {
            cachedKimiLatestVersion = latest
            isCheckingUpdate = false

            if hasUpdate {
                // 如果还在"稍后提醒"的延迟期内，不设置 pendingUpdateVersion，也不发通知
                let now = Date().timeIntervalSince1970
                guard now >= snoozedKimiUpdateUntil else {
                    return
                }

                // 避免重复通知：只有首次发现该版本时才发送通知
                if pendingUpdateVersion != latest {
                    pendingUpdateVersion = latest
                    cachedKimiReleaseNotes = notes ?? ""
                    pendingReleaseNotes = notes
                    snoozedKimiUpdateUntil = 0
                    sendUpdateNotification(version: latest)
                }
            } else {
                // 本地已经是最新版，清空待更新状态和延迟记录
                pendingUpdateVersion = nil
                snoozedKimiUpdateUntil = 0
            }
        }
    }

    func checkCachedKimiUpdate() {
        guard !cachedKimiLatestVersion.isEmpty,
              kimiVersion != LanguageManager.tr("未检测到"), kimiVersion != LanguageManager.tr("检测中…") else { return }

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
            // 本地已经是最新版，清空待更新状态和延迟记录
            pendingUpdateVersion = nil
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
        guard let latest = await fetchLatestVersionFromAppcast() else { return }

        let current = normalizeVersion(appVersion())

        guard compareVersions(current, latest) == .orderedAscending else { return }
        guard latest != ignoredAppUpdateVersion else { return }

        await MainActor.run {
            pendingAppUpdateVersion = latest
        }
    }

    /// 从 Sparkle appcast.xml 中解析最新版本号，避免调用 GitHub API 触发限流
    private func fetchLatestVersionFromAppcast() async -> String? {
        guard let feedURLString = Bundle.main.infoDictionary?["SUFeedURL"] as? String,
              let url = URL(string: feedURLString) else {
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            let xml = String(data: data, encoding: .utf8) ?? ""
            let pattern = "<sparkle:shortVersionString>([^<]+)</sparkle:shortVersionString>"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
                  let match = regex.firstMatch(in: xml, options: [], range: NSRange(xml.startIndex..., in: xml)),
                  let range = Range(match.range(at: 1), in: xml) else {
                return nil
            }

            return String(xml[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
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
        content.title = LanguageManager.tr("KimiCode 有新版本")
        content.body = LanguageManager.tr("KimiCode %@ 已发布，点击更新。", arguments: [version])
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
        return output.isEmpty || output.contains("No such file") ? LanguageManager.tr("未检测到") : output
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
            return LanguageManager.tr("API Key 格式错误，应以 sk-kimi- 开头")
        case .invalidURL:
            return LanguageManager.tr("请求地址无效")
        case .networkError(let msg):
            return LanguageManager.tr("网络错误：%@", arguments: [msg])
        case .httpError(let code, let msg):
            return LanguageManager.tr("Kimi API 返回错误（%1$@）：%2$@", arguments: ["\(code)", msg])
        case .invalidResponse:
            return LanguageManager.tr("无法解析 API 返回数据")
        }
    }
}
