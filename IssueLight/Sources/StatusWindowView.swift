import SwiftUI
import IssueLightCore

struct StatusWindowView: View {
    @ObservedObject var model: IssueLightModel

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
                if let observedAt = model.latestSuccessfulRefresh {
                    let date = observedAt.formatted(date: .abbreviated, time: .omitted)
                    let time = observedAt.formatted(date: .omitted, time: .shortened)
                    Text("Zuletzt erfolgreich geprüft: \(date), \(time)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.hasConfiguredSource && !model.hasEnabledSource {
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
            if model.refreshState == .refreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Status wird aktualisiert")
            }
            Button("Aktualisieren") {
                model.refresh()
            }
            .keyboardShortcut("r")
            .disabled(!model.hasEnabledSource)
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasConfiguredSource {
            ContentUnavailableView(
                "Keine Quelle konfiguriert",
                systemImage: "server.rack",
                description: Text("Füge zuerst eine Monitoring-Quelle hinzu.")
            )
        } else if !model.hasEnabledSource {
            ContentUnavailableView(
                "Keine Quelle aktiv",
                systemImage: "pause.circle",
                description: Text("Aktiviere mindestens eine Quelle, um den Status zu überwachen.")
            )
        } else if model.hasActiveSnapshot {
            VStack(spacing: 0) {
                if !model.failedSources.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.failedSources) { failure in
                            Label("\(failure.source.name): \(failure.message)", systemImage: "wifi.exclamationmark")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.orange.opacity(0.12))
                    .accessibilityLabel(
                        [
                            model.hasPartialRefreshFailure
                                ? "Teilweise veralteter Status. \(model.failedSources.count) Quellen konnten nicht aktualisiert werden."
                                : "Veralteter Status. Keine aktive Quelle konnte aktualisiert werden.",
                            model.failedSources
                                .map { "\($0.source.name): \($0.message)" }
                                .joined(separator: " "),
                        ]
                        .joined(separator: " ")
                    )
                }
                if model.actionableIssues.isEmpty && model.coveredIssues.isEmpty {
                    ContentUnavailableView(
                        model.failedSources.isEmpty ? "Alles ruhig" : "Keine aktuellen Probleme",
                        systemImage: "checkmark.circle",
                        description: Text(
                            model.failedSources.isEmpty
                                ? "Keine Hosts oder Services benötigen Aufmerksamkeit."
                                : "Die erreichbaren Quellen melden keine Probleme. Mindestens ein Stand ist veraltet."
                        )
                    )
                } else {
                    List {
                        if !model.actionableIssues.isEmpty {
                            Section("Benötigt Aufmerksamkeit") {
                                ForEach(model.actionableIssues) { issue in
                                    MonitoringIssueRow(
                                        issue: issue,
                                        sourceName: model.sources.count > 1 ? model.sourceName(for: issue.sourceID) : nil
                                    )
                                }
                            }
                        }
                        if !model.coveredIssues.isEmpty {
                            Section("Quittiert oder in Wartungszeit") {
                                ForEach(model.coveredIssues) { issue in
                                    MonitoringIssueRow(
                                        issue: issue,
                                        sourceName: model.sources.count > 1 ? model.sourceName(for: issue.sourceID) : nil
                                    )
                                }
                            }
                        }
                    }
                }
            }
        } else if case .failed(let message) = model.refreshState {
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
