import AppKit
import SwiftUI
import IssueLightCore

struct StatusMenuView: View {
    @ObservedObject var model: IssueLightModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        summary

        if !model.actionableIssues.isEmpty {
            Divider()
            ForEach(model.actionableIssues.prefix(5)) { issue in
                Label(issueTitle(issue), systemImage: issueSymbol(issue))
                    .help(issue.summary)
            }
            if model.actionableIssues.count > 5 {
                Button("Alle \(model.actionableIssues.count) Probleme zeigen …") {
                    showStatus()
                }
            }
        }

        if !model.coveredIssues.isEmpty {
            Label(
                "\(model.coveredIssues.count) quittiert oder in Wartungszeit",
                systemImage: "checkmark.shield"
            )
        }

        Divider()

        if model.hasConfiguredSource {
            Button("Status zeigen …") {
                showStatus()
            }
            Button("Jetzt aktualisieren") {
                model.refresh()
            }
            .keyboardShortcut("r")
        }

        Button("Quellen …") {
            openWindow(id: "sources")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("IssueLight beenden") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    @ViewBuilder
    private var summary: some View {
        if !model.hasConfiguredSource {
            Label("Keine Quelle konfiguriert", systemImage: "exclamationmark.triangle")
        } else if case .failed(let message) = model.refreshState {
            Label("Aktualisierung fehlgeschlagen", systemImage: "wifi.exclamationmark")
                .help(message)
            if let observedAt = model.snapshot?.observedAt {
                Text("Letzter erfolgreicher Stand: \(observedAt.formatted(date: .omitted, time: .shortened))")
            }
        } else if model.refreshState == .refreshing, model.snapshot == nil {
            Label("Status wird geladen …", systemImage: "arrow.clockwise")
        } else if model.actionableIssues.isEmpty {
            Label("Keine Probleme benötigen Aufmerksamkeit", systemImage: "checkmark.circle")
            lastSuccessfulRefresh
        } else {
            Label(
                "\(model.actionableIssues.count) Probleme benötigen Aufmerksamkeit",
                systemImage: model.menuBarSymbol
            )
            lastSuccessfulRefresh
        }
    }

    @ViewBuilder
    private var lastSuccessfulRefresh: some View {
        if let observedAt = model.snapshot?.observedAt {
            Text("Zuletzt geprüft: \(observedAt.formatted(date: .omitted, time: .shortened))")
        }
    }

    private func showStatus() {
        openWindow(id: "status")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func issueTitle(_ issue: MonitoringIssue) -> String {
        switch issue.kind {
        case .host:
            return issue.displayName
        case .service:
            return "\(issue.hostName) · \(issue.displayName)"
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
