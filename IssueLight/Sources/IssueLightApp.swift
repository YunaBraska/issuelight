import SwiftUI
import IssueLightCore
#if DEBUG
import Darwin
#endif

@main
struct IssueLightApp: App {
    @StateObject private var model: IssueLightModel
    @StateObject private var languageSettings: AppLanguageSettings
    @StateObject private var externalActions: ExternalActionCoordinator
    @StateObject private var notificationCoordinator: IssueNotificationCoordinator
    private let updateController: AppUpdateController

    init() {
#if DEBUG
        DebugReviewCredentialSeeder.runIfRequested()
#endif
        let settings = AppLanguageSettings()
        let tunnelManager = SSHTunnelManager()
        let connectionCoordinator = AutomaticConnectionCoordinator(tunnelManager: tunnelManager)
        let issueModel = IssueLightModel(
            localizationLocale: settings.locale,
            connectionCoordinator: connectionCoordinator
        )
        let actionCoordinator = ExternalActionCoordinator(tunnelManager: tunnelManager)
        let issueNotificationCoordinator = IssueNotificationCoordinator(locale: settings.locale)
        actionCoordinator.observeSources(issueModel)
        issueNotificationCoordinator.observe(issueModel)
        issueNotificationCoordinator.configureNavigation(
            issueURL: { [weak issueModel] issue in
                issueModel?.webTarget(for: issue)?.url
            },
            target: { [weak issueModel] sourceID, url in
                issueModel?.webTarget(sourceID: sourceID, url: url)
            },
            open: { [weak issueModel, weak actionCoordinator] target in
                guard let actionCoordinator else { return }
                if case .failure(let error) = await actionCoordinator.openWeb(target) {
                    issueModel?.reportExternalActionError(error)
                }
            }
        )
        Task {
            await issueNotificationCoordinator.prepareForSession()
        }
        _languageSettings = StateObject(wrappedValue: settings)
        _externalActions = StateObject(wrappedValue: actionCoordinator)
        _notificationCoordinator = StateObject(wrappedValue: issueNotificationCoordinator)
        _model = StateObject(wrappedValue: issueModel)
        updateController = AppUpdateController()
    }

    var body: some Scene {
        MenuBarExtra {
            StatusMenuView(model: model, externalActions: externalActions)
                .appLanguageEnvironment(languageSettings)
                .onChange(of: languageSettings.selection) {
                    model.setLocalizationLocale(languageSettings.locale)
                    notificationCoordinator.setLocale(languageSettings.locale)
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
            IssueLightSettingsView(
                model: model,
                languageSettings: languageSettings,
                notificationCoordinator: notificationCoordinator,
                updateController: updateController
            )
                .appLanguageEnvironment(languageSettings)
                .onChange(of: languageSettings.selection) {
                    model.setLocalizationLocale(languageSettings.locale)
                    notificationCoordinator.setLocale(languageSettings.locale)
                }
        }
        .windowResizability(.contentMinSize)
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
