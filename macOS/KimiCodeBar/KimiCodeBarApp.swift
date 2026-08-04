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

    /// 设置窗口侧边导航栏底色：与内容区（kimiPanelBackground）拉开层次——
    /// 浅色下略深半档、深色下略亮半档，一眼区分导航与内容
    static var kimiSidebarBackground: Color {
        dynamicColor(
            light: NSColor(red: 0.86, green: 0.86, blue: 0.89, alpha: 1.0),
            dark: NSColor(red: 0.09, green: 0.11, blue: 0.18, alpha: 1.0)
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
        // WorkBuddy 主账号：sparkle 图标 + 积分数字
        if model.primaryAccount?.provider == .workbuddy {
            if let primary = model.primaryAccount,
               let credits = model.accountWorkBuddyCredits[primary.id] {
                Image(nsImage: MenuBarTextRenderer.workBuddyImage(creditsText: credits.remainingText))
            } else {
                Text(model.text)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
        } else if model.primaryAccount?.provider == .deepseek {
            // DeepSeek 主账号：鲸鱼图标 + 余额数字
            if let primary = model.primaryAccount,
               let balance = model.accountBalances[primary.id] {
                Image(nsImage: MenuBarTextRenderer.deepseekImage(balanceText: balance.balanceText))
            } else {
                Text(model.text)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
        } else if let quota = model.quota {
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

// MARK: - 多账号卡片显示风格

enum MultiAccountCardStyle: String, CaseIterable, Identifiable {
    /// 经典风格：大百分比 + 分割线 + 进度条 + 标题/重置时间分列
    case classic
    /// 极简风格：标签 + 百分比 + 进度条 + 重置时间，单行紧凑
    case minimal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic: return LanguageManager.tr("经典")
        case .minimal: return LanguageManager.tr("极简")
        }
    }

    var iconName: String {
        switch self {
        case .classic: return "rectangle.split.3x1"
        case .minimal: return "rectangle.righthalf.inset.filled"
        }
    }
}

@MainActor
enum MenuBarTextRenderer {
    // 模板图只读取 alpha 通道，实际染色由系统按菜单栏明暗外观决定，此处颜色只需保证不透明
    private static let textColor = Color.black

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

    /// DeepSeek 鲸鱼图标 + 余额数字（不带货币符号，余额显示两位小数）。
    /// 鲸鱼图标 adapted from CodexBar (MIT)，渲染为 template 图由系统按菜单栏明暗染色。
    static func deepseekImage(balanceText: String) -> NSImage {
        let content = HStack(spacing: 3) {
            WhaleShape()
                .fill(textColor)
                .frame(width: 18, height: 18)
            Text(balanceText)
                .font(.system(size: 12, weight: .medium, design: .default))
                .monospacedDigit()
        }
        .foregroundStyle(textColor)
        .frame(height: 20)
        .fixedSize(horizontal: true, vertical: false)

        return render(content)
    }

    /// WorkBuddy 积分图标 + 积分数字（sparkle template 图，由系统按菜单栏明暗染色）
    static func workBuddyImage(creditsText: String) -> NSImage {
        let content = HStack(spacing: 3) {
            Image(systemName: "sparkle")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
            Text(creditsText)
                .font(.system(size: 12, weight: .medium, design: .default))
                .monospacedDigit()
        }
        .foregroundStyle(textColor)
        .frame(height: 20)
        .fixedSize(horizontal: true, vertical: false)

        return render(content)
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
        nsImage.isTemplate = true
        return nsImage
    }
}

// MARK: - SVG path 解析

extension CGPath {
    /// 解析 SVG path data 字符串为 CGPath。支持 M/m, L/l, C/c, Z/z 命令。
    /// 用于把 CodexBar 的 DeepSeek 鲸鱼 SVG 图标渲染为菜单栏 template 图。
    static func parseSVGPath(_ data: String) -> CGPath {
        let path = CGMutablePath()
        let chars = Array(data)
        var i = 0
        var current = CGPoint.zero
        var start = CGPoint.zero
        var cmd: Character = "M"

        func skipSeparators() {
            while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n" || chars[i] == "\t" {
                i += 1
            }
        }

        func scanNumber() -> CGFloat {
            skipSeparators()
            var s = ""
            if i < chars.count, chars[i] == "-" || chars[i] == "+" {
                s.append(chars[i]); i += 1
            }
            while i < chars.count {
                let c = chars[i]
                if c.isNumber || c == "." {
                    s.append(c); i += 1
                } else {
                    break
                }
            }
            return CGFloat(Double(s) ?? 0)
        }

        func scanCommand() -> Character? {
            skipSeparators()
            if i < chars.count, chars[i].isLetter {
                let c = chars[i]; i += 1
                return c
            }
            return nil
        }

        while i < chars.count {
            if let c = scanCommand() {
                cmd = c
            }

            switch cmd {
            case "M":
                let x = scanNumber(); let y = scanNumber()
                current = CGPoint(x: x, y: y); start = current
                path.move(to: current)
                cmd = "L"
            case "m":
                let x = scanNumber(); let y = scanNumber()
                current = CGPoint(x: current.x + x, y: current.y + y); start = current
                path.move(to: current)
                cmd = "l"
            case "L":
                let x = scanNumber(); let y = scanNumber()
                current = CGPoint(x: x, y: y)
                path.addLine(to: current)
            case "l":
                let x = scanNumber(); let y = scanNumber()
                current = CGPoint(x: current.x + x, y: current.y + y)
                path.addLine(to: current)
            case "C":
                let x1 = scanNumber(); let y1 = scanNumber()
                let x2 = scanNumber(); let y2 = scanNumber()
                let x = scanNumber(); let y = scanNumber()
                path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
                current = CGPoint(x: x, y: y)
            case "c":
                let x1 = scanNumber(); let y1 = scanNumber()
                let x2 = scanNumber(); let y2 = scanNumber()
                let x = scanNumber(); let y = scanNumber()
                let p1 = CGPoint(x: current.x + x1, y: current.y + y1)
                let p2 = CGPoint(x: current.x + x2, y: current.y + y2)
                let p = CGPoint(x: current.x + x, y: current.y + y)
                path.addCurve(to: p, control1: p1, control2: p2)
                current = p
            case "Z", "z":
                path.closeSubpath()
                current = start
            default:
                i += 1
            }
        }
        return path
    }
}

// MARK: - DeepSeek 鲸鱼图标

/// DeepSeek 鲸鱼图标 Shape：从 SVG path data 渲染。
/// path data adapted from CodexBar (MIT License)。
struct WhaleShape: Shape {
    /// 鲸鱼 SVG path（viewBox 0 0 30 30）
    private static let pathData = "M27.501 8.46875C27.249 8.3457 27.1406 8.58008 26.9932 8.69922C26.9434 8.73828 26.9004 8.78906 26.8584 8.83398C26.4902 9.22852 26.0605 9.48633 25.5 9.45508C24.6787 9.41016 23.9785 9.66797 23.3594 10.2969C23.2275 9.52148 22.79 9.05859 22.125 8.76172C21.7764 8.60742 21.4238 8.45312 21.1807 8.11719C21.0098 7.87891 20.9639 7.61328 20.8779 7.35156C20.8242 7.19336 20.7695 7.03125 20.5879 7.00391C20.3906 6.97266 20.3135 7.13867 20.2363 7.27734C19.9258 7.84375 19.8066 8.46875 19.8174 9.10156C19.8447 10.5234 20.4453 11.6562 21.6367 12.4629C21.7725 12.5547 21.8076 12.6484 21.7646 12.7832C21.6836 13.0605 21.5869 13.3301 21.501 13.6074C21.4473 13.7852 21.3662 13.8242 21.1768 13.7461C20.5225 13.4727 19.957 13.0684 19.458 12.5781C18.6104 11.7578 17.8438 10.8516 16.8877 10.1426C16.6631 9.97656 16.4395 9.82227 16.207 9.67578C15.2314 8.72656 16.335 7.94727 16.5898 7.85547C16.8574 7.75977 16.6826 7.42773 15.8193 7.43164C14.957 7.43555 14.167 7.72461 13.1611 8.10938C13.0137 8.16797 12.8594 8.21094 12.7002 8.24414C11.7871 8.07227 10.8389 8.0332 9.84766 8.14453C7.98242 8.35352 6.49219 9.23633 5.39648 10.7441C4.08105 12.5547 3.77148 14.6133 4.15039 16.7617C4.54883 19.0234 5.70215 20.8984 7.47559 22.3633C9.31348 23.8809 11.4307 24.625 13.8457 24.4824C15.3125 24.3984 16.9463 24.2012 18.7881 22.6406C19.2529 22.8711 19.7402 22.9629 20.5498 23.0332C21.1729 23.0918 21.7725 23.002 22.2373 22.9062C22.9648 22.752 22.9141 22.0781 22.6514 21.9531C20.5186 20.959 20.9863 21.3633 20.5605 21.0371C21.6445 19.752 23.2783 18.418 23.917 14.0977C23.9668 13.7539 23.9238 13.5391 23.917 13.2598C23.9131 13.0918 23.9512 13.0254 24.1445 13.0059C24.6787 12.9453 25.1973 12.7988 25.6738 12.5352C27.0557 11.7793 27.6123 10.5391 27.7441 9.05078C27.7637 8.82422 27.7402 8.58789 27.501 8.46875ZM15.46 21.8613C13.3926 20.2344 12.3906 19.6992 11.9766 19.7227C11.5898 19.7441 11.6592 20.1875 11.7441 20.4766C11.833 20.7617 11.9492 20.959 12.1123 21.209C12.2246 21.375 12.3018 21.623 12 21.8066C11.334 22.2207 10.1768 21.668 10.1221 21.6406C8.77539 20.8477 7.64941 19.7988 6.85547 18.3652C6.08984 16.9844 5.64453 15.5039 5.57129 13.9238C5.55176 13.541 5.66406 13.4062 6.04297 13.3379C6.54199 13.2461 7.05762 13.2266 7.55664 13.2988C9.66602 13.6074 11.4619 14.5527 12.9668 16.0469C13.8262 16.9004 14.4766 17.918 15.1465 18.9121C15.8584 19.9688 16.625 20.9746 17.6006 21.7988C17.9443 22.0879 18.2197 22.3086 18.4824 22.4707C17.6895 22.5586 16.3652 22.5781 15.46 21.8613ZM16.4502 15.4805C16.4502 15.3105 16.5859 15.1758 16.7568 15.1758C16.7949 15.1758 16.8301 15.1836 16.8613 15.1953C16.9033 15.2109 16.9424 15.2344 16.9727 15.2695C17.0273 15.3223 17.0586 15.4004 17.0586 15.4805C17.0586 15.6504 16.9229 15.7852 16.7529 15.7852C16.582 15.7852 16.4502 15.6504 16.4502 15.4805ZM19.5273 17.0625C19.3301 17.1426 19.1328 17.2129 18.9434 17.2207C18.6494 17.2344 18.3281 17.1152 18.1533 16.9688C17.8828 16.7422 17.6895 16.6152 17.6074 16.2168C17.5732 16.0469 17.5928 15.7852 17.623 15.6348C17.6934 15.3105 17.6152 15.1035 17.3877 14.9141C17.2012 14.7598 16.9658 14.7188 16.7061 14.7188C16.6094 14.7188 16.5205 14.6758 16.4541 14.6406C16.3457 14.5859 16.2568 14.4512 16.3418 14.2852C16.3691 14.2324 16.501 14.1016 16.5322 14.0781C16.8838 13.877 17.29 13.9434 17.666 14.0938C18.0146 14.2363 18.2773 14.498 18.6562 14.8672C19.0439 15.3145 19.1133 15.4395 19.334 15.7734C19.5078 16.0371 19.667 16.3066 19.7754 16.6152C19.8408 16.8066 19.7559 16.9648 19.5273 17.0625Z"

    func path(in rect: CGRect) -> Path {
        let cgPath = CGPath.parseSVGPath(Self.pathData)
        // 原始 viewBox 30×30，按比例缩放到 rect
        let scale = min(rect.width / 30, rect.height / 30)
        var transform = CGAffineTransform(scaleX: scale, y: scale)
        let scaled = cgPath.copy(using: &transform) ?? cgPath
        return Path(scaled)
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
    /// 配色风格：默认蓝底实色；彩色卡片背景上（如关于页渐变卡片）用白色描边版
    var style: KimiCodeLogoLayerView.Style = .filled

    var body: some View {
        KimiCodeLogoLayerViewWrapper(width: width, isAnimating: isAnimating, style: style)
            .frame(width: width, height: width * 22 / 32)
    }
}

struct KimiCodeLogoLayerViewWrapper: NSViewRepresentable {
    let width: CGFloat
    let isAnimating: Bool
    var style: KimiCodeLogoLayerView.Style = .filled

    func makeNSView(context: Context) -> KimiCodeLogoLayerView {
        let view = KimiCodeLogoLayerView(frame: NSRect(x: 0, y: 0, width: width, height: width * 22 / 32))
        view.logoWidth = width
        view.style = style
        return view
    }

    func updateNSView(_ nsView: KimiCodeLogoLayerView, context: Context) {
        nsView.logoWidth = width
        nsView.style = style
        nsView.setAnimationsPaused(!isAnimating)
    }
}

final class KimiCodeLogoLayerView: NSView {
    /// Logo 配色风格：filled 蓝底实色（默认，用于常规底色）；outline 白色描边（用于彩色渐变背景）
    enum Style {
        case filled
        case outline
    }

    var logoWidth: CGFloat = 44 {
        didSet { updateLayout() }
    }

    var style: Style = .filled {
        didSet { applyStyle() }
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

        layer?.addSublayer(bodyLayer)
        layer?.addSublayer(leftEyeLayer)
        layer?.addSublayer(rightEyeLayer)

        applyStyle()
        updateLayout()
    }

    /// 按 style 应用身体与眼睛配色（outline 时身体改为白色描边、去掉蓝色光晕）
    private func applyStyle() {
        switch style {
        case .filled:
            let kimiBlue = NSColor(red: 0.23, green: 0.51, blue: 0.96, alpha: 1.0)
            bodyLayer.fillColor = kimiBlue.cgColor
            bodyLayer.strokeColor = nil
            bodyLayer.lineWidth = 0
            bodyLayer.shadowColor = kimiBlue.withAlphaComponent(0.35).cgColor
            bodyLayer.shadowOpacity = 1
            bodyLayer.shadowRadius = 8
            bodyLayer.shadowOffset = CGSize(width: 0, height: -3)
        case .outline:
            bodyLayer.fillColor = nil
            bodyLayer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
            bodyLayer.lineWidth = max(1.2, 1.2 * scale)
            bodyLayer.shadowOpacity = 0
        }
        updateEyeColors()
    }

    private func updateEyeColors() {
        let eyeColor: NSColor
        switch style {
        case .filled:
            eyeColor = NSColor(name: nil, dynamicProvider: { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return isDark
                    ? NSColor(red: 0x18 / 255.0, green: 0x18 / 255.0, blue: 0x17 / 255.0, alpha: 1.0)
                    : NSColor.white
            })
        case .outline:
            eyeColor = NSColor.white.withAlphaComponent(0.9)
        }
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
        if style == .outline {
            bodyLayer.lineWidth = max(1.2, 1.2 * scale)
        }

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

    /// CLI 版本行显示条件：用户开启，或（启用检查更新且）检测到 CLI 新版本时强制显示（无视隐藏设置）。
    /// 加 enableKimiCLIUpdateCheck 守卫：关闭检查更新后，即便磁盘缓存里有新版本号，也不强制冒出版本行。
    private var shouldShowKimiVersionRow: Bool {
        model.showKimiVersionRow
        || (model.enableKimiCLIUpdateCheck && (model.pendingUpdateVersion != nil || model.hasCachedKimiUpdate))
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
                    #if DEBUG
                    .overlay(alignment: .bottomTrailing) {
                        Text("DEV")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(Color(red: 0.86, green: 0.22, blue: 0.22))
                            )
                            .overlay(
                                Capsule().stroke(.white, lineWidth: 1)
                            )
                            .offset(x: 5, y: 3)
                    }
                    #endif

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
                // 账号配额区：单账号直接出大卡片，多账号每账号一张紧凑卡片（内部左右双列压缩布局）
                AccountQuotaListView()

                // 本机消耗量卡片：扫描本地会话记录（wire.jsonl usage.record）得出 Token 消耗。
                // Kimi Code CLI 本身可以调用其他模型（如 DeepSeek），本地会话记录跟当前主账号是哪个平台无关，
                // 因此切换主账号时不影响此卡片显示与否，只看用户开关 showLocalUsageCard。
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

            // KimiCode CLI 版本行：仅 Kimi 平台时显示；检测到新版本时无视设置强制显示
            if shouldShowKimiVersionRow, model.primaryAccount?.provider != .deepseek {
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
                // Kimi Web UI 已临时屏蔽，面板打开不再探测 58627 端口（Kimi Web 未运行时
                // 会刷大量 Connection refused 日志）。恢复 KimiServerCard 时取消注释即可。
                // Task { await model.refreshKimiServerState() }
                // 面板打开立即刷新一次额度（refresh 内部有 isRefreshing 守卫，正在刷新时会自动跳过）
                model.refresh(showsLoading: false)
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

            Button(action: { SettingsWindowManager.shared.show(pane: .accounts) }) {
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

                    LText("等待授权…")
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

// MARK: - 账号配额区（OAuth 多账号）

/// 账号配额区：按平台渲染对应卡片。Kimi 走用量卡片体系（单账号大卡片 / 多账号紧凑列表），
/// DeepSeek 走余额卡片（预充值按量付费，与 Kimi 订阅额度模型不同，各自独立卡片）。
///
/// 多账号场景下：鼠标悬停某张卡 → 手型光标 + 轻蓝色描边；点击 → 设为主账号。
/// 单账号不挂交互（无需切换）。
struct AccountQuotaListView: View {
    @StateObject private var model = KimiCodeBarModel.shared

    /// 当前鼠标悬停的账号 ID（同一时刻最多一张卡高亮）
    @State private var hoveredAccountID: UUID?

    var body: some View {
        VStack(spacing: 8) {
            if model.accounts.count <= 1, let account = model.accounts.first {
                if account.provider == .deepseek {
                    DeepSeekBalanceCard(account: account)
                } else if account.provider == .workbuddy {
                    WorkBuddyCard(account: account)
                } else {
                    SingleAccountQuotaCards(account: account)
                }
            } else {
                ForEach(model.accounts) { account in
                    let isPrimary = account.id == model.primaryAccountID
                    Group {
                        if account.provider == .deepseek {
                            DeepSeekBalanceCard(account: account)
                        } else if account.provider == .workbuddy {
                            WorkBuddyCard(account: account)
                        } else {
                            AccountQuotaCard(
                                account: account,
                                isPrimary: isPrimary
                            )
                        }
                    }
                    .modifier(AccountCardHover(
                        accountID: account.id,
                        isPrimary: isPrimary,
                        hoveredID: $hoveredAccountID,
                        onTap: { model.setPrimaryAccount(account.id) }
                    ))
                }
            }
        }
    }
}

/// 多账号卡片悬停 / 选中修饰器：
/// - 鼠标进入 → 手型光标 + 轻蓝色描边
/// - 主账号卡片本身就有视觉区分（标签 + 数字主色），此处只额外加描边，避免再加重背景
/// - 点击 → 调用 onTap，由调用方切主账号
private struct AccountCardHover: ViewModifier {
    let accountID: UUID
    let isPrimary: Bool
    @Binding var hoveredID: UUID?
    let onTap: () -> Void

    func body(content: Content) -> some View {
        let isHovered = hoveredID == accountID
        return content
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    // 主账号描边略深一档、悬停时轻蓝；非主账号只在悬停时出描边
                    .stroke(
                        Color.kimiBlue.opacity(isPrimary ? 0.85 : 0.65),
                        lineWidth: isHovered ? 1.5 : (isPrimary ? 1 : 0)
                    )
                    .animation(.easeOut(duration: 0.12), value: isHovered)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                hoveredID = hovering ? accountID : (hoveredID == accountID ? nil : hoveredID)
            }
            .onTapGesture { onTap() }
            .cursor(.pointingHand)
    }
}

// MARK: - DeepSeek 余额卡片

/// DeepSeek 账号余额卡片：极简单行布局。
/// [小 logo] 账号名 [主账号/失效标签] ............ [加载圈/¥余额/🌐]
///
/// 设计考量：DeepSeek 官方 API 仅暴露 total_balance 一个核心数字，
/// 没有"本周用量 / 5小时用量"等分维度数据，也不提供累计消费。
/// 多放字段（赠送 / 充值拆分）属于信息冗余且视觉负担，按兄弟要求做成单行横条。
/// 余额数字用主色 + semibold 视觉强调，与 Kimi 卡的百分比数字同级。
private struct DeepSeekBalanceCard: View {
    let account: KimiAccount

    @StateObject private var model = KimiCodeBarModel.shared
    @StateObject private var languageManager = LanguageManager.shared

    @State private var isHoveredConsole = false

    private var balance: DeepSeekBalance? {
        model.accountBalances[account.id]
    }

    private var state: KimiAccountState {
        model.accountStates[account.id] ?? .idle
    }

    private var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    private var isPrimary: Bool {
        account.id == model.primaryAccountID
    }

    var body: some View {
        HStack(spacing: 8) {
            // 左：DeepSeek 小 logo
            Image(account.provider.logoImageName)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)

            // 账号名（次级色，与 Kimi 卡标头同级）
            Text(model.displayName(for: account))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.kimiTextSecondary)
                .lineLimit(1)

            // 标签：仅展示「登录失效」
            if case .unauthorized = state {
                tagPill(languageManager.tr("登录失效"), color: .red)
            }

            Spacer(minLength: 8)

            // 右侧动作位 / 状态位
            if case .unauthorized = state {
                // 失效：不显示数字，只保留右侧动作给后续重授权入口（当前空）
                EmptyView()
            } else if isLoading && balance == nil {
                LoadingRing()
                    .frame(width: 12, height: 12)
            } else if let balance {
                // 正常：余额数字（主色 + semibold 强调）+ 后台入口（地球图标）
                Text(balance.balanceWithSymbol)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.kimiTextPrimary)
                    .lineLimit(1)

                if !balance.isAvailable {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }

                // 后台入口：地球图标，悬停高亮，点击打开 DeepSeek 控制台
                // 只放图标不加文字，单行横条尽量省空间，保持视觉简洁
                Button(action: {
                    NSWorkspace.shared.open(DeepSeekBalanceService.consoleURL)
                }) {
                    Image(systemName: "globe")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isHoveredConsole ? .kimiTextPrimary : .kimiTextSecondary)
                        .frame(width: 22, height: 22)
                        .background(isHoveredConsole ? Color.kimiTextPrimary.opacity(0.14) : Color.kimiTextPrimary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
                .onHover { isHoveredConsole = $0 }
                .help(languageManager.tr("打开 DeepSeek 控制台"))
            } else {
                LText("暂无余额")
                    .font(.system(size: 13))
                    .foregroundStyle(.kimiTextTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.kimiCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// 与 Kimi AccountQuotaCard 同步的小号标签样式
    private func tagPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - WorkBuddy 积分卡片

/// WorkBuddy 积分卡片：极简单行布局，与 DeepSeek 卡同款节奏。
/// [小 logo] 账号名 [当前标签] ............ ✦ 积分 [启动按钮]
///
/// 启动按钮：点击 → 写配置（如有快照切换）→ 重启 WorkBuddy 客户端。
/// 积分用星星图标 ✦ 暗示（区别于余额 ¥ 符号）。
private struct WorkBuddyCard: View {
    let account: KimiAccount

    @StateObject private var model = KimiCodeBarModel.shared
    @StateObject private var languageManager = LanguageManager.shared

    @State private var isHoveredLaunch = false

    private var credits: WorkBuddyCredits? {
        model.accountWorkBuddyCredits[account.id]
    }

    private var state: KimiAccountState {
        model.accountStates[account.id] ?? .idle
    }

    private var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    /// 该账号是否是当前 WorkBuddy 客户端登录的账号
    private var isActive: Bool {
        model.workBuddyActiveUID == account.workBuddyCredential?.uid
    }

    /// 今日是否已签到
    private var isCheckedInToday: Bool {
        model.accountCheckinDates[account.id] == WorkBuddyService.todayString()
    }

    var body: some View {
        HStack(spacing: 8) {
            // 左：WorkBuddy 小 logo
            Image("workbuddy-logo")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)

            // 账号名
            Text(model.displayName(for: account))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.kimiTextSecondary)
                .lineLimit(1)

            // 标签：当前 / 已签到
            if isActive {
                tagPill(languageManager.tr("当前"), color: .kimiBlue)
            }
            if isCheckedInToday {
                tagPill(languageManager.tr("已签到"), color: .green)
            }

            Spacer(minLength: 8)

            // 右侧：积分 / 状态 / 启动按钮
            if isLoading && credits == nil {
                LoadingRing()
                    .frame(width: 12, height: 12)
            } else if let credits {
                // 积分（sparkle 图标 + 数字）
                HStack(spacing: 3) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 10))
                        .foregroundStyle(.kimiTextSecondary)
                    Text(credits.remainingText)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.kimiTextPrimary)
                        .lineLimit(1)
                }

                // 启动按钮：写该账号到 auth 文件 → 重启 WorkBuddy（切换 + 启动）
                Button(action: { model.launchWorkBuddy(account: account) }) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isHoveredLaunch ? .kimiTextPrimary : .kimiTextSecondary)
                        .frame(width: 22, height: 22)
                        .background(isHoveredLaunch ? Color.kimiTextPrimary.opacity(0.14) : Color.kimiTextPrimary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
                .onHover { isHoveredLaunch = $0 }
                .help(languageManager.tr("启动 WorkBuddy"))
            } else {
                Text("--")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.kimiTextTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.kimiCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func tagPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - 单账号完整卡片组

/// 单账号：直接展示本周/5小时用量大卡片 + 加油包卡片。
private struct SingleAccountQuotaCards: View {
    let account: KimiAccount

    @StateObject private var model = KimiCodeBarModel.shared
    @StateObject private var languageManager = LanguageManager.shared

    /// 该账号最近一次拉取成功的配额（失败时保留旧值）
    private var quota: KimiQuota? {
        model.accountQuotas[account.id]
    }

    /// 该账号当前加载状态
    private var state: KimiAccountState {
        model.accountStates[account.id] ?? .idle
    }

    private var isLoadingState: Bool {
        if case .loading = state { return true }
        return false
    }

    var body: some View {
        if case .unauthorized = state {
            AccountUnauthorizedHint()
        } else {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    UsageCard(
                        title: languageManager.tr("本周用量"),
                        subtitle: nil,
                        percentage: quota?.weekly.percentage ?? 0,
                        reset: quota?.weekly.timeUntilReset ?? "--",
                        color: .kimiBlue,
                        isLoading: isLoadingState
                    )

                    UsageCard(
                        title: languageManager.tr("5小时用量"),
                        subtitle: nil,
                        percentage: quota?.fiveHour.percentage ?? 0,
                        reset: quota?.fiveHour.timeUntilReset ?? "--",
                        color: .orange,
                        isLoading: isLoadingState
                    )
                }

                // 加油包按官方后台开通状态自动显示：已开通才展示，未开通不占位
                if quota?.boosterWallet?.isEnabled == true {
                    BoosterWalletCard(
                        wallet: quota?.boosterWallet,
                        isLoading: isLoadingState
                    )
                }
            }
        }
    }
}

// MARK: - 多账号配额卡片

/// 多账号：每个账号一张紧凑卡片。头部为账号名与标签，下方复刻单账号 UsageCard 的
/// 左右双列布局（本周 / 5小时），信息层级与尺寸全面压缩，多账号时整组高度可控。
private struct AccountQuotaCard: View {
    let account: KimiAccount
    let isPrimary: Bool

    @StateObject private var model = KimiCodeBarModel.shared
    @StateObject private var languageManager = LanguageManager.shared

    /// 该账号最近一次拉取成功的配额（失败时保留旧值）
    private var quota: KimiQuota? {
        model.accountQuotas[account.id]
    }

    /// 该账号当前加载状态
    private var state: KimiAccountState {
        model.accountStates[account.id] ?? .idle
    }

    private var isLoadingState: Bool {
        if case .loading = state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // MARK: - 标头：账号名 + 标签行（主账号 / 会员等级 / 登录失效）
            // 账号名刻意用次级色弱化：整张卡片唯一的高亮元素是配额大数字，保证第一眼聚焦额度
            HStack(spacing: 6) {
                Text(model.displayName(for: account))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.kimiTextSecondary)
                    .lineLimit(1)

                if case .apiKey = account.credential {
                    tagPill("API Key", color: .kimiTextSecondary)
                }

                // 会员等级体系调整期：API Key 渠道取到的等级不可靠，暂只对 OAuth 账号展示
                if case .oauth = account.credential, let level = quota?.membershipLevel, !level.isEmpty {
                    tagPill(KimiQuota.membershipDisplayName(level), color: .purple)
                }

                if case .unauthorized = state {
                    tagPill(languageManager.tr("登录失效"), color: .red)
                }

                Spacer(minLength: 8)

                if isLoadingState {
                    LoadingRing()
                        .frame(width: 12, height: 12)
                }
            }

            // 简约分割线：标头与内容之间的视觉分区
            Rectangle()
                .fill(Color.kimiTextPrimary.opacity(0.06))
                .frame(height: 1)

            // MARK: - 内容
            if case .unauthorized = state {
                // 凭证保留，引导到设置-账号管理处理（管理操作在设置页完成）
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red)

                    LText("登录失效，请到设置-账号管理处理")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.kimiTextSecondary)
                }
            } else {
                // 拉取失败时保留旧数据展示，并在头部下方给出灰色错误提示
                if case .failed(let message) = state {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.kimiTextTertiary)
                        .lineLimit(1)
                }

                // 根据用户选择的显示风格渲染限额区域
                switch model.multiAccountCardStyle {
                case .classic:
                    // 经典风格：左右双列，大百分比 + 进度条 + 标题/重置时间分列
                    HStack(spacing: 12) {
                        CompactQuotaColumn(
                            title: languageManager.tr("本周用量"),
                            reset: quota?.weekly.timeUntilReset,
                            percentage: quota?.weekly.percentage,
                            color: .kimiBlue,
                            isLoading: isLoadingState
                        )

                        // 两列之间的细分隔线，呼应「一边是周限额、一边是5小时限额」的分区感
                        Rectangle()
                            .fill(Color.kimiTextPrimary.opacity(0.08))
                            .frame(width: 1)
                            .padding(.vertical, 2)

                        CompactQuotaColumn(
                            title: languageManager.tr("5小时用量"),
                            reset: quota?.fiveHour.timeUntilReset,
                            percentage: quota?.fiveHour.percentage,
                            color: .orange,
                            isLoading: isLoadingState
                        )
                    }

                case .minimal:
                    // 极简风格：单行紧凑，短标签 + 百分比 + 进度条 + 重置时间
                    VStack(alignment: .leading, spacing: 6) {
                        MinimalQuotaRow(
                            label: "7天",
                            reset: quota?.weekly.timeUntilReset,
                            percentage: quota?.weekly.percentage,
                            color: .kimiBlue,
                            isLoading: isLoadingState
                        )

                        MinimalQuotaRow(
                            label: "5时",
                            reset: quota?.fiveHour.timeUntilReset,
                            percentage: quota?.fiveHour.percentage,
                            color: .orange,
                            isLoading: isLoadingState
                        )
                    }
                }

                // 加油包按官方后台开通状态自动显示：已开通才展示，未开通不占位
                if quota?.boosterWallet?.isEnabled == true {
                    AccountBoosterLine(
                        wallet: quota?.boosterWallet,
                        isLoading: isLoadingState
                    )
                }
            }
        }
        .padding(14)
        .background(Color.kimiCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    /// 卡片头部的小号标签：与设置页 StatusTag 同一比例（9pt / 0.12 底色 / 圆角 4）
    private func tagPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - 紧凑限额列

/// 多账号卡片内的单列限额。视觉层级复刻单账号 UsageCard：小号标题在上，
/// 超大百分比做视觉主角（第一眼聚焦额度），下方细进度条与重置时间为次要信息。
/// 相比单账号大卡片仅做尺寸收敛：标题 11pt、数值 24pt、进度条 4pt、重置时间 10pt。
private struct CompactQuotaColumn: View {
    let title: String
    let reset: String?
    let percentage: Int?
    let color: Color
    let isLoading: Bool

    private var clampedPercentage: Int {
        min(percentage ?? 0, 100)
    }

    /// 压缩重置时间文本：去掉「后重置」，「小时」→「时」，「分钟」→「分」
    /// 例："20小时38分钟后重置"→"20时38分"，"1小时38分钟后重置"→"1时38分"，"38分钟后重置"→"38分"
    private var compressedReset: String {
        guard let reset else { return "--" }
        // "后重置" 去掉
        var s = reset
        s = s.replacingOccurrences(of: "后重置", with: "")
        s = s.replacingOccurrences(of: "小时", with: "时")
        s = s.replacingOccurrences(of: "分钟", with: "分")
        return s.isEmpty ? reset : s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 百分比靠左，重置时间靠右
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if !isLoading {
                    if percentage != nil {
                        Text("\(clampedPercentage)")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.kimiTextPrimary)
                        + Text("%")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.kimiTextPrimary)
                    } else {
                        Text("--")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(.kimiTextTertiary)
                    }
                }

                if isLoading {
                    LoadingRing()
                        .frame(width: 18, height: 18)
                }

                Spacer(minLength: 4)

                Text(compressedReset)
                    .font(.system(size: 10))
                    .foregroundStyle(.kimiTextTertiary)
                    .lineLimit(1)
            }
            .frame(height: 28)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .frame(height: 4)
                        .foregroundStyle(Color.kimiTextPrimary.opacity(0.10))

                    Capsule()
                        .frame(width: proxy.size.width * CGFloat(clampedPercentage) / 100, height: 4)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [color, color.opacity(0.55)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .shadow(color: color.opacity(0.4), radius: 2, x: 0, y: 1)
                }
            }
            .frame(height: 4)

            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.kimiTextSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 极简限额行

