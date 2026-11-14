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
    @State private var pendingAction: PendingIssueAction?
    @Environment(\.locale) private var locale

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
            supportedActions: model.supportedActions,
            activeActionIssueIDs: model.activeActionIssueIDs,
            refresh: { model.refresh() },
            performRecheck: { issue in
                Task { await model.perform(.recheck, on: issue) }
            },
            requestAcknowledgement: { issue in
                pendingAction = PendingIssueAction(issue: issue, kind: .acknowledge)
            },
            requestDowntime: { issue in
                pendingAction = PendingIssueAction(issue: issue, kind: .scheduleDowntime)
            }
        )
        .sheet(item: $pendingAction) { pendingAction in
            IssueActionSheet(model: model, pendingAction: pendingAction)
        }
        .alert(
            model.actionFeedback?.succeeded == true
                ? AppLocalization.string("Aktion abgeschlossen", locale: locale)
                : AppLocalization.string("Aktion fehlgeschlagen", locale: locale),
            isPresented: Binding(
                get: { model.actionFeedback != nil },
                set: { if !$0 { model.dismissActionFeedback() } }
            ),
            presenting: model.actionFeedback
        ) { _ in
            Button("OK") { model.dismissActionFeedback() }
        } message: { feedback in
            Text(verbatim: feedback.message)
        }
    }
}

