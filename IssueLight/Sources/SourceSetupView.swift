import SwiftUI
import UniformTypeIdentifiers
import IssueLightCore

struct SourceSetupView: View {
    private enum PendingNavigation {
        case add
        case select(UUID)
    }

    @ObservedObject var model: IssueLightModel
    @Environment(\.locale) private var locale
    private let certificateContentTypes: [UTType] = [
        UTType(filenameExtension: "cer") ?? .data,
        UTType(filenameExtension: "crt") ?? .data,
        UTType(filenameExtension: "der") ?? .data,
        UTType(filenameExtension: "pem") ?? .data,
    ]
    @State private var importURL: URL?
    @State private var isChoosingIdentity = false
    @State private var isImportingIdentity = false
    @State private var isChoosingServerCertificate = false
    @State private var isChoosingPinnedServerCertificate = false
    @State private var isConfirmingDeletion = false
    @State private var isConfirmingDiscard = false
    @State private var pendingNavigation: PendingNavigation?
    @State private var connectionTask: Task<Void, Never>?

    var body: some View {
        NavigationSplitView {
            List(selection: sourceSelection) {
                ForEach(model.sources) { source in
                    SourceRow(source: source, model: model)
                        .tag(source.id)
                }
            }
            .navigationTitle("Quellen")
            .overlay {
                if model.sources.isEmpty {
                    ContentUnavailableView(
                        "Noch keine Quellen",
                        systemImage: "server.rack",
                        description: Text("Füge deine erste Monitoring-Quelle hinzu.")
                    )
                }
            }
            .toolbar {
                Button {
                    requestAdd()
                } label: {
                    Label("Quelle hinzufügen", systemImage: "plus")
                }
                .help("Neue Quelle")
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            editor
                .navigationTitle(
                    model.isCreatingSource
                        ? AppLocalization.string("Neue Quelle", locale: locale)
                        : model.name
                )
        }
        .frame(minWidth: 780, minHeight: 600)
        .onDisappear {
            connectionTask?.cancel()
            Task { _ = await model.cleanupUnreferencedManagedServerCertificates() }
        }
        .sheet(isPresented: $isImportingIdentity) {
            if let importURL {
                IdentityImportView(fileURL: importURL, model: model, isPresented: $isImportingIdentity)
            }
        }
        .confirmationDialog(
            "Quelle wirklich entfernen?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Quelle entfernen", role: .destructive) {
                Task { await model.deleteSource() }
            }
        } message: {
            Text(model.deletionMessage)
        }
        .confirmationDialog(
            "Ungespeicherte Änderungen verwerfen?",
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Änderungen verwerfen", role: .destructive) {
                performPendingNavigation()
            }
            Button("Weiter bearbeiten", role: .cancel) {
                pendingNavigation = nil
            }
        } message: {
            Text("Die Änderungen an der aktuellen Quelle wurden noch nicht gespeichert.")
        }
    }

    private var sourceSelection: Binding<UUID?> {
        Binding(
            get: { model.selectedSourceID },
            set: { sourceID in
                guard let sourceID, sourceID != model.selectedSourceID else { return }
                requestSelection(sourceID)
            }
        )
    }

    private var editor: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Quelle aktiv", isOn: $model.isSourceEnabled)
                    if model.providers.count == 1 {
                        LabeledContent("Typ", value: model.providerDisplayName)
                    } else {
                        Picker("Typ", selection: $model.selectedProviderID) {
                            ForEach(model.providers, id: \.id) { provider in
                                Text(provider.displayName).tag(provider.id)
                            }
                        }
                    }
                    TextField("Name", text: $model.name, prompt: Text("Produktion"))
                    TextField("Server", text: $model.endpoint, prompt: Text("https://icinga.example:5665"))
                        .textContentType(.URL)
                } header: {
                    if model.isCreatingSource {
                        Text("Neue Quelle")
                    } else {
                        Text("Quelle")
                    }
                } footer: {
                    Text("IssueLight prüft Hosts und Services über die reale API dieser Quelle.")
                }

                Section("Authentifizierung") {
                    Picker("Methode", selection: $model.authenticationChoice) {
                        ForEach(model.authenticationChoices) { choice in
                            Text(verbatim: choice.displayName(locale: locale)).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)

                    if model.authenticationChoice == .basic {
                        TextField("Benutzername", text: $model.username)
                            .textContentType(.username)
                        SecureField("Passwort", text: $model.password)
                            .textContentType(.password)
                        Text(
                            model.hasStoredBasicPassword
                                ? AppLocalization.string(
                                    "Leer lassen, um das vorhandene Passwort bei unveränderten Zugangsdaten beizubehalten.",
                                    locale: locale
                                )
                                : AppLocalization.string(
                                    "Das Passwort wird ausschließlich im macOS-Schlüsselbund gespeichert.",
                                    locale: locale
                                )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        if let identityLoadError = model.identityLoadError {
                            Label(identityLoadError, systemImage: "exclamationmark.circle")
                                .foregroundStyle(.red)
                        }
                        Picker("Identität", selection: $model.selectedIdentityID) {
                            Text("Zertifikat auswählen …").tag("")
                            ForEach(model.identities) { identity in
                                Text(identity.displayName).tag(identity.id)
                            }
                        }
                        Button("PKCS#12 importieren …") {
                            isChoosingIdentity = true
                        }
                        .fileImporter(
                            isPresented: $isChoosingIdentity,
                            allowedContentTypes: [
                                UTType(filenameExtension: "p12") ?? .data,
                                UTType(filenameExtension: "pfx") ?? .data,
                            ],
                            allowsMultipleSelection: false
                        ) { result in
                            if case .success(let urls) = result, let url = urls.first {
                                importURL = url
                                isImportingIdentity = true
                            }
                        }
                    }
                }

                Section {
                    Picker("Serververtrauen", selection: $model.serverTrustChoice) {
                        ForEach(model.serverTrustChoices) { choice in
                            Text(verbatim: choice.displayName(locale: locale)).tag(choice)
                        }
                    }

                    if model.serverTrustChoice == .customCertificate {
                        if let certificate = model.selectedServerCertificate {
                            LabeledContent("CA", value: certificate.displayName)
                            Text("SHA-256: \(certificate.sha256Fingerprint)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        } else {
                            Label("Importiere genau ein CA-Zertifikat.", systemImage: "exclamationmark.circle")
                                .foregroundStyle(.orange)
                        }
                        Button(
                            model.selectedServerCertificate == nil
                                ? AppLocalization.string("CA-Zertifikat importieren …", locale: locale)
                                : AppLocalization.string("CA-Zertifikat ersetzen …", locale: locale)
                        ) {
                            isChoosingServerCertificate = true
                        }
                        .fileImporter(
                            isPresented: $isChoosingServerCertificate,
                            allowedContentTypes: certificateContentTypes,
                            allowsMultipleSelection: false
                        ) { result in
                            if case .success(let urls) = result, let url = urls.first {
                                Task { _ = await model.importServerCertificate(at: url) }
                            }
                        }
                    } else if model.serverTrustChoice == .pinnedCertificate {
                        if model.pinnedServerCertificateSHA256.isEmpty {
                            Label("Wähle genau ein Serverzertifikat aus.", systemImage: "exclamationmark.circle")
                                .foregroundStyle(.orange)
                        } else {
                            Text("SHA-256: \(model.pinnedServerCertificateSHA256)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text("Bei einer Zertifikatserneuerung bleibt die Verbindung blockiert, bis du das neue Zertifikat hier geprüft und ausgewählt hast.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button(
                            model.pinnedServerCertificateSHA256.isEmpty
                                ? AppLocalization.string("Serverzertifikat auswählen …", locale: locale)
                                : AppLocalization.string("Serverzertifikat ersetzen …", locale: locale)
                        ) {
                            isChoosingPinnedServerCertificate = true
                        }
                        .fileImporter(
                            isPresented: $isChoosingPinnedServerCertificate,
                            allowedContentTypes: certificateContentTypes,
                            allowsMultipleSelection: false
                        ) { result in
                            if case .success(let urls) = result, let url = urls.first {
                                _ = model.pinServerCertificate(at: url)
                            }
                        }
                    } else if model.serverTrustChoice == .disabled {
                        Label {
                            Text("Unsicher. Identität und Serverdaten können abgefangen oder verändert werden. Diese Ausnahme gilt nur für diese Quelle.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(.orange)
                    }
                } header: {
                    Text("TLS")
                } footer: {
                    Text("macOS-Systemvertrauen ist der Standard. Eigene CAs und exakte Serverzertifikate gelten nur für diese Quelle. Die vollständige Deaktivierung ist für isolierte Homelabs gedacht.")
                }

            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(0)
            .disabled(isWorking)

            Divider()
            VStack(alignment: .leading, spacing: 12) {
                activityView
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    if !model.isCreatingSource {
                        Button("Quelle entfernen", role: .destructive) {
                            isConfirmingDeletion = true
                        }
                        .disabled(isWorking)
                    }
                    Spacer()
                    if model.isTestingConnection {
                        Button("Abbrechen", role: .cancel) {
                            connectionTask?.cancel()
                        }
                    } else {
                        Button("Verbindung testen") {
                            connectionTask = Task { await model.testConnection() }
                        }
                        .disabled(isWorking)
                    }

                    Button("Speichern") {
                        Task { await model.save() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || !model.hasUnsavedChanges)
                }
            }
            .padding(16)
            .background(.bar)
            .layoutPriority(1)
        }
    }

    @ViewBuilder
    private var activityView: some View {
        switch model.activity {
        case .idle:
            Text("Konfiguration eingeben, Verbindung prüfen und anschließend speichern.")
                .foregroundStyle(.secondary)
        case .working(let message):
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text(message)
            }
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private var isWorking: Bool {
        if case .working = model.activity { return true }
        return false
    }

    private func requestAdd() {
        connectionTask?.cancel()
        if model.hasUnsavedChanges {
            pendingNavigation = .add
            isConfirmingDiscard = true
        } else {
            model.beginAddingSource()
        }
    }

    private func requestSelection(_ sourceID: UUID) {
        connectionTask?.cancel()
        if model.hasUnsavedChanges {
            pendingNavigation = .select(sourceID)
            isConfirmingDiscard = true
        } else {
            Task { await model.selectSource(id: sourceID) }
        }
    }

    private func performPendingNavigation() {
        guard let pendingNavigation else { return }
        self.pendingNavigation = nil
        Task {
            _ = await model.cleanupUnreferencedManagedServerCertificates()
            switch pendingNavigation {
            case .add:
                model.beginAddingSource()
            case .select(let sourceID):
                await model.selectSource(id: sourceID)
            }
        }
    }
}

private struct SourceRow: View {
    let source: MonitoringSource
    @ObservedObject var model: IssueLightModel
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .lineLimit(1)
                Group {
                    if source.isEnabled {
                        Text(verbatim: model.providerName(for: source))
                    } else {
                        Text("Pausiert")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(source.name), \(statusLabel)")
    }

    private var statusSymbol: String {
        switch model.sourceRefreshState(for: source.id) {
        case .notConfigured:
            return "circle"
        case .disabled:
            return "pause.circle"
        case .refreshing:
            return "arrow.clockwise"
        case .current:
            switch model.snapshots[source.id]?.highestAttentionSeverity {
            case .critical:
                return "exclamationmark.octagon.fill"
            case .unknown:
                return "questionmark.diamond.fill"
            case .warning:
                return "exclamationmark.triangle.fill"
            case nil:
                return "checkmark.circle"
            }
        case .failed:
            return "wifi.exclamationmark"
        }
    }

    private var statusColor: Color {
        switch model.sourceRefreshState(for: source.id) {
        case .notConfigured, .disabled, .refreshing:
            return .secondary
        case .current:
            switch model.snapshots[source.id]?.highestAttentionSeverity {
            case .critical:
                return .red
            case .unknown:
                return .purple
            case .warning:
                return .orange
            case nil:
                return .green
            }
        case .failed:
            return .red
        }
    }

    private var statusLabel: String {
        switch model.sourceRefreshState(for: source.id) {
        case .notConfigured:
            return AppLocalization.string("nicht konfiguriert", locale: locale)
        case .disabled:
            return AppLocalization.string("pausiert", locale: locale)
        case .refreshing:
            return AppLocalization.string("wird aktualisiert", locale: locale)
        case .current:
            let count = model.snapshots[source.id]?.actionableIssues.count ?? 0
            return IssueCountText.sourceStatus(count, locale: locale)
        case .failed(let message):
            return AppLocalization.string("Aktualisierung fehlgeschlagen, \(message)", locale: locale)
        }
    }
}

private struct IdentityImportView: View {
    let fileURL: URL
    @ObservedObject var model: IssueLightModel
    @Binding var isPresented: Bool
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Client-Zertifikat importieren")
                .font(.title2.weight(.semibold))
            Text(fileURL.lastPathComponent)
                .foregroundStyle(.secondary)
            SecureField("PKCS#12-Passwort", text: $password)
                .textContentType(.password)
            Text("Das Importpasswort wird nicht gespeichert.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Abbrechen") { isPresented = false }
                Button("Importieren") {
                    Task {
                        if await model.importIdentity(at: fileURL, password: password) {
                            isPresented = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