/// 多账号卡片「极简」风格的单行限额：短标签 + 百分比 + 进度条 + 重置时间，全在一行。
/// 每个元素尺寸收敛到最小：标签 11pt、百分比 13pt、进度条 3pt、重置时间 10pt。
private struct MinimalQuotaRow: View {
    /// 短标签，如「周」「5h」
    let label: String
    let reset: String?
    let percentage: Int?
    let color: Color
    let isLoading: Bool

    private var clampedPercentage: Int {
        min(percentage ?? 0, 100)
    }

    /// 压缩重置时间文本（与 CompactQuotaColumn 同逻辑）
    private var compressedReset: String {
        guard let reset else { return "--" }
        var s = reset
        s = s.replacingOccurrences(of: "后重置", with: "")
        s = s.replacingOccurrences(of: "小时", with: "时")
        s = s.replacingOccurrences(of: "分钟", with: "分")
        return s.isEmpty ? reset : s
    }

    var body: some View {
        HStack(spacing: 8) {
            // 短标签
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.kimiTextSecondary)
                .frame(width: 20, alignment: .leading)

            // 百分比：固定宽度，保证两行进度条起点一致
            Group {
                if !isLoading {
                    if percentage != nil {
                        Text("\(clampedPercentage)%")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.kimiTextPrimary)
                    } else {
                        Text("--%")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.kimiTextTertiary)
                    }
                } else {
                    LoadingRing()
                        .frame(width: 12, height: 12)
                }
            }
            .frame(width: 32, alignment: .leading)

            // 进度条
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .frame(height: 3)
                        .foregroundStyle(Color.kimiTextPrimary.opacity(0.10))

                    Capsule()
                        .frame(width: proxy.size.width * CGFloat(clampedPercentage) / 100, height: 3)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [color, color.opacity(0.55)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }
            }
            .frame(height: 3)

            // 重置时间：固定宽度，保证两行进度条长度一致
            Text(compressedReset)
                .font(.system(size: 10))
                .foregroundStyle(.kimiTextTertiary)
                .lineLimit(1)
                .frame(width: 48, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 多账号风格选择卡片

/// 设置页「多账号显示风格」的可选卡片：标题 + 勾选 + 内嵌小预览，一行排列两个。
/// 视觉风格对齐 SettingsOptionCard，但内嵌预览替代了 subtitle。
private struct MultiAccountStyleOptionCard: View {
    let style: MultiAccountCardStyle
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                // 标题行：图标 + 名称 + 勾选
                HStack(spacing: 8) {
                    Image(systemName: style.iconName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isSelected ? .kimiBlue : .kimiTextSecondary)

                    Text(style.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.kimiTextPrimary)

                    Spacer(minLength: 4)

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isSelected ? .kimiBlue : .kimiTextTertiary)
                }

                // 内嵌预览
                MultiAccountCardStylePreview(style: style)
                    .frame(maxWidth: .infinity)
            }
            .padding(10)
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

