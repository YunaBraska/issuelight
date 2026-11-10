import Foundation
import IssueLightCore
import Security

@MainActor
final class IssueLightModel: ObservableObject {
    enum AuthenticationChoice: String, CaseIterable, Identifiable {
        case basic = "Benutzername & Passwort"
        case clientCertificate = "Client-Zertifikat"

        var id: String { rawValue }

        var method: AuthenticationMethod {
            switch self {
            case .basic:
                return .basic
            case .clientCertificate:
                return .clientCertificate
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

    @Published var name = ""
    @Published var endpoint = ""
    @Published var isSourceEnabled = true
    @Published var selectedProviderID: ProviderID {
        didSet {
            guard selectedProviderID != oldValue else { return }
            synchronizeProviderCapabilities()
        }
    }
    @Published var authenticationChoice = AuthenticationChoice.basic
    @Published var username = ""
    @Published var password = ""
    @Published var selectedIdentityID = ""
    @Published var identities: [ClientIdentityDescriptor] = []
    @Published private(set) var identityLoadError: String?
    @Published private(set) var hasStoredBasicPassword = false
    @Published var verifiesServerCertificate = true
    @Published private(set) var activity = Activity.idle
    @Published private(set) var isTestingConnection = false
    @Published private(set) var sources: [MonitoringSource] = []
    @Published private(set) var selectedSourceID: UUID?
    @Published private(set) var snapshots: [UUID: MonitoringSnapshot] = [:]
    @Published private(set) var refreshStates: [UUID: RefreshState] = [:]

    private var sourceID = UUID()
    private let sourceStore: SourceStore?
    private let providerRegistry: ProviderRegistry
    private let passwordVault: KeychainPasswordVault
    private let identityCatalog: KeychainIdentityCatalog
    private var hasStarted = false
    private var refreshLoopTask: Task<Void, Never>?
    private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    private var connectionTestID: UUID?

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

    var isCreatingSource: Bool {
        selectedSourceID == nil
    }

    var hasUnsavedChanges: Bool {
        if !password.isEmpty { return true }
        guard let selectedSource else {
            return !name.isEmpty
                || !endpoint.isEmpty
                || !username.isEmpty
                || !selectedIdentityID.isEmpty
                || !isSourceEnabled
        }

        let authentication: AuthenticationConfiguration
        switch authenticationChoice {
        case .basic:
            authentication = .basic(username: username)
        case .clientCertificate:
            authentication = .clientCertificate(identityID: selectedIdentityID)
        }
        return name != selectedSource.name
            || endpoint != selectedSource.endpoint.absoluteString
            || isSourceEnabled != selectedSource.isEnabled
            || selectedProviderID != selectedSource.providerID
            || authentication != selectedSource.authentication
            || verifiesServerCertificate != selectedSource.serverTrust.verifiesServerCertificate
    }

    var providers: [ProviderDescriptor] {
        providerRegistry.descriptors
    }

    var providerDisplayName: String {
        providerRegistry.provider(for: selectedProviderID)?.descriptor.displayName
            ?? selectedProviderID.rawValue
    }

    var authenticationChoices: [AuthenticationChoice] {
        guard let methods = providerRegistry
            .provider(for: selectedProviderID)?
            .descriptor.capabilities.authenticationMethods else {
            return []
        }
        return AuthenticationChoice.allCases.filter { methods.contains($0.method) }
    }

    var canDisableServerCertificateVerification: Bool {
        providerRegistry
            .provider(for: selectedProviderID)?
            .descriptor.capabilities.serverTrustMethods.contains(.disabled) == true
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

    var latestSuccessfulRefresh: Date? {
        activeSnapshots.map(\.observedAt).max()
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
            return .failed("\(failures.count) Quellen konnten nicht aktualisiert werden.")
        }
        if enabledSources.contains(where: { refreshStates[$0.id] == .refreshing }) {
            return .refreshing
        }
        if enabledSources.allSatisfy({ refreshStates[$0.id] == .current }) {
            return .current
        }
        return .refreshing
    }

    var menuBarSymbol: String {
        if !hasConfiguredSource { return "exclamationmark.triangle" }
        if !hasEnabledSource { return "pause.circle" }
        switch actionableIssues.map(\.severity).max() {
        case .critical:
            return "exclamationmark.octagon.fill"
        case .unknown:
            return "questionmark.diamond.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case nil:
            if case .failed = refreshState { return "wifi.exclamationmark" }
            return refreshState == .refreshing ? "arrow.clockwise" : "checkmark.circle"
        }
    }

    var deletionMessage: String {
        guard let selectedSource else { return "Die Quellenkonfiguration wird von diesem Mac entfernt." }
        switch selectedSource.authentication {
        case .basic:
            return "Die Konfiguration und das zugehörige Basic-Passwort werden von diesem Mac entfernt."
        case .clientCertificate:
            return "Die Konfiguration wird entfernt. Das Client-Zertifikat bleibt im macOS-Schlüsselbund."
        }
    }

    convenience init() {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "io.github.yunabraska.issuelight"
        let fileURL = try? SourceStore.defaultFileURL(bundleIdentifier: bundleIdentifier)
        let store = fileURL.map(SourceStore.init(fileURL:))
        self.init(
            sourceStore: store,
            providerRegistry: .builtIn(),
            passwordVault: KeychainPasswordVault(),
            identityCatalog: KeychainIdentityCatalog(),
            startsAutomatically: true
        )
        if store == nil {
            activity = .failure("Der Speicherort für die Quellen konnte nicht geöffnet werden.")
        }
    }

    init(
        sourceStore: SourceStore?,
        providerRegistry: ProviderRegistry,
        passwordVault: KeychainPasswordVault,
        identityCatalog: KeychainIdentityCatalog,
        startsAutomatically: Bool
    ) {
        self.sourceStore = sourceStore
        self.providerRegistry = providerRegistry
        self.passwordVault = passwordVault
        self.identityCatalog = identityCatalog
        selectedProviderID = providerRegistry.descriptors.first?.id ?? ProviderID(rawValue: "")
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
        activity = .working("Gespeicherte Quellen werden geladen …")
        do {
            sources = try await sourceStore.load()
            for source in sources where !source.isEnabled {
                refreshStates[source.id] = .disabled
            }
            if let firstSource = sources.first {
                await selectSource(id: firstSource.id)
            } else {
                beginAddingSource()
            }
        } catch {
            activity = .failure("Die gespeicherten Quellen konnten nicht geladen werden: \(error.localizedDescription)")
            return
        }

        do {
            identities = try await identityCatalog.identities()
            identityLoadError = nil
            activity = .idle
        } catch {
            identities = []
            let message = "Client-Zertifikate konnten nicht aus dem Schlüsselbund gelesen werden."
            identityLoadError = message
            activity = authenticationChoice == .clientCertificate
                ? .failure(message)
                : .idle
        }
    }

    func selectSource(id: UUID) async {
        guard let source = sources.first(where: { $0.id == id }) else { return }
        connectionTestID = nil
        isTestingConnection = false
        selectedSourceID = source.id
        apply(source)
        password = ""
        do {
            let hasPassword: Bool
            if case .basic = source.authentication {
                hasPassword = try await passwordVault.password(for: BasicCredentialScope(source: source)) != nil
            } else {
                hasPassword = false
            }
            guard selectedSourceID == source.id else { return }
            hasStoredBasicPassword = hasPassword
            activity = .idle
        } catch {
            guard selectedSourceID == source.id else { return }
            hasStoredBasicPassword = false
            activity = .failure("Das gespeicherte Passwort konnte nicht aus dem Schlüsselbund gelesen werden.")
        }
    }

    func beginAddingSource() {
        connectionTestID = nil
        isTestingConnection = false
        selectedSourceID = nil
        sourceID = UUID()
        name = ""
        endpoint = ""
        isSourceEnabled = true
        selectedProviderID = providerRegistry.descriptors.first?.id ?? ProviderID(rawValue: "")
        authenticationChoice = authenticationChoices.first ?? .basic
        username = ""
        password = ""
        selectedIdentityID = ""
        hasStoredBasicPassword = false
        verifiesServerCertificate = true
        activity = .idle
    }

    func testConnection() async {
        guard let source = sourceFromForm() else { return }
        guard let provider = providerRegistry.provider(for: source.providerID) else {
            activity = .failure("Der konfigurierte Monitoring-Typ ist nicht verfügbar.")
            return
        }
        connectionTestID = source.id
        isTestingConnection = true
        activity = .working("Verbindung wird geprüft …")

        let result: ConnectionTestResult
        switch source.authentication {
        case .basic:
            do {
                guard let resolvedPassword = try await basicPassword(for: source) else {
                    guard connectionTestID == source.id else { return }
                    isTestingConnection = false
                    activity = .failure("Gib ein Passwort ein.")
                    return
                }
                result = await provider.testConnection(to: source, credential: .password(resolvedPassword))
            } catch {
                guard connectionTestID == source.id else { return }
                isTestingConnection = false
                activity = .failure("Das Passwort konnte nicht aus dem Schlüsselbund gelesen werden.")
                return
            }
        case .clientCertificate(let identityID):
            do {
                let identity = try await identityCatalog.identity(id: identityID)
                guard let identity else {
                    guard connectionTestID == source.id else { return }
                    isTestingConnection = false
                    activity = .failure("Das Client-Zertifikat ist nicht mehr im Schlüsselbund verfügbar.")
                    return
                }
                result = await provider.testConnection(to: source, credential: .clientIdentity(identity))
            } catch {
                guard connectionTestID == source.id else { return }
                isTestingConnection = false
                activity = .failure("Das Client-Zertifikat konnte nicht aus dem Schlüsselbund gelesen werden.")
                return
            }
        }

        guard connectionTestID == source.id else { return }
        connectionTestID = nil
        isTestingConnection = false
        activity = message(for: result)
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
        guard let source = sourceFromForm(), let sourceStore else { return }
        activity = .working("Quelle wird gespeichert …")
        let previousSource = selectedSource

        do {
            let previousScope = try basicCredentialScope(for: previousSource)
            let newScope = try basicCredentialScope(for: source)
            let previousPassword: String?
            if let previousScope, previousScope == newScope {
                previousPassword = try await passwordVault.password(for: previousScope)
            } else {
                previousPassword = nil
            }
            var storedNewPassword = false
            switch source.authentication {
            case .basic:
                guard let newScope else {
                    activity = .failure("Die Zugangsdaten sind ungültig.")
                    return
                }
                if password.isEmpty {
                    guard previousPassword != nil else {
                        activity = .failure("Gib ein Passwort ein.")
                        return
                    }
                } else {
                    try await passwordVault.store(password, for: newScope)
                    storedNewPassword = true
                }
            case .clientCertificate:
                break
            }

            let persistedSources: [MonitoringSource]
            do {
                persistedSources = try await sourceStore.upsert(source)
            } catch {
                if storedNewPassword, let newScope {
                    if newScope == previousScope, let previousPassword {
                        try? await passwordVault.store(previousPassword, for: newScope)
                    } else {
                        try? await passwordVault.deletePassword(for: newScope)
                    }
                }
                throw error
            }

            let connectionChanged = previousSource.map {
                $0.providerID != source.providerID
                    || $0.endpoint != source.endpoint
                    || $0.authentication != source.authentication
                    || $0.serverTrust != source.serverTrust
            } ?? true
            refreshTasks[source.id]?.cancel()
            refreshTasks[source.id] = nil
            if connectionChanged {
                snapshots[source.id] = nil
            }
            sources = persistedSources
            selectedSourceID = source.id
            sourceID = source.id
            password = ""
            hasStoredBasicPassword = newScope != nil

            var cleanupFailed = false
            if let previousScope, previousScope != newScope {
                do {
                    try await passwordVault.deletePassword(for: previousScope)
                } catch {
                    cleanupFailed = true
                }
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
            activity = cleanupFailed
                ? .failure("Quelle gespeichert, aber das alte Basic-Passwort konnte nicht entfernt werden.")
                : .success("Quelle gespeichert. Geheimnisse bleiben im macOS-Schlüsselbund.")
        } catch {
            activity = .failure("Die Quelle konnte nicht gespeichert werden: \(error.localizedDescription)")
        }
    }

    func deleteSource() async {
        guard let source = selectedSource, let sourceStore else { return }
        activity = .working("Quelle wird entfernt …")
        let removedIndex = sources.firstIndex(where: { $0.id == source.id }) ?? 0

        let persistedSources: [MonitoringSource]
        do {
            persistedSources = try await sourceStore.remove(id: source.id)
        } catch {
            activity = .failure("Die Quelle konnte nicht entfernt werden: \(error.localizedDescription)")
            return
        }

        refreshTasks[source.id]?.cancel()
        refreshTasks[source.id] = nil
        snapshots[source.id] = nil
        refreshStates[source.id] = nil
        sources = persistedSources
        if !hasEnabledSource {
            refreshLoopTask?.cancel()
            refreshLoopTask = nil
        }

        var cleanupFailed = false
        if case .basic = source.authentication {
            do {
                try await passwordVault.deletePassword(for: BasicCredentialScope(source: source))
            } catch {
                cleanupFailed = true
            }
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
            activity = .failure("Die Quelle wurde entfernt, aber das Basic-Passwort konnte nicht aus dem Schlüsselbund gelöscht werden.")
        } else if case .clientCertificate = source.authentication {
            activity = .success("Quelle entfernt. Das Client-Zertifikat bleibt im macOS-Schlüsselbund.")
        } else {
            activity = .success("Quelle und gespeichertes Basic-Passwort wurden entfernt.")
        }
    }

    func importIdentity(at fileURL: URL, password: String) async -> Bool {
        activity = .working("Zertifikat wird importiert …")
        do {
            let descriptor = try await identityCatalog.importPKCS12(at: fileURL, password: password)
            identities = try await identityCatalog.identities()
            identityLoadError = nil
            selectedIdentityID = descriptor.id
            authenticationChoice = .clientCertificate
            activity = .success("„\(descriptor.displayName)“ wurde in den Schlüsselbund importiert.")
            return true
        } catch {
            activity = .failure("Das PKCS#12-Zertifikat konnte nicht importiert werden. Datei oder Passwort ist ungültig.")
            return false
        }
    }

    func sourceName(for sourceID: UUID) -> String {
        sources.first(where: { $0.id == sourceID })?.name ?? "Unbekannte Quelle"
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

    private func sourceFromForm() -> MonitoringSource? {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            activity = .failure("Die Serveradresse ist keine gültige URL.")
            return nil
        }

        let authentication: AuthenticationConfiguration
        switch authenticationChoice {
        case .basic:
            authentication = .basic(username: username)
        case .clientCertificate:
            authentication = .clientCertificate(identityID: selectedIdentityID)
        }

        var source: MonitoringSource
        if var existingSource = selectedSource {
            existingSource.name = name
            existingSource.providerID = selectedProviderID
            existingSource.isEnabled = isSourceEnabled
            existingSource.authentication = authentication
            if existingSource.updateEndpoint(url) {
                verifiesServerCertificate = true
            }
            existingSource.setServerCertificateVerification(enabled: verifiesServerCertificate)
            source = existingSource
        } else {
            source = MonitoringSource(
                id: sourceID,
                name: name,
                providerID: selectedProviderID,
                endpoint: url,
                isEnabled: isSourceEnabled,
                authentication: authentication,
                serverTrust: verifiesServerCertificate ? .system : .disabled
            )
        }
        guard let provider = providerRegistry.provider(for: selectedProviderID) else {
            activity = .failure("Der ausgewählte Monitoring-Typ ist nicht verfügbar.")
            return nil
        }
        let issues = provider.validate(source)
        guard issues.isEmpty else {
            activity = .failure(validationMessage(issues))
            return nil
        }
        return source
    }

    private func basicCredentialScope(for source: MonitoringSource?) throws -> BasicCredentialScope? {
        guard let source, case .basic = source.authentication else { return nil }
        return try BasicCredentialScope(source: source)
    }

    private func basicPassword(for source: MonitoringSource) async throws -> String? {
        if !password.isEmpty {
            return password
        }
        let requestedScope = try BasicCredentialScope(source: source)
        guard requestedScope == (try basicCredentialScope(for: selectedSource)) else {
            return nil
        }
        return try await passwordVault.password(for: requestedScope)
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
            refreshStates[source.id] = .failed("Der konfigurierte Monitoring-Typ ist nicht verfügbar.")
            return
        }
        let result: SnapshotLoadResult
        switch source.authentication {
        case .basic:
            do {
                let password = try await passwordVault.password(for: BasicCredentialScope(source: source))
                guard let password else {
                    guard !Task.isCancelled else { return }
                    refreshStates[source.id] = .failed("Das Passwort ist nicht mehr im Schlüsselbund verfügbar.")
                    return
                }
                result = await provider.loadSnapshot(from: source, credential: .password(password))
            } catch {
                guard !Task.isCancelled else { return }
                refreshStates[source.id] = .failed("Das Passwort konnte nicht aus dem Schlüsselbund gelesen werden.")
                return
            }
        case .clientCertificate(let identityID):
            do {
                let identity = try await identityCatalog.identity(id: identityID)
                guard let identity else {
                    guard !Task.isCancelled else { return }
                    refreshStates[source.id] = .failed("Das Client-Zertifikat ist nicht mehr im Schlüsselbund verfügbar.")
                    return
                }
                result = await provider.loadSnapshot(from: source, credential: .clientIdentity(identity))
            } catch {
                guard !Task.isCancelled else { return }
                refreshStates[source.id] = .failed("Das Client-Zertifikat konnte nicht aus dem Schlüsselbund gelesen werden.")
                return
            }
        }

        guard !Task.isCancelled else { return }
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
        sourceID = source.id
        name = source.name
        endpoint = source.endpoint.absoluteString
        isSourceEnabled = source.isEnabled
        selectedProviderID = source.providerID
        username = ""
        selectedIdentityID = ""
        verifiesServerCertificate = source.serverTrust.verifiesServerCertificate
        switch source.authentication {
        case .basic(let storedUsername):
            authenticationChoice = .basic
            username = storedUsername
        case .clientCertificate(let identityID):
            authenticationChoice = .clientCertificate
            selectedIdentityID = identityID
        }
    }

    private func validationMessage(_ issues: [SourceValidationIssue]) -> String {
        if issues.contains(.emptyName) { return "Gib der Quelle einen Namen." }
        if issues.contains(.missingHost) { return "Die Serveradresse benötigt einen Hostnamen." }
        if issues.contains(.emptyUsername) { return "Gib einen Benutzernamen ein." }
        if issues.contains(.invalidUsername) { return "Der Benutzername darf keinen Doppelpunkt enthalten." }
        if issues.contains(.missingClientIdentity) { return "Wähle ein Client-Zertifikat aus dem Schlüsselbund." }
        if issues.contains(where: {
            if case .unsupportedAuthentication = $0 { return true }
            return false
        }) {
            return "Diese Authentifizierung wird vom ausgewählten Monitoring-Typ nicht unterstützt."
        }
        if issues.contains(where: {
            if case .unsupportedPath = $0 { return true }
            return false
        }) {
            return "Verwende nur eine vom ausgewählten Monitoring-Typ unterstützte Serveradresse."
        }
        if issues.contains(where: {
            if case .unsupportedScheme = $0 { return true }
            return false
        }) {
            return "Der ausgewählte Monitoring-Typ akzeptiert diese Serveradresse nicht."
        }
        return "Die Quellenkonfiguration ist ungültig."
    }

    private func synchronizeProviderCapabilities() {
        let choices = authenticationChoices
        if !choices.contains(authenticationChoice), let first = choices.first {
            authenticationChoice = first
        }
        if !canDisableServerCertificateVerification {
            verifiesServerCertificate = true
        }
    }

    private func message(for result: ConnectionTestResult) -> Activity {
        switch result {
        case .connected:
            return .success("\(providerDisplayName) ist erreichbar. Host- und Servicezugriff funktionieren.")
        case .failed(.authentication):
            return .failure("Die Anmeldung wurde abgelehnt. Prüfe Zugangsdaten oder API-Benutzer.")
        case .failed(.authorization):
            return .failure("Die Anmeldung funktioniert, aber Rechte für Hosts oder Services fehlen.")
        case .failed(.tls):
            return .failure("Die TLS-Verbindung ist fehlgeschlagen. Prüfe Zertifikat und Servernamen.")
        case .failed(.unreachable):
            return .failure("Der Server ist nicht erreichbar.")
        case .failed(.clientCertificateNotAvailable):
            return .failure("Das ausgewählte Client-Zertifikat ist nicht mehr im Schlüsselbund verfügbar.")
        case .failed(.incompatibleResponse):
            return .failure("Der Server antwortet, liefert aber keine kompatible Monitoring-Antwort.")
        case .failed(.server(let code)), .failed(.http(let code)):
            return .failure("Der Server antwortete mit HTTP \(code).")
        case .failed(.cancelled):
            return .failure("Der Verbindungstest wurde abgebrochen.")
        case .failed(.unsupportedTrustConfiguration):
            return .failure("Diese Zertifikatsoption wird von dieser Version noch nicht unterstützt.")
        case .failed(.invalidConfiguration(let issues)):
            return .failure(validationMessage(issues))
        }
    }

    private func refreshMessage(for failure: ConnectionFailure) -> String {
        switch failure {
        case .authentication:
            return "Die Anmeldung wurde abgelehnt."
        case .authorization:
            return "Die API-Rechte reichen nicht zum Lesen des Status."
        case .tls:
            return "Die sichere Verbindung ist fehlgeschlagen."
        case .unreachable:
            return "Der Server ist nicht erreichbar."
        case .clientCertificateNotAvailable:
            return "Das Client-Zertifikat ist nicht mehr verfügbar."
        case .incompatibleResponse:
            return "Der Server lieferte keine kompatiblen Monitoring-Daten."
        case .server(let statusCode), .http(let statusCode):
            return "Der Server antwortete mit HTTP \(statusCode)."
        case .unsupportedTrustConfiguration:
            return "Diese Zertifikatsoption wird noch nicht unterstützt."
        case .invalidConfiguration:
            return "Die Quellenkonfiguration ist ungültig."
        case .cancelled:
            return "Die Aktualisierung wurde abgebrochen."
        }
    }
}
