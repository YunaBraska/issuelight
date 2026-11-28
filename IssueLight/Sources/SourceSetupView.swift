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
    @State private var filterSource: MonitoringSource?

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
                            name: model.draftSourceName,
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
                            localized("Noch keine Quellen"),
                            systemImage: "server.rack",
                            description: Text(verbatim: localized("Füge deine erste Monitoring-Quelle hinzu."))
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
        .sheet(item: $filterSource) { source in
            SourceIssueFilterEditor(source: source, issues: model.snapshots[source.id]?.issues) {
                await model.saveIssueFilter($0, for: source.id)
            }
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
                    startConnectionTest()
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

    private var disabledTrustWarning: Text {
        Text(
            verbatim: localized(
                "Unsicher. Identität und Serverdaten können abgefangen oder verändert werden. Diese Ausnahme gilt nur für diese Quelle."
            )
        )
    }

    private func localized(_ resource: LocalizedStringResource) -> String {
        AppLocalization.string(resource, locale: locale)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle(localized("Quelle aktiv"), isOn: $model.isSourceEnabled)
                    Picker(localized("Typ"), selection: $model.selectedProviderID) {
                        ForEach(model.providers, id: \.id) { provider in
                            Text(provider.displayName).tag(provider.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("source-provider-picker")
                    TextField(
                        localized("Name"),
                        text: $model.name,
                        prompt: Text(verbatim: model.suggestedSourceName)
                    )
                    TextField(
                        localized("Server"),
                        text: $model.endpoint,
                        prompt: Text(verbatim: model.endpointPrompt)
                    )
                        .textContentType(.URL)
                    if let source = model.selectedSource {
                        Button(localized("Filter konfigurieren …")) {
                            filterSource = source
                        }
                        .accessibilityIdentifier("source-filter-settings")
                    }
                } header: {
                    if model.isCreatingSource {
                        Text(verbatim: localized("Neue Quelle"))
                    } else {
                        Text(verbatim: localized("Quelle"))
                    }
                }

                Section(localized("Authentifizierung")) {
                    Picker(localized("Methode"), selection: $model.authenticationChoice) {
                        ForEach(model.authenticationChoices) { choice in
                            Text(verbatim: choice.displayName(locale: locale)).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)

                    if model.authenticationChoice == .basic {
                        TextField(localized("Benutzername"), text: $model.username)
                            .textContentType(.username)
                        SecureField(localized("Passwort"), text: $model.credentialSecret)
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
                    } else if model.authenticationChoice == .apiKey {
                        if model.apiUsernameIsVisible {
                            if model.apiUsernameIsRequired {
                                TextField(localized("Benutzername"), text: $model.username)
                                    .textContentType(.username)
                            } else {
                                TextField(localized("API-Benutzer (optional)"), text: $model.username)
                                    .textContentType(.username)
                            }
                        }
                        SecureField(localized("API-Schlüssel"), text: $model.credentialSecret)
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
                        Picker(localized("Identität"), selection: $model.selectedIdentityID) {
                            Text(verbatim: localized("Zertifikat auswählen …")).tag("")
                            ForEach(model.identities) { identity in
                                Text(identity.displayName).tag(identity.id)
                            }
                        }
                        Button(localized("PKCS#12 importieren …")) {
                            isChoosingIdentity = true
                        }
                        .buttonStyle(.bordered)
                        .pointerHoverFeedback(cornerRadius: 7)
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

                    if model.selectedProviderOffersActions,
                       !model.selectedAuthenticationSupportsActions {
                        Label(
                            "Schnellaktionen sind mit dieser Authentifizierung nicht verfügbar.",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if model.isEndpointUsingTLS {
                    Section {
                        LabeledContent(localized("Serververtrauen")) {
                            HStack(spacing: 8) {
                                Picker("", selection: $model.serverTrustChoice) {
                                    ForEach(model.serverTrustChoices) { choice in
                                        Text(verbatim: choice.displayName(locale: locale)).tag(choice)
                                    }
                                }
                                .labelsHidden()

                                if model.serverTrustChoice == .disabled {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                        .help(disabledTrustWarning)
                                        .accessibilityLabel(Text(verbatim: localized("Zertifikatsprüfung aus")))
                                        .accessibilityHint(disabledTrustWarning)
                                }

                                if model.canReviewBlockedServerCertificate {
                                    Button(localized("Zertifikat vertrauen")) {
                                        fetchPresentedServerCertificate()
                                    }
                                    .buttonStyle(.bordered)
                                    .pointerHoverFeedback(cornerRadius: 7)
                                    .disabled(certificateFetchTask != nil)
                                }
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
                                Label(
                                    localized("Importiere genau ein CA-Zertifikat."),
                                    systemImage: "exclamationmark.circle"
                                )
                                    .foregroundStyle(.orange)
                            }
                            Button(
                                model.selectedServerCertificate == nil
                                    ? AppLocalization.string("CA-Zertifikat importieren …", locale: locale)
                                    : AppLocalization.string("CA-Zertifikat ersetzen …", locale: locale)
                            ) {
                                isChoosingServerCertificate = true
                            }
                            .buttonStyle(.bordered)
                            .pointerHoverFeedback(cornerRadius: 7)
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
                                Label(
                                    localized("Wähle genau ein Serverzertifikat aus."),
                                    systemImage: "exclamationmark.circle"
                                )
                                    .foregroundStyle(.orange)
                            } else {
                                Text("SHA-256: \(model.pinnedServerCertificateSHA256)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Text(
                                    verbatim: localized(
                                        "Bei einer Zertifikatserneuerung bleibt die Verbindung blockiert, bis du das neue Zertifikat hier geprüft und ausgewählt hast."
                                    )
                                )
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
                            .buttonStyle(.bordered)
                            .pointerHoverFeedback(cornerRadius: 7)
                            .fileImporter(
                                isPresented: $isChoosingPinnedServerCertificate,
                                allowedContentTypes: certificateContentTypes,
                                allowsMultipleSelection: false
                            ) { result in
                                if case .success(let urls) = result, let url = urls.first {
                                    _ = model.pinServerCertificate(at: url)
                                }
                            }
                        }
                    } header: {
                        Text("TLS")
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
                        SSHTunnelSettingsView(
                            host: $model.sshTunnelHost,
                            username: $model.sshTunnelUsername,
                            port: $model.sshTunnelPort,
                            identityFilePath: $model.sshTunnelIdentityFilePath,
                            preferredLocalPort: $model.sshTunnelPreferredLocalPort,
                            automaticHost: model.automaticSSHTunnelHost,
                            chooseIdentity: chooseSSHIdentity
                        )
                    }
                } header: {
                    Text(verbatim: "API / Web")
                } footer: {
                    if !AppDistribution.supportsSSHTunnels {
                        Text(
                            verbatim: localized(
                                "Die App-Store-Ausgabe verbindet sich direkt mit der Monitoring-Quelle. SSH-Tunnel sowie SSH- und RDP-Startaktionen stehen in der direkten GitHub-Ausgabe bereit."
                            )
                        )
                    }
                }

                if AppDistribution.supportsRemoteAccess {
                    Section {
                        Toggle(localized("SSH für überwachten Host"), isOn: $model.sshActionEnabled)
                        if model.sshActionEnabled {
                            TextField(
                                localized("SSH-Benutzername"),
                                text: $model.sshUsername,
                                prompt: Text(verbatim: "OpenSSH")
                            )
                            .textContentType(.username)
                            PortNumberField(localized("SSH-Port"), value: $model.sshPort)
                        }

                        Toggle(localized("RDP für überwachten Host"), isOn: $model.rdpActionEnabled)
                        if model.rdpActionEnabled {
                            TextField(localized("RDP-Benutzername"), text: $model.rdpUsername)
                                .textContentType(.username)
                            PortNumberField(localized("RDP-Port"), value: $model.rdpPort)
                        }
                    } header: {
                        Text(verbatim: "SSH / RDP")
                    } footer: {
                        Text(
                            verbatim: localized(
                                "Diese optionalen Aktionen öffnen den in einem Problem genannten Host. Sie sind nicht der SSH-Tunnel zur Monitoring-Quelle."
                            )
                        )
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
                    DisclosureGroup(
                        localized("Verbindungsversuche"),
                        isExpanded: $isShowingConnectionAttempts
                    ) {
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
                        Button(localized("Quelle entfernen"), role: .destructive) {
                            isConfirmingDeletion = true
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .pointerHoverFeedback(cornerRadius: 7)
                        .disabled(isWorking)
                    }
                    Spacer()
                    if model.isTestingConnection {
                        Button(localized("Abbrechen"), role: .cancel) {
                            connectionTask?.cancel()
                        }
                        .buttonStyle(.bordered)
                        .pointerHoverFeedback(cornerRadius: 7)
                    } else {
                        Button(localized("Verbindung testen")) {
                            startConnectionTest()
                        }
                        .buttonStyle(.bordered)
                        .pointerHoverFeedback(cornerRadius: 7)
                        .disabled(isWorking)
                    }

                    Button(localized("Speichern")) {
                        Task { await model.save() }
                    }
                    .buttonStyle(.borderedProminent)
                    .pointerHoverFeedback(cornerRadius: 7)
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

    private func startConnectionTest() {
        connectionTask?.cancel()
        connectionTask = Task { await model.testConnection() }
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
        case .serverTrustBlocked(let message), .failed(let message):
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
            let count = model.visibleIssues(for: source).count(where: \.requiresAttention)
            return IssueCountText.sourceStatus(count, locale: locale)
        case .failed(let message):
            return AppLocalization.string("Aktualisierung fehlgeschlagen, \(message)", locale: locale)
        }
    }
}

struct SourceIssueFilterEditor: View {
    private struct Rule: Identifiable {
        let id = UUID()
        var pattern: IssueExclusionPattern
    }

    let source: MonitoringSource
    let issues: [MonitoringIssue]?
    let save: (SourceIssueFilter) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var draft: SourceIssueFilter
    @State private var rules: [Rule]
    @State private var isSaving = false
    @State private var saveFailed = false

    init(
        source: MonitoringSource,
        issues: [MonitoringIssue]? = nil,
        save: @escaping (SourceIssueFilter) async -> Bool
    ) {
        self.source = source
        self.issues = issues
        self.save = save
        let filter = source.issueFilter ?? SourceIssueFilter()
        _draft = State(initialValue: filter)
        _rules = State(initialValue: filter.patterns.map { Rule(pattern: $0) })
    }

    var body: some View {
        let filter = editedFilter
        let validRules = filter.patterns.allSatisfy(\.hasValidSyntax)
        let normalized = filter.normalized
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: localized("Filter")).font(.headline)
                    Text(source.name).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(localized("Ausstehende Prüfungen anzeigen"), isOn: $draft.showPendingChecks)
                    .toggleStyle(.checkbox)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(isSaving)
            }
            .padding()

            Form {
                Section {
                    HStack(alignment: .top, spacing: 20) {
                        conditions(localized("Hosts"), isHost: true, selection: $draft.hostConditions)
                        Divider()
                        conditions(localized("Services"), isHost: false, selection: $draft.serviceConditions)
                    }
                    Toggle(localized("Services bei Host-Wartung"), isOn: $draft.hideServicesOfHostsInDowntime)
                } header: {
                    Text(verbatim: localized("Probleme ausblenden"))
                }
                .toggleStyle(.checkbox)

                Section {
                    if !rules.isEmpty {
                        ruleTable
                    }
                    Button {
                        rules.append(Rule(pattern: IssueExclusionPattern()))
                    } label: {
                        Label(localized("Regel hinzufügen"), systemImage: "plus")
                    }
                    .accessibilityIdentifier("add-source-filter-rule")
                } header: {
                    Text(verbatim: localized("Ausschlussregeln"))
                }
            }
            .formStyle(.grouped)
            .disabled(isSaving)

            Divider()
            HStack {
                if !validRules {
                    Text(verbatim: localized("Ungültiger regulärer Ausdruck"))
                        .foregroundStyle(.red)
                } else if saveFailed {
                    Text(verbatim: localized("Filter konnten nicht gespeichert werden."))
                        .foregroundStyle(.red)
                } else if let issues {
                    let eligible = draft.showPendingChecks ? issues : issues.filter { $0.severity != .pending }
                    let hidden = eligible.count - (normalized?.retainingVisibleIssues(eligible).count ?? eligible.count)
                    Text(verbatim: localized("Ausgeblendet: \(hidden)"))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(localized("Abbrechen")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(localized("Speichern")) {
                    isSaving = true
                    Task {
                        if await save(filter) {
                            dismiss()
                        } else {
                            saveFailed = true
                        }
                        isSaving = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!validRules || normalized == source.issueFilter)
            }
            .disabled(isSaving)
            .padding()
        }
        .frame(width: 620, height: 590)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(isSaving)
    }

    private var ruleTable: some View {
        let statusWidth: CGFloat = 124
        let removeWidth: CGFloat = 34
        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(verbatim: localized("Host")).frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: localized("Service")).frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: localized("Status")).frame(width: statusWidth, alignment: .leading)
                Color.clear.frame(width: removeWidth, height: 1)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)

            ForEach($rules) { $rule in
                let canMatchServices = rule.pattern.states?.contains(where: \.appliesToServices) ?? true
                HStack(spacing: 8) {
                    TextField(localized("Host"), text: $rule.pattern.host, prompt: Text(verbatim: localized("Alle Hosts")))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                    TextField(
                        localized("Service"), text: $rule.pattern.service,
                        prompt: Text(verbatim: canMatchServices ? localized("Alle Services") : "")
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    ruleOptions($rule.pattern)
                        .frame(width: statusWidth, alignment: .leading)
                    Button {
                        let ruleID = rule.id
                        rules.removeAll { $0.id == ruleID }
                    } label: {
                        Image(systemName: "minus")
                            .frame(width: 14, height: 18)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(localized("Regel entfernen"))
                    .help(localized("Regel entfernen"))
                    .frame(width: removeWidth)
                }
            }
        }
    }

    private func conditions(
        _ title: String,
        isHost: Bool,
        selection: Binding<Set<IssueFilterCondition>>
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(verbatim: title).font(.subheadline.weight(.semibold))
            ForEach(IssueFilterCondition.allCases, id: \.self) { condition in
                let label = conditionTitle(condition)
                Toggle(label, isOn: Binding(
                    get: { selection.wrappedValue.contains(condition) },
                    set: { enabled in
                        if enabled {
                            selection.wrappedValue.insert(condition)
                        } else {
                            selection.wrappedValue.remove(condition)
                        }
                    }
                ))
                .accessibilityLabel("\(title): \(label)")
                .accessibilityIdentifier("\(isHost ? "host" : "service")-filter-\(condition.rawValue)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func conditionTitle(_ condition: IssueFilterCondition) -> String {
        switch condition {
        case .downtime: localized("Wartungszeit")
        case .acknowledged: localized("Quittiert")
        case .flapping: localized("Flapping")
        case .notificationsDisabled: localized("Benachrichtigungen deaktiviert")
        case .softState: localized("Vorläufiger Zustand")
        }
    }

    private func ruleOptions(_ rule: Binding<IssueExclusionPattern>) -> some View {
        let allStates = Set(IssueFilterState.allCases)
        let applicableStates = rule.wrappedValue.applicableStates
        let selectedStates = rule.wrappedValue.states.map { states in
            applicableStates.filter(states.contains)
        }
        let statusTitle = selectedStates.map { states in
            states.isEmpty
                ? localized("Keine Zustände")
                : states.map(\.abbreviation).joined(separator: ", ")
        } ?? localized("Alle Zustände")
        let statusDescription = selectedStates.flatMap { states in
            states.isEmpty ? nil : states.map { $0.localizedName(locale: locale) }.joined(separator: ", ")
        } ?? statusTitle
        return Menu {
            Toggle(localized("Regulärer Ausdruck"), isOn: Binding(
                get: { rule.wrappedValue.usesRegularExpressions == true },
                set: { rule.wrappedValue.usesRegularExpressions = $0 ? true : nil }
            ))
            Divider()
            Button(localized("Alle Zustände")) { rule.wrappedValue.states = nil }
            ForEach(applicableStates, id: \.self) { state in
                Toggle(state.localizedName(locale: locale), isOn: Binding(
                    get: { rule.wrappedValue.states?.contains(state) ?? true },
                    set: { enabled in
                        var selection = rule.wrappedValue.states ?? allStates
                        if enabled { selection.insert(state) } else { selection.remove(state) }
                        rule.wrappedValue.states = selection == allStates ? nil : selection
                    }
                ))
            }
        } label: {
            HStack(spacing: 4) {
                if rule.wrappedValue.usesRegularExpressions == true {
                    Text(verbatim: ".*").monospaced().foregroundStyle(.secondary)
                }
                Text(verbatim: statusTitle)
                    .lineLimit(1)
            }
        }
        .fixedSize()
        .accessibilityLabel(localized("Status"))
        .accessibilityValue(statusDescription)
        .help(statusDescription)
        .accessibilityIdentifier("source-filter-rule-options")
    }

    private var editedFilter: SourceIssueFilter {
        var filter = draft
        filter.patterns = rules.map(\.pattern)
        return filter
    }

    private func localized(_ resource: LocalizedStringResource) -> String {
        AppLocalization.string(resource, locale: locale)
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

struct SSHTunnelSettingsView: View {
    @Binding var host: String
    @Binding var username: String
    @Binding var port: String
    @Binding var identityFilePath: String
    @Binding var preferredLocalPort: String
    let automaticHost: String
    let chooseIdentity: () -> Void

    var body: some View {
        Group {
            ViewThatFits(in: .horizontal) {
                LabeledContent("Server") {
                    HStack(spacing: 10) {
                        hostField
                            .frame(minWidth: 150)
                        Divider()
                            .frame(height: 18)
                        Text("SSH-Port")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        portField
                            .frame(width: 64)
                    }
                }
                VStack(spacing: 10) {
                    LabeledContent("Server") {
                        hostField
                    }
                    LabeledContent("SSH-Port") {
                        portField
                    }
                }
            }

            LabeledContent("Benutzername") {
                TextField(
                    "Benutzername",
                    text: $username,
                    prompt: Text(verbatim: "~/.ssh/config")
                )
                .labelsHidden()
                .textContentType(.username)
            }

            LabeledContent("SSH-Schlüssel") {
                HStack(spacing: 8) {
                    Button(action: chooseIdentity) {
                        HStack(spacing: 7) {
                            Image(systemName: "key")
                                .accessibilityHidden(true)
                            Text(verbatim: identityLabel)
                                .foregroundStyle(identityFilePath.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text("Auswählen …")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .pointerHoverFeedback(cornerRadius: 7)
                    .help(identityFilePath.isEmpty ? "~/.ssh/config / SSH agent" : identityFilePath)

                    if !identityFilePath.isEmpty {
                        Button {
                            identityFilePath = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .frame(width: 24, height: 24)
                                .pointerHoverFeedback()
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .help("Ausgewählten Schlüssel entfernen")
                    }
                }
            }

            LabeledContent("Bevorzugter lokaler Port") {
                TextField(
                    "Bevorzugter lokaler Port",
                    text: $preferredLocalPort,
                    prompt: Text(verbatim: "—")
                )
                .labelsHidden()
                .frame(width: 90)
            }
        }
    }

    private var hostField: some View {
        TextField(
            "Server",
            text: $host,
            prompt: Text(verbatim: automaticHost)
        )
        .labelsHidden()
        .textContentType(.URL)
    }

    private var portField: some View {
        TextField(
            "SSH-Port",
            text: $port,
            prompt: Text(verbatim: "22")
        )
        .labelsHidden()
    }

    private var identityLabel: String {
        guard !identityFilePath.isEmpty else { return "~/.ssh/config · SSH agent" }
        return URL(fileURLWithPath: identityFilePath).lastPathComponent
    }
}

struct PortNumberField: View {
    static var format: IntegerFormatStyle<Int> {
        .number.grouping(.never)
    }

    let title: String
    @Binding var value: Int

    init(_ title: String, value: Binding<Int>) {
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
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Serverzertifikat festlegen", systemImage: "checkmark.shield")
                .font(.title2.weight(.semibold))
            Text(verbatim: certificate.subject)
                .font(.headline)
                .textSelection(.enabled)
            LabeledContent("Server", value: certificate.endpoint.absoluteString)
                .textSelection(.enabled)
            if let issuer = certificate.issuer {
                LabeledContent("Aussteller", value: issuer)
                    .textSelection(.enabled)
            }
            if let validity {
                LabeledContent("Gültigkeit", value: validity)
                    .textSelection(.enabled)
            }
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
                    .buttonStyle(.bordered)
                    .pointerHoverFeedback(cornerRadius: 7)
                    .keyboardShortcut(.cancelAction)
                Button("Zertifikat vertrauen", action: trust)
                    .buttonStyle(.borderedProminent)
                    .pointerHoverFeedback(cornerRadius: 7)
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

    private var validity: String? {
        guard let validFrom = certificate.validFrom,
              let validUntil = certificate.validUntil else {
            return nil
        }
        let format = Date.FormatStyle(
            date: .abbreviated,
            time: .shortened,
            locale: locale
        )
        return "\(validFrom.formatted(format)) – \(validUntil.formatted(format))"
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
                    .buttonStyle(.bordered)
                    .pointerHoverFeedback(cornerRadius: 7)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, role: .destructive, action: confirm)
                    .buttonStyle(.bordered)
                    .pointerHoverFeedback(cornerRadius: 7)
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
    @Environment(\.locale) private var locale

    var body: some View {
        HStack {
            Button(action: addSource) {
                Label(
                    AppLocalization.string("Quelle hinzufügen", locale: locale),
                    systemImage: "plus"
                )
                    .frame(minHeight: 24)
                    .contentShape(Rectangle())
                    .pointerHoverFeedback()
            }
            .buttonStyle(.borderless)
            .help(AppLocalization.string("Neue Quelle", locale: locale))
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
                    .buttonStyle(.bordered)
                    .pointerHoverFeedback(cornerRadius: 7)
                Button("Importieren") {
                    Task {
                        if await model.importIdentity(at: fileURL, password: password) {
                            isPresented = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .pointerHoverFeedback(cornerRadius: 7)
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .opaqueInteractiveSurface()
    }
}
