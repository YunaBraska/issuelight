import SwiftUI
import IssueLightCore

struct StatusWindowView: View {
    @ObservedObject var model: IssueLightModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 620, minHeight: 420)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name.isEmpty ? "IssueLight" : model.name)
                    .font(.title2.weight(.semibold))
                if let observedAt = model.snapshot?.observedAt {
                    Text("Zuletzt erfolgreich geprüft: \(observedAt.formatted(date: .abbreviated, time: .shortened))")
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
            .disabled(!model.hasConfiguredSource)
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
        } else if let snapshot = model.snapshot {
            VStack(spacing: 0) {
                if case .failed(let message) = model.refreshState {
                    Label(message, systemImage: "wifi.exclamationmark")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.orange.opacity(0.12))
                        .accessibilityLabel("Veralteter Status. \(message)")
                }
                if snapshot.issues.isEmpty {
                    ContentUnavailableView(
                        "Alles ruhig",
                        systemImage: "checkmark.circle",
                        description: Text("Keine Hosts oder Services benötigen Aufmerksamkeit.")
                    )
                } else {
                    List {
                        if !model.actionableIssues.isEmpty {
                            Section("Benötigt Aufmerksamkeit") {
                                ForEach(model.actionableIssues) { issue in
                                    MonitoringIssueRow(issue: issue)
                                }
                            }
                        }
                        if !model.coveredIssues.isEmpty {
                            Section("Quittiert oder in Wartungszeit") {
                                ForEach(model.coveredIssues) { issue in
                                    MonitoringIssueRow(issue: issue)
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
        return "\(context) \(title), \(severityText)\(coverage), \(issue.summary)"
    }
}