// MARK: - 多账号卡片风格预览

/// 设置页「多账号显示风格」的模拟预览：用假数据渲染一个缩小版卡片，
/// 让用户直观看到每种风格的视觉效果。非实时、非交互。
private struct MultiAccountCardStylePreview: View {
    let style: MultiAccountCardStyle

    var body: some View {
        switch style {
        case .classic:
            classicPreview
        case .minimal:
            minimalPreview
        }
    }

    // 经典风格预览：标头 + 分割线 + 左右双列
    private var classicPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 标头
            HStack(spacing: 4) {
                Text("Kimi")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.kimiTextSecondary)
                PreviewTagPill("主账号", color: .kimiBlue)
            }

            Rectangle()
                .fill(Color.kimiTextPrimary.opacity(0.06))
                .frame(height: 1)

            // 双列
            HStack(spacing: 8) {
                PreviewCompactQuotaColumn(title: "本周用量", percentage: 56, reset: "20时38分", color: .kimiBlue)
                Rectangle()
                    .fill(Color.kimiTextPrimary.opacity(0.08))
                    .frame(width: 1)
                PreviewCompactQuotaColumn(title: "5小时用量", percentage: 0, reset: "1时38分", color: .orange)
            }
        }
        .padding(10)
        .background(Color.kimiCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 320)
    }

    // 极简风格预览：标头 + 分割线 + 两行紧凑行
    private var minimalPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 标头
            HStack(spacing: 4) {
                Text("Kimi")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.kimiTextSecondary)
                PreviewTagPill("主账号", color: .kimiBlue)
            }

            Rectangle()
                .fill(Color.kimiTextPrimary.opacity(0.06))
                .frame(height: 1)

            // 极简单行
            VStack(alignment: .leading, spacing: 4) {
                PreviewMinimalRow(label: "7天", percentage: 56, reset: "3天2时", color: .kimiBlue)
                PreviewMinimalRow(label: "5时", percentage: 0, reset: "2时28分", color: .orange)
            }
        }
        .padding(10)
        .background(Color.kimiCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 320)
    }
}

