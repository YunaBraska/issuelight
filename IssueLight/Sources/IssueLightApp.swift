import SwiftUI
import IssueLightCore
#if DEBUG
import Darwin
#endif

@main
struct IssueLightApp: App {
    @StateObject private var model: IssueLightModel
    @StateObject private var languageSettings: AppLanguageSettings

    init() {
#if DEBUG
        DebugReviewCredentialSeeder.runIfRequested()
#endif
        let settings = AppLanguageSettings()
        _languageSettings = StateObject(wrappedValue: settings)
        _model = StateObject(
            wrappedValue: IssueLightModel(localizationLocale: settings.locale)
        )
    }

    var body: some Scene {
        MenuBarExtra {
            StatusMenuView(model: model)
                .appLanguageEnvironment(languageSettings)
                .onChange(of: languageSettings.selection) {
                    model.setLocalizationLocale(languageSettings.locale)
                }
        } label: {
            StatusMenuLabel(
                symbol: model.menuBarSymbol,
                counts: MenuBarIssueCounts(issues: model.actionableIssues),
                accessibilityText: menuBarAccessibilityLabel
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            IssueLightSettingsView(model: model, languageSettings: languageSettings)
                .appLanguageEnvironment(languageSettings)
                .onChange(of: languageSettings.selection) {
                    model.setLocalizationLocale(languageSettings.locale)
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {}
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

#if DEBUG
private enum DebugReviewCredentialSeeder {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, arguments[1] == "--seed-review-password" else {
            return
        }
        guard let endpoint = URL(string: arguments[2]),
              let password = readLine(),
              !password.isEmpty else {
            fputs("IssueLight review credential input is invalid.\n", stderr)
            exit(2)
        }

        let source = MonitoringSource(
            id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            name: "Local Icinga 2 Review Lab",
            providerID: Icinga2Provider.id,
            endpoint: endpoint,
            authentication: .basic(username: "issuelight-basic"),
            serverTrust: .disabled
        )
        let semaphore = DispatchSemaphore(value: 0)
        var status: Int32 = 1
        Task.detached {
            defer { semaphore.signal() }
            do {
                let scope = try BasicCredentialScope(source: source)
                try await KeychainPasswordVault().store(password, for: scope)
                status = 0
            } catch {
                fputs("IssueLight review credential could not be stored.\n", stderr)
            }
        }
        semaphore.wait()
        exit(status)
    }
}
#endif
