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
        case refreshing
        case current
        case failed(String)
    }

    @Published var name = ""
    @Published var endpoint = ""
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
    @Published private(set) var hasConfiguredSource = false
    @Published private(set) var isTestingConnection = false
    @Published private(set) var snapshot: MonitoringSnapshot?
    @Published private(set) var refreshState = RefreshState.notConfigured

    private var sourceID = UUID()
    private var loadedSource: MonitoringSource?
    private let sourceStore: SourceStore?
    private let providerRegistry = ProviderRegistry.builtIn()
    private let passwordVault = KeychainPasswordVault()
    private let identityCatalog = KeychainIdentityCatalog()
    private var hasStarted = false
    private var refreshLoopTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    var actionableIssues: [MonitoringIssue] {
        snapshot?.actionableIssues ?? []
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

    var coveredIssues: [MonitoringIssue] {
        snapshot?.issues.filter { !$0.requiresAttention } ?? []
    }

    var menuBarSymbol: String {
        if !hasConfiguredSource { return "exclamationmark.triangle" }
        if case .failed = refreshState { return "wifi.exclamationmark" }
        switch snapshot?.highestAttentionSeverity {
        case .critical:
            return "exclamationmark.octagon.fill"
        case .unknown:
            return "questionmark.diamond.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case nil:
            return refreshState == .refreshing ? "arrow.clockwise" : "checkmark.circle"
        }
    }

    var deletionMessage: String {
        guard let loadedSource else { return "Die Quellenkonfiguration wird von diesem Mac entfernt." }
        switch loadedSource.authentication {
        case .basic:
            return "Die Konfiguration und das zugehörige Basic-Passwort werden von diesem Mac entfernt."
        case .clientCertificate:
            return "Die Konfiguration wird entfernt. Das Client-Zertifikat bleibt im macOS-Schlüsselbund."
        }
    }

    init() {
        selectedProviderID = providerRegistry.descriptors.first?.id ?? ProviderID(rawValue: "")
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "io.github.yunabraska.issuelight"
        if let fileURL = try? SourceStore.defaultFileURL(bundleIdentifier: bundleIdentifier) {
            sourceStore = SourceStore(fileURL: fileURL)
        } else {
            sourceStore = nil
            activity = .failure("Der Speicherort für die Quellen konnte nicht geöffnet werden.")
        }
        Task { [weak self] in
            await self?.start()
        }
    }

    deinit {
        refreshTask?.cancel()
        refreshLoopTask?.cancel()
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await load()
        if hasConfiguredSource {
            startRefreshLoop()
            refresh()
        }
    }

    func load() async {
        guard let sourceStore else { return }
        activity = .working("Gespeicherte Quellen werden geladen …")
        do {
            let sources = try await sourceStore.load()
            hasConfiguredSource = !sources.isEmpty
            if let source = sources.first {
                loadedSource = source
                apply(source)
                if case .basic = source.authentication {
                    let scope = try BasicCredentialScope(source: source)
                    hasStoredBasicPassword = try await passwordVault.password(for: scope) != nil
                } else {
                    hasStoredBasicPassword = false
                }
            } else {
                loadedSource = nil
                sourceID = UUID()
                refreshState = .notConfigured
            }
        } catch {
            activity = .failure("Die gespeicherte Quelle konnte nicht geladen werden: \(error.localizedDescription)")
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

    func testConnection() async {
        guard let source = sourceFromForm() else { return }
        guard let provider = providerRegistry.provider(for: source.providerID) else {
            activity = .failure("Der konfigurierte Monitoring-Typ ist nicht verfügbar.")
            return
        }
        isTestingConnection = true
        defer { isTestingConnection = false }
        activity = .working("Verbindung wird geprüft …")

        let result: ConnectionTestResult
        switch source.authentication {
        case .basic:
            do {
                guard let resolvedPassword = try await basicPassword(for: source) else {
                    activity = .failure("Gib ein Passwort ein.")
                    return
                }
                result = await provider.testConnection(to: source, credential: .password(resolvedPassword))
            } catch {
                activity = .failure("Das Passwort konnte nicht aus dem Schlüsselbund gelesen werden.")
                return
            }
        case .clientCertificate(let identityID):
            do {
                let identity = try await identityCatalog.identity(id: identityID)
                guard let identity else {
                    activity = .failure("Das Client-Zertifikat ist nicht mehr im Schlüsselbund verfügbar.")
                    return
                }
                result = await provider.testConnection(to: source, credential: .clientIdentity(identity))
            } catch {
                activity = .failure("Das Client-Zertifikat konnte nicht aus dem Schlüsselbund gelesen werden.")
                return
            }
        }

        activity = message(for: result)
    }

    func refresh() {
        guard let source = loadedSource, source.isEnabled else {
            refreshTask?.cancel()
            snapshot = nil
            refreshState = .notConfigured
            return
        }

        refreshTask?.cancel()
        refreshState = .refreshing
        refreshTask = Task { [weak self] in
            await self?.performRefresh(source: source)
        }
    }

    func save() async {
        guard let source = sourceFromForm(), let sourceStore else { return }
        activity = .working("Quelle wird gespeichert …")

        do {
            let previousScope = try basicCredentialScope(for: loadedSource)
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
            do {
                _ = try await sourceStore.upsert(source)
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
            if let previousScope, previousScope != newScope {
                try await passwordVault.deletePassword(for: previousScope)
            }
            loadedSource = source
            hasConfiguredSource = true
            hasStoredBasicPassword = newScope != nil
            password = ""
            activity = .success("Quelle gespeichert. Geheimnisse bleiben im macOS-Schlüsselbund.")
            startRefreshLoop()
            refresh()
        } catch {
            activity = .failure("Die Quelle konnte nicht gespeichert werden: \(error.localizedDescription)")
        }
    }

    func deleteSource() async {
        guard let source = loadedSource, let sourceStore else { return }
        activity = .working("Quelle wird entfernt …")

        do {
            _ = try await sourceStore.remove(id: source.id)
        } catch {
            activity = .failure("Die Quelle konnte nicht entfernt werden: \(error.localizedDescription)")
            return
        }

        refreshTask?.cancel()
        refreshLoopTask?.cancel()
        loadedSource = nil
        sourceID = UUID()
        name = ""
        endpoint = ""
        authenticationChoice = .basic
        username = ""
        password = ""
        hasStoredBasicPassword = false
        selectedIdentityID = ""
        verifiesServerCertificate = true
        hasConfiguredSource = false
        snapshot = nil
        refreshState = .notConfigured

        guard case .basic = source.authentication else {
            activity = .success("Quelle entfernt. Das Client-Zertifikat bleibt im macOS-Schlüsselbund.")
            return
        }
        do {
            try await passwordVault.deletePassword(for: BasicCredentialScope(source: source))
            activity = .success("Quelle und gespeichertes Basic-Passwort wurden entfernt.")
        } catch {
            activity = .failure(
                "Die Quelle wurde entfernt, aber das Basic-Passwort konnte nicht aus dem Schlüsselbund gelöscht werden."
            )
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
        if var existingSource = loadedSource {
            existingSource.name = name
            existingSource.providerID = selectedProviderID
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
        guard requestedScope == (try basicCredentialScope(for: loadedSource)) else {
            return nil
        }
        return try await passwordVault.password(for: requestedScope)
    }

    private func startRefreshLoop() {
        refreshLoopTask?.cancel()
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
        guard let provider = providerRegistry.provider(for: source.providerID) else {
            refreshState = .failed("Der konfigurierte Monitoring-Typ ist nicht verfügbar.")
            return
        }
        let result: SnapshotLoadResult
        switch source.authentication {
        case .basic:
            do {
                let password = try await passwordVault.password(for: BasicCredentialScope(source: source))
                guard let password else {
                    refreshState = .failed("Das Passwort ist nicht mehr im Schlüsselbund verfügbar.")
                    return
                }
                result = await provider.loadSnapshot(from: source, credential: .password(password))
            } catch {
                guard !Task.isCancelled else { return }
                refreshState = .failed("Das Passwort konnte nicht aus dem Schlüsselbund gelesen werden.")
                return
            }
        case .clientCertificate(let identityID):
            do {
                let identity = try await identityCatalog.identity(id: identityID)
                guard let identity else {
                    refreshState = .failed("Das Client-Zertifikat ist nicht mehr im Schlüsselbund verfügbar.")
                    return
                }
                result = await provider.loadSnapshot(from: source, credential: .clientIdentity(identity))
            } catch {
                guard !Task.isCancelled else { return }
                refreshState = .failed("Das Client-Zertifikat konnte nicht aus dem Schlüsselbund gelesen werden.")
                return
            }
        }

        guard !Task.isCancelled else { return }
        switch result {
        case .loaded(let loadedSnapshot):
            snapshot = loadedSnapshot
            refreshState = .current
        case .failed(.cancelled):
            return
        case .failed(let failure):
            refreshState = .failed(refreshMessage(for: failure))
        }
    }

    private func apply(_ source: MonitoringSource) {
        sourceID = source.id
        name = source.name
        endpoint = source.endpoint.absoluteString
        selectedProviderID = source.providerID
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
