import Foundation
import IssueLightCore
import Security

@MainActor
final class IssueLightModel: ObservableObject {
    enum AuthenticationChoice: String, CaseIterable, Identifiable {
        case basic
        case apiKey
        case clientCertificate

        var id: String { rawValue }

        func displayName(locale: Locale) -> String {
            switch self {
            case .basic:
                return AppLocalization.string("Benutzername & Passwort", locale: locale)
            case .apiKey:
                return AppLocalization.string("API-Schlüssel", locale: locale)
            case .clientCertificate:
                return AppLocalization.string("Client-Zertifikat", locale: locale)
            }
        }

        var method: AuthenticationMethod {
            switch self {
            case .basic:
                return .basic
            case .apiKey:
                return .apiKey
            case .clientCertificate:
                return .clientCertificate
            }
        }
    }

    enum ServerTrustChoice: String, CaseIterable, Identifiable {
        case system
        case customCertificate
        case pinnedCertificate
        case disabled

        var id: String { rawValue }

        func displayName(locale: Locale) -> String {
            switch self {
            case .system:
                return AppLocalization.string("macOS-Systemvertrauen", locale: locale)
            case .customCertificate:
                return AppLocalization.string("Eigene CA", locale: locale)
            case .pinnedCertificate:
                return AppLocalization.string("Serverzertifikat festlegen", locale: locale)
            case .disabled:
                return AppLocalization.string("Zertifikatsprüfung aus", locale: locale)
            }
        }

        var method: ServerTrustMethod {
            switch self {
            case .system:
                return .system
            case .customCertificate:
                return .customCertificate
            case .pinnedCertificate:
                return .pinnedCertificate
            case .disabled:
                return .disabled
            }
        }
    }

    enum Activity: Equatable {
        case idle
        case working(String)
        case success(String)
        case failure(String)
    }

    enum RefreshState: Equatable {
        case notConfigured
        case disabled
        case refreshing
        case current
        case failed(String)
    }

    struct SourceFailure: Identifiable {
        let source: MonitoringSource
        let message: String

        var id: UUID { source.id }
    }

    struct ActionError: Equatable {
        let message: String
    }

    enum ConnectionEndpointState: Equatable {
        case notTested
        case checking
        case direct
        case ssh
        case serverTrustBlocked(String)
        case failed(String)
    }

    struct ConnectionStatus: Equatable {
        var api: ConnectionEndpointState = .notTested
        var web: ConnectionEndpointState = .notTested
    }

    struct ConnectionAttempt: Equatable, Identifiable {
        let endpoint: String
        let route: String
        let outcome: String

        var id: String { "\(endpoint)|\(route)|\(outcome)" }
    }

    @Published var name = ""
    @Published var endpoint = "" {
        didSet {
            guard endpoint != oldValue else { return }
            if !isEndpointUsingTLS {
                serverTrustChoice = .system
                selectedServerCertificate = nil
                pinnedServerCertificateSHA256 = ""
            }
            guard var source = selectedSource,
                  let newEndpoint = URL(
                      string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                  ) else {
                return
            }
            if let oldEndpoint = URL(
                string: oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
            ) {
                source.endpoint = oldEndpoint
            }
            guard source.updateEndpoint(newEndpoint) else {
                return
            }
            serverTrustChoice = .system
            selectedServerCertificate = nil
            pinnedServerCertificateSHA256 = ""
        }
    }
    @Published var isSourceEnabled = true
    @Published var selectedProviderID: ProviderID {
        didSet {
            guard selectedProviderID != oldValue else { return }
            synchronizeProviderCapabilities()
        }
    }
    @Published var authenticationChoice = AuthenticationChoice.basic
    @Published var username = ""
    @Published var credentialSecret = ""
    @Published var selectedIdentityID = ""
    @Published var identities: [ClientIdentityDescriptor] = []
    @Published private(set) var identityLoadError: String?
    @Published private(set) var hasStoredCredentialSecret = false
    @Published var serverTrustChoice = ServerTrustChoice.system
    @Published private(set) var selectedServerCertificate: ServerCertificateDescriptor?
    @Published private(set) var pinnedServerCertificateSHA256 = ""
    @Published var webURL = ""
    @Published var sshTunnelHost = ""
    @Published var sshTunnelUsername = ""
    @Published var sshTunnelPort = ""
    @Published var sshTunnelIdentityFilePath = ""
    @Published var sshTunnelPreferredLocalPort = ""
    @Published var sshActionEnabled = false
    @Published var sshUsername = ""
    @Published var sshPort = 22
    @Published var rdpActionEnabled = false
    @Published var rdpUsername = ""
    @Published var rdpPort = 3_389
    @Published private(set) var activity = Activity.idle
    @Published private(set) var isTestingConnection = false
    @Published private(set) var sources: [MonitoringSource] = []
    @Published private(set) var hasLoadedSources = false
    @Published private(set) var selectedSourceID: UUID?
    @Published private(set) var snapshots: [UUID: MonitoringSnapshot] = [:]
    @Published private(set) var refreshStates: [UUID: RefreshState] = [:]
    @Published private(set) var activeActionIssueIDs: Set<String> = []
    @Published private(set) var actionError: ActionError?
    @Published private(set) var connectionStatuses: [UUID: ConnectionStatus] = [:]
    @Published private(set) var connectionAttempts: [ConnectionAttempt] = []

    private var sourceID = UUID()
    private let sourceStore: SourceStore?
    private let providerRegistry: ProviderRegistry
    private let passwordVault: KeychainPasswordVault
    private let identityCatalog: KeychainIdentityCatalog
    private let certificateCatalog: KeychainServerCertificateCatalog
    private let accessResolver: ProviderAccessResolver
    private let connectionCoordinator: AutomaticConnectionCoordinator
    private let presentedServerCertificateFetcher: (
        URL,
        ProviderSOCKSProxy?
    ) async -> PresentedServerCertificateResult
    private var hasStarted = false
    private var refreshLoopTask: Task<Void, Never>?
    private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    private var connectionTestID: UUID?
    private var connectionStatusSources: [UUID: MonitoringSource] = [:]
    private var localizationLocale: Locale

    var hasConfiguredSource: Bool {
        !sources.isEmpty
    }

    var hasEnabledSource: Bool {
        sources.contains(where: \.isEnabled)
    }

    var selectedSource: MonitoringSource? {
        guard let selectedSourceID else { return nil }
        return sources.first(where: { $0.id == selectedSourceID })
    }

    var selectedConnectionStatus: ConnectionStatus {
        connectionStatuses[sourceID] ?? ConnectionStatus()
    }

    var isCreatingSource: Bool {
        selectedSourceID == nil
    }

    var hasUnsavedChanges: Bool {
        if !credentialSecret.isEmpty { return true }
        guard let selectedSource else {
            return !name.isEmpty
                || !endpoint.isEmpty
                || !username.isEmpty
                || !selectedIdentityID.isEmpty
                || !pinnedServerCertificateSHA256.isEmpty
                || !isSourceEnabled
                || hasNavigationInput
        }

        let authentication: AuthenticationConfiguration
        switch authenticationChoice {
        case .basic:
            authentication = .basic(username: username)
        case .apiKey:
            authentication = .apiKey(username: username)
        case .clientCertificate:
            authentication = .clientCertificate(identityID: selectedIdentityID)
        }
        let serverTrust: ServerTrustConfiguration
        switch serverTrustChoice {
        case .system:
            serverTrust = .system
        case .customCertificate:
            serverTrust = .customCertificate(certificateID: selectedServerCertificate?.id ?? "")
        case .pinnedCertificate:
            serverTrust = .pinnedCertificate(sha256: pinnedServerCertificateSHA256)
        case .disabled:
            serverTrust = .disabled
        }
        return name != selectedSource.name
            || endpoint != selectedSource.editableEndpoint
            || isSourceEnabled != selectedSource.isEnabled
            || selectedProviderID != selectedSource.providerID
            || authentication != selectedSource.authentication
            || serverTrust != selectedSource.serverTrust
            || webURL != (selectedSource.web?.editableBaseURL ?? "")
            || sshTunnelHost != ((selectedSource.sshTunnel ?? selectedSource.web?.automaticSSHTunnel)?.bastionHost ?? "")
            || sshTunnelUsername != ((selectedSource.sshTunnel ?? selectedSource.web?.automaticSSHTunnel)?.username ?? "")
            || sshTunnelPort != (
                ((selectedSource.sshTunnel ?? selectedSource.web?.automaticSSHTunnel)?.port).map(String.init) ?? ""
            )
            || sshTunnelIdentityFilePath != ((selectedSource.sshTunnel ?? selectedSource.web?.automaticSSHTunnel)?.identityFilePath ?? "")
            || sshTunnelPreferredLocalPort != (
                (selectedSource.sshTunnel ?? selectedSource.web?.automaticSSHTunnel)?
                    .preferredLocalPort.map(String.init) ?? ""
            )
            || sshActionEnabled != (selectedSource.remoteAccess?.ssh != nil)
            || sshUsername != (selectedSource.remoteAccess?.ssh?.username ?? "")
            || sshPort != (selectedSource.remoteAccess?.ssh?.port ?? 22)
            || rdpActionEnabled != (selectedSource.remoteAccess?.rdp != nil)
            || rdpUsername != (selectedSource.remoteAccess?.rdp?.username ?? "")
            || rdpPort != (selectedSource.remoteAccess?.rdp?.port ?? 3_389)
    }