/// 预览用的缩小版标签胶囊
private struct PreviewTagPill: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.system(size: 7, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

/// 预览用的缩小版 CompactQuotaColumn
private struct PreviewCompactQuotaColumn: View {
    let title: String
    let percentage: Int
    let reset: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(percentage)")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.kimiTextPrimary)
                + Text("%")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.kimiTextPrimary)

                Spacer(minLength: 2)

                Text(reset)
                    .font(.system(size: 6))
                    .foregroundStyle(.kimiTextTertiary)
            }
            .frame(height: 16)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .frame(height: 2)
                        .foregroundStyle(Color.kimiTextPrimary.opacity(0.10))
                    Capsule()
                        .frame(width: proxy.size.width * CGFloat(percentage) / 100, height: 2)
                        .foregroundStyle(color)
                }
            }
            .frame(height: 2)

            Text(title)
                .font(.system(size: 7, weight: .medium))
                .foregroundStyle(.kimiTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 预览用的缩小版 MinimalQuotaRow
private struct PreviewMinimalRow: View {
    let label: String
    let percentage: Int
    let reset: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 7, weight: .medium))
                .foregroundStyle(.kimiTextSecondary)
                .frame(width: 16, alignment: .leading)

            Text("\(percentage)%")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.kimiTextPrimary)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .frame(height: 2)
                        .foregroundStyle(Color.kimiTextPrimary.opacity(0.10))
                    Capsule()
                        .frame(width: proxy.size.width * CGFloat(percentage) / 100, height: 2)
                        .foregroundStyle(color)
                }
            }
            .frame(height: 2)

            Text(reset)
                .font(.system(size: 6))
                .foregroundStyle(.kimiTextTertiary)
        }
    }
}

// MARK: - 加油包余额行

/// 多账号卡片内的加油包余额行：标题 + 启用状态标签，右侧本月消费与余额；
/// 下方橙色胶囊进度条（本月消费 / 月度上限），字号与进度条规格对齐 CompactQuotaColumn。
private struct AccountBoosterLine: View {
    let wallet: BoosterWallet?
    let isLoading: Bool

    private var progress: Double {
        guard let wallet, wallet.monthlyChargeLimitEnabled, wallet.monthlyChargeLimitYuan > 0 else { return 0 }
        return min(wallet.monthlyUsedYuan / wallet.monthlyChargeLimitYuan, 1.0)
    }

    private var limitText: String {
        guard let wallet, wallet.monthlyChargeLimitEnabled, wallet.monthlyChargeLimitCents > 0 else {
            return LanguageManager.tr("无限制")
        }
        return formatCurrency(wallet.monthlyChargeLimitYuan, currency: wallet.currency)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                LText("加油包余额")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.kimiTextTertiary)

