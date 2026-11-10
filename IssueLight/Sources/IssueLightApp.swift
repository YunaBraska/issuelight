import SwiftUI

@main
struct IssueLightApp: App {
    @StateObject private var model = IssueLightModel()

    var body: some Scene {
        Window("Quellen", id: "sources") {
            SourceSetupView(model: model)
        }
        .defaultSize(width: 920, height: 680)
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
        if !model.hasEnabledSource {
            return "IssueLight, alle Quellen pausiert"
        }
        let count = model.actionableIssues.count
        let attention = IssueCountText.attention(count)
        if case .failed(let message) = model.refreshState {
            let failure = model.hasPartialRefreshFailure
                ? "Aktualisierung teilweise fehlgeschlagen"
                : "Status veraltet"
            return "IssueLight. \(attention). \(failure): \(message)"
        }
        return "IssueLight. \(attention)"
    }
}