    var providers: [ProviderDescriptor] {
        providerRegistry.descriptors
    }

    var providerDisplayName: String {
        providerRegistry.provider(for: selectedProviderID)?.descriptor.displayName
            ?? selectedProviderID.rawValue
    }

    var endpointPrompt: String {
        providerRegistry.provider(for: selectedProviderID)?.descriptor.endpointExample ?? ""
    }

    var automaticSSHTunnelHost: String {
        let hint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let provider = providerRegistry.provider(for: selectedProviderID) else {
            return ""
        }
        return provider.endpointCandidates(from: hint.isEmpty ? endpointPrompt : hint)
            .compactMap(\.host)
            .first ?? ""
    }

    var suggestedSourceName: String {
        SourceNameSuggestion.name(
            rawEndpoint: endpoint,
            providerName: providerDisplayName,
            sourceID: sourceID
        )
    }

    var draftSourceName: String {
        let enteredName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return enteredName.isEmpty ? suggestedSourceName : enteredName
    }

    var isEndpointUsingTLS: Bool {
        if let provider = providerRegistry.provider(for: selectedProviderID),
           let candidate = provider.endpointCandidates(from: endpoint).first {
            return candidate.scheme?.lowercased() == "https"
        }
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return true }
        let candidate = value.contains("://") ? value : "https://\(value)"
        return URLComponents(string: candidate)?.scheme?.lowercased() == "https"
    }

    var canReviewBlockedServerCertificate: Bool {
        guard isEndpointUsingTLS,
              serverTrustChoice != .disabled,
              case .serverTrustBlocked = selectedConnectionStatus.api,
              let testedSource = connectionStatusSources[sourceID],
              testedSource.providerID == selectedProviderID,
              let provider = providerRegistry.provider(for: selectedProviderID) else {
            return false
        }
        return provider.endpointCandidates(from: endpoint).contains(testedSource.endpoint)
    }

    var authenticationChoices: [AuthenticationChoice] {
        guard let methods = providerRegistry
            .provider(for: selectedProviderID)?
            .descriptor.capabilities.authenticationMethods else {
            return []
        }
        return AuthenticationChoice.allCases.filter { methods.contains($0.method) }
    }

    var apiUsernameIsRequired: Bool {
        providerRegistry.provider(for: selectedProviderID)?
            .descriptor.capabilities.apiKeyUsernameRequirement == .required
    }

    var apiUsernameIsVisible: Bool {
        guard let requirement = providerRegistry.provider(for: selectedProviderID)?
            .descriptor.capabilities.apiKeyUsernameRequirement else {
            return false
        }
        return requirement != .hidden
    }

    var selectedProviderOffersActions: Bool {
        providerRegistry.provider(for: selectedProviderID)?
            .descriptor.capabilities.actions.isEmpty == false
    }

    var selectedAuthenticationSupportsActions: Bool {
        providerRegistry.provider(for: selectedProviderID)?
            .descriptor.capabilities.actionAuthenticationMethods
            .contains(authenticationChoice.method) == true
    }

    var serverTrustChoices: [ServerTrustChoice] {
        guard let methods = providerRegistry
            .provider(for: selectedProviderID)?
            .descriptor.capabilities.serverTrustMethods else {
            return []
        }
        return ServerTrustChoice.allCases.filter { methods.contains($0.method) }
    }

    func supportedActions(for issue: MonitoringIssue) -> Set<MonitoringActionKind> {
        guard let source = sources.first(where: { $0.id == issue.sourceID }),
              let provider = providerRegistry.provider(for: source.providerID) else { return [] }
        return provider.supportedActions(for: source)
    }

    func webTarget(for issue: MonitoringIssue) -> IssueWebTarget? {
        guard let source = sources.first(where: { $0.id == issue.sourceID }),
              let provider = providerRegistry.provider(for: source.providerID),
              let url = provider.webURL(for: issue, from: source) else {
            return nil
        }
        return webTarget(sourceID: source.id, url: url)
    }

    func webTarget(sourceID: UUID, url: URL) -> IssueWebTarget? {
        guard let source = sources.first(where: { $0.id == sourceID }) else { return nil }
        return IssueWebTarget(
            sourceID: source.id,
            url: url,
            automaticSSHTunnel: AppDistribution.supportsSSHTunnels
                ? resolvedSSHTunnelConfiguration(for: source)
                : nil
        )
    }

    var automaticWebBaseURL: URL? {
        guard let endpoint = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let provider = providerRegistry.provider(for: selectedProviderID) else {
            return nil
        }
        var source = selectedSource ?? MonitoringSource(
            name: name,
            providerID: selectedProviderID,
            endpoint: endpoint,
            authentication: .basic(username: username)
        )
        source.name = name
        source.providerID = selectedProviderID
        _ = source.updateEndpoint(endpoint)
        return provider.defaultWebBaseURL(for: source)
    }

    func sshURL(for issue: MonitoringIssue) -> URL? {
        guard AppDistribution.supportsRemoteAccess,
              let source = sources.first(where: { $0.id == issue.sourceID }),
              let configuration = source.remoteAccess?.ssh else {
            return nil
        }
        return IssueNavigationURL.ssh(for: issue, configuration: configuration)
    }

    func rdpURL(for issue: MonitoringIssue) -> URL? {
        guard AppDistribution.supportsRemoteAccess,
              let source = sources.first(where: { $0.id == issue.sourceID }),
              let configuration = source.remoteAccess?.rdp else {
            return nil
        }
        return IssueNavigationURL.rdp(for: issue, configuration: configuration)
    }

    func reportMissingWebConfiguration() {
        actionError = ActionError(
            message: localized("Konfiguriere zuerst die Web-URL dieser Quelle.")
        )
    }

    func reportExternalActionError(_ error: ExternalActionError) {
        let message: String
        switch error {
        case .applicationUnavailable:
            message = localized("Für diese Aktion ist keine passende App installiert.")
        case .secureTunnelUnsupported:
            message = localized("Automatische SSH-Tunnel für HTTPS-Webseiten sind wegen der Zertifikatsprüfung nicht verfügbar. Verwende direkten Zugriff oder eine HTTP-Verbindung innerhalb des Tunnels.")
        case .tunnelCouldNotStart(let detail):
            message = localized("Der SSH-Tunnel konnte nicht gestartet werden: \(detail)")
        }
        actionError = ActionError(message: message)
    }

    func dismissActionError() {
        actionError = nil
    }

    func perform(_ action: MonitoringAction, on issue: MonitoringIssue) async {
        guard !activeActionIssueIDs.contains(issue.id) else { return }
        actionError = nil
        guard let source = sources.first(where: { $0.id == issue.sourceID }), source.isEnabled else {
            actionError = ActionError(
                message: localized("Die zugehörige Quelle ist nicht verfügbar.")
            )
            return
        }
        guard let provider = providerRegistry.provider(for: source.providerID),
              provider.supportedActions(for: source).contains(action.kind) else {
            actionError = ActionError(
                message: localized("Diese Aktion wird von der Quelle nicht unterstützt.")
            )
            return
        }

        activeActionIssueIDs.insert(issue.id)
        defer { activeActionIssueIDs.remove(issue.id) }
        let accessResolution = await accessResolver.resolve(source: source)
        let access: ProviderAccess
        switch accessResolution {
        case .resolved(let resolvedAccess):
            access = resolvedAccess
        case .failed(let failure):
            actionError = ActionError(message: accessMessage(for: failure))
            return
        }

        let (result, path) = await connectionCoordinator.performUsingBestAPIPath(
            source: source,
            access: access,
            operation: { routedAccess in
                await provider.perform(
                    action,
                    on: issue,
                    from: source,
                    access: routedAccess
                )
            },
            isUnreachable: { result in
                result == .failed(.unreachable)
            }
        )
        updateAPIConnectionStatus(for: source.id, result: result, path: path)
        connectionStatusSources[source.id] = source
        switch result {
        case .completed:
            if let refreshTask = refresh(sourceID: source.id) {
                await refreshTask.value
            }
        case .rejected(let message):
            actionError = ActionError(message: message)
        case .failed(let failure):
            actionError = ActionError(message: refreshMessage(for: failure))
        }
    }

    var actionableIssues: [MonitoringIssue] {
        activeSnapshots.flatMap(\.actionableIssues).sorted(by: issueOrder)
    }

    var coveredIssues: [MonitoringIssue] {
        activeSnapshots
            .flatMap(\.issues)
            .filter { !$0.requiresAttention }
            .sorted(by: issueOrder)
    }

    var hasActiveSnapshot: Bool {
        !activeSnapshots.isEmpty
    }

    var failedSources: [SourceFailure] {
        sources.compactMap { source in
            guard source.isEnabled, case .failed(let message) = refreshStates[source.id] else {
                return nil
            }
            return SourceFailure(source: source, message: message)
        }
    }

    var hasPartialRefreshFailure: Bool {
        let enabledCount = sources.filter(\.isEnabled).count
        return !failedSources.isEmpty && failedSources.count < enabledCount
    }

    var refreshState: RefreshState {
        if sources.isEmpty { return .notConfigured }
        let enabledSources = sources.filter(\.isEnabled)
        if enabledSources.isEmpty { return .disabled }
        let failures = failedSources
        if let failure = failures.first {
            if failures.count == 1 {
                return .failed("\(failure.source.name): \(failure.message)")
            }
            return .failed(localized("\(failures.count) Quellen konnten nicht aktualisiert werden."))
        }
        if enabledSources.contains(where: { refreshStates[$0.id] == .refreshing }) {
            return .refreshing
        }
        if enabledSources.allSatisfy({ refreshStates[$0.id] == .current }) {
            return .current
        }
        return .refreshing
    }

    var deletionMessage: String {
        guard let selectedSource else {
            return localized("Die Quellenkonfiguration wird von diesem Mac entfernt.")
        }
        let credentialMessage: String
        switch selectedSource.authentication {
        case .basic:
            credentialMessage = localized("Die Konfiguration und das zugehörige Basic-Passwort werden von diesem Mac entfernt.")
        case .apiKey:
            credentialMessage = localized("Die Konfiguration und der zugehörige API-Schlüssel werden von diesem Mac entfernt.")
        case .clientCertificate:
            credentialMessage = localized("Die Konfiguration wird entfernt. Das Client-Zertifikat bleibt im macOS-Schlüsselbund.")
        }
        if case .customCertificate = selectedSource.serverTrust {
            return localized("\(credentialMessage) Ein von IssueLight importiertes CA-Zertifikat wird nur entfernt, wenn keine andere Quelle es verwendet. Vorhandene fremde Zertifikate bleiben unberührt.")
        }
        return credentialMessage
    }

    convenience init(
        localizationLocale: Locale = .current,
        connectionCoordinator: AutomaticConnectionCoordinator? = nil
    ) {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "berlin.yuna.issuelight"
        let fileURL = try? SourceStore.defaultFileURL(bundleIdentifier: bundleIdentifier)
        let store = fileURL.map(SourceStore.init(fileURL:))
        let certificateCatalog = KeychainServerCertificateCatalog(ownershipScope: bundleIdentifier)
        self.init(
            sourceStore: store,
            providerRegistry: .builtIn(),
            passwordVault: KeychainPasswordVault(),
            identityCatalog: KeychainIdentityCatalog(),
            certificateCatalog: certificateCatalog,
            connectionCoordinator: connectionCoordinator,
            startsAutomatically: true,
            localizationLocale: localizationLocale
        )
        if store == nil {
            activity = .failure(localized("Der Speicherort für die Quellen konnte nicht geöffnet werden."))
        }
    }

    init(
        sourceStore: SourceStore?,
        providerRegistry: ProviderRegistry,
        passwordVault: KeychainPasswordVault,
        identityCatalog: KeychainIdentityCatalog,
        certificateCatalog: KeychainServerCertificateCatalog,
        connectionCoordinator: AutomaticConnectionCoordinator? = nil,
        presentedServerCertificateFetcher: @escaping (
            URL,
            ProviderSOCKSProxy?
        ) async -> PresentedServerCertificateResult = { endpoint, proxy in
            await PresentedServerCertificateFetcher.fetch(from: endpoint, socksProxy: proxy)
        },
        startsAutomatically: Bool,
        localizationLocale: Locale = .current
    ) {
        self.sourceStore = sourceStore
        self.providerRegistry = providerRegistry
        self.passwordVault = passwordVault
        self.identityCatalog = identityCatalog
        self.certificateCatalog = certificateCatalog
        self.connectionCoordinator = connectionCoordinator ?? AutomaticConnectionCoordinator()
        self.presentedServerCertificateFetcher = presentedServerCertificateFetcher
        self.localizationLocale = localizationLocale
        accessResolver = ProviderAccessResolver(
            passwordVault: passwordVault,
            identityCatalog: identityCatalog,
            certificateCatalog: certificateCatalog
        )
        selectedProviderID = providerRegistry.provider(for: Icinga2Provider.id) == nil
            ? providerRegistry.descriptors.first?.id ?? ProviderID(rawValue: "")
            : Icinga2Provider.id
        if startsAutomatically {
            Task { [weak self] in
                await self?.start()
            }
        }
    }

    deinit {
        refreshTasks.values.forEach { $0.cancel() }
        refreshLoopTask?.cancel()
    }

    func setLocalizationLocale(_ locale: Locale) {
        localizationLocale = locale
        objectWillChange.send()
    }

    private func localized(_ resource: LocalizedStringResource) -> String {
        AppLocalization.string(resource, locale: localizationLocale)
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await load()
        if hasEnabledSource {
            startRefreshLoop()
            if let initialRefresh = refresh() {
                await initialRefresh.value
            }
        }
    }

    func load() async {
        guard let sourceStore else { return }
        activity = .working(localized("Gespeicherte Quellen werden geladen …"))
        do {
            sources = try await sourceStore.load()
            connectionCoordinator.reconcileSources(sources)
            hasLoadedSources = true
            for source in sources where !source.isEnabled {
                refreshStates[source.id] = .disabled
            }
            if let firstSource = sources.first {
                await selectSource(id: firstSource.id)
            } else {
                beginAddingSource()
            }
        } catch {
            activity = .failure(localized("Die gespeicherten Quellen konnten nicht geladen werden: \(error.localizedDescription)"))
            return
        }

        let certificateCleanupSucceeded = await cleanupUnreferencedManagedServerCertificates()

        do {
            identities = try await identityCatalog.identities()
            identityLoadError = nil
            if case .working = activity {
                activity = .idle
            }
        } catch {
            identities = []
            let message = localized("Client-Zertifikate konnten nicht aus dem Schlüsselbund gelesen werden.")
            identityLoadError = message
            if authenticationChoice == .clientCertificate {
                activity = .failure(message)
            } else if case .working = activity {
                activity = .idle
            }
        }
        if !certificateCleanupSucceeded, case .idle = activity {
            activity = .failure(localized("Nicht mehr verwendete CA-Zertifikate konnten nicht aus dem Schlüsselbund entfernt werden."))
        }
    }

    func selectSource(id: UUID) async {
        guard let source = sources.first(where: { $0.id == id }) else { return }
        connectionTestID = nil
        isTestingConnection = false
        activity = .working(localized("Quelle wird geladen …"))
        selectedSourceID = source.id
        apply(source)
        credentialSecret = ""
        do {
            let hasCredential = try await containsStoredCredential(for: source)
            guard selectedSourceID == source.id else { return }
            hasStoredCredentialSecret = hasCredential
        } catch KeychainPasswordVaultError.interactionNotAllowed {
            guard selectedSourceID == source.id else { return }
            hasStoredCredentialSecret = false
            activity = .failure(
                localized("macOS gibt diesen Schlüsselbund-Eintrag nicht ohne Nachfrage frei. Gib das Geheimnis in der Quelle erneut ein.")
            )
        } catch {
            guard selectedSourceID == source.id else { return }
            hasStoredCredentialSecret = false
            activity = .failure(localized("Die gespeicherten Zugangsdaten konnten nicht aus dem Schlüsselbund gelesen werden."))
        }

        do {
            let descriptor: ServerCertificateDescriptor?
            if case .customCertificate(let certificateID) = source.serverTrust {
                descriptor = try await certificateCatalog.descriptor(id: certificateID)
            } else {
                descriptor = nil
            }
            guard selectedSourceID == source.id else { return }
            selectedServerCertificate = descriptor
            if case .customCertificate = source.serverTrust, descriptor == nil {
                activity = .failure(localized("Das CA-Zertifikat ist nicht mehr im Schlüsselbund verfügbar."))
            } else if case .working = activity {
                activity = .idle
            }
        } catch {
            guard selectedSourceID == source.id else { return }
            selectedServerCertificate = nil
            activity = .failure(localized("Das CA-Zertifikat konnte nicht aus dem Schlüsselbund gelesen werden."))
        }
    }

    func beginAddingSource() {
        connectionTestID = nil
        isTestingConnection = false
        connectionAttempts = []
        selectedSourceID = nil
        sourceID = UUID()
        name = ""
        endpoint = ""
        isSourceEnabled = true
        selectedProviderID = providerRegistry.provider(for: Icinga2Provider.id) == nil
            ? providerRegistry.descriptors.first?.id ?? ProviderID(rawValue: "")
            : Icinga2Provider.id
        authenticationChoice = authenticationChoices.first ?? .basic
        username = ""
        credentialSecret = ""
        selectedIdentityID = ""
        hasStoredCredentialSecret = false
        serverTrustChoice = .system
        selectedServerCertificate = nil
        pinnedServerCertificateSHA256 = ""
        resetNavigationForm()
        activity = .idle
    }

    func testConnection() async {
        guard let provider = providerRegistry.provider(for: selectedProviderID) else {
            activity = .failure(localized("Der konfigurierte Monitoring-Typ ist nicht verfügbar."))
            return
        }
        let candidates = provider.endpointCandidates(from: endpoint)
        guard !candidates.isEmpty else {
            activity = .failure(localized("Die Serveradresse benötigt einen Hostnamen."))
            return
        }

        let testedSourceID = sourceID
        connectionTestID = testedSourceID
        isTestingConnection = true
        connectionAttempts = []
        connectionStatuses[testedSourceID] = ConnectionStatus(api: .checking, web: .checking)
        activity = .working(localized("Verbindung wird geprüft …"))

        var finalSource: MonitoringSource?
        var finalResult = ConnectionTestResult.failed(.unreachable)
        var finalPath = AutomaticConnectionPath.direct

        for (candidateIndex, candidate) in candidates.enumerated() {
            guard let source = sourceFromForm(endpointOverride: candidate) else {
                connectionTestID = nil
                isTestingConnection = false
                connectionStatuses[testedSourceID] = ConnectionStatus()
                return
            }
            finalSource = source

            var allowsStoredCredential = true
            if source.authentication.method != .clientCertificate {
                let requestedScope = try? credentialScope(for: source)
                let selectedScope = try? credentialScope(for: selectedSource)
                allowsStoredCredential = requestedScope != nil && requestedScope == selectedScope
                if credentialSecret.isEmpty && !allowsStoredCredential {
                    let detail = source.authentication.method == .apiKey
                        ? localized("Gib einen API-Schlüssel ein.")
                        : localized("Gib ein Passwort ein.")
                    connectionAttempts.append(
                        ConnectionAttempt(
                            endpoint: candidate.absoluteString,
                            route: "—",
                            outcome: detail
                        )
                    )
                    if candidateIndex < candidates.index(before: candidates.endIndex) {
                        continue
                    }
                    await testWebConnection(for: source, provider: provider)
                    guard connectionTestID == testedSourceID else { return }
                    connectionTestID = nil
                    isTestingConnection = false
                    connectionStatuses[testedSourceID]?.api = .failed(detail)
                    connectionStatusSources[testedSourceID] = source
                    activity = .failure(detail)
                    return
                }
            }

            let accessResolution = await accessResolver.resolve(
                source: source,
                credentialOverride: credentialSecret,
                allowsStoredCredential: allowsStoredCredential,
                keychainInteraction: .allow
            )
            guard connectionTestID == testedSourceID else { return }
            let access: ProviderAccess
            switch accessResolution {
            case .resolved(let resolvedAccess):
                access = resolvedAccess
            case .failed(let failure):
                let detail = accessMessage(for: failure)
                connectionAttempts.append(
                    ConnectionAttempt(
                        endpoint: candidate.absoluteString,
                        route: "—",
                        outcome: detail
                    )
                )
                await testWebConnection(for: source, provider: provider)
                guard connectionTestID == testedSourceID else { return }
                connectionTestID = nil
                isTestingConnection = false
                connectionStatuses[testedSourceID]?.api = .failed(detail)
                connectionStatusSources[testedSourceID] = source
                activity = .failure(detail)
                return
            }

            let (result, path) = await connectionCoordinator.performUsingBestAPIPath(
                source: source,
                access: access,
                rediscoverDirect: true,
                operation: { routedAccess in
                    await provider.testConnection(to: source, access: routedAccess)
                },
                isUnreachable: { result in
                    result == .failed(.unreachable)
                }
            )
            guard connectionTestID == testedSourceID else { return }
            finalResult = result
            finalPath = path
            connectionAttempts.append(connectionAttempt(for: source, result: result, path: path))

            if result == .failed(.cancelled) || Task.isCancelled {
                connectionStatuses[testedSourceID] = ConnectionStatus()
                connectionStatusSources[testedSourceID] = nil
                connectionTestID = nil
                isTestingConnection = false
                activity = message(for: .failed(.cancelled))
                return
            }
            if result == .connected {
                let certificate = selectedServerCertificate
                endpoint = source.endpoint.absoluteString
                name = source.name
                selectedServerCertificate = certificate
                switch source.serverTrust {
                case .system:
                    serverTrustChoice = .system
                case .customCertificate:
                    serverTrustChoice = .customCertificate
                case .pinnedCertificate(let sha256):
                    serverTrustChoice = .pinnedCertificate
                    pinnedServerCertificateSHA256 = sha256
                case .disabled:
                    serverTrustChoice = .disabled
                }
                updateAPIConnectionStatus(for: testedSourceID, result: result, path: path)
                await testWebConnection(for: source, provider: provider)
                guard connectionTestID == testedSourceID else { return }
                connectionStatusSources[testedSourceID] = source
                connectionTestID = nil
                isTestingConnection = false
                activity = message(for: result)
                return
            }
            if !shouldTryNextEndpointCandidate(after: result) {
                break
            }
        }

        guard let finalSource else {
            connectionStatuses[testedSourceID] = ConnectionStatus()
            connectionTestID = nil
            isTestingConnection = false
            return
        }
        updateAPIConnectionStatus(for: testedSourceID, result: finalResult, path: finalPath)
        await testWebConnection(for: finalSource, provider: provider)
        guard connectionTestID == testedSourceID else { return }
        connectionStatusSources[testedSourceID] = finalSource
        connectionTestID = nil
        isTestingConnection = false
        activity = message(for: finalResult)
    }

    @discardableResult
    func refresh() -> Task<Void, Never>? {
        let tasks = sources.filter(\.isEnabled).map { refresh(sourceID: $0.id) }.compactMap { $0 }
        guard !tasks.isEmpty else { return nil }
        return Task {
            for task in tasks {
                await task.value
            }
        }
    }

    @discardableResult
    func refresh(sourceID: UUID) -> Task<Void, Never>? {
        guard let source = sources.first(where: { $0.id == sourceID }), source.isEnabled else {
            refreshTasks[sourceID]?.cancel()
            refreshTasks[sourceID] = nil
            if sources.contains(where: { $0.id == sourceID }) {
                refreshStates[sourceID] = .disabled
            } else {
                refreshStates[sourceID] = nil
            }
            return nil
        }

        refreshTasks[sourceID]?.cancel()
        refreshStates[sourceID] = .refreshing
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(source: source)
        }
        refreshTasks[sourceID] = task
        return task
    }

    func save() async {
        let requestedEnabledState = isSourceEnabled
        guard var source = sourceFromForm(requiresValidConfiguration: false),
              let sourceStore,
              let provider = providerRegistry.provider(for: source.providerID) else {
            return
        }
        activity = .working(localized("Quelle wird gespeichert …"))
        let previousSource = selectedSource
        let configurationIssues = provider.validate(source)
        let previousScope = try? credentialScope(for: previousSource)
        let newScope = try? credentialScope(for: source)
        var credentialReady: Bool
        var credentialStorageFailed = false

        switch source.authentication {
        case .basic, .apiKey:
            credentialReady = newScope != nil
                && newScope == previousScope
                && hasStoredCredentialSecret
        case .clientCertificate(let identityID):
            credentialReady = !identityID.isEmpty
        }
        source.isEnabled = requestedEnabledState
            && configurationIssues.isEmpty
            && credentialReady

        do {
            var persistedSources = try await sourceStore.upsert(source)

            if source.authentication.method != .clientCertificate,
               !credentialSecret.isEmpty,
               configurationIssues.isEmpty,
               let newScope {
                do {
                    try await storeCredential(credentialSecret, for: newScope)
                    credentialReady = true
                    source.isEnabled = requestedEnabledState && configurationIssues.isEmpty
                    persistedSources = try await sourceStore.upsert(source)
                    credentialSecret = ""
                } catch {
                    credentialStorageFailed = true
                    source.isEnabled = false
                    persistedSources = try await sourceStore.upsert(source)
                }
            }

            let connectionChanged = previousSource.map {
                $0.providerID != source.providerID
                    || $0.endpoint != source.endpoint
                    || $0.endpointInput != source.endpointInput
                    || $0.authentication != source.authentication
                    || $0.serverTrust != source.serverTrust
                    || $0.sshTunnel != source.sshTunnel
                    || $0.web != source.web
            } ?? true
            refreshTasks[source.id]?.cancel()
            refreshTasks[source.id] = nil
            if connectionChanged {
                snapshots[source.id] = nil
                if connectionStatusSources[source.id] != source {
                    connectionStatuses[source.id] = nil
                    connectionStatusSources[source.id] = nil
                }
            }
            sources = persistedSources
            connectionCoordinator.reconcileSources(sources)
            selectedSourceID = source.id
            sourceID = source.id
            name = source.name
            endpoint = source.editableEndpoint
            webURL = source.web?.editableBaseURL ?? ""
            isSourceEnabled = source.isEnabled
            hasStoredCredentialSecret = credentialReady && newScope != nil
            if source.customServerCertificateID == nil {
                selectedServerCertificate = nil
            }

            var cleanupFailed = false
            let changedAwayFromPreviousCredential: Bool
            switch source.authentication {
            case .basic, .apiKey:
                changedAwayFromPreviousCredential = credentialReady && previousScope != newScope
            case .clientCertificate:
                changedAwayFromPreviousCredential = credentialReady
            }
            if changedAwayFromPreviousCredential, let previousScope {
                do {
                    try await deleteCredential(for: previousScope)
                } catch {
                    cleanupFailed = true
                }
            }
            if !(await cleanupUnreferencedManagedServerCertificates()) {
                cleanupFailed = true
            }

            if source.isEnabled {
                startRefreshLoop()
                refresh(sourceID: source.id)
            } else {
                refreshStates[source.id] = .disabled
                if !hasEnabledSource {
                    refreshLoopTask?.cancel()
                    refreshLoopTask = nil
                }
            }

            if credentialStorageFailed {
                activity = .failure(
                    localized("Entwurf gespeichert. Die Zugangsdaten konnten nicht im macOS-Schlüsselbund gespeichert werden; die Quelle bleibt pausiert.")
                )
            } else if !configurationIssues.isEmpty || !credentialReady {
                activity = .success(
                    localized("Entwurf gespeichert. Vervollständige und teste die Verbindung, bevor du die Quelle aktivierst.")
                )
            } else if cleanupFailed {
                activity = .failure(localized("Quelle gespeichert, aber nicht mehr verwendete Schlüsselbund-Einträge konnten nicht vollständig entfernt werden."))
            } else {
                activity = .success(localized("Quelle gespeichert. Geheimnisse bleiben im macOS-Schlüsselbund."))
            }
        } catch {
            activity = .failure(localized("Die Quelle konnte nicht gespeichert werden: \(error.localizedDescription)"))
        }
    }

    func deleteSource() async {
        guard let source = selectedSource, let sourceStore else { return }
        activity = .working(localized("Quelle wird entfernt …"))
        let removedIndex = sources.firstIndex(where: { $0.id == source.id }) ?? 0

        let persistedSources: [MonitoringSource]
        do {
            persistedSources = try await sourceStore.remove(id: source.id)
        } catch {
            activity = .failure(localized("Die Quelle konnte nicht entfernt werden: \(error.localizedDescription)"))
            return
        }

        refreshTasks[source.id]?.cancel()
        refreshTasks[source.id] = nil
        snapshots[source.id] = nil
        refreshStates[source.id] = nil
        connectionStatuses[source.id] = nil
        connectionStatusSources[source.id] = nil
        connectionCoordinator.stop(sourceID: source.id)
        sources = persistedSources
        connectionCoordinator.reconcileSources(sources)
        if !hasEnabledSource {
            refreshLoopTask?.cancel()
            refreshLoopTask = nil
        }

        var cleanupFailed = false
        if source.authentication.method != .clientCertificate,
           let scope = try? credentialScope(for: source) {
            do {
                try await deleteCredential(for: scope)
            } catch {
                cleanupFailed = true
            }
        }
        if !(await cleanupUnreferencedManagedServerCertificates()) {
            cleanupFailed = true
        }

        if sources.isEmpty {
            refreshLoopTask?.cancel()
            refreshLoopTask = nil
            beginAddingSource()
        } else {
            let nextIndex = min(removedIndex, sources.count - 1)
            await selectSource(id: sources[nextIndex].id)
        }

        if cleanupFailed {
            activity = .failure(localized("Die Quelle wurde entfernt, aber nicht mehr verwendete Schlüsselbund-Einträge konnten nicht vollständig gelöscht werden."))
        } else {
            let message: String
            switch source.authentication {
            case .basic:
                message = localized("Quelle und gespeichertes Basic-Passwort wurden entfernt.")
            case .apiKey:
                message = localized("Quelle und gespeicherter API-Schlüssel wurden entfernt.")
            case .clientCertificate:
                message = localized("Quelle entfernt. Das Client-Zertifikat bleibt im macOS-Schlüsselbund.")
            }
            activity = .success(message)
        }
    }

    func importIdentity(at fileURL: URL, password: String) async -> Bool {
        let hasSecurityScopedAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScopedAccess {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        activity = .working(localized("Zertifikat wird importiert …"))
        do {
            let descriptor = try await identityCatalog.importPKCS12(at: fileURL, password: password)
            identities = try await identityCatalog.identities()
            identityLoadError = nil
            selectedIdentityID = descriptor.id
            authenticationChoice = .clientCertificate
            activity = .success(localized("„\(descriptor.displayName)“ wurde in den Schlüsselbund importiert."))
            return true
        } catch {
            activity = .failure(localized("Das PKCS#12-Zertifikat konnte nicht importiert werden. Datei oder Passwort ist ungültig."))
            return false
        }
    }

    func importServerCertificate(at fileURL: URL) async -> Bool {
        let hasSecurityScopedAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScopedAccess {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        activity = .working(localized("CA-Zertifikat wird importiert …"))
        do {
            let descriptor = try await certificateCatalog.importCertificate(at: fileURL)
            selectedServerCertificate = descriptor
            serverTrustChoice = .customCertificate
            let cleanupSucceeded = await cleanupUnreferencedManagedServerCertificates(
                retainingAdditionalIDs: [descriptor.id]
            )
            activity = cleanupSucceeded
                ? .success(localized("„\(descriptor.displayName)“ wird nur für diese Quellenkonfiguration als CA verwendet."))
                : .failure(localized("Das CA-Zertifikat wurde importiert, aber ein zuvor ungenutztes Zertifikat konnte nicht entfernt werden."))
            return true
        } catch KeychainServerCertificateCatalogError.multipleCertificatesNotSupported {
            activity = .failure(localized("Wähle eine Datei mit genau einem CA-Zertifikat."))
            return false
        } catch {
            activity = .failure(localized("Das CA-Zertifikat konnte nicht importiert werden."))
            return false
        }
    }

    func pinServerCertificate(at fileURL: URL) -> Bool {
        let hasSecurityScopedAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScopedAccess {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        activity = .working(localized("Serverzertifikat wird geprüft …"))
        do {
            pinnedServerCertificateSHA256 = try ServerCertificateFingerprint.sha256(at: fileURL)
            serverTrustChoice = .pinnedCertificate
            activity = .success(
                localized("Der SHA-256-Fingerprint wurde übernommen. Prüfe die Verbindung, bevor du die Quelle speicherst.")
            )
            return true
        } catch ServerCertificateFingerprintError.multipleCertificatesNotSupported {
            activity = .failure(localized("Wähle eine Datei mit genau einem Serverzertifikat."))
            return false
        } catch {
            activity = .failure(localized("Das Serverzertifikat konnte nicht gelesen werden."))
            return false
        }
    }

    func fetchPresentedServerCertificate() async -> PresentedServerCertificate? {
        guard let provider = providerRegistry.provider(for: selectedProviderID) else {
            activity = .failure(localized("Der konfigurierte Monitoring-Typ ist nicht verfügbar."))
            return nil
        }
        let candidates = provider.endpointCandidates(from: endpoint)
        guard !candidates.isEmpty else {
            activity = .failure(localized("Die Serveradresse benötigt einen Hostnamen."))
            return nil
        }

        activity = .working(localized("Serverzertifikat wird geprüft …"))
        var finalFailure = ConnectionFailure.unreachable
        for candidate in candidates {
            guard let source = sourceFromForm(
                endpointOverride: candidate,
                requiresValidConfiguration: false
            ) else {
                return nil
            }
            let access = ProviderAccess(credential: .password(""))
            let (result, _) = await connectionCoordinator.performUsingBestAPIPath(
                source: source,
                access: access,
                rediscoverDirect: true,
                operation: { routedAccess in
                    await self.presentedServerCertificateFetcher(
                        candidate,
                        routedAccess.socksProxy
                    )
                },
                isUnreachable: { result in
                    result == .failed(.unreachable)
                }
            )
            switch result {
            case .fetched(let certificate):
                activity = .idle
                return certificate
            case .failed(.cancelled):
                activity = .idle
                return nil
            case .failed(let failure):
                finalFailure = failure
            }
        }

        activity = message(for: .failed(finalFailure))
        return nil
    }

    func trustPresentedServerCertificate(_ certificate: PresentedServerCertificate) {
        endpoint = certificate.endpoint.absoluteString
        pinnedServerCertificateSHA256 = certificate.sha256Fingerprint
        serverTrustChoice = .pinnedCertificate
        activity = .success(
            localized("Der SHA-256-Fingerprint wurde übernommen. Prüfe die Verbindung, bevor du die Quelle speicherst.")
        )
    }

    func cleanupUnreferencedManagedServerCertificates(
        retainingAdditionalIDs: Set<String> = []
    ) async -> Bool {
        var referencedCertificateIDs = Set(sources.compactMap(\.customServerCertificateID))
        referencedCertificateIDs.formUnion(retainingAdditionalIDs)
        do {
            _ = try await certificateCatalog.deleteUnreferencedManagedCertificates(
                referencedCertificateIDs: referencedCertificateIDs
            )
            return true
        } catch {
            return false
        }
    }

    func sourceName(for sourceID: UUID) -> String {
        sources.first(where: { $0.id == sourceID })?.name ?? localized("Unbekannte Quelle")
    }

    func providerName(for source: MonitoringSource) -> String {
        providerRegistry.provider(for: source.providerID)?.descriptor.displayName ?? source.providerID.rawValue
    }

    func sourceRefreshState(for sourceID: UUID) -> RefreshState {
        guard let source = sources.first(where: { $0.id == sourceID }) else { return .notConfigured }
        if !source.isEnabled { return .disabled }
        return refreshStates[sourceID] ?? .refreshing
    }

    private var activeSnapshots: [MonitoringSnapshot] {
        sources.filter(\.isEnabled).compactMap { snapshots[$0.id] }
    }

    private func issueOrder(_ lhs: MonitoringIssue, _ rhs: MonitoringIssue) -> Bool {
        if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
        let lhsSource = sources.firstIndex(where: { $0.id == lhs.sourceID }) ?? .max
        let rhsSource = sources.firstIndex(where: { $0.id == rhs.sourceID }) ?? .max
        if lhsSource != rhsSource { return lhsSource < rhsSource }
        return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
    }

    private func sourceFromForm(
        endpointOverride: URL? = nil,
        requiresValidConfiguration: Bool = true
    ) -> MonitoringSource? {
        let endpointValue = urlInputWithoutEmbeddedCredentials(
            endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let url = endpointOverride ?? URL(string: endpointValue) ?? MonitoringSource.unresolvedEndpoint
        let endpointInput = endpointOverride == nil ? endpointValue : nil
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty
            ? SourceNameSuggestion.name(
                rawEndpoint: endpointOverride?.absoluteString ?? endpointValue,
                providerName: providerDisplayName,
                sourceID: sourceID
            )
            : trimmedName
        let webConfiguration = navigationWebConfiguration()

        let authentication: AuthenticationConfiguration
        switch authenticationChoice {
        case .basic:
            authentication = .basic(username: username)
        case .apiKey:
            authentication = .apiKey(username: username)
        case .clientCertificate:
            authentication = .clientCertificate(identityID: selectedIdentityID)
        }

        let serverTrust: ServerTrustConfiguration
        if !isEndpointUsingTLS {
            serverTrust = .system
        } else {
            switch serverTrustChoice {
            case .system:
                serverTrust = .system
            case .customCertificate:
                serverTrust = .customCertificate(certificateID: selectedServerCertificate?.id ?? "")
            case .pinnedCertificate:
                serverTrust = .pinnedCertificate(sha256: pinnedServerCertificateSHA256)
            case .disabled:
                serverTrust = .disabled
            }
        }

        var source: MonitoringSource
        if var existingSource = selectedSource {
            existingSource.name = resolvedName
            existingSource.providerID = selectedProviderID
            existingSource.isEnabled = isSourceEnabled
            existingSource.authentication = authentication
            _ = existingSource.updateEndpoint(url)
            existingSource.endpointInput = endpointInput
            existingSource.serverTrust = serverTrust
            existingSource.sshTunnel = AppDistribution.supportsSSHTunnels ? sshTunnelOverrides() : nil
            existingSource.web = webConfiguration
            existingSource.remoteAccess = AppDistribution.supportsRemoteAccess
                ? navigationRemoteAccessConfiguration()
                : nil
            source = existingSource
        } else {
            source = MonitoringSource(
                id: sourceID,
                name: resolvedName,
                providerID: selectedProviderID,
                endpoint: url,
                endpointInput: endpointInput,
                isEnabled: isSourceEnabled,
                authentication: authentication,
                serverTrust: serverTrust,
                sshTunnel: AppDistribution.supportsSSHTunnels ? sshTunnelOverrides() : nil,
                web: webConfiguration,
                remoteAccess: AppDistribution.supportsRemoteAccess
                    ? navigationRemoteAccessConfiguration()
                    : nil
            )
        }
        guard let provider = providerRegistry.provider(for: selectedProviderID) else {
            activity = .failure(localized("Der ausgewählte Monitoring-Typ ist nicht verfügbar."))
            return nil
        }
        let issues = provider.validate(source)
        guard issues.isEmpty || !requiresValidConfiguration else {
            activity = .failure(validationMessage(issues))
            return nil
        }
        if !issues.isEmpty {
            source.isEnabled = false
        }
        return source
    }

    private func credentialScope(for source: MonitoringSource?) throws -> StoredCredentialScope? {
        guard let source else { return nil }
        switch source.authentication {
        case .basic:
            return .basic(try BasicCredentialScope(source: source))
        case .apiKey:
            return .apiKey(try APIKeyCredentialScope(source: source))
        case .clientCertificate:
            return nil
        }
    }

    private func containsStoredCredential(for source: MonitoringSource) async throws -> Bool {
        guard let scope = try credentialScope(for: source) else { return false }
        switch scope {
        case .basic(let basicScope):
            return try await passwordVault.containsPassword(for: basicScope)
        case .apiKey(let apiKeyScope):
            return try await passwordVault.containsAPIKey(for: apiKeyScope)
        }
    }

    private func storeCredential(_ secret: String, for scope: StoredCredentialScope) async throws {
        switch scope {
        case .basic(let basicScope):
            try await passwordVault.store(secret, for: basicScope)
        case .apiKey(let apiKeyScope):
            try await passwordVault.store(secret, for: apiKeyScope)
        }
    }

    private func deleteCredential(for scope: StoredCredentialScope) async throws {
        switch scope {
        case .basic(let basicScope):
            try await passwordVault.deletePassword(for: basicScope)
        case .apiKey(let apiKeyScope):
            try await passwordVault.deleteAPIKey(for: apiKeyScope)
        }
    }

    private func startRefreshLoop() {
        guard refreshLoopTask == nil else { return }
        refreshLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    private func performRefresh(source: MonitoringSource) async {
        guard !Task.isCancelled else { return }
        guard let provider = providerRegistry.provider(for: source.providerID) else {
            let message = localized("Der konfigurierte Monitoring-Typ ist nicht verfügbar.")
            refreshStates[source.id] = .failed(message)
            connectionStatuses[source.id, default: ConnectionStatus()].api = .failed(message)
            connectionStatusSources[source.id] = source
            return
        }
        let accessResolution = await accessResolver.resolve(source: source)
        guard !Task.isCancelled else { return }
        let access: ProviderAccess
        switch accessResolution {
        case .resolved(let resolvedAccess):
            access = resolvedAccess
        case .failed(let failure):
            let message = accessMessage(for: failure)
            refreshStates[source.id] = .failed(message)
            connectionStatuses[source.id, default: ConnectionStatus()].api = .failed(message)
            connectionStatusSources[source.id] = source
            return
        }
        let (result, path) = await connectionCoordinator.performUsingBestAPIPath(
            source: source,
            access: access,
            operation: { routedAccess in
                await provider.loadSnapshot(from: source, access: routedAccess)
            },
            isUnreachable: { result in
                result == .failed(.unreachable)
            }
        )

        guard !Task.isCancelled else { return }
        updateAPIConnectionStatus(for: source.id, result: result, path: path)
        connectionStatusSources[source.id] = source
        switch result {
        case .loaded(let loadedSnapshot):
            snapshots[source.id] = loadedSnapshot
            refreshStates[source.id] = .current
        case .failed(.cancelled):
            return
        case .failed(let failure):
            refreshStates[source.id] = .failed(refreshMessage(for: failure))
        }
    }

    private func apply(_ source: MonitoringSource) {
        connectionAttempts = []
        sourceID = source.id
        name = source.name
        endpoint = source.editableEndpoint
        isSourceEnabled = source.isEnabled
        selectedProviderID = source.providerID
        username = ""
        selectedIdentityID = ""
        selectedServerCertificate = nil
        pinnedServerCertificateSHA256 = ""
        switch source.authentication {
        case .basic(let storedUsername):
            authenticationChoice = .basic
            username = storedUsername
        case .apiKey(let storedUsername):
            authenticationChoice = .apiKey
            username = storedUsername
        case .clientCertificate(let identityID):
            authenticationChoice = .clientCertificate
            selectedIdentityID = identityID
        }
        switch source.serverTrust {
        case .system:
            serverTrustChoice = .system
        case .customCertificate:
            serverTrustChoice = .customCertificate
        case .pinnedCertificate(let sha256):
            serverTrustChoice = .pinnedCertificate
            pinnedServerCertificateSHA256 = sha256
        case .disabled:
            serverTrustChoice = .disabled
        }
        webURL = source.web?.editableBaseURL ?? ""
        let tunnel = source.sshTunnel ?? source.web?.automaticSSHTunnel
        sshTunnelHost = tunnel?.bastionHost ?? ""
        sshTunnelUsername = tunnel?.username ?? ""
        sshTunnelPort = tunnel.map { String($0.port) } ?? ""
        sshTunnelIdentityFilePath = tunnel?.identityFilePath ?? ""
        sshTunnelPreferredLocalPort = tunnel?.preferredLocalPort.map(String.init) ?? ""
        sshActionEnabled = source.remoteAccess?.ssh != nil
        sshUsername = source.remoteAccess?.ssh?.username ?? ""
        sshPort = source.remoteAccess?.ssh?.port ?? 22
        rdpActionEnabled = source.remoteAccess?.rdp != nil
        rdpUsername = source.remoteAccess?.rdp?.username ?? ""
        rdpPort = source.remoteAccess?.rdp?.port ?? 3_389
    }

    private func validationMessage(_ issues: [SourceValidationIssue]) -> String {
        if issues.contains(.emptyName) { return localized("Gib der Quelle einen Namen.") }
        if issues.contains(.missingHost) { return localized("Die Serveradresse benötigt einen Hostnamen.") }
        if issues.contains(.emptyUsername) { return localized("Gib einen Benutzernamen ein.") }
        if issues.contains(.invalidUsername) { return localized("Der Benutzername darf keinen Doppelpunkt enthalten.") }
        if issues.contains(.missingClientIdentity) { return localized("Wähle ein Client-Zertifikat aus dem Schlüsselbund.") }
        if issues.contains(.missingServerCertificate) { return localized("Importiere ein CA-Zertifikat.") }
        if issues.contains(.invalidPinnedCertificate) { return localized("Wähle ein gültiges Serverzertifikat für den SHA-256-Pin aus.") }
        if issues.contains(.invalidWebURL) { return localized("Gib eine gültige Web-URL ohne Zugangsdaten, Abfrage oder Fragment ein.") }
        if issues.contains(where: {
            if case .invalidRemotePort = $0 { return true }
            return false
        }) {
            return localized("Ports müssen zwischen 1 und 65535 liegen.")
        }
        if issues.contains(where: {
            if case .unsupportedAuthentication = $0 { return true }
            return false
        }) {
            return localized("Diese Authentifizierung wird vom ausgewählten Monitoring-Typ nicht unterstützt.")
        }
        if issues.contains(where: {
            if case .unsupportedPath = $0 { return true }
            return false
        }) {
            return localized("Verwende nur eine vom ausgewählten Monitoring-Typ unterstützte Serveradresse.")
        }
        if issues.contains(where: {
            if case .unsupportedScheme = $0 { return true }
            return false
        }) {
            return localized("Der ausgewählte Monitoring-Typ akzeptiert diese Serveradresse nicht.")
        }
        return localized("Die Quellenkonfiguration ist ungültig.")
    }

    private func synchronizeProviderCapabilities() {
        let choices = authenticationChoices
        if !choices.contains(authenticationChoice), let first = choices.first {
            authenticationChoice = first
        }
        let trustChoices = serverTrustChoices
        if !trustChoices.contains(serverTrustChoice), let first = trustChoices.first {
            serverTrustChoice = first
            selectedServerCertificate = nil
            pinnedServerCertificateSHA256 = ""
        }
    }

    private var hasNavigationInput: Bool {
        !webURL.isEmpty
            || !sshTunnelHost.isEmpty
            || !sshTunnelUsername.isEmpty
            || !sshTunnelPort.isEmpty
            || !sshTunnelIdentityFilePath.isEmpty
            || !sshTunnelPreferredLocalPort.isEmpty
            || sshActionEnabled
            || !sshUsername.isEmpty
            || sshPort != 22
            || rdpActionEnabled
            || !rdpUsername.isEmpty
            || rdpPort != 3_389
    }

    private func navigationWebConfiguration() -> MonitoringWebConfiguration? {
        let value = urlInputWithoutEmbeddedCredentials(
            webURL.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !value.isEmpty else { return nil }
        let url = URL(string: value) ?? MonitoringSource.unresolvedEndpoint
        return MonitoringWebConfiguration(baseURL: url, baseURLInput: value)
    }

    private func resolvedSSHTunnelConfiguration(for source: MonitoringSource) -> SSHTunnelConfiguration {
        let overrides = source.sshTunnel ?? source.web?.automaticSSHTunnel
        let configuredHost = overrides?.bastionHost.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return SSHTunnelConfiguration(
            bastionHost: configuredHost.isEmpty ? source.endpoint.host ?? "" : configuredHost,
            username: overrides?.username ?? "",
            port: overrides?.port ?? 22,
            identityFilePath: overrides?.identityFilePath,
            preferredLocalPort: overrides?.preferredLocalPort
        )
    }

    private func sshTunnelOverrides() -> SSHTunnelConfiguration? {
        let preferredPort = sshTunnelPreferredLocalPort.isEmpty
            ? nil
            : Int(sshTunnelPreferredLocalPort)
        let hasOverrides = !sshTunnelHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !sshTunnelUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !sshTunnelPort.isEmpty
            || !sshTunnelIdentityFilePath.isEmpty
            || !sshTunnelPreferredLocalPort.isEmpty
        guard hasOverrides else { return nil }
        return SSHTunnelConfiguration(
            bastionHost: sshTunnelHost.trimmingCharacters(in: .whitespacesAndNewlines),
            username: sshTunnelUsername.trimmingCharacters(in: .whitespacesAndNewlines),
            port: Int(sshTunnelPort) ?? (sshTunnelPort.isEmpty ? 22 : 0),
            identityFilePath: sshTunnelIdentityFilePath.isEmpty ? nil : sshTunnelIdentityFilePath,
            preferredLocalPort: preferredPort ?? (sshTunnelPreferredLocalPort.isEmpty ? nil : 0)
        )
    }

    private func navigationRemoteAccessConfiguration() -> RemoteAccessConfiguration? {
        let ssh = sshActionEnabled
            ? RemoteLoginConfiguration(
                username: sshUsername.trimmingCharacters(in: .whitespacesAndNewlines),
                port: sshPort
            )
            : nil
        let rdp = rdpActionEnabled
            ? RemoteLoginConfiguration(
                username: rdpUsername.trimmingCharacters(in: .whitespacesAndNewlines),
                port: rdpPort
            )
            : nil
        guard ssh != nil || rdp != nil else { return nil }
        return RemoteAccessConfiguration(ssh: ssh, rdp: rdp)
    }

    private func resetNavigationForm() {
        webURL = ""
        sshTunnelHost = ""
        sshTunnelUsername = ""
        sshTunnelPort = ""
        sshTunnelIdentityFilePath = ""
        sshTunnelPreferredLocalPort = ""
        sshActionEnabled = false
        sshUsername = ""
        sshPort = 22
        rdpActionEnabled = false
        rdpUsername = ""
        rdpPort = 3_389
    }

    private func testWebConnection(
        for source: MonitoringSource,
        provider: any MonitoringProvider
    ) async {
        guard let url = source.web?.baseURL ?? provider.defaultWebBaseURL(for: source) else {
            connectionStatuses[source.id]?.web = .failed(
                localized("Konfiguriere zuerst die Web-URL dieser Quelle.")
            )
            return
        }
        let path = await connectionCoordinator.checkWeb(source: source, url: url)
        guard connectionTestID == source.id else { return }
        connectionStatuses[source.id]?.web = connectionState(for: path)
        switch path {
        case .direct:
            connectionAttempts.append(
                ConnectionAttempt(
                    endpoint: url.absoluteString,
                    route: "Web · \(localized("Direkt"))",
                    outcome: "OK"
                )
            )
        case .ssh:
            connectionAttempts.append(
                ConnectionAttempt(endpoint: url.absoluteString, route: "Web · SSH", outcome: "OK")
            )
        case .unavailable:
            connectionAttempts.append(
                ConnectionAttempt(
                    endpoint: url.absoluteString,
                    route: "Web",
                    outcome: localized("Der Server ist nicht erreichbar.")
                )
            )
        }
    }

    private func updateAPIConnectionStatus(
        for sourceID: UUID,
        result: ConnectionTestResult,
        path: AutomaticConnectionPath
    ) {
        switch result {
        case .connected:
            connectionStatuses[sourceID, default: ConnectionStatus()].api = connectionState(for: path)
        case .failed(.cancelled):
            break
        case .failed(let failure):
            connectionStatuses[sourceID, default: ConnectionStatus()].api = connectionFailureState(failure)
        }
    }

    private func updateAPIConnectionStatus(
        for sourceID: UUID,
        result: SnapshotLoadResult,
        path: AutomaticConnectionPath
    ) {
        switch result {
        case .loaded:
            connectionStatuses[sourceID, default: ConnectionStatus()].api = connectionState(for: path)
        case .failed(.cancelled):
            break
        case .failed(let failure):
            connectionStatuses[sourceID, default: ConnectionStatus()].api = connectionFailureState(failure)
        }
    }

    private func updateAPIConnectionStatus(
        for sourceID: UUID,
        result: MonitoringActionResult,
        path: AutomaticConnectionPath
    ) {
        switch result {
        case .completed, .rejected:
            connectionStatuses[sourceID, default: ConnectionStatus()].api = connectionState(for: path)
        case .failed(.cancelled):
            break
        case .failed(let failure):
            connectionStatuses[sourceID, default: ConnectionStatus()].api = connectionFailureState(failure)
        }
    }

    private func connectionFailureState(
        _ failure: ConnectionFailure
    ) -> ConnectionEndpointState {
        let message = refreshMessage(for: failure)
        return failure == .tls ? .serverTrustBlocked(message) : .failed(message)
    }

    private func connectionState(for path: AutomaticConnectionPath) -> ConnectionEndpointState {
        switch path {
        case .direct:
            return .direct
        case .ssh:
            return .ssh
        case .unavailable:
            return .failed(localized("Der Server ist nicht erreichbar."))
        }
    }

    private func shouldTryNextEndpointCandidate(after result: ConnectionTestResult) -> Bool {
        switch result {
        case .failed(.unreachable), .failed(.incompatibleResponse), .failed(.http(statusCode: 404)),
             .failed(.server(statusCode: 404)):
            return true
        default:
            return false
        }
    }

    private func connectionAttempt(
        for source: MonitoringSource,
        result: ConnectionTestResult,
        path: AutomaticConnectionPath
    ) -> ConnectionAttempt {
        let route: String
        switch path {
        case .direct:
            route = localized("Direkt")
        case .ssh:
            route = "SSH"
        case .unavailable:
            route = "—"
        }

        let outcome: String
        switch result {
        case .connected:
            outcome = localized("\(providerDisplayName) ist erreichbar. Host- und Servicezugriff funktionieren.")
        case .failed(let failure):
            outcome = refreshMessage(for: failure)
        }
        return ConnectionAttempt(
            endpoint: source.endpoint.absoluteString,
            route: route,
            outcome: outcome
        )
    }

    private func accessMessage(for failure: ProviderAccessFailure) -> String {
        switch failure {
        case .passwordNotAvailable:
            return localized("Das Passwort ist nicht mehr im Schlüsselbund verfügbar.")
        case .passwordAccessFailed:
            return localized("macOS gibt das Passwort im Hintergrund nicht ohne Nachfrage frei. Öffne die Quelle und gib es erneut ein.")
        case .apiKeyNotAvailable:
            return localized("Der API-Schlüssel ist nicht mehr im Schlüsselbund verfügbar.")
        case .apiKeyAccessFailed:
            return localized("macOS gibt den API-Schlüssel im Hintergrund nicht frei. Öffne die Quelle und gib ihn erneut ein.")
        case .clientIdentityNotAvailable:
            return localized("Das Client-Zertifikat ist nicht mehr im Schlüsselbund verfügbar.")
        case .clientIdentityInteractionRequired:
            return localized("macOS benötigt deine Freigabe für den privaten Schlüssel. Öffne die Quelle und starte „Verbindung testen“.")
        case .clientIdentityAccessFailed:
            return localized("Das Client-Zertifikat konnte nicht aus dem Schlüsselbund gelesen werden.")
        case .serverCertificateNotAvailable:
            return localized("Das CA-Zertifikat ist nicht mehr im Schlüsselbund verfügbar.")
        case .serverCertificateAccessFailed:
            return localized("Das CA-Zertifikat konnte nicht aus dem Schlüsselbund gelesen werden.")
        }
    }

    private func message(for result: ConnectionTestResult) -> Activity {
        switch result {
        case .connected:
            return .success(localized("\(providerDisplayName) ist erreichbar. Host- und Servicezugriff funktionieren."))
        case .failed(.authentication):
            return .failure(localized("Die Anmeldung wurde abgelehnt. Prüfe Zugangsdaten oder API-Benutzer."))
        case .failed(.authorization):
            return .failure(localized("Die Anmeldung funktioniert, aber Rechte für Hosts oder Services fehlen."))
        case .failed(.tls):
            return .failure(localized("Die TLS-Verbindung ist fehlgeschlagen. Prüfe Zertifikat und Servernamen."))
        case .failed(.unreachable):
            return .failure(localized("Der Server ist nicht erreichbar."))
        case .failed(.clientCertificateNotAvailable):
            return .failure(localized("Das ausgewählte Client-Zertifikat ist nicht mehr im Schlüsselbund verfügbar."))
        case .failed(.serverCertificateNotAvailable):
            return .failure(localized("Das ausgewählte CA-Zertifikat ist nicht mehr im Schlüsselbund verfügbar."))
        case .failed(.incompatibleResponse):
            return .failure(localized("Der Server antwortet, liefert aber keine kompatible Monitoring-Antwort."))
        case .failed(.server(let code)), .failed(.http(let code)):
            return .failure(localized("Der Server antwortete mit HTTP \(code)."))
        case .failed(.cancelled):
            return .failure(localized("Der Verbindungstest wurde abgebrochen."))
        case .failed(.unsupportedTrustConfiguration):
            return .failure(localized("Diese Zertifikatsoption wird von dieser Version noch nicht unterstützt."))
        case .failed(.invalidConfiguration(let issues)):
            return .failure(validationMessage(issues))
        }
    }

    private func refreshMessage(for failure: ConnectionFailure) -> String {
        switch failure {
        case .authentication:
            return localized("Die Anmeldung wurde abgelehnt.")
        case .authorization:
            return localized("Die API-Rechte reichen nicht zum Lesen des Status.")
        case .tls:
            return localized("Die sichere Verbindung ist fehlgeschlagen.")
        case .unreachable:
            return localized("Der Server ist nicht erreichbar.")
        case .clientCertificateNotAvailable:
            return localized("Das Client-Zertifikat ist nicht mehr verfügbar.")
        case .serverCertificateNotAvailable:
            return localized("Das CA-Zertifikat ist nicht mehr verfügbar.")
        case .incompatibleResponse:
            return localized("Der Server lieferte keine kompatiblen Monitoring-Daten.")
        case .server(let statusCode), .http(let statusCode):
            return localized("Der Server antwortete mit HTTP \(statusCode).")
        case .unsupportedTrustConfiguration:
            return localized("Diese Zertifikatsoption wird noch nicht unterstützt.")
        case .invalidConfiguration:
            return localized("Die Quellenkonfiguration ist ungültig.")
        case .cancelled:
            return localized("Die Aktualisierung wurde abgebrochen.")
        }
    }
}

private enum StoredCredentialScope: Equatable {
    case basic(BasicCredentialScope)
    case apiKey(APIKeyCredentialScope)
}

private func urlInputWithoutEmbeddedCredentials(_ value: String) -> String {
    guard !value.isEmpty else { return value }
    if var components = URLComponents(string: value),
       components.user != nil || components.password != nil {
        components.user = nil
        components.password = nil
        return components.string ?? ""
    }
    guard !value.contains("?"),
          !value.contains("#"),
          let separator = value.lastIndex(of: "@") else {
        return value
    }
    return String(value[value.index(after: separator)...])
}
