import SwiftUI

@main
struct IssueLightApp: App {
    @StateObject private var model: IssueLightModel
    @StateObject private var languageSettings: AppLanguageSettings

    init() {
        let settings = AppLanguageSettings()
        _languageSettings = StateObject(wrappedValue: settings)
        _model = StateObject(
            wrappedValue: IssueLightModel(localizationLocale: settings.locale)
        )
    }

    var body: some Scene {
        Window(
            AppLocalization.string("Quellen", locale: languageSettings.locale),
            id: "sources"
        ) {
            SourceSetupView(model: model)
                .appLanguageEnvironment(languageSettings)
        }
        .defaultSize(width: 920, height: 680)
        .windowResizability(.contentMinSize)

        Window("IssueLight", id: "status") {
            StatusWindowView(model: model)
                .appLanguageEnvironment(languageSettings)
        }
        .defaultSize(width: 760, height: 560)

        MenuBarExtra {
            StatusMenuView(model: model, languageSettings: languageSettings)
                .appLanguageEnvironment(languageSettings)
                .onChange(of: languageSettings.selection) {
                    model.setLocalizationLocale(languageSettings.locale)
                }
        } label: {
            StatusMenuLabel(
                symbol: model.menuBarSymbol,
                issueCount: model.actionableIssues.count,
                accessibilityText: menuBarAccessibilityLabel
            )
        }
        .menuBarExtraStyle(.menu)

        Settings {
            LanguageSettingsView(languageSettings: languageSettings)
                .appLanguageEnvironment(languageSettings)
                .onChange(of: languageSettings.selection) {
                    model.setLocalizationLocale(languageSettings.locale)
                }
        }
    }

    private var menuBarAccessibilityLabel: String {
        if !model.hasConfiguredSource {
            return AppLocalization.string(
                "IssueLight, keine Quelle konfiguriert",
                locale: languageSettings.locale
            )
        }
        if !model.hasEnabledSource {
            return AppLocalization.string(
                "IssueLight, alle Quellen pausiert",
                locale: languageSettings.locale
            )
        }
        let count = model.actionableIssues.count
        let attention = IssueCountText.attention(count, locale: languageSettings.locale)
        if case .failed(let message) = model.refreshState {
            let failure = model.hasPartialRefreshFailure
                ? AppLocalization.string("Aktualisierung teilweise fehlgeschlagen", locale: languageSettings.locale)
                : AppLocalization.string("Status veraltet", locale: languageSettings.locale)
            return AppLocalization.string(
                "IssueLight. \(attention). \(failure): \(message)",
                locale: languageSettings.locale
            )
        }
        return AppLocalization.string("IssueLight. \(attention)", locale: languageSettings.locale)
    }
}
