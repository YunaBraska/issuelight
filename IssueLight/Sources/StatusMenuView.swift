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
    let down: Int

    init(issues: [MonitoringIssue]) {
        critical = issues.filter { $0.kind == .service && $0.severity == .critical }.count
        warning = issues.filter { $0.kind == .service && $0.severity == .warning }.count
        unknown = issues.filter { $0.kind == .service && $0.severity == .unknown }.count
        down = issues.filter { $0.kind == .host }.count
    }

    var compactText: String {
        [
            critical > 0 ? "C:\(critical)" : nil,
            warning > 0 ? "W:\(warning)" : nil,
            unknown > 0 ? "U:\(unknown)" : nil,
            down > 0 ? "D:\(down)" : nil,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }
}

struct StatusMenuView: View {
    @ObservedObject var model: IssueLightModel
    @ObservedObject var externalActions: ExternalActionCoordinator
    @Environment(\.openSettings) private var openSettings
    @State private var pendingAction: PendingIssueAction?
    @StateObject private var filters = PanelFilterSettings()
    @Environment(\.locale) private var locale

    var body: some View {
        StatusMenuContent(
            hasConfiguredSource: model.hasConfiguredSource,
            hasEnabledSource: model.hasEnabledSource,
            hasActiveSnapshot: model.hasActiveSnapshot,
            actionableIssues: model.actionableIssues,
            coveredIssues: model.coveredIssues,
            sourceNames: Dictionary(uniqueKeysWithValues: model.sources.map { ($0.id, $0.name) }),
            filters: filters,
            refreshState: model.refreshState,
            hasPartialRefreshFailure: model.hasPartialRefreshFailure,
            supportedActions: model.supportedActions,
            activeActionIssueIDs: model.activeActionIssueIDs,
            openSettings: {
                openSettings()
                NSApp.activate()
            },
            openIssue: { issue in
                Task {
                    guard let target = model.webTarget(for: issue) else {
                        model.reportMissingWebConfiguration()
                        return
                    }
                    if case .failure(let error) = await externalActions.openWeb(target) {
                        model.reportExternalActionError(error)
                    }
                }
            },
            openSSH: { issue in
                guard let url = model.sshURL(for: issue) else { return }
                if case .failure(let error) = externalActions.openRemote(url) {
                    model.reportExternalActionError(error)
                }
            },
            openRDP: { issue in
                guard let url = model.rdpURL(for: issue) else { return }
                if case .failure(let error) = externalActions.openRemote(url) {
                    model.reportExternalActionError(error)
                }
            },
            hasSSH: { model.sshURL(for: $0) != nil },
            hasRDP: { model.rdpURL(for: $0) != nil },
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
        .onChange(of: model.sources.map(\.id), initial: true) { _, sourceIDs in
            filters.reconcile(
                sourceIDs: Set(sourceIDs),
                isAuthoritative: model.hasLoadedSources
            )
        }
        .onChange(of: model.hasLoadedSources) { _, hasLoadedSources in
            filters.reconcile(
                sourceIDs: Set(model.sources.map(\.id)),
                isAuthoritative: hasLoadedSources
            )
        }
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
    @ObservedObject var filters: PanelFilterSettings
    let refreshState: IssueLightModel.RefreshState
    let hasPartialRefreshFailure: Bool
    let supportedActions: (MonitoringIssue) -> Set<MonitoringActionKind>
    let activeActionIssueIDs: Set<String>
    let openSettings: () -> Void
    let openIssue: (MonitoringIssue) -> Void
    let openSSH: (MonitoringIssue) -> Void
    let openRDP: (MonitoringIssue) -> Void
    let hasSSH: (MonitoringIssue) -> Bool
    let hasRDP: (MonitoringIssue) -> Bool
    let performRecheck: (MonitoringIssue) -> Void
    let requestAcknowledgement: (MonitoringIssue) -> Void
    let requestDowntime: (MonitoringIssue) -> Void
    @Environment(\.locale) private var locale
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    AppLocalization.string("Probleme durchsuchen", locale: locale),
                    text: $searchText
                )
                .textFieldStyle(.plain)
                .accessibilityIdentifier("issue-search")
                .disabled(!hasActiveSnapshot || actionableIssues.isEmpty && coveredIssues.isEmpty)
                if refreshState == .refreshing {
                    ProgressView()
                        .controlSize(.small)
                }
                filterMenu
                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .help(AppLocalization.string("Einstellungen …", locale: locale))
                .accessibilityLabel(AppLocalization.string("Einstellungen …", locale: locale))
                .accessibilityIdentifier("open-settings")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if hasActiveSnapshot, case .failed(let message) = refreshState {
                Label(
                    hasPartialRefreshFailure
                        ? AppLocalization.string("Aktualisierung teilweise fehlgeschlagen", locale: locale)
                        : AppLocalization.string("Status ist veraltet", locale: locale),
                    systemImage: "wifi.exclamationmark"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
                .help(message)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }

            issuePanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 720, height: panelHeight)
    }

