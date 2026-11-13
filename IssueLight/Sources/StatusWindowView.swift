import SwiftUI
import IssueLightCore

struct StatusWindowView: View {
    @ObservedObject var model: IssueLightModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        StatusWindowContent(
            hasConfiguredSource: model.hasConfiguredSource,
            hasEnabledSource: model.hasEnabledSource,
            hasActiveSnapshot: model.hasActiveSnapshot,
            latestSuccessfulRefresh: model.latestSuccessfulRefresh,
            refreshState: model.refreshState,
            hasPartialRefreshFailure: model.hasPartialRefreshFailure,
            failedSources: model.failedSources.map {
                StatusSourceFailure(id: $0.source.id, sourceName: $0.source.name, message: $0.message)
            },
            actionableIssues: model.actionableIssues,
            coveredIssues: model.coveredIssues,
            sourceNames: Dictionary(uniqueKeysWithValues: model.sources.map { ($0.id, $0.name) }),
            refresh: { model.refresh() },
            openSources: {
                openWindow(id: "sources")
            }
        )
    }
}

struct StatusSourceFailure: Identifiable, Equatable {
    let id: UUID
    let sourceName: String
    let message: String
}

struct StatusWindowContent: View {
    let hasConfiguredSource: Bool
    let hasEnabledSource: Bool
    let hasActiveSnapshot: Bool
    let latestSuccessfulRefresh: Date?
    let refreshState: IssueLightModel.RefreshState
    let hasPartialRefreshFailure: Bool
    let failedSources: [StatusSourceFailure]
    let actionableIssues: [MonitoringIssue]
    let coveredIssues: [MonitoringIssue]
    let sourceNames: [UUID: String]
    let refresh: () -> Void
    let openSources: () -> Void
    @Environment(\.locale) private var locale
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            minWidth: 620,
            maxWidth: .infinity,
            minHeight: 420,
            maxHeight: .infinity,
            alignment: .top
        )
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("IssueLight")
                    .font(.title2.weight(.semibold))
                if let observedAt = latestSuccessfulRefresh {
                    let date = observedAt.formatted(
                        Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)
                    )
                    let time = observedAt.formatted(
                        Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)
                    )
                    Text("Zuletzt erfolgreich geprüft: \(date), \(time)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if hasConfiguredSource && !hasEnabledSource {
                    Text("Alle Quellen sind pausiert")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Noch kein erfolgreicher Statusabruf")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if refreshState == .refreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Status wird aktualisiert")
            }
            Button("Aktualisieren") {
                refresh()
            }
            .keyboardShortcut("r")
            .disabled(!hasEnabledSource)
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if !hasConfiguredSource {
            ContentUnavailableView {
                Label("Keine Quelle konfiguriert", systemImage: "server.rack")
            } description: {
                Text("Füge zuerst eine Monitoring-Quelle hinzu.")
            } actions: {
                Button("Quelle hinzufügen …") {
                    openSources()
                }
                .keyboardShortcut(.defaultAction)
            }
        } else if !hasEnabledSource {
            ContentUnavailableView {
                Label("Keine Quelle aktiv", systemImage: "pause.circle")
            } description: {
                Text("Aktiviere mindestens eine Quelle, um den Status zu überwachen.")
            } actions: {
                Button("Quellen öffnen …") {
                    openSources()
                }
                .keyboardShortcut(.defaultAction)
            }
        } else if hasActiveSnapshot {
            let search = MonitoringIssueSearch(query: searchText, sourceNames: sourceNames)
            let filteredActionableIssues = search.filter(actionableIssues)
            let filteredCoveredIssues = search.filter(coveredIssues)
            VStack(spacing: 0) {
                if !failedSources.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(failedSources) { failure in
                            Label("\(failure.sourceName): \(failure.message)", systemImage: "wifi.exclamationmark")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.orange.opacity(0.12))
                    .accessibilityLabel(
                        [
                            hasPartialRefreshFailure
                                ? "Teilweise veralteter Status. \(failedSources.count) Quellen konnten nicht aktualisiert werden."
                                : "Veralteter Status. Keine aktive Quelle konnte aktualisiert werden.",
                            failedSources
                                .map { "\($0.sourceName): \($0.message)" }
                                .joined(separator: " "),
                        ]
                        .joined(separator: " ")
                    )
                }
                if actionableIssues.isEmpty && coveredIssues.isEmpty {
                    ContentUnavailableView(
                        failedSources.isEmpty ? "Alles ruhig" : "Keine aktuellen Probleme",
                        systemImage: "checkmark.circle",
                        description: Text(
                            failedSources.isEmpty
                                ? "Keine Hosts oder Services benötigen Aufmerksamkeit."
                                : "Die erreichbaren Quellen melden keine Probleme. Mindestens ein Stand ist veraltet."
                        )
                    )
                } else {
                    Group {
                        if filteredActionableIssues.isEmpty && filteredCoveredIssues.isEmpty {
                            ContentUnavailableView(
                                "Keine Treffer",
                                systemImage: "magnifyingglass",
                                description: Text("Kein Problem passt zu „\(searchText)“.")
                            )
                        } else {
                            List {
                                if !filteredActionableIssues.isEmpty {
                                    Section("Benötigt Aufmerksamkeit") {
                                        ForEach(filteredActionableIssues) { issue in
                                            MonitoringIssueRow(
                                                issue: issue,
                                                sourceName: sourceNames.count > 1 ? sourceNames[issue.sourceID] : nil
                                            )
                                        }
                                    }
                                }
                                if !filteredCoveredIssues.isEmpty {
                                    Section("Quittiert oder in Wartungszeit") {
                                        ForEach(filteredCoveredIssues) { issue in
                                            MonitoringIssueRow(
                                                issue: issue,
                                                sourceName: sourceNames.count > 1 ? sourceNames[issue.sourceID] : nil
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .searchable(text: $searchText, prompt: "Probleme durchsuchen")
                }
            }
        } else if case .failed(let message) = refreshState {
            ContentUnavailableView(
                "Status konnte nicht geladen werden",
                systemImage: "wifi.exclamationmark",
                description: Text(message)
            )
        } else {
            ContentUnavailableView(
                "Status wird geladen",
                systemImage: "arrow.clockwise",
                description: Text("IssueLight fragt Hosts und Services bei der Quelle ab.")
            )
        }
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

private struct MonitoringIssueRow: View {
    let issue: MonitoringIssue
    let sourceName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .fontWeight(.medium)
                Text(issue.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let sourceName {
                    Label(sourceName, systemImage: "server.rack")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if issue.isAcknowledged || issue.isInDowntime {
                    Text(coverageText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(severityText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var title: String {
        switch issue.kind {
        case .host:
            return issue.displayName
        case .service:
            return "\(issue.hostName) · \(issue.displayName)"
        }
    }

    private var symbol: String {
        switch issue.severity {
        case .critical:
            return "exclamationmark.octagon.fill"
        case .unknown:
            return "questionmark.diamond.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch issue.severity {
        case .critical:
            return .red
        case .unknown:
            return .purple
        case .warning:
            return .orange
        }
    }

    private var severityText: String {
        switch issue.severity {
        case .critical:
            return "Kritisch"
        case .unknown:
            return "Unbekannt"
        case .warning:
            return "Warnung"
        }
    }

    private var coverageText: String {
        switch (issue.isAcknowledged, issue.isInDowntime) {
        case (true, true):
            return "Quittiert · Wartungszeit"
        case (true, false):
            return "Quittiert"
        case (false, true):
            return "Wartungszeit"
        case (false, false):
            return ""
        }
    }

    private var accessibilityLabel: String {
        let context = issue.kind == .host ? "Host" : "Service"
        let coverage = coverageText.isEmpty ? "" : ", \(coverageText)"
        let source = sourceName.map { ", Quelle \($0)" } ?? ""
        return "\(context) \(title), \(severityText)\(coverage)\(source), \(issue.summary)"
    }
}
