import AppKit
import SwiftUI

struct StatusMenuView: View {
    @ObservedObject var model: SourceSetupModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.hasConfiguredSource {
            Label(model.name.isEmpty ? "Icinga 2" : model.name, systemImage: "server.rack")
        } else {
            Label("Keine Quelle konfiguriert", systemImage: "exclamationmark.triangle")
        }

        Divider()

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
}