                if let wallet {
                    LText(wallet.isEnabled ? "已启用" : "未启用")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(wallet.isEnabled ? .green : .kimiTextTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background((wallet.isEnabled ? Color.green : Color.kimiTextTertiary).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                Spacer()

                if isLoading {
                    LoadingRing()
                        .frame(width: 10, height: 10)
                } else {
                    if let wallet {
                        HStack(spacing: 4) {
                            LText("本月消费")
                                .font(.system(size: 10))
                                .foregroundStyle(.kimiTextTertiary)

                            Text("\(formatCurrency(wallet.monthlyUsedYuan, currency: wallet.currency)) / \(limitText)")
                                .font(.system(size: 10))
                                .foregroundStyle(.kimiTextTertiary)
                                .monospacedDigit()
                        }
                    }

                    if let wallet {
                        Text(formatCurrency(wallet.balanceYuan, currency: wallet.currency))
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(wallet.isEnabled ? .kimiTextPrimary : .kimiTextTertiary)
                    } else {
                        Text("--")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.kimiTextTertiary)
                    }
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .frame(height: 4)
                        .foregroundStyle(Color.kimiTextPrimary.opacity(0.10))

                    let fillColor: Color = (wallet?.isEnabled ?? false) ? .orange : .kimiTextTertiary
                    Capsule()
                        .frame(width: proxy.size.width * CGFloat(progress), height: 4)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [fillColor, fillColor.opacity(0.55)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .shadow(color: fillColor.opacity(0.4), radius: 2, x: 0, y: 1)
                }
            }
            .frame(height: 4)
        }
    }
}

// MARK: - 登录失效提示

/// 单账号登录失效：凭证保留，引导到设置-账号管理处理（管理操作在设置页完成）
private struct AccountUnauthorizedHint: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.red)

            LText("登录失效，请到设置-账号管理处理")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.kimiTextSecondary)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
final class SettingsWindowManager: ObservableObject {
    static let shared = SettingsWindowManager()
    private var window: NSWindow?

    /// 当前选中的设置页，默认「账号管理」（设置面板第一项）
    @Published var selectedPane: SettingsPane = .accounts

    private init() {}

