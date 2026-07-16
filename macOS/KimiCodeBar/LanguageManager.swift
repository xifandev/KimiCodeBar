import SwiftUI

// MARK: - 应用语言

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans
    case en

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return LanguageManager.tr("跟随系统")
        case .zhHans: return "中文"
        case .en: return "English"
        }
    }

    var subtitle: String {
        switch self {
        case .system: return LanguageManager.tr("自动匹配系统语言")
        case .zhHans: return LanguageManager.tr("使用简体中文界面")
        case .en: return LanguageManager.tr("使用英文界面")
        }
    }

    var iconName: String {
        switch self {
        case .system: return "globe"
        case .zhHans: return "character.book.closed"
        case .en: return "globe.americas"
        }
    }
}

// MARK: - 语言管理

/// 应用内语言切换。中文界面文案即本地化 key，英文翻译由 Localizable.xcstrings
/// 编译进 en.lproj；查不到译文时回退 key 本身（中文），界面不会出现空白。
/// 视图用 @StateObject 订阅 shared 实例即可随语言切换自动重渲染；
/// 服务层等任意上下文可直接调用静态 `LanguageManager.tr(...)`。
@MainActor
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "appLanguage")
        }
    }

    private init() {
        let rawValue = UserDefaults.standard.string(forKey: "appLanguage") ?? ""
        language = AppLanguage(rawValue: rawValue) ?? .system
    }

    func tr(_ key: String) -> String { Self.tr(key) }

    func tr(_ key: String, _ args: CVarArg...) -> String { Self.tr(key, arguments: args) }

    func tr(_ key: String, arguments: [CVarArg]) -> String { Self.tr(key, arguments: arguments) }

    /// 实际生效的语言：跟随系统时，系统首选语言为中文则用中文，否则用英文
    nonisolated static var resolvedLanguage: AppLanguage {
        let rawValue = UserDefaults.standard.string(forKey: "appLanguage") ?? ""
        let language = AppLanguage(rawValue: rawValue) ?? .system
        switch language {
        case .zhHans, .en:
            return language
        case .system:
            for preferred in Locale.preferredLanguages {
                if preferred.hasPrefix("zh") { return .zhHans }
                if preferred.hasPrefix("en") { return .en }
            }
            return .en
        }
    }

    private nonisolated static let englishBundle: Bundle? = {
        guard let path = Bundle.main.path(forResource: "en", ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }()

    nonisolated static func tr(_ key: String) -> String {
        guard resolvedLanguage == .en, let bundle = englishBundle else { return key }
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    nonisolated static func tr(_ key: String, arguments: [CVarArg]) -> String {
        String(format: tr(key), arguments: arguments)
    }
}

// MARK: - 本地化文本视图

/// 自观察语言切换的 Text 包装：语言变化时自动重渲染，调用处与 `Text("...")` 用法一致，
/// 插值串改为 `%@` 格式传入，如 `LText("授权码 %@", code)`。
struct LText: View {
    @StateObject private var languageManager = LanguageManager.shared

    private let key: String
    private let args: [CVarArg]

    init(_ key: String, _ args: CVarArg...) {
        self.key = key
        self.args = args
    }

    var body: some View {
        Text(languageManager.tr(key, arguments: args))
    }
}