private struct PendingIssueAction: Identifiable {
    let id = UUID()
    let issue: MonitoringIssue
    let kind: MonitoringActionKind
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
    let supportedActions: (MonitoringIssue) -> Set<MonitoringActionKind>
    let activeActionIssueIDs: Set<String>
    let refresh: () -> Void
    let performRecheck: (MonitoringIssue) -> Void
    let requestAcknowledgement: (MonitoringIssue) -> Void
    let requestDowntime: (MonitoringIssue) -> Void
    @Environment(\.locale) private var locale
    @State private var expandedIssueID: String?
    @State private var searchText = ""

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
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .labelStyle(.iconOnly)
                .help(AppLocalization.string("Einstellungen …", locale: locale))
            }
            .padding(14)

            Divider()

            if showsSearch {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(
                        AppLocalization.string("Probleme durchsuchen", locale: locale),
                        text: $searchText
                    )
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("issue-search")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                Divider()
            }

            issuePanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 430, height: panelHeight)
    }

    private var panelHeight: CGFloat {
        if !hasConfiguredSource || !hasEnabledSource || !hasActiveSnapshot {
            return 260
        }
        if actionableIssues.isEmpty && coveredIssues.isEmpty {
            return 280
        }
        let searchHeight: CGFloat = showsSearch ? 40 : 0
        let coveredSummaryHeight: CGFloat = filteredCoveredIssues.isEmpty ? 0 : 38
        let actionHeight: CGFloat = expandedIssueID == nil ? 0 : 42
        return min(
            520,
            max(
                240,
                128
                    + CGFloat(filteredActionableIssues.count + filteredCoveredIssues.count) * 62
                    + searchHeight
                    + coveredSummaryHeight
                    + actionHeight
            )
        )
    }

    private var showsSearch: Bool {
        actionableIssues.count + coveredIssues.count > 8
    }

    private var filteredActionableIssues: [MonitoringIssue] {
        MonitoringIssueSearch(query: searchText, sourceNames: sourceNames).filter(actionableIssues)
    }

    private var filteredCoveredIssues: [MonitoringIssue] {
        MonitoringIssueSearch(query: searchText, sourceNames: sourceNames).filter(coveredIssues)
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
        } else if hasActiveSnapshot, actionableIssues.isEmpty, coveredIssues.isEmpty {
            ContentUnavailableView(
                AppLocalization.string("Alles ruhig", locale: locale),
                systemImage: "checkmark.circle",
                description: Text(verbatim: AppLocalization.string("Keine Hosts oder Services benötigen Aufmerksamkeit.", locale: locale))
            )
        } else if hasActiveSnapshot {
            if filteredActionableIssues.isEmpty && filteredCoveredIssues.isEmpty {
                ContentUnavailableView(
                    AppLocalization.string("Keine Treffer", locale: locale),
                    systemImage: "magnifyingglass",
                    description: Text(
                        verbatim: AppLocalization.string(
                            "Kein Problem passt zu „\(searchText)“.",
                            locale: locale
                        )
                    )
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredActionableIssues) { issue in
                            issueEntry(issue)
                        }
                        if !filteredCoveredIssues.isEmpty {
                            Label(
                                IssueCountText.covered(filteredCoveredIssues.count, locale: locale),
                                systemImage: "checkmark.shield"
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                        }
                        ForEach(filteredCoveredIssues) { issue in
                            issueEntry(issue)
                        }
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

    private func issueEntry(_ issue: MonitoringIssue) -> some View {
        StatusPanelIssueEntry(
            issue: issue,
            sourceName: sourceNames.count > 1 ? sourceNames[issue.sourceID] : nil,
            isExpanded: expandedIssueID == issue.id,
            isPerformingAction: activeActionIssueIDs.contains(issue.id),
            actions: supportedActions(issue),
            toggle: {
                expandedIssueID = expandedIssueID == issue.id ? nil : issue.id
            },
            performRecheck: { performRecheck(issue) },
            requestAcknowledgement: { requestAcknowledgement(issue) },
            requestDowntime: { requestDowntime(issue) }
        )
    }

}

struct MonitoringIssueSearch {
    let query: String
    let sourceNames: [UUID: String]

    init(query: String, sourceNames: [UUID: String]) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceNames = sourceNames
    }

    func filter(_ issues: [MonitoringIssue]) -> [MonitoringIssue] {
        guard !query.isEmpty else { return issues }
        return issues.filter { issue in
            issue.displayName.localizedCaseInsensitiveContains(query)
                || issue.hostName.localizedCaseInsensitiveContains(query)
                || issue.summary.localizedCaseInsensitiveContains(query)
                || (sourceNames[issue.sourceID] ?? "").localizedCaseInsensitiveContains(query)
        }
    }
}

private struct StatusPanelIssueEntry: View {
    let issue: MonitoringIssue
    let sourceName: String?
    let isExpanded: Bool
    let isPerformingAction: Bool
    let actions: Set<MonitoringActionKind>
    let toggle: () -> Void
    let performRecheck: () -> Void
    let requestAcknowledgement: () -> Void
    let requestDowntime: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                StatusPanelIssueRow(
                    issue: issue,
                    sourceName: sourceName,
                    isExpanded: isExpanded
                )
            }
            .buttonStyle(.plain)
            if isExpanded {
                HStack(spacing: 12) {
                    Spacer(minLength: 32)
                    Button(action: performRecheck) {
                        Label(
                            AppLocalization.string("Erneut prüfen", locale: locale),
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .disabled(!actions.contains(.recheck))
                    Button(action: requestAcknowledgement) {
                        Label(
                            AppLocalization.string("Quittieren …", locale: locale),
                            systemImage: "checkmark.message"
                        )
                    }
                    .disabled(!actions.contains(.acknowledge) || issue.isAcknowledged)
                    Button(action: requestDowntime) {
                        Label(
                            AppLocalization.string("Wartungszeit", locale: locale),
                            systemImage: "calendar.badge.clock"
                        )
                    }
                    .disabled(!actions.contains(.scheduleDowntime) || issue.isInDowntime)
                    Spacer(minLength: 8)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .padding(.bottom, 8)
            }
            Divider()
                .padding(.leading, 44)
        }
        .disabled(isPerformingAction)
    }
}

private struct IssueActionSheet: View {
    @ObservedObject var model: IssueLightModel
    let pendingAction: PendingIssueAction
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var author = NSFullUserName()
    @State private var comment = ""
    @State private var duration: TimeInterval = 3_600

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(verbatim: title)
                .font(.title2.bold())
            Text(verbatim: pendingAction.issue.summary)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Form {
                TextField(AppLocalization.string("Autor", locale: locale), text: $author)
                TextField(AppLocalization.string("Kommentar", locale: locale), text: $comment, axis: .vertical)
                    .lineLimit(2...4)
                if pendingAction.kind == .scheduleDowntime {
                    Picker(AppLocalization.string("Dauer", locale: locale), selection: $duration) {
                        Text(verbatim: AppLocalization.string("30 Minuten", locale: locale)).tag(TimeInterval(1_800))
                        Text(verbatim: AppLocalization.string("1 Stunde", locale: locale)).tag(TimeInterval(3_600))
                        Text(verbatim: AppLocalization.string("2 Stunden", locale: locale)).tag(TimeInterval(7_200))
                        Text(verbatim: AppLocalization.string("4 Stunden", locale: locale)).tag(TimeInterval(14_400))
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button(AppLocalization.string("Abbrechen", locale: locale)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(AppLocalization.string("Bestätigen", locale: locale)) {
                    let issue = pendingAction.issue
                    let action: MonitoringAction
                    if pendingAction.kind == .acknowledge {
                        action = .acknowledge(author: author, comment: comment)
                    } else {
                        let start = Date()
                        action = .scheduleDowntime(
                            author: author,
                            comment: comment,
                            start: start,
                            end: start.addingTimeInterval(duration)
                        )
                    }
                    dismiss()
                    Task { await model.perform(action, on: issue) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private var title: String {
        pendingAction.kind == .acknowledge
            ? AppLocalization.string("Problem quittieren", locale: locale)
            : AppLocalization.string("Wartungszeit planen", locale: locale)
    }
}

private struct StatusPanelIssueRow: View {
    let issue: MonitoringIssue
    let sourceName: String?
    let isExpanded: Bool
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
                if issue.isAcknowledged || issue.isInDowntime {
                    Text(verbatim: coverageText)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
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
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
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

    private var coverageText: String {
        switch (issue.isAcknowledged, issue.isInDowntime) {
        case (true, true):
            return AppLocalization.string("Quittiert · Wartungszeit", locale: locale)
        case (true, false):
            return AppLocalization.string("Quittiert", locale: locale)
        case (false, true):
            return AppLocalization.string("Wartungszeit", locale: locale)
        case (false, false):
            return ""
        }
    }
}
