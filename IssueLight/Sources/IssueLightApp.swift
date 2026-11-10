import SwiftUI

@main
struct IssueLightApp: App {
    @StateObject private var model = IssueLightModel()

    var body: some Scene {
        Window("Quellen", id: "sources") {
            SourceSetupView(model: model)
        }
        .defaultSize(width: 620, height: 620)
        .windowResizability(.contentMinSize)

        Window("IssueLight", id: "status") {
            StatusWindowView(model: model)
        }
        .defaultSize(width: 760, height: 560)

        MenuBarExtra {
            StatusMenuView(model: model)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: model.menuBarSymbol)
                if !model.actionableIssues.isEmpty {
                    Text("\(model.actionableIssues.count)")
                        .monospacedDigit()
                }
            }
            .accessibilityLabel(menuBarAccessibilityLabel)
        }
        .menuBarExtraStyle(.menu)
    }

    private var menuBarAccessibilityLabel: String {
        if !model.hasConfiguredSource {
            return "IssueLight, keine Quelle konfiguriert"
        }
        if case .failed(let message) = model.refreshState {
            return "IssueLight, Aktualisierung fehlgeschlagen: \(message)"
        }
        let count = model.actionableIssues.count
        return count == 0
            ? "IssueLight, keine Probleme benötigen Aufmerksamkeit"
            : "IssueLight, \(count) Probleme benötigen Aufmerksamkeit"
    }
}
