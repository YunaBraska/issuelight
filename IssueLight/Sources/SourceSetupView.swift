import AppKit
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
    @State private var presentedServerCertificate: PresentedServerCertificate?
    @State private var isShowingSSHOverrides = false
    @State private var isShowingConnectionAttempts = false
    @State private var isConfirmingDeletion = false
    @State private var isConfirmingDiscard = false
    @State private var pendingNavigation: PendingNavigation?
    @State private var connectionTask: Task<Void, Never>?
    @State private var certificateFetchTask: Task<Void, Never>?

    init(
        model: IssueLightModel,
        initiallyShowsSSHOverrides: Bool = false
    ) {
        self.model = model
        _isShowingSSHOverrides = State(initialValue: initiallyShowsSSHOverrides)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: sourceSelection) {
                    if model.isCreatingSource {
                        SourceDraftRow(
                            name: model.suggestedSourceName,
                            providerName: model.providerDisplayName
                        )
                    }
                    ForEach(model.sources) { source in
                        SourceRow(source: source, model: model)
                            .tag(source.id)
                    }
                }
                .overlay {
                    if model.sources.isEmpty && !model.isCreatingSource {
                        ContentUnavailableView(
                            "Noch keine Quellen",
                            systemImage: "server.rack",
                            description: Text("Füge deine erste Monitoring-Quelle hinzu.")
                        )
                    }
                }

                Divider()
                SourceSidebarFooter(addSource: requestAdd)
            }
            .frame(width: 250)

            Divider()

            editor
        }
        .frame(minWidth: 700, minHeight: 500)
        .onDisappear {
            connectionTask?.cancel()
            certificateFetchTask?.cancel()
            Task { _ = await model.cleanupUnreferencedManagedServerCertificates() }
        }
        .sheet(isPresented: $isImportingIdentity) {
            if let importURL {
                IdentityImportView(fileURL: importURL, model: model, isPresented: $isImportingIdentity)
            }
        }
        .sheet(item: $presentedServerCertificate) { certificate in
            PresentedServerCertificateTrustView(
                certificate: certificate,
                cancel: { presentedServerCertificate = nil },
                trust: {
                    model.trustPresentedServerCertificate(certificate)
                    presentedServerCertificate = nil
                }
            )
        }
        .sheet(isPresented: $isConfirmingDeletion) {
            OpaqueConfirmationView(
                title: "Quelle wirklich entfernen?",
                message: model.deletionMessage,
                confirmTitle: "Quelle entfernen",
                cancelTitle: "Abbrechen",
                confirm: {
                    isConfirmingDeletion = false
                    Task { await model.deleteSource() }
                },
                cancel: { isConfirmingDeletion = false }
            )
        }
        .sheet(isPresented: $isConfirmingDiscard) {
            OpaqueConfirmationView(
                title: "Ungespeicherte Änderungen verwerfen?",
                message: AppLocalization.string(
                    "Die Änderungen an der aktuellen Quelle wurden noch nicht gespeichert.",
                    locale: locale
                ),
                confirmTitle: "Änderungen verwerfen",
                cancelTitle: "Weiter bearbeiten",
                confirm: {
                    isConfirmingDiscard = false
                    performPendingNavigation()
                },
                cancel: {
                    isConfirmingDiscard = false
                    pendingNavigation = nil
                }
            )
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
                    Picker("Typ", selection: $model.selectedProviderID) {
                        ForEach(model.providers, id: \.id) { provider in
                            Text(provider.displayName).tag(provider.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("source-provider-picker")
                    TextField(
                        "Name",
                        text: $model.name,
                        prompt: Text(verbatim: model.suggestedSourceName)
                    )
                    TextField(
                        "Server",
                        text: $model.endpoint,
                        prompt: Text(verbatim: model.endpointPrompt)
                    )
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
                        SecureField("Passwort", text: $model.credentialSecret)
                            .textContentType(.password)
                        Text(
                            model.hasStoredCredentialSecret
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
                        if model.selectedProviderID == ThrukProvider.id {
                            Label {
                                Text(
                                    verbatim: AppLocalization.string(
                                        "Thruk-Schnellaktionen benötigen einen API-Schlüssel.",
                                        locale: locale
                                    )
                                )
                            } icon: {
                                Image(systemName: "info.circle")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    } else if model.authenticationChoice == .apiKey {
                        if model.apiUsernameIsRequired {
                            TextField("Benutzername", text: $model.username)
                                .textContentType(.username)
                        } else {
                            TextField("API-Benutzer (optional)", text: $model.username)
                                .textContentType(.username)
                        }
                        SecureField("API-Schlüssel", text: $model.credentialSecret)
                            .textContentType(.password)
                        Text(
                            model.hasStoredCredentialSecret
                                ? AppLocalization.string(
                                    "Leer lassen, um den vorhandenen API-Schlüssel bei unveränderten Zugangsdaten beizubehalten.",
                                    locale: locale
                                )
                                : AppLocalization.string(
                                    "Der API-Schlüssel wird ausschließlich im macOS-Schlüsselbund gespeichert.",
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

                if model.isEndpointUsingTLS {
                    Section {
                        Picker("Serververtrauen", selection: $model.serverTrustChoice) {
                            ForEach(model.serverTrustChoices) { choice in
                                Text(verbatim: choice.displayName(locale: locale)).tag(choice)
                            }
                        }

                        if model.serverTrustChoice == .system {
                            Button("Vom Server abrufen …") {
                                fetchPresentedServerCertificate()
                            }
                            .disabled(certificateFetchTask != nil)
                        } else if model.serverTrustChoice == .customCertificate {
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
                            Button("Vom Server abrufen …") {
                                fetchPresentedServerCertificate()
                            }
                            .disabled(certificateFetchTask != nil)
                        } else if model.serverTrustChoice == .disabled {
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("HTTPS bleibt aktiv. Nur die Zertifikatsprüfung ist deaktiviert.")
                                    Text("Unsicher. Identität und Serverdaten können abgefangen oder verändert werden. Diese Ausnahme gilt nur für diese Quelle.")
                                }
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

                Section {
                    LabeledContent {
                        ConnectionEndpointStatusView(state: model.selectedConnectionStatus.api)
                    } label: {
                        Text(verbatim: "API")
                    }
                    LabeledContent {
                        ConnectionEndpointStatusView(state: model.selectedConnectionStatus.web)
                    } label: {
                        Text(verbatim: "Web")
                    }
                    LabeledContent {
                        TextField(
                            text: $model.webURL,
                            prompt: Text(verbatim: model.automaticWebBaseURL?.absoluteString ?? "https://monitoring.example/web")
                        ) {
                            Text("Web-URL")
                        }
                        .labelsHidden()
                        .textContentType(.URL)
                    } label: {
                        Text("Web-URL")
                    }

                    if AppDistribution.supportsSSHTunnels {
                        SSHSettingsDisclosureRow(isExpanded: $isShowingSSHOverrides)
                    }
                    if AppDistribution.supportsSSHTunnels && isShowingSSHOverrides {
                        TextField(
                            "Bastion",
                            text: $model.sshTunnelHost,
                            prompt: Text(verbatim: automaticSSHHost)
                        )
                        TextField(
                            "Benutzername",
                            text: $model.sshTunnelUsername,
                            prompt: Text(verbatim: "OpenSSH")
                        )
                            .textContentType(.username)
                        TextField("SSH-Port", text: $model.sshTunnelPort, prompt: Text(verbatim: "22"))
                        LabeledContent("SSH-Schlüssel") {
                            HStack(spacing: 8) {
                                if model.sshTunnelIdentityFilePath.isEmpty {
                                    Text(verbatim: "~/.ssh/config / SSH agent")
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                } else {
                                    Text(URL(fileURLWithPath: model.sshTunnelIdentityFilePath).lastPathComponent)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Button {
                                        model.sshTunnelIdentityFilePath = ""
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .frame(width: 24, height: 24)
                                            .pointerHoverFeedback()
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Ausgewählten Schlüssel entfernen")
                                }
                                Button("Auswählen …") {
                                    chooseSSHIdentity()
                                }
                            }
                        }
                        TextField(
                            "Bevorzugter lokaler Port",
                            text: $model.sshTunnelPreferredLocalPort
                        )
                    }
                } header: {
                    Text(verbatim: "API / Web")
                } footer: {
                    if !AppDistribution.supportsSSHTunnels {
                        Text("Die App-Store-Ausgabe verbindet sich direkt mit der Monitoring-Quelle. SSH-Tunnel sowie SSH- und RDP-Startaktionen stehen in der direkten GitHub-Ausgabe bereit.")
                    }
                }

                if AppDistribution.supportsRemoteAccess {
                    Section {
                        Toggle("SSH für überwachten Host", isOn: $model.sshActionEnabled)
                        if model.sshActionEnabled {
                            TextField(
                                "SSH-Benutzername",
                                text: $model.sshUsername,
                                prompt: Text(verbatim: "OpenSSH")
                            )
                            .textContentType(.username)
                            PortNumberField("SSH-Port", value: $model.sshPort)
                        }

                        Toggle("RDP für überwachten Host", isOn: $model.rdpActionEnabled)
                        if model.rdpActionEnabled {
                            TextField("RDP-Benutzername", text: $model.rdpUsername)
                                .textContentType(.username)
                            PortNumberField("RDP-Port", value: $model.rdpPort)
                        }
                    } header: {
                        Text(verbatim: "SSH / RDP")
                    } footer: {
                        Text("Diese optionalen Aktionen öffnen den in einem Problem genannten Host. Sie sind nicht der SSH-Tunnel zur Icinga-Quelle.")
                    }
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
                if !model.connectionAttempts.isEmpty {
                    DisclosureGroup("Verbindungsversuche", isExpanded: $isShowingConnectionAttempts) {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(model.connectionAttempts) { attempt in
                                HStack(spacing: 8) {
                                    Text(verbatim: attempt.endpoint)
                                        .font(.caption.monospaced())
                                        .lineLimit(1)
                                        .help(attempt.endpoint)
                                    Spacer(minLength: 8)
                                    Text(verbatim: attempt.route)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(verbatim: attempt.outcome)
                                        .font(.caption.weight(.medium))
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.caption)
                }

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
            .background(Color(nsColor: .windowBackgroundColor))
            .layoutPriority(1)
        }
    }

    @ViewBuilder
    private var activityView: some View {
        switch model.activity {
        case .idle:
            EmptyView()
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

    private var automaticSSHHost: String {
        URL(string: model.endpoint.trimmingCharacters(in: .whitespacesAndNewlines))?.host
            ?? "api.example"
    }

    private func chooseSSHIdentity() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        let sshDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
        if FileManager.default.fileExists(atPath: sshDirectory.path) {
            panel.directoryURL = sshDirectory
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.sshTunnelIdentityFilePath = url.path
        }
    }

    private func fetchPresentedServerCertificate() {
        certificateFetchTask?.cancel()
        certificateFetchTask = Task {
            let certificate = await model.fetchPresentedServerCertificate()
            guard !Task.isCancelled else { return }
            presentedServerCertificate = certificate
            certificateFetchTask = nil
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

struct ConnectionEndpointStatusView: View {
    let state: IssueLightModel.ConnectionEndpointState

    @ViewBuilder
    var body: some View {
        switch state {
        case .notTested:
            Text(verbatim: "—")
                .foregroundStyle(.secondary)
        case .checking:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(Text("Verbindung wird geprüft …"))
        case .direct:
            Label("Direkt", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .ssh:
            Label("SSH", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 260, alignment: .trailing)
                .help(message)
        }
    }
}

struct SourceDraftRow: View {
    let name: String
    let providerName: String
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(.tint)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name)
                    .lineLimit(1)
                Text(verbatim: "\(providerName) · \(AppLocalization.string("Neue Quelle", locale: locale))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(Color.accentColor.opacity(0.12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("new-source-draft")
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
                        Text(verbatim: "\(model.providerName(for: source)) · \(statusLabel)")
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
            return "checkmark.circle.fill"
        case .failed:
            return "wifi.exclamationmark"
        }
    }

    private var statusColor: Color {
        switch model.sourceRefreshState(for: source.id) {
        case .notConfigured, .disabled, .refreshing:
            return .secondary
        case .current:
            return .green
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

struct SSHSettingsDisclosureRow: View {
    @Binding var isExpanded: Bool
    @State private var isHovering = false

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
                Text("Quelle über SSH erreichen")
                Spacer()
                Text("Nur als Fallback")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(.secondary.opacity(isHovering ? 0.12 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(Text("Quelle über SSH erreichen"))
        .accessibilityAddTraits(isExpanded ? .isSelected : [])
        .accessibilityIdentifier("ssh-settings-disclosure")
    }
}

struct PortNumberField: View {
    static var format: IntegerFormatStyle<Int> {
        .number.grouping(.never)
    }

    let title: LocalizedStringKey
    @Binding var value: Int

    init(_ title: LocalizedStringKey, value: Binding<Int>) {
        self.title = title
        _value = value
    }

    var body: some View {
        TextField(title, value: $value, format: Self.format)
    }
}

struct PresentedServerCertificateTrustView: View {
    let certificate: PresentedServerCertificate
    let cancel: () -> Void
    let trust: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Serverzertifikat festlegen", systemImage: "checkmark.shield")
                .font(.title2.weight(.semibold))
            Text(verbatim: certificate.subject)
                .font(.headline)
                .textSelection(.enabled)
            LabeledContent("Server", value: certificate.endpoint.absoluteString)
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: "SHA-256")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: displayFingerprint)
                    .font(.caption.monospaced())
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Text("Vergleiche den SHA-256-Fingerprint vor der Bestätigung mit einer vertrauenswürdigen Angabe deines Administrators.")
                .font(.callout.weight(.medium))
            Text("Bei einer Zertifikatserneuerung bleibt die Verbindung blockiert, bis du das neue Zertifikat hier geprüft und ausgewählt hast.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Abbrechen", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Zertifikat vertrauen", action: trust)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
        .opaqueInteractiveSurface()
        .accessibilityIdentifier("presented-server-certificate")
    }

    private var displayFingerprint: String {
        let bytes = certificate.sha256Fingerprint.split(separator: ":")
        return stride(from: 0, to: bytes.count, by: 16)
            .map { offset in
                bytes[offset..<min(offset + 16, bytes.count)].joined(separator: ":")
            }
            .joined(separator: "\n")
    }
}

struct OpaqueConfirmationView: View {
    let title: LocalizedStringKey
    let message: String
    let confirmTitle: LocalizedStringKey
    let cancelTitle: LocalizedStringKey
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: "exclamationmark.triangle")
                .font(.title2.weight(.semibold))
            Text(verbatim: message)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(cancelTitle, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, role: .destructive, action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 440)
        .opaqueInteractiveSurface()
        .accessibilityIdentifier("opaque-confirmation")
    }
}

struct SourceSidebarFooter: View {
    let addSource: () -> Void

    var body: some View {
        HStack {
            Button(action: addSource) {
                Label("Quelle hinzufügen", systemImage: "plus")
                    .frame(minHeight: 24)
            }
            .buttonStyle(.borderless)
            .help("Neue Quelle")
            .accessibilityIdentifier("add-source")
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
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
        .opaqueInteractiveSurface()
    }
}
