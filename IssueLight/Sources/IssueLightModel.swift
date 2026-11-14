import Foundation
import IssueLightCore
import Security

@MainActor
final class IssueLightModel: ObservableObject {
    enum AuthenticationChoice: String, CaseIterable, Identifiable {
        case basic
        case clientCertificate

        var id: String { rawValue }

        func displayName(locale: Locale) -> String {
            switch self {
            case .basic:
                return AppLocalization.string("Benutzername & Passwort", locale: locale)
            case .clientCertificate:
                return AppLocalization.string("Client-Zertifikat", locale: locale)
            }
        }

        var method: AuthenticationMethod {
            switch self {
            case .basic:
                return .basic
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
                return AppLocalization.string("Prüfung deaktiviert", locale: locale)
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

    struct ActionFeedback: Identifiable, Equatable {
        let id = UUID()
        let succeeded: Bool
        let message: String
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
    @Published var serverTrustChoice = ServerTrustChoice.system
    @Published private(set) var selectedServerCertificate: ServerCertificateDescriptor?
    @Published private(set) var pinnedServerCertificateSHA256 = ""
    @Published private(set) var activity = Activity.idle
    @Published private(set) var isTestingConnection = false
    @Published private(set) var sources: [MonitoringSource] = []
    @Published private(set) var selectedSourceID: UUID?
    @Published private(set) var snapshots: [UUID: MonitoringSnapshot] = [:]
    @Published private(set) var refreshStates: [UUID: RefreshState] = [:]
    @Published private(set) var activeActionIssueIDs: Set<String> = []
    @Published private(set) var actionFeedback: ActionFeedback?

    private var sourceID = UUID()
    private let sourceStore: SourceStore?
    private let providerRegistry: ProviderRegistry
    private let passwordVault: KeychainPasswordVault
    private let identityCatalog: KeychainIdentityCatalog
    private let certificateCatalog: KeychainServerCertificateCatalog
    private let accessResolver: ProviderAccessResolver
    private var hasStarted = false
    private var refreshLoopTask: Task<Void, Never>?
    private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    private var connectionTestID: UUID?
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
                || !pinnedServerCertificateSHA256.isEmpty
                || !isSourceEnabled
        }

        let authentication: AuthenticationConfiguration
        switch authenticationChoice {
        case .basic:
            authentication = .basic(username: username)
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
            || endpoint != selectedSource.endpoint.absoluteString
            || isSourceEnabled != selectedSource.isEnabled
            || selectedProviderID != selectedSource.providerID
            || authentication != selectedSource.authentication
            || serverTrust != selectedSource.serverTrust
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

    var serverTrustChoices: [ServerTrustChoice] {
        guard let methods = providerRegistry
            .provider(for: selectedProviderID)?
            .descriptor.capabilities.serverTrustMethods else {
            return []
        }
        return ServerTrustChoice.allCases.filter { methods.contains($0.method) }
    }

    func supportedActions(for issue: MonitoringIssue) -> Set<MonitoringActionKind> {
        guard let source = sources.first(where: { $0.id == issue.sourceID }) else { return [] }
        return providerRegistry.provider(for: source.providerID)?.descriptor.capabilities.actions ?? []
    }

    func dismissActionFeedback() {
        actionFeedback = nil
    }

    func perform(_ action: MonitoringAction, on issue: MonitoringIssue) async {
        guard !activeActionIssueIDs.contains(issue.id) else { return }
        guard let source = sources.first(where: { $0.id == issue.sourceID }), source.isEnabled else {
            actionFeedback = ActionFeedback(
                succeeded: false,
                message: localized("Die zugehörige Quelle ist nicht verfügbar.")
            )
            return
        }
        guard let provider = providerRegistry.provider(for: source.providerID),
              provider.descriptor.capabilities.actions.contains(action.kind) else {
            actionFeedback = ActionFeedback(
                succeeded: false,
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
            actionFeedback = ActionFeedback(succeeded: false, message: accessMessage(for: failure))
            return
        }

        let result = await provider.perform(action, on: issue, from: source, access: access)
        switch result {
        case .completed:
            actionFeedback = ActionFeedback(
                succeeded: true,
                message: localized("Die Aktion wurde von Icinga 2 bestätigt.")
            )
            if let refreshTask = refresh(sourceID: source.id) {
                await refreshTask.value
            }
        case .rejected(let message):
            actionFeedback = ActionFeedback(succeeded: false, message: message)
        case .failed(let failure):
            actionFeedback = ActionFeedback(succeeded: false, message: refreshMessage(for: failure))
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
        guard let selectedSource else {
            return localized("Die Quellenkonfiguration wird von diesem Mac entfernt.")
        }
        let credentialMessage: String
        switch selectedSource.authentication {
        case .basic:
            credentialMessage = localized("Die Konfiguration und das zugehörige Basic-Passwort werden von diesem Mac entfernt.")
        case .clientCertificate:
            credentialMessage = localized("Die Konfiguration wird entfernt. Das Client-Zertifikat bleibt im macOS-Schlüsselbund.")
        }
        if case .customCertificate = selectedSource.serverTrust {
            return localized("\(credentialMessage) Ein von IssueLight importiertes CA-Zertifikat wird nur entfernt, wenn keine andere Quelle es verwendet. Vorhandene fremde Zertifikate bleiben unberührt.")
        }
        return credentialMessage
    }

    convenience init(localizationLocale: Locale = .current) {
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
        startsAutomatically: Bool,
        localizationLocale: Locale = .current
    ) {
        self.sourceStore = sourceStore
        self.providerRegistry = providerRegistry
        self.passwordVault = passwordVault
        self.identityCatalog = identityCatalog
        self.certificateCatalog = certificateCatalog
        self.localizationLocale = localizationLocale
        accessResolver = ProviderAccessResolver(
            passwordVault: passwordVault,
            identityCatalog: identityCatalog,
            certificateCatalog: certificateCatalog
        )
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
        password = ""
        do {
            let hasPassword: Bool
            if case .basic = source.authentication {
                hasPassword = try await passwordVault.containsPassword(for: BasicCredentialScope(source: source))
            } else {
                hasPassword = false
            }
            guard selectedSourceID == source.id else { return }
            hasStoredBasicPassword = hasPassword
        } catch KeychainPasswordVaultError.interactionNotAllowed {
            guard selectedSourceID == source.id else { return }
            hasStoredBasicPassword = false
            activity = .failure(
                localized("macOS gibt diesen Schlüsselbund-Eintrag nicht ohne Nachfrage frei. Gib das Passwort in der Quelle erneut ein.")
            )
        } catch {
            guard selectedSourceID == source.id else { return }
            hasStoredBasicPassword = false
            activity = .failure(localized("Das gespeicherte Passwort konnte nicht aus dem Schlüsselbund gelesen werden."))
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
        serverTrustChoice = .system
        selectedServerCertificate = nil
        pinnedServerCertificateSHA256 = ""
        activity = .idle
    }

    func testConnection() async {
        guard let source = sourceFromForm() else { return }
        guard let provider = providerRegistry.provider(for: source.providerID) else {
            activity = .failure(localized("Der konfigurierte Monitoring-Typ ist nicht verfügbar."))
            return
        }
        connectionTestID = source.id
        isTestingConnection = true
        activity = .working(localized("Verbindung wird geprüft …"))

        var allowsStoredPassword = true
        if case .basic = source.authentication {
            let requestedScope = try? BasicCredentialScope(source: source)
            let selectedScope = try? basicCredentialScope(for: selectedSource)
            allowsStoredPassword = requestedScope != nil && requestedScope == selectedScope
            if password.isEmpty && !allowsStoredPassword {
                connectionTestID = nil
                isTestingConnection = false
                activity = .failure(localized("Gib ein Passwort ein."))
                return
            }
        }
        let accessResolution = await accessResolver.resolve(
            source: source,
            passwordOverride: password,
            allowsStoredPassword: allowsStoredPassword,
            keychainInteraction: .allow
        )
        guard connectionTestID == source.id else { return }
        let access: ProviderAccess
        switch accessResolution {
        case .resolved(let resolvedAccess):
            access = resolvedAccess
        case .failed(let failure):
            connectionTestID = nil
            isTestingConnection = false
            activity = .failure(accessMessage(for: failure))
            return
        }
        let result = await provider.testConnection(to: source, access: access)

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
        activity = .working(localized("Quelle wird gespeichert …"))
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
                    activity = .failure(localized("Die Zugangsdaten sind ungültig."))
                    return
                }
                if password.isEmpty {
                    guard previousPassword != nil else {
                        activity = .failure(localized("Gib ein Passwort ein."))
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
            if source.customServerCertificateID == nil {
                selectedServerCertificate = nil
            }

            var cleanupFailed = false
            if let previousScope, previousScope != newScope {
                do {
                    try await passwordVault.deletePassword(for: previousScope)
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
            activity = cleanupFailed
                ? .failure(localized("Quelle gespeichert, aber nicht mehr verwendete Schlüsselbund-Einträge konnten nicht vollständig entfernt werden."))
                : .success(localized("Quelle gespeichert. Geheimnisse bleiben im macOS-Schlüsselbund."))
        } catch KeychainPasswordVaultError.interactionNotAllowed {
            activity = .failure(
                localized("macOS gibt diesen Schlüsselbund-Eintrag nicht ohne Nachfrage frei. Entferne den alten IssueLight-Eintrag in der Schlüsselbundverwaltung und speichere die Quelle erneut.")
            )
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
            case .clientCertificate:
                message = localized("Quelle entfernt. Das Client-Zertifikat bleibt im macOS-Schlüsselbund.")
            }
            activity = .success(message)
        }
    }

    func importIdentity(at fileURL: URL, password: String) async -> Bool {
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

    private func sourceFromForm() -> MonitoringSource? {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            activity = .failure(localized("Die Serveradresse ist keine gültige URL."))
            return nil
        }

        let authentication: AuthenticationConfiguration
        switch authenticationChoice {
        case .basic:
            authentication = .basic(username: username)
        case .clientCertificate:
            authentication = .clientCertificate(identityID: selectedIdentityID)
        }

        var serverTrust: ServerTrustConfiguration
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

        var source: MonitoringSource
        if var existingSource = selectedSource {
            existingSource.name = name
            existingSource.providerID = selectedProviderID
            existingSource.isEnabled = isSourceEnabled
            existingSource.authentication = authentication
            if existingSource.updateEndpoint(url) {
                serverTrustChoice = .system
                selectedServerCertificate = nil
                pinnedServerCertificateSHA256 = ""
                serverTrust = .system
            }
            existingSource.serverTrust = serverTrust
            source = existingSource
        } else {
            source = MonitoringSource(
                id: sourceID,
                name: name,
                providerID: selectedProviderID,
                endpoint: url,
                isEnabled: isSourceEnabled,
                authentication: authentication,
                serverTrust: serverTrust
            )
        }
        guard let provider = providerRegistry.provider(for: selectedProviderID) else {
            activity = .failure(localized("Der ausgewählte Monitoring-Typ ist nicht verfügbar."))
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
            refreshStates[source.id] = .failed(localized("Der konfigurierte Monitoring-Typ ist nicht verfügbar."))
            return
        }
        let accessResolution = await accessResolver.resolve(source: source)
        guard !Task.isCancelled else { return }
        let access: ProviderAccess
        switch accessResolution {
        case .resolved(let resolvedAccess):
            access = resolvedAccess
        case .failed(let failure):
            refreshStates[source.id] = .failed(accessMessage(for: failure))
            return
        }
        let result = await provider.loadSnapshot(from: source, access: access)

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
        selectedServerCertificate = nil
        pinnedServerCertificateSHA256 = ""
        switch source.authentication {
        case .basic(let storedUsername):
            authenticationChoice = .basic
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
    }

    private func validationMessage(_ issues: [SourceValidationIssue]) -> String {
        if issues.contains(.emptyName) { return localized("Gib der Quelle einen Namen.") }
        if issues.contains(.missingHost) { return localized("Die Serveradresse benötigt einen Hostnamen.") }
        if issues.contains(.emptyUsername) { return localized("Gib einen Benutzernamen ein.") }
        if issues.contains(.invalidUsername) { return localized("Der Benutzername darf keinen Doppelpunkt enthalten.") }
        if issues.contains(.missingClientIdentity) { return localized("Wähle ein Client-Zertifikat aus dem Schlüsselbund.") }
        if issues.contains(.missingServerCertificate) { return localized("Importiere ein CA-Zertifikat.") }
        if issues.contains(.invalidPinnedCertificate) { return localized("Wähle ein gültiges Serverzertifikat für den SHA-256-Pin aus.") }
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

    private func accessMessage(for failure: ProviderAccessFailure) -> String {
        switch failure {
        case .passwordNotAvailable:
            return localized("Das Passwort ist nicht mehr im Schlüsselbund verfügbar.")
        case .passwordAccessFailed:
            return localized("macOS gibt das Passwort im Hintergrund nicht ohne Nachfrage frei. Öffne die Quelle und gib es erneut ein.")
        case .clientIdentityNotAvailable:
            return localized("Das Client-Zertifikat ist nicht mehr im Schlüsselbund verfügbar.")
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
