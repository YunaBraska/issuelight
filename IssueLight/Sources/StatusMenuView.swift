import AppKit
import SwiftUI
import IssueLightCore

struct StatusMenuLabel: View {
    let symbol: String
    let counts: MenuBarIssueCounts
    let accessibilityText: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if !counts.compactText.isEmpty {
                Text(verbatim: counts.compactText)
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(accessibilityText)
    }
}

struct MenuBarIssueCounts: Equatable {
    let critical: Int
    let warning: Int
    let unknown: Int

    init(issues: [MonitoringIssue]) {
        critical = issues.filter { $0.severity == .critical }.count
        warning = issues.filter { $0.severity == .warning }.count
        unknown = issues.filter { $0.severity == .unknown }.count
    }

    var compactText: String {
        [
            critical > 0 ? "C:\(critical)" : nil,
            warning > 0 ? "W:\(warning)" : nil,
            unknown > 0 ? "U:\(unknown)" : nil,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
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
    let quit: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    summary
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
                if refreshState == .refreshing {
                    ProgressView()
                        .controlSize(.small)
                }
                if hasConfiguredSource {
                    Button(action: refresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("r")
                    .disabled(!hasEnabledSource)
                    .help(AppLocalization.string("Jetzt aktualisieren", locale: locale))
                }
            }
            .padding(14)

            Divider()

            issuePanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 12) {
                if hasConfiguredSource {
                    Button(AppLocalization.string("Status zeigen …", locale: locale), action: showStatus)
                }
                Button(AppLocalization.string("Quellen …", locale: locale), action: openSources)
                Spacer()
                AppLanguageMenu(languageSettings: languageSettings)
                    .labelStyle(.iconOnly)
                    .help(AppLocalization.string("Sprache", locale: locale))
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .labelStyle(.iconOnly)
                .help(AppLocalization.string("Einstellungen …", locale: locale))
                Menu {
                    Link(destination: URL(string: "https://github.com/YunaBraska/issuelight/releases")!) {
                        Text(
                            verbatim: AppLocalization.string(
                                "Veröffentlichungen anzeigen …",
                                locale: locale
                            )
                        )
                    }
                    Divider()
                    Button(AppLocalization.string("IssueLight beenden", locale: locale), action: quit)
                        .keyboardShortcut("q")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(12)
        }
        .frame(width: 430, height: panelHeight)
    }

    private var panelHeight: CGFloat {
        if !hasConfiguredSource || !hasEnabledSource || !hasActiveSnapshot {
            return 260
        }
        if actionableIssues.isEmpty {
            return 280
        }
        let coveredSummaryHeight: CGFloat = coveredIssues.isEmpty ? 0 : 38
        return min(520, max(240, 128 + CGFloat(actionableIssues.count) * 56 + coveredSummaryHeight))
    }

    @ViewBuilder
    private var issuePanel: some View {
        if !hasConfiguredSource {
            ContentUnavailableView(
                AppLocalization.string("Keine Quelle konfiguriert", locale: locale),
                systemImage: "server.rack",
                description: Text(verbatim: AppLocalization.string("Füge zuerst eine Monitoring-Quelle hinzu.", locale: locale))
            )
        } else if !hasEnabledSource {
            ContentUnavailableView(
                AppLocalization.string("Keine Quelle aktiv", locale: locale),
                systemImage: "pause.circle",
                description: Text(verbatim: AppLocalization.string("Aktiviere mindestens eine Quelle, um den Status zu überwachen.", locale: locale))
            )
        } else if hasActiveSnapshot, actionableIssues.isEmpty {
            ContentUnavailableView(
                AppLocalization.string("Alles ruhig", locale: locale),
                systemImage: "checkmark.circle",
                description: Text(verbatim: AppLocalization.string("Keine Hosts oder Services benötigen Aufmerksamkeit.", locale: locale))
            )
        } else if hasActiveSnapshot {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(actionableIssues) { issue in
                        Button(action: showStatus) {
                            StatusPanelIssueRow(
                                issue: issue,
                                sourceName: sourceNames.count > 1 ? sourceNames[issue.sourceID] : nil
                            )
                        }
                        .buttonStyle(.plain)
                        Divider()
                            .padding(.leading, 44)
                    }
                    if !coveredIssues.isEmpty {
                        Label(
                            IssueCountText.covered(coveredIssues.count, locale: locale),
                            systemImage: "checkmark.shield"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        } else if case .failed(let message) = refreshState {
            ContentUnavailableView(
                AppLocalization.string("Status konnte nicht geladen werden", locale: locale),
                systemImage: "wifi.exclamationmark",
                description: Text(verbatim: message)
            )
        } else {
            ContentUnavailableView(
                AppLocalization.string("Status wird geladen", locale: locale),
                systemImage: "arrow.clockwise",
                description: Text(verbatim: AppLocalization.string("IssueLight fragt Hosts und Services bei der Quelle ab.", locale: locale))
            )
        }
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

}

private struct StatusPanelIssueRow: View {
    let issue: MonitoringIssue
    let sourceName: String?
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(verbatim: issue.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let sourceName {
                    Label(sourceName, systemImage: "server.rack")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(verbatim: severityText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        issue.kind == .host ? issue.displayName : "\(issue.hostName) · \(issue.displayName)"
    }

    private var symbol: String {
        switch issue.severity {
        case .critical: return "exclamationmark.octagon.fill"
        case .unknown: return "questionmark.diamond.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch issue.severity {
        case .critical: return .red
        case .unknown: return .purple
        case .warning: return .orange
        }
    }

    private var severityText: String {
        switch issue.severity {
        case .critical: return AppLocalization.string("Kritisch", locale: locale)
        case .unknown: return AppLocalization.string("Unbekannt", locale: locale)
        case .warning: return AppLocalization.string("Warnung", locale: locale)
        }
    }
}