    private var panelHeight: CGFloat {
        if !hasConfiguredSource || !hasEnabledSource || !hasActiveSnapshot {
            return 220
        }
        if actionableIssues.isEmpty && coveredIssues.isEmpty {
            return 200
        }
        let failureHeight: CGFloat
        if case .failed = refreshState {
            failureHeight = 30
        } else {
            failureHeight = 0
        }
        return min(
            520,
            max(
                180,
                52
                    + CGFloat(filteredActionableIssues.count + filteredCoveredIssues.count) * 40
                    + failureHeight
            )
        )
    }

    private var filteredActionableIssues: [MonitoringIssue] {
        MonitoringIssueSearch(query: searchText, sourceNames: sourceNames)
            .filter(actionableIssues)
            .filter { filters.includes($0, isCovered: false) }
    }

    private var filteredCoveredIssues: [MonitoringIssue] {
        MonitoringIssueSearch(query: searchText, sourceNames: sourceNames)
            .filter(coveredIssues)
            .filter { filters.includes($0, isCovered: true) }
    }

    private var filterMenu: some View {
        Menu {
            Picker(AppLocalization.string("Instanz", locale: locale), selection: $filters.sourceID) {
                Text(verbatim: AppLocalization.string("Alle Instanzen", locale: locale)).tag("")
                ForEach(sourceNames.sorted(by: { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }), id: \.key) { sourceID, name in
                    Text(verbatim: name).tag(sourceID.uuidString.lowercased())
                }
            }
            Picker(AppLocalization.string("Status", locale: locale), selection: $filters.severity) {
                Text(verbatim: AppLocalization.string("Alle Zustände", locale: locale)).tag(PanelSeverityFilter.all)
                Text(verbatim: AppLocalization.string("Kritisch", locale: locale)).tag(PanelSeverityFilter.critical)
                Text(verbatim: AppLocalization.string("Warnung", locale: locale)).tag(PanelSeverityFilter.warning)
                Text(verbatim: AppLocalization.string("Unbekannt", locale: locale)).tag(PanelSeverityFilter.unknown)
                Text(verbatim: "DOWN").tag(PanelSeverityFilter.down)
            }
            Picker(AppLocalization.string("Sichtbarkeit", locale: locale), selection: $filters.coverage) {
                Text(verbatim: AppLocalization.string("Alle Probleme", locale: locale)).tag(PanelCoverageFilter.all)
                Text(verbatim: AppLocalization.string("Benötigt Aufmerksamkeit", locale: locale)).tag(PanelCoverageFilter.attention)
                Text(verbatim: AppLocalization.string("Quittiert oder in Wartungszeit", locale: locale)).tag(PanelCoverageFilter.covered)
            }
            if filters.isActive {
                Divider()
                Button(AppLocalization.string("Filter zurücksetzen", locale: locale)) {
                    filters.reset()
                }
            }
        } label: {
            Image(systemName: filters.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(AppLocalization.string("Filter", locale: locale))
        .accessibilityLabel(AppLocalization.string("Filter", locale: locale))
        .accessibilityIdentifier("issue-filter")
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
                            searchText.isEmpty
                                ? "Keine Probleme entsprechen den aktiven Filtern."
                                : "Kein Problem passt zu „\(searchText)“.",
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

    private func issueEntry(_ issue: MonitoringIssue) -> some View {
        StatusPanelIssueEntry(
            issue: issue,
            sourceName: sourceNames[issue.sourceID] ?? AppLocalization.string("Unbekannte Quelle", locale: locale),
            isPerformingAction: activeActionIssueIDs.contains(issue.id),
            actions: supportedActions(issue),
            openIssue: { openIssue(issue) },
            openSSH: hasSSH(issue) ? { openSSH(issue) } : nil,
            openRDP: hasRDP(issue) ? { openRDP(issue) } : nil,
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
    let sourceName: String
    let isPerformingAction: Bool
    let actions: Set<MonitoringActionKind>
    let openIssue: () -> Void
    let openSSH: (() -> Void)?
    let openRDP: (() -> Void)?
    let performRecheck: () -> Void
    let requestAcknowledgement: () -> Void
    let requestDowntime: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 4) {
            Button(action: openIssue) {
                StatusPanelIssueRow(
                    issue: issue,
                    sourceName: sourceName
                )
            }
            .buttonStyle(.plain)
            .help(AppLocalization.string("In Weboberfläche öffnen", locale: locale))

            if isPerformingAction {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 84)
            } else {
                quickAction(
                    AppLocalization.string("Erneut prüfen", locale: locale),
                    systemImage: "play.circle",
                    enabled: actions.contains(.recheck),
                    action: performRecheck
                )
                quickAction(
                    AppLocalization.string("Quittieren …", locale: locale),
                    systemImage: "checkmark.message",
                    enabled: actions.contains(.acknowledge) && !issue.isAcknowledged,
                    action: requestAcknowledgement
                )
                quickAction(
                    AppLocalization.string("Wartungszeit", locale: locale),
                    systemImage: "calendar.badge.clock",
                    enabled: actions.contains(.scheduleDowntime) && !issue.isInDowntime,
                    action: requestDowntime
                )
            }
        }
        .padding(.trailing, 8)
        .frame(height: 39)
        .background(issue.presentationColor.opacity(issue.requiresAttention ? 0.09 : 0.045))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(issue.presentationColor)
                .frame(width: 3)
        }
        .overlay(alignment: .bottom) { Divider().padding(.leading, 34) }
        .contextMenu {
            Button(AppLocalization.string("In Weboberfläche öffnen", locale: locale), systemImage: "safari", action: openIssue)
            if let openSSH {
                Button("SSH", systemImage: "terminal", action: openSSH)
            }
            if let openRDP {
                Button("RDP", systemImage: "rectangle.connected.to.line.below", action: openRDP)
            }
        }
    }

    private func quickAction(
        _ title: String,
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(title)
        .accessibilityLabel(title)
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
    let sourceName: String
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 20)
                .help(severityText)
            Text(verbatim: sourceName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 82, alignment: .leading)
                .help(sourceName)
            Text(verbatim: title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .frame(width: 154, alignment: .leading)
                .help(title)
            Text(verbatim: issue.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(issue.summary)
            if let durationText {
                Text(verbatim: durationText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
                    .help(AppLocalization.string("Dauer", locale: locale))
            }
            if let attemptText {
                Text(verbatim: attemptText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
                    .help(AppLocalization.string("Versuch", locale: locale))
            }
            if issue.isAcknowledged || issue.isInDowntime {
                Image(systemName: issue.isInDowntime ? "calendar.badge.clock" : "checkmark.message")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .help(coverageText)
            }
        }
        .padding(.leading, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var title: String {
        issue.kind == .host ? issue.displayName : "\(issue.hostName) · \(issue.displayName)"
    }

    private var symbol: String {
        if issue.kind == .host {
            return "network.slash"
        }
        switch issue.severity {
        case .critical: return "exclamationmark.octagon.fill"
        case .unknown: return "questionmark.diamond.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        issue.presentationColor
    }

    private var severityText: String {
        if issue.kind == .host {
            return "DOWN"
        }
        switch issue.severity {
        case .critical: return AppLocalization.string("Kritisch", locale: locale)
        case .unknown: return AppLocalization.string("Unbekannt", locale: locale)
        case .warning: return AppLocalization.string("Warnung", locale: locale)
        }
    }

    private var durationText: String? {
        guard let stateChangedAt = issue.stateChangedAt else { return nil }
        let interval = max(0, Date.now.timeIntervalSince(stateChangedAt))
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        return formatter.string(from: interval)
    }

    private var attemptText: String? {
        guard let checkAttempt = issue.checkAttempt,
              let maxCheckAttempts = issue.maxCheckAttempts else {
            return nil
        }
        return "\(checkAttempt)/\(maxCheckAttempts)"
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

    private var accessibilityText: String {
        [sourceName, severityText, title, issue.summary, durationText, attemptText, coverageText]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: ", ")
    }
}

private extension MonitoringIssue {
    var presentationColor: Color {
        switch severity {
        case .critical: return .red
        case .unknown: return .purple
        case .warning: return .orange
        }
    }
}
