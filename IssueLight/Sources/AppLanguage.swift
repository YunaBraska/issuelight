import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case hindi = "hi"
    case spanish = "es"
    case arabic = "ar"
    case french = "fr"
    case bengali = "bn"
    case portuguese = "pt"
    case indonesian = "id"
    case urdu = "ur"
    case russian = "ru"
    case german = "de"
    case japanese = "ja"
    case nigerianPidgin = "pcm"
    case marathi = "mr"
    case vietnamese = "vi"
    case telugu = "te"
    case swahili = "sw"
    case hausa = "ha"
    case turkish = "tr"
    case swedish = "sv"

    var id: String { rawValue }

    static var supportedLanguages: [AppLanguage] {
        allCases.filter { $0 != .system }
    }

    var locale: Locale {
        self == .system ? .autoupdatingCurrent : Locale(identifier: rawValue)
    }

    var nativeName: String {
        switch self {
        case .system:
            return ""
        case .english:
            return "English"
        case .simplifiedChinese:
            return "简体中文"
        case .hindi:
            return "हिन्दी"
        case .spanish:
            return "Español"
        case .arabic:
            return "العربية"
        case .french:
            return "Français"
        case .bengali:
            return "বাংলা"
        case .portuguese:
            return "Português"
        case .indonesian:
            return "Bahasa Indonesia"
        case .urdu:
            return "اردو"
        case .russian:
            return "Русский"
        case .german:
            return "Deutsch"
        case .japanese:
            return "日本語"
        case .nigerianPidgin:
            return "Naijá"
        case .marathi:
            return "मराठी"
        case .vietnamese:
            return "Tiếng Việt"
        case .telugu:
            return "తెలుగు"
        case .swahili:
            return "Kiswahili"
        case .hausa:
            return "Hausa"
        case .turkish:
            return "Türkçe"
        case .swedish:
            return "Svenska"
        }
    }

    var isRightToLeft: Bool {
        self == .arabic || self == .urdu
    }
}

enum AppLocalization {
    static func string(_ resource: LocalizedStringResource, locale: Locale) -> String {
        let localizedResource = LocalizedStringResource(
            resource.defaultValue,
            table: resource.table,
            locale: locale,
            bundle: .forClass(LocalizationBundleToken.self)
        )
        return String(localized: localizedResource)
    }
}

private final class LocalizationBundleToken: NSObject {}

@MainActor
final class AppLanguageSettings: ObservableObject {
    static let defaultsKey = "appLanguage"

    @Published var selection: AppLanguage {
        didSet {
            defaults?.set(selection.rawValue, forKey: Self.defaultsKey)
        }
    }

    var locale: Locale {
        selection.locale
    }

    private let defaults: UserDefaults?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = defaults.string(forKey: Self.defaultsKey)
            .flatMap(AppLanguage.init(rawValue:))
            ?? .system
    }

    init(selection: AppLanguage) {
        defaults = nil
        self.selection = selection
    }
}

private struct AppLanguageEnvironmentModifier: ViewModifier {
    @ObservedObject var languageSettings: AppLanguageSettings
    @Environment(\.layoutDirection) private var systemLayoutDirection

    func body(content: Content) -> some View {
        content
            .environment(\.locale, languageSettings.locale)
            .environment(\.layoutDirection, layoutDirection)
    }

    private var layoutDirection: LayoutDirection {
        if languageSettings.selection == .system {
            return systemLayoutDirection
        }
        return languageSettings.selection.isRightToLeft ? .rightToLeft : .leftToRight
    }
}

extension View {
    func appLanguageEnvironment(_ languageSettings: AppLanguageSettings) -> some View {
        modifier(AppLanguageEnvironmentModifier(languageSettings: languageSettings))
    }
}