    /// 打开设置窗口并定位到指定页（默认账号管理）
    func show(pane: SettingsPane = .accounts) {
        selectedPane = pane
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
        // 现代 macOS 设置窗口做法（参考豆包/系统设置）：隐藏标题文字 + 标题栏透明 +
        // 内容延伸至窗口顶部，红绿灯按钮直接浮在侧边栏底色上，消除标题栏与内容区的割裂感
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        // 标题栏视觉消失后，允许从空白区域拖动窗口
        window.isMovableByWindowBackground = true
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
    case accounts
    case basic
    case panelCustom
    case archive
    case skills
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accounts: return LanguageManager.tr("账号管理")
        case .basic: return LanguageManager.tr("基本设置")
        case .panelCustom: return LanguageManager.tr("外观样式")
        case .archive: return LanguageManager.tr("自动归档")
        case .skills: return LanguageManager.tr("技能管理")
        case .about: return LanguageManager.tr("关于")
        }
    }

    var icon: String {
        switch self {
        case .accounts: return "person.2"
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
    @StateObject private var windowManager = SettingsWindowManager.shared

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(SettingsPane.allCases) { pane in
                        SettingsSidebarItem(
                            pane: pane,
                            isSelected: windowManager.selectedPane == pane
                        ) {
                            windowManager.selectedPane = pane
                        }
                    }
                }
                .padding(.horizontal, 12)
                // 顶部留出红绿灯按钮区域（窗口已改为全尺寸内容视图，按钮浮在侧边栏上）
                .padding(.top, 40)

                Spacer()
            }
            .frame(width: 180)
            .background(Color.kimiSidebarBackground)

            switch windowManager.selectedPane {
            case .basic:
                BasicSettingsView()
            case .accounts:
                AccountsSettingsView()
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

// MARK: - 基本设置

struct BasicSettingsView: View {
    @StateObject private var model = KimiCodeBarModel.shared
    @StateObject private var launchAtLoginManager = LaunchAtLoginManager.shared
    @StateObject private var languageManager = LanguageManager.shared

    @State private var quotaIntervalText = "5"
    @State private var updateIntervalText = "30"
    @FocusState private var focusedField: APISettingField?

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginManager.isEnabled },
            set: { launchAtLoginManager.setEnabled($0) }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LText("基本设置")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.kimiTextPrimary)

                // 启动
                SettingsCard {
                    SettingsCardRow(title: languageManager.tr("开机自动启动")) {
                        Toggle("", isOn: launchAtLoginBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .cursor(.pointingHand)
                    }
                }

                // 额度刷新
                SettingsCard {
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
                }

                // KimiCode CLI 检查更新
                SettingsCard {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsCardRow(
                            title: languageManager.tr("KimiCode CLI 检查更新"),
                            subtitle: languageManager.tr("关闭后打开面板和后台都不再检查新版本")
                        ) {
                            Toggle("", isOn: $model.enableKimiCLIUpdateCheck)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .cursor(.pointingHand)
                                .onChange(of: model.enableKimiCLIUpdateCheck) { _, isEnabled in
                                    if !isEnabled {
                                        // 关闭时清掉待更新状态，避免残留弹窗/通知
                                        model.pendingUpdateVersion = nil
                                        model.snoozedKimiUpdateUntil = 0
                                    }
                                    // 重启 Timer：开启时按间隔起 Timer，关闭时 invalidate
                                    model.restartTimers()
                                }
                        }

                        SettingsCardDivider()

                        SettingsCardRow(title: languageManager.tr("检查更新间隔")) {
                            HStack(spacing: 6) {
                                TextField("", text: $updateIntervalText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 60)
                                    .focused($focusedField, equals: .updateInterval)
                                    .disabled(!model.enableKimiCLIUpdateCheck)
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
                        .opacity(model.enableKimiCLIUpdateCheck ? 1.0 : 0.5)
                    }
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
            }
            .padding(.horizontal, 24)
            .padding(.top, 44)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.kimiPanelBackground)
        .onAppear {
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
}

// MARK: - 外观

/// 设置窗口「外观样式」页：卡片显示开关、外观主题、菜单栏样式。
struct PanelCustomSettingsView: View {
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var model = KimiCodeBarModel.shared
    @StateObject private var languageManager = LanguageManager.shared

    @State private var isHoveredRepoLink = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LText("外观样式")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.kimiTextPrimary)

                // 卡片显示
                SettingsCard(title: languageManager.tr("卡片显示")) {
                    VStack(alignment: .leading, spacing: 0) {
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
                            title: languageManager.tr("KimiCodeBar 版本号"),
                            subtitle: languageManager.tr("发现新版本时会强制显示")
                        ) {
                            Toggle("", isOn: $model.showAppUpdateRow)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .cursor(.pointingHand)
                        }
                    }
                }

                // 多账号显示风格
                SettingsCard(title: languageManager.tr("多账号显示风格")) {
                    HStack(spacing: 10) {
                        ForEach(MultiAccountCardStyle.allCases) { style in
                            MultiAccountStyleOptionCard(
                                style: style,
                                isSelected: model.multiAccountCardStyle == style
                            ) {
                                model.multiAccountCardStyle = style
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
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
                                .foregroundStyle(.white)
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

                // 建议反馈：外观建议欢迎到仓库提 Issue / PR
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Text("✨")
                            .font(.system(size: 12))

                        LText("如果你有更好的建议，欢迎去仓库提交 Issue 或 PR。")
                            .font(.system(size: 12))
                            .foregroundStyle(.kimiTextSecondary)
                    }

                    Spacer()

                    Button(action: {
                        NSWorkspace.shared.open(URL(string: "https://github.com/xifandev/KimiCodeBar")!)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "link")
                                .font(.system(size: 10, weight: .medium))
                            LText("GitHub 仓库")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(isHoveredRepoLink ? .kimiTextPrimary : .kimiTextSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(isHoveredRepoLink ? Color.kimiTextPrimary.opacity(0.14) : Color.kimiTextPrimary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .cursor(.pointingHand)
                    .onHover { isHoveredRepoLink = $0 }
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
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LText("关于")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.kimiTextPrimary)

                // GitHub 开源社区卡片
                GitHubCommunityCard()

                // 贡献者鸣谢：感谢每一位共建者，也欢迎更多人加入
                ContributorsCard()
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

// MARK: - 贡献者

/// GitHub 贡献者（公开 API，无需鉴权）
struct GitHubContributor: Decodable, Identifiable {
    let login: String
    let avatarURL: URL?
    let contributions: Int
    let type: String?

    var id: String { login }

    enum CodingKeys: String, CodingKey {
        case login
        case contributions
        case type
        case avatarURL = "avatar_url"
    }
}

/// 贡献者列表提供者：App 生命周期内只拉取一次；失败静默降级（隐藏列表、保留共建入口）。
final class ContributorsProvider: ObservableObject {
    static let shared = ContributorsProvider()

    @Published private(set) var contributors: [GitHubContributor] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false

    private var didStartLoad = false

    private init() {}

    func loadIfNeeded() {
        guard !didStartLoad else { return }
        didStartLoad = true
        isLoading = true

        Task {
            defer { isLoading = false }
            do {
                let url = URL(string: "https://api.github.com/repos/xifandev/KimiCodeBar/contributors")!
                var request = URLRequest(url: url, timeoutInterval: 10)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, _) = try await URLSession.shared.data(for: request)
                let all = try JSONDecoder().decode([GitHubContributor].self, from: data)
                // 只展示真实用户：过滤 Bot（如 github-actions[bot]）
                contributors = all.filter { $0.type != "Bot" && !$0.login.contains("[bot]") }
            } catch {
                loadFailed = true
            }
        }
    }
}

/// 「关于」页的贡献者鸣谢板块：头像 + 用户名 + 提交数，底部为共建入口。
private struct ContributorsCard: View {
    @StateObject private var provider = ContributorsProvider.shared
    @StateObject private var languageManager = LanguageManager.shared

    @State private var isHoveredContribute = false

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 0) {
                // 标题 + 人数徽章
                HStack(spacing: 6) {
                    LText("贡献者")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.kimiTextPrimary)

                    if !provider.contributors.isEmpty {
                        Text("\(provider.contributors.count)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.kimiTextSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.kimiTextPrimary.opacity(0.08))
                            .clipShape(Capsule())
                    }

                    Spacer()

                    if provider.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

                if provider.isLoading && provider.contributors.isEmpty {
                    skeletonRows
                } else if !provider.contributors.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(provider.contributors) { contributor in
                            ContributorRow(contributor: contributor)
                        }
                    }
                    .padding(.bottom, 6)
                }

                Divider()
                    .background(Color.kimiTextPrimary.opacity(0.08))
                    .padding(.leading, 16)

                // 共建入口
                HStack(spacing: 8) {
                    LText("每一个 PR 都欢迎，期待在这里看到你的名字")
                        .font(.system(size: 12))
                        .foregroundStyle(.kimiTextSecondary)

                    Spacer()

                    Button(action: {
                        NSWorkspace.shared.open(URL(string: "https://github.com/xifandev/KimiCodeBar")!)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "link")
                                .font(.system(size: 10, weight: .medium))
                            LText("参与共建")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(isHoveredContribute ? .kimiTextPrimary : .kimiTextSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(isHoveredContribute ? Color.kimiTextPrimary.opacity(0.14) : Color.kimiTextPrimary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .cursor(.pointingHand)
                    .onHover { isHoveredContribute = $0 }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .onAppear { provider.loadIfNeeded() }
    }

    /// 加载中的骨架行
    private var skeletonRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color.kimiTextPrimary.opacity(0.08))
                        .frame(width: 28, height: 28)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.kimiTextPrimary.opacity(0.08))
                        .frame(width: 120, height: 12)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
}

/// 单个贡献者行：头像 + 用户名 + 提交数
private struct ContributorRow: View {
    let contributor: GitHubContributor

    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: contributor.avatarURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    Circle().fill(Color.kimiTextPrimary.opacity(0.10))
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(Circle())

            Text(contributor.login)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.kimiTextPrimary)

            Spacer()

            Text(LanguageManager.tr("%1$d 次提交", arguments: [contributor.contributions]))
                .font(.system(size: 11))
                .foregroundStyle(.kimiTextTertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
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
                // 应用图标：蓝色渐变卡片上用白色描边版（蓝底实色 Logo 与卡片底色撞色）
                AnimatedKimiCodeLogo(width: 54, isAnimating: false, style: .outline)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("KimiCodeBar")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)

                        Text("Open Source")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.18))
                            .clipShape(RoundedRectangle(cornerRadius: 5))

                        // 版本号跟在标题行（原底部应用信息卡片已合并至此）
                        LText("版本 %@", appVersion())
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.65))
                            .monospacedDigit()
                    }

                    LText("完全开源，代码公开透明。")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)

                    LText("欢迎 Star、提交 Issue 或参与共建，让这款工具变得更好。")
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

    @AppStorage("quotaRefreshInterval") var quotaRefreshInterval: Double = 3
    @AppStorage("updateCheckInterval") var updateCheckInterval: Double = 10
    /// 是否启用 KimiCode CLI 更新检查。关闭后：后台 Timer 不启动、面板打开不联网检查、
    /// 不基于缓存弹窗、不发系统通知；本地版本号读取（loadKimiVersion）不受影响，
    /// 版本行仍可正常显示当前 CLI 版本号（供用户排查/反馈 issue 时查看）。
    @AppStorage("enableKimiCLIUpdateCheck") var enableKimiCLIUpdateCheck: Bool = true
    @AppStorage("menuBarDisplayScheme") var menuBarDisplayScheme: MenuBarDisplayScheme = .compact
    @AppStorage("ignoredAppUpdateVersion") var ignoredAppUpdateVersion: String = ""
    @AppStorage("cachedKimiLatestVersion") var cachedKimiLatestVersion: String = ""
    @AppStorage("cachedKimiReleaseNotes") var cachedKimiReleaseNotes: String = ""
    @AppStorage("snoozedKimiUpdateUntil") var snoozedKimiUpdateUntil: Double = 0

    // MARK: - 卡片显示（用户控制各卡片是否显示）
    @AppStorage("showLocalUsageCard") var showLocalUsageCard: Bool = true
    @AppStorage("showKimiServerCard") var showKimiServerCard: Bool = true
    @AppStorage("showKimiVersionRow") var showKimiVersionRow: Bool = false
    @AppStorage("showAppUpdateRow") var showAppUpdateRow: Bool = false

    // MARK: - 多账号卡片显示风格
    @AppStorage("multiAccountCardStyle") var multiAccountCardStyle: MultiAccountCardStyle = .classic

    // MARK: - WorkBuddy 集成
    /// 每个账号的积分（key = account UUID），失败时保留旧值
    @Published var accountWorkBuddyCredits: [UUID: WorkBuddyCredits] = [:]
    /// 每个账号的签到日期（UUID → "yyyy-MM-dd"），驱动 UI 显示「已签到」标签
    @Published var accountCheckinDates: [UUID: String] = [:]
    /// WorkBuddy 客户端是否在运行
    @Published var isWorkBuddyRunning = false
    /// 当前在 WorkBuddy 中登录的账号 uid（读 auth 文件得到）
    @Published var workBuddyActiveUID: String?

    @Published var text = "-- · --"
    @Published var quota: KimiQuota?
    @Published var errorMessage: String?
    @Published var isLoading = false

    @Published var oauthDeviceAuth: KimiDeviceAuthorization?
    @Published var oauthLoginInProgress = false
    @Published var oauthLoginError: String?

    // MARK: - 多账号

    /// 账号列表（镜像 KimiAccountStore 的内存状态）
    @Published var accounts: [KimiAccount] = []
    /// 主账号 ID：菜单栏文字/图形与面板只展示主账号用量
    @Published var primaryAccountID: UUID?
    /// 每个账号最近一次拉取成功的配额（失败时保留旧值）。仅 Kimi 账号有值。
    @Published var accountQuotas: [UUID: KimiQuota] = [:]
    /// 每个账号最近一次拉取成功的余额（失败时保留旧值）。仅 DeepSeek 账号有值。
    @Published var accountBalances: [UUID: DeepSeekBalance] = [:]
    /// 每个账号的加载状态（错误隔离：单账号失败不影响其他账号）
    @Published var accountStates: [UUID: KimiAccountState] = [:]
    /// CLI 活跃账号（与 CLI 凭证文件 token 匹配的账号），用于账号列表「CLI 使用中」标签；
    /// CLI 轮换 token 后匹配失效，自动回退为 nil
    @Published var cliActiveAccountID: UUID?

    /// 当前主账号（便捷访问）：面板按其 provider 决定渲染哪种卡片
    var primaryAccount: KimiAccount? {
        guard let id = primaryAccountID else { return nil }
        return accounts.first(where: { $0.id == id })
    }

    /// 兼容属性：主账号的 OAuth token（API Key 主账号为 nil）。现有 UI 只读它判断是否已授权。
    var oauthToken: KimiOAuthToken? {
        guard let id = primaryAccountID else { return nil }
        return accounts.first(where: { $0.id == id })?.oauthToken
    }

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
    private let deepseekService = DeepSeekBalanceService()
    private let oauthService = KimiOAuthService()
    private var oauthLoginTask: Task<Void, Never>?
    private var timer: Timer?
    private var updateTimer: Timer?

    /// 正在刷新配额时置 true，防止并发 refresh() 调用。
    /// Kimi 服务端每次刷新都会轮换 refresh_token，两次并发刷新会导致第二次被判定为 unauthorized。
    private var isRefreshing = false

    /// 当前是否已配置可用凭证（决定菜单栏是否提示去设置）
    var hasCredential: Bool {
        !accounts.isEmpty
    }

    init() {
        // 迁移旧的 WorkBuddy 独立账号存储到 KimiAccountStore 统一体系
        WorkBuddyService.migrateOldAccounts()
        // 加载账号凭证并保证主账号有效（旧版凭证格式按无账号处理，需重新登录）
        let store = KimiAccountStore.shared
        store.ensurePrimaryAccount()
        let snapshot = store.snapshot
        accounts = snapshot.accounts
        primaryAccountID = snapshot.primaryAccountID
        refresh(showsLoading: false)
        refreshWorkBuddyAccounts()
        Task { await loadKimiVersion() }
        startQuotaTimer()
        startUpdateTimer()
        // 关闭检查更新时，清掉可能残留的待更新状态，避免启动后弹窗/通知
        if !enableKimiCLIUpdateCheck {
            pendingUpdateVersion = nil
            snoozedKimiUpdateUntil = 0
        }
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
        // 关闭检查更新时不起后台 Timer，确保后台不再做任何 CLI 更新检查
        guard enableKimiCLIUpdateCheck else {
            updateTimer = nil
            return
        }
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
    ///   仅手动点「刷新」按钮时传 true；后台场景（启动、定时器、面板打开、
    ///   设置窗口 onAppear）一律传 false，避免界面无谓闪烁。
    /// - Note: 正在刷新时直接跳过，避免并发刷新同一个 refresh_token 导致服务端轮换冲突。
    func refresh(showsLoading: Bool = true) {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshCliActiveAccount()
        refreshAllAccounts(showsLoading: showsLoading)
    }

    /// 解析单个 OAuth 账号当前可用的 access token。
    /// 过期前自动用 refresh_token 换新；刷新前再读一次磁盘，防御其他 Bar 实例刚刷新过；
    /// 授权被吊销（unauthorized）时返回 nil，由调用方把账号标记为「登录失效」——
    /// 凭证保留在列表中等待用户重新授权，不删除。
    private func resolveAccessToken(for accountID: UUID) async -> String? {
        let store = KimiAccountStore.shared
        guard let token = store.account(id: accountID)?.oauthToken, token.isValid else { return nil }

        guard token.needsRefresh else {
            return token.accessToken
        }

        // 刷新前再读一次磁盘：防御其他 Bar 实例刚完成刷新并写入了新凭证
        if let latest = store.freshAccount(id: accountID)?.oauthToken,
           latest.accessToken != token.accessToken,
           !latest.needsRefresh {
            return latest.accessToken
        }

        let result = await oauthService.refreshAccessToken(token)
        switch result {
        case .success(let newToken):
            store.updateOAuthToken(id: accountID, token: newToken)
            return newToken.accessToken
        case .failure(.unauthorized):
            // 若磁盘上已是另一份凭证（其他实例刷新成功），直接沿用
            if let latest = store.freshAccount(id: accountID)?.oauthToken,
               latest.accessToken != token.accessToken {
                return latest.accessToken
            }
            // 授权已被吊销：标记「登录失效」，等待用户重新授权
            return nil
        case .failure:
            // 网络等原因刷新失败，先沿用旧 token 让服务端决定是否拒绝
            return token.accessToken
        }
    }

    // MARK: - 多账号刷新

    /// 并行刷新全部账号的配额。错误隔离：单账号失败（含登录失效）只标记该账号，
    /// 不影响其他账号，也不删除任何凭证。完成后把主账号数据同步到兼容属性。
    func refreshAllAccounts(showsLoading: Bool = true) {
        if showsLoading {
            isLoading = true
        }
        errorMessage = nil

        let store = KimiAccountStore.shared
        // 同步磁盘最新状态（含其他 Bar 实例的写入）
        store.reload()
        store.ensurePrimaryAccount()
        let snapshot = store.snapshot
        accounts = snapshot.accounts
        primaryAccountID = snapshot.primaryAccountID

        guard !snapshot.accounts.isEmpty else {
            if showsLoading {
                isLoading = false
            }
            isRefreshing = false
            accountQuotas = [:]
            accountBalances = [:]
            accountStates = [:]
            accountWorkBuddyCredits = [:]
            accountCheckinDates = [:]
            syncPrimaryCompat()
            return
        }

        // 清掉已删除账号的缓存（例如被其他 Bar 实例删除）
        let validIDs = Set(snapshot.accounts.map(\.id))
        accountQuotas = accountQuotas.filter { validIDs.contains($0.key) }
        accountBalances = accountBalances.filter { validIDs.contains($0.key) }
        accountStates = accountStates.filter { validIDs.contains($0.key) }
        accountWorkBuddyCredits = accountWorkBuddyCredits.filter { validIDs.contains($0.key) }
        accountCheckinDates = accountCheckinDates.filter { validIDs.contains($0.key) }

        for account in snapshot.accounts {
            accountStates[account.id] = .loading
        }

        Task {
            // result 与 error 均为 nil 表示「登录失效」（resolveAccessToken 返回 nil / Key 无效）
            var results: [(UUID, AccountFetchResult?, QuotaError?)] = []
            await withTaskGroup(of: (UUID, AccountFetchResult?, QuotaError?).self) { group in
                for account in snapshot.accounts {
                    group.addTask {
                        switch account.provider {
                        case .kimi:
                            // Kimi：OAuth 走 token 刷新链路，API Key 直接当 Bearer token 用
                            let token: String?
                            switch account.credential {
                            case .oauth:
                                token = await self.resolveAccessToken(for: account.id)
                            case .apiKey(let key):
                                token = key
                            case .workbuddy:
                                token = nil
                            }
                            guard let accessToken = token else {
                                return (account.id, nil, nil)
                            }
                            switch await self.service.fetchQuota(token: accessToken) {
                            case .success(let quota):
                                return (account.id, .kimi(quota), nil)
                            case .failure(let error):
                                return (account.id, nil, error)
                            }
                        case .deepseek:
                            // DeepSeek：仅 API Key，无 OAuth
                            guard case .apiKey(let key) = account.credential else {
                                return (account.id, nil, nil)
                            }
                            switch await self.deepseekService.fetchBalance(apiKey: key) {
                            case .success(let balance):
                                return (account.id, .deepseek(balance), nil)
                            case .failure(let error):
                                // Key 无效（401/403）按「登录失效」处理，引导用户修改 Key
                                if case .httpError(let statusCode, _) = error, statusCode == 401 || statusCode == 403 {
                                    return (account.id, nil, nil)
                                }
                                return (account.id, nil, error)
                            }
                        case .workbuddy:
                            // WorkBuddy 账号由 refreshWorkBuddyAccounts() 独立处理积分，此处跳过
                            return (account.id, nil, nil)
                        }
                    }
                }
                for await item in group {
                    results.append(item)
                }
            }

            await MainActor.run {
                for (id, result, error) in results {
                    if let result {
                        switch result {
                        case .kimi(let quota):
                            self.accountQuotas[id] = quota
                        case .deepseek(let balance):
                            self.accountBalances[id] = balance
                        case .workbuddy(let credits):
                            self.accountWorkBuddyCredits[id] = credits
                        }
                        self.accountStates[id] = .loaded
                    } else if let error {
                        self.accountStates[id] = .failed(self.errorDescription(error))
                    } else {
                        self.accountStates[id] = .unauthorized
                    }
                }
                // 同步一次镜像（token 可能已被刷新轮换），并清掉期间被删除账号的缓存
                let latest = KimiAccountStore.shared.snapshot
                self.accounts = latest.accounts
                self.primaryAccountID = latest.primaryAccountID
                let validIDs = Set(latest.accounts.map(\.id))
                self.accountQuotas = self.accountQuotas.filter { validIDs.contains($0.key) }
                self.accountBalances = self.accountBalances.filter { validIDs.contains($0.key) }
                self.accountStates = self.accountStates.filter { validIDs.contains($0.key) }
                self.accountWorkBuddyCredits = self.accountWorkBuddyCredits.filter { validIDs.contains($0.key) }
                self.accountCheckinDates = self.accountCheckinDates.filter { validIDs.contains($0.key) }
                if showsLoading {
                    self.isLoading = false
                }
                self.isRefreshing = false
                self.syncPrimaryCompat()
            }
        }
    }

    /// 把主账号数据同步到兼容属性（quota / text / errorMessage），
    /// 让现有只读这些属性的 UI 在多账号下无需修改即可工作。
    private func syncPrimaryCompat() {
        guard let primaryID = primaryAccountID,
              let primaryAccount = accounts.first(where: { $0.id == primaryID }) else {
            quota = nil
            text = LanguageManager.tr("未登录")
            errorMessage = nil
            return
        }
        switch primaryAccount.provider {
        case .kimi:
            if let primaryQuota = accountQuotas[primaryID] {
                quota = primaryQuota
                text = LanguageManager.tr("周 %1$d%% · 5h %2$d%%", arguments: [primaryQuota.weekly.percentage, primaryQuota.fiveHour.percentage])
            } else {
                quota = nil
                text = "--"
            }
        case .deepseek:
            // DeepSeek 主账号：quota 置 nil（Kimi 用量视图不渲染），余额走 accountBalances
            quota = nil
            if let balance = accountBalances[primaryID] {
                text = balance.balanceText
            } else {
                text = "--"
            }
        case .workbuddy:
            quota = nil
            if let credits = accountWorkBuddyCredits[primaryID] {
                text = credits.remainingText
            } else {
                text = "--"
            }
        }
        switch accountStates[primaryID] {
        case .failed(let message):
            errorMessage = message
        case .unauthorized:
            errorMessage = LanguageManager.tr("授权已失效，请重新登录")
        default:
            errorMessage = nil
        }
    }

    // MARK: - OAuth 授权登录（添加账号）

    /// 添加一个账号：启动 Device Code Flow → 后台轮询直至授权完成，
    /// 成功后尽力去重再加入账号列表。0 账号时即添加第一个账号（自动成为主账号）。
    /// 仅在无任何账号（首次登录）时自动打开浏览器；已有账号时不自动打开——
    /// 浏览器当前登录的可能是其他账号，自动打开会直接以该账号完成授权，用户无法登录全新账号。
    func startOAuthLogin() {
        runDeviceAuthorizationFlow(autoOpenBrowser: accounts.isEmpty) { token in
            await self.finishAddingAccount(token: token)
        }
    }

    /// 设备授权流程的公共部分，成功后由 onSuccess 决定 token 的用途（添加账号 / 重新授权）。
    /// autoOpenBrowser 为 true 时拿到授权链接后直接呼出浏览器，否则由用户在界面手动操作。
    private func runDeviceAuthorizationFlow(autoOpenBrowser: Bool, onSuccess: @escaping (KimiOAuthToken) async -> Void) {
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
                if autoOpenBrowser, let urlString = auth.displayURL, let url = URL(string: urlString) {
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
                await onSuccess(token)
            case .failure(let error) where error != .cancelled:
                oauthLoginError = oauthErrorDescription(error)
            case .failure:
                break
            }
        }
    }

    /// 授权成功后收尾：拉一次 usages 尽力提取账号唯一标识做去重，
    /// 判定重复则丢弃新 token、不新增账号；否则加入列表并刷新。
    private func finishAddingAccount(token: KimiOAuthToken) async {
        var identifier: String?
        if case .success(let quota) = await service.fetchQuota(token: token.accessToken) {
            identifier = quota.userIdentifier
        }

        let store = KimiAccountStore.shared
        if let identifier,
           store.snapshot.accounts.contains(where: { $0.accountIdentifier == identifier }) {
            // 重复账号：丢弃新 token
            oauthLoginError = LanguageManager.tr("该账号已添加，无需重复授权")
            return
        }

        store.addAccount(KimiAccount(
            id: UUID(),
            alias: nil,
            provider: .kimi,
            credential: .oauth(token),
            accountIdentifier: identifier
        ))
        store.ensurePrimaryAccount()
        let snapshot = store.snapshot
        accounts = snapshot.accounts
        primaryAccountID = snapshot.primaryAccountID
        refresh(showsLoading: false)
    }

    func cancelOAuthLogin() {
        oauthLoginTask?.cancel()
        oauthLoginTask = nil
        oauthDeviceAuth = nil
        oauthLoginInProgress = false
    }

    // MARK: - 账号管理

    /// 删除账号：移除凭证与该账号的配额/状态缓存。
    /// 删除主账号时，主账号顺延为原列表中排在其后的账号（其后无账号则取第一个）。
    func removeAccount(_ id: UUID) {
        let store = KimiAccountStore.shared
        let removedIndex = accounts.firstIndex(where: { $0.id == id })
        let wasPrimary = (primaryAccountID == id)

        store.removeAccount(id: id)
        let remaining = store.snapshot.accounts
        if wasPrimary, let removedIndex, remaining.indices.contains(removedIndex) {
            store.setPrimaryAccount(remaining[removedIndex].id)
        }
        store.ensurePrimaryAccount()

        let snapshot = store.snapshot
        accounts = snapshot.accounts
        primaryAccountID = snapshot.primaryAccountID
        accountQuotas.removeValue(forKey: id)
        accountBalances.removeValue(forKey: id)
        accountStates.removeValue(forKey: id)
        accountWorkBuddyCredits.removeValue(forKey: id)
        accountCheckinDates.removeValue(forKey: id)
        syncPrimaryCompat()
    }

    /// 重命名账号别名；传 nil 或空白字符串表示清除别名（回退显示「账号 N」）
    func renameAccount(_ id: UUID, alias: String?) {
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        KimiAccountStore.shared.setAlias(id: id, alias: (trimmed?.isEmpty == false) ? trimmed : nil)
        accounts = KimiAccountStore.shared.snapshot.accounts
    }

    /// 设置主账号：菜单栏文字/图形与兼容属性只展示主账号用量
    func setPrimaryAccount(_ id: UUID) {
        guard accounts.contains(where: { $0.id == id }) else { return }
        KimiAccountStore.shared.setPrimaryAccount(id)
        primaryAccountID = id
        syncPrimaryCompat()
    }

    /// 重新授权：对指定账号重走设备授权流程，成功后替换其 token 并更新账号标识。
    /// 用于「登录失效」的账号恢复；不会删除该账号的别名等其它信息。
    func reauthorizeAccount(_ id: UUID) {
        runDeviceAuthorizationFlow(autoOpenBrowser: false) { token in
            var identifier: String?
            if case .success(let quota) = await self.service.fetchQuota(token: token.accessToken) {
                identifier = quota.userIdentifier
            }
            let store = KimiAccountStore.shared
            store.updateOAuthToken(id: id, token: token)
            if let identifier {
                store.updateAccountIdentifier(id: id, identifier: identifier)
            }
            self.accounts = store.snapshot.accounts
            self.accountStates[id] = .idle
            self.refresh(showsLoading: false)
        }
    }

    // MARK: - API Key 账号

    /// 添加 API Key 账号：先拉一次接口验证 Key，成功则落库。
    /// provider 决定走哪个验证服务（Kimi → usages，DeepSeek → balance）。
    /// 返回 nil 表示成功；否则返回面向用户的错误文案。
    @discardableResult
    func addApiKeyAccount(provider: AccountProvider, key: String, alias: String?) async -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return LanguageManager.tr("请输入 API Key")
        }

        switch provider {
        case .kimi:
            switch await service.fetchQuota(token: trimmed) {
            case .success(let quota):
                let store = KimiAccountStore.shared
                if let identifier = quota.userIdentifier,
                   store.snapshot.accounts.contains(where: { $0.accountIdentifier == identifier }) {
                    return LanguageManager.tr("该账号已添加，无需重复添加")
                }
                let cleanAlias = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
                store.addAccount(KimiAccount(
                    id: UUID(),
                    alias: (cleanAlias?.isEmpty == false) ? cleanAlias : nil,
                    provider: .kimi,
                    credential: .apiKey(trimmed),
                    accountIdentifier: quota.userIdentifier
                ))
                store.ensurePrimaryAccount()
                let snapshot = store.snapshot
                accounts = snapshot.accounts
                primaryAccountID = snapshot.primaryAccountID
                refresh(showsLoading: false)
                return nil
            case .failure(let error):
                return errorDescription(error)
            }
        case .deepseek:
            switch await deepseekService.fetchBalance(apiKey: trimmed) {
            case .success:
                let store = KimiAccountStore.shared
                // DeepSeek balance API 不返回账号身份信息，按 API Key 去重
                if store.snapshot.accounts.contains(where: {
                    if case .apiKey(let existingKey) = $0.credential, $0.provider == .deepseek {
                        return existingKey == trimmed
                    }
                    return false
                }) {
                    return LanguageManager.tr("该 API Key 已添加，无需重复添加")
                }
                // DeepSeek 账号不像 Kimi 能从接口拿到身份信息，别名留空时默认填 "DeepSeek"，
                // 避免列表里出现 "账号 1" 这种无辨识度的名字；用户可随时在设置里改。
                let cleanAlias = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedAlias = (cleanAlias?.isEmpty == false) ? cleanAlias : "DeepSeek"
                store.addAccount(KimiAccount(
                    id: UUID(),
                    alias: resolvedAlias,
                    provider: .deepseek,
                    credential: .apiKey(trimmed),
                    accountIdentifier: nil
                ))
                store.ensurePrimaryAccount()
                let snapshot = store.snapshot
                accounts = snapshot.accounts
                primaryAccountID = snapshot.primaryAccountID
                refresh(showsLoading: false)
                return nil
            case .failure(let error):
                return errorDescription(error)
            }
        case .workbuddy:
            // WorkBuddy 走独立 addWorkBuddyAccount()（读本地 auth 文件），这里兜底返回错误
            return LanguageManager.tr("WorkBuddy 账号请用本地读取方式添加")
        }
    }

    /// 修改 API Key 账号的密钥（「登录失效」后的恢复入口）：验证通过才落盘。
    /// 按账号 provider 走对应验证服务。返回 nil 表示成功；否则返回面向用户的错误文案。
    @discardableResult
    func updateApiKey(for id: UUID, key: String) async -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return LanguageManager.tr("请输入 API Key")
        }

        guard let account = accounts.first(where: { $0.id == id }) else { return nil }

        switch account.provider {
        case .kimi:
            switch await service.fetchQuota(token: trimmed) {
            case .success(let quota):
                let store = KimiAccountStore.shared
                store.updateApiKey(id: id, key: trimmed)
                if let identifier = quota.userIdentifier {
                    store.updateAccountIdentifier(id: id, identifier: identifier)
                }
                accounts = store.snapshot.accounts
                accountStates[id] = .idle
                refresh(showsLoading: false)
                return nil
            case .failure(let error):
                return errorDescription(error)
            }
        case .deepseek:
            switch await deepseekService.fetchBalance(apiKey: trimmed) {
            case .success:
                let store = KimiAccountStore.shared
                store.updateApiKey(id: id, key: trimmed)
                accounts = store.snapshot.accounts
                accountStates[id] = .idle
                refresh(showsLoading: false)
                return nil
            case .failure(let error):
                return errorDescription(error)
            }
        case .workbuddy:
            // WorkBuddy Key 不可修改（认证态由 WorkBuddy 客户端管理）
            return LanguageManager.tr("WorkBuddy 账号 Key 由 WorkBuddy 客户端管理")
        }
    }

    // MARK: - CLI 账号切换

    /// 重算 CLI 活跃账号：读 CLI 凭证文件并与账号列表比对 token。
    /// 账号列表展示「CLI 使用中」标签前调用；CLI 轮换 token 后匹配失效，标签自然消失。
    func refreshCliActiveAccount() {
        let token = CliCredentialsService.loadToken()
        cliActiveAccountID = CliCredentialsService.matchedAccountID(token: token, in: accounts)
    }

    /// 切换 CLI 活跃账号：把指定账号的 token 原子写入 CLI 凭证文件。
    /// 仅做这一次性写入，此后 Bar 与 CLI 凭证各自独立、不再同步（见 CONTEXT.md「凭证隔离原则」）。
    /// 仅支持 OAuth 账号：CLI 凭证格式是 access/refresh token 对，API Key 账号无法写入。
    func switchCliAccount(to id: UUID) throws {
        guard let account = accounts.first(where: { $0.id == id }),
              let token = account.oauthToken else { return }
        try CliCredentialsService.writeToken(token)
        refreshCliActiveAccount()
    }

    /// 账号显示名：优先别名，回退「账号 N」（N 为列表中的位置）
    func displayName(for account: KimiAccount) -> String {
        if let alias = account.alias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
            return alias
        }
        // 无别名兜底：DeepSeek 账号默认叫 "DeepSeek"，WorkBuddy 用客户端昵称，Kimi 走"账号 N"
        if account.provider == .deepseek {
            return "DeepSeek"
        }
        if account.provider == .workbuddy, let cred = account.workBuddyCredential {
            return cred.nickname
        }
        let index = accounts.firstIndex(where: { $0.id == account.id }) ?? 0
        return LanguageManager.tr("账号 %1$d", arguments: [index + 1])
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
        refreshWorkBuddyAccounts()
        Task {
            await checkForKimiCLIUpdate()
            await checkForAppUpdate()
            // Kimi Web UI 已临时屏蔽，手动刷新不再探测 58627 端口。恢复时取消注释即可。
            // await refreshKimiServerState()
        }
    }

    // MARK: - WorkBuddy 集成

    /// 刷新 WorkBuddy 账号的积分 + 运行状态。
    /// 遍历 accounts 中 provider == .workbuddy 的账号，逐个签到 + 查积分。
    func refreshWorkBuddyAccounts() {
        isWorkBuddyRunning = WorkBuddyService.shared.isWorkBuddyRunning()
        workBuddyActiveUID = WorkBuddyService.shared.currentActiveUID()

        let wbAccounts = accounts.filter { $0.provider == .workbuddy }
        guard !wbAccounts.isEmpty else { return }

        Task {
            let today = WorkBuddyService.todayString()
            for account in wbAccounts {
                await MainActor.run { accountStates[account.id] = .loading }

                var didCallCheckinAPI = false
                if account.workBuddyCredential?.lastCheckinDate != today {
                    didCallCheckinAPI = true
                    let result = await WorkBuddyService.shared.checkin(account: account)
                    if result.success {
                        KimiAccountStore.shared.updateWorkBuddyCheckinDate(id: account.id, date: today)
                        await MainActor.run { accountCheckinDates[account.id] = today }
                    }
                } else {
                    await MainActor.run { accountCheckinDates[account.id] = today }
                }

                // Reload account (checkin may have refreshed token)
                let refreshed = KimiAccountStore.shared.freshAccount(id: account.id) ?? account
                let credits = await WorkBuddyService.shared.fetchCredits(account: refreshed)
                await MainActor.run {
                    if let credits {
                        accountWorkBuddyCredits[account.id] = credits
                        accountStates[account.id] = .loaded
                    } else {
                        accountStates[account.id] = .failed("积分获取失败")
                    }
                }

                if didCallCheckinAPI && account.id != wbAccounts.last?.id {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    /// 从本地 auth 文件添加当前 WorkBuddy 登录账号。
    /// 成功返回 nil，失败返回错误描述。
    func addWorkBuddyAccount() -> String? {
        guard let newAccount = WorkBuddyService.shared.addCurrentAccount() else {
            return LanguageManager.tr("未检测到 WorkBuddy 登录信息，请先在 WorkBuddy 中登录")
        }
        let store = KimiAccountStore.shared
        // Dedup by WB uid (accountIdentifier)
        if let existing = store.snapshot.accounts.first(where: { $0.accountIdentifier == newAccount.accountIdentifier }) {
            // Already added — update credential (token may have refreshed)
            store.updateWorkBuddyCredential(id: existing.id, credential: newAccount.workBuddyCredential!)
        } else {
            store.addAccount(newAccount)
        }
        store.ensurePrimaryAccount()
        let snapshot = store.snapshot
        accounts = snapshot.accounts
        primaryAccountID = snapshot.primaryAccountID
        refresh(showsLoading: false)
        return nil
    }

    /// 切换到指定 WorkBuddy 账号并启动 / 重启客户端。
    /// 先把该账号的 token 对 + 快照写回 auth 文件（使 WorkBuddy 启动后使用该账号），
    /// 再终止旧进程并重新启动。逻辑迁移自 wbSwitch 项目。
    func launchWorkBuddy(account: KimiAccount) {
        WorkBuddyService.shared.switchTo(account: account)
        WorkBuddyService.shared.restartWorkBuddy { [weak self] in
            self?.isWorkBuddyRunning = WorkBuddyService.shared.isWorkBuddyRunning()
            self?.workBuddyActiveUID = WorkBuddyService.shared.currentActiveUID()
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
        // 关闭检查更新时直接返回（双保险：拦联网 + 弹窗 + 系统通知，sendUpdateNotification 在此函数内调用）
        guard enableKimiCLIUpdateCheck else { return }
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
        // 关闭检查更新时不基于缓存弹窗
        guard enableKimiCLIUpdateCheck else { return }
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
