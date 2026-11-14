import AppKit
import SwiftUI
import IssueLightCore

struct StatusMenuLabel: View {
    let symbol: String
    let issueCount: Int
    let accessibilityText: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if issueCount > 0 {
                Text(verbatim: "\(issueCount)")
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(accessibilityText)
    }
}

struct StatusMenuView: View {
    @ObservedObject var model: IssueLightModel
    @ObservedObject var languageSettings: AppLanguageSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        StatusMenuContent(
            hasConfiguredSource: model.hasConfiguredSource,
            hasEnabledSource: model.hasEnabledSource,
            hasActiveSnapshot: model.hasActiveSnapshot,
            actionableIssues: model.actionableIssues,
            coveredIssues: model.coveredIssues,
            sourceNames: Dictionary(uniqueKeysWithValues: model.sources.map { ($0.id, $0.name) }),
            refreshState: model.refreshState,
            hasPartialRefreshFailure: model.hasPartialRefreshFailure,
            latestSuccessfulRefresh: model.latestSuccessfulRefresh,
            menuBarSymbol: model.menuBarSymbol,
            languageSettings: languageSettings,
            showStatus: {
                openWindow(id: "status")
                NSApplication.shared.activate(ignoringOtherApps: true)
            },
            refresh: { model.refresh() },
            openSources: {
                openWindow(id: "sources")
                NSApplication.shared.activate(ignoringOtherApps: true)
            },
            showAbout: {
                NSApplication.shared.activate(ignoringOtherApps: true)
                NSApplication.shared.orderFrontStandardAboutPanel(nil)
            },
            quit: { NSApplication.shared.terminate(nil) }
        )
    }
}

struct StatusMenuContent: View {
    let hasConfiguredSource: Bool
    let hasEnabledSource: Bool
    let hasActiveSnapshot: Bool
    let actionableIssues: [MonitoringIssue]
    let coveredIssues: [MonitoringIssue]
    let sourceNames: [UUID: String]
    let refreshState: IssueLightModel.RefreshState
    let hasPartialRefreshFailure: Bool
    let latestSuccessfulRefresh: Date?
    let menuBarSymbol: String
    @ObservedObject var languageSettings: AppLanguageSettings
    let showStatus: () -> Void
    let refresh: () -> Void
    let openSources: () -> Void
    let showAbout: () -> Void
    let quit: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        summary

        if !actionableIssues.isEmpty {
            Divider()
            ForEach(actionableIssues.prefix(5)) { issue in
                Label(issueTitle(issue), systemImage: issueSymbol(issue))
                    .help(issue.summary)
            }
            if actionableIssues.count > 5 {
                Button(
                    AppLocalization.string(
                        "Alle \(actionableIssues.count) Probleme zeigen …",
                        locale: locale
                    ),
                    action: showStatus
                )
            }
        }

        if !coveredIssues.isEmpty {
            Label(
                IssueCountText.covered(coveredIssues.count, locale: locale),
                systemImage: "checkmark.shield"
            )
        }

        Divider()

        if hasConfiguredSource {
            Button(AppLocalization.string("Status zeigen …", locale: locale), action: showStatus)
            Button(AppLocalization.string("Jetzt aktualisieren", locale: locale), action: refresh)
                .keyboardShortcut("r")
                .disabled(!hasEnabledSource)
        }

        Button(AppLocalization.string("Quellen …", locale: locale), action: openSources)

        AppLanguageMenu(languageSettings: languageSettings)

        SettingsLink {
            Text(verbatim: AppLocalization.string("Einstellungen …", locale: locale))
        }

        Divider()

        Link(destination: URL(string: "https://github.com/YunaBraska/issuelight/releases")!) {
            Text(
                verbatim: AppLocalization.string(
                    "Veröffentlichungen anzeigen …",
                    locale: locale
                )
            )
        }

        Button(AppLocalization.string("Über IssueLight", locale: locale), action: showAbout)

        Divider()

        Button(AppLocalization.string("IssueLight beenden", locale: locale), action: quit)
            .keyboardShortcut("q")
    }

    @ViewBuilder
    private var summary: some View {
        if !hasConfiguredSource {
            Label(
                AppLocalization.string("Keine Quelle konfiguriert", locale: locale),
                systemImage: "exclamationmark.triangle"
            )
        } else if !hasEnabledSource {
            Label(
                AppLocalization.string("Alle Quellen pausiert", locale: locale),
                systemImage: "pause.circle"
            )
        } else if !actionableIssues.isEmpty {
            Label(
                IssueCountText.attention(actionableIssues.count, locale: locale),
                systemImage: menuBarSymbol
            )
            lastSuccessfulRefresh
            if case .failed(let message) = refreshState {
                if hasPartialRefreshFailure {
                    Label(
                        AppLocalization.string("Aktualisierung teilweise fehlgeschlagen", locale: locale),
                        systemImage: "wifi.exclamationmark"
                    )
                        .help(message)
                } else {
                    Label(
                        AppLocalization.string("Status ist veraltet", locale: locale),
                        systemImage: "wifi.exclamationmark"
                    )
                        .help(message)
                }
            }
        } else if case .failed(let message) = refreshState {
            if hasPartialRefreshFailure {
                Label(
                    AppLocalization.string("Aktualisierung teilweise fehlgeschlagen", locale: locale),
                    systemImage: "wifi.exclamationmark"
                )
                    .help(message)
            } else {
                Label(
                    AppLocalization.string("Aktualisierung fehlgeschlagen", locale: locale),
                    systemImage: "wifi.exclamationmark"
                )
                    .help(message)
            }
            lastSuccessfulRefresh
        } else if refreshState == .refreshing, !hasActiveSnapshot {
            Label(
                AppLocalization.string("Status wird geladen …", locale: locale),
                systemImage: "arrow.clockwise"
            )
        } else if actionableIssues.isEmpty {
            Label(IssueCountText.attention(0, locale: locale), systemImage: "checkmark.circle")
            lastSuccessfulRefresh
        }
    }

    @ViewBuilder
    private var lastSuccessfulRefresh: some View {
        if let latestSuccessfulRefresh {
            Text(
                verbatim: AppLocalization.string(
                    "Zuletzt geprüft: \(latestSuccessfulRefresh.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)))",
                    locale: locale
                )
            )
        }
    }

    private func issueTitle(_ issue: MonitoringIssue) -> String {
        let source = sourceNames.count > 1
            ? "\(sourceNames[issue.sourceID] ?? AppLocalization.string("Unbekannte Quelle", locale: locale)): "
            : ""
        switch issue.kind {
        case .host:
            return "\(source)\(issue.displayName)"
        case .service:
            return "\(source)\(issue.hostName) · \(issue.displayName)"
        }
    }

    private func issueSymbol(_ issue: MonitoringIssue) -> String {
        switch issue.severity {
        case .critical:
            return "exclamationmark.octagon.fill"
        case .unknown:
            return "questionmark.diamond.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        }
    }
}
