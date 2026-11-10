import Foundation
import IssueLightCore
import Security

@MainActor
final class SourceSetupModel: ObservableObject {
    enum AuthenticationChoice: String, CaseIterable, Identifiable {
        case basic = "Benutzername & Passwort"
        case clientCertificate = "Client-Zertifikat"

        var id: String { rawValue }
    }

    enum Activity: Equatable {
        case idle
        case working(String)
        case success(String)
        case failure(String)
    }

    @Published var name = ""
    @Published var endpoint = ""
    @Published var authenticationChoice = AuthenticationChoice.basic
    @Published var username = ""
    @Published var password = ""
    @Published var selectedIdentityID = ""
    @Published var identities: [ClientIdentityDescriptor] = []
    @Published private(set) var identityLoadError: String?
    @Published var verifiesServerCertificate = true
    @Published private(set) var activity = Activity.idle
    @Published private(set) var hasConfiguredSource = false
    @Published private(set) var isTestingConnection = false

    private var sourceID = UUID()
    private var loadedSource: MonitoringSource?
    private let sourceStore: SourceStore?
    private let passwordVault = KeychainPasswordVault()
    private let identityCatalog = KeychainIdentityCatalog()
    private let connectionTester = Icinga2ConnectionTester()

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
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "io.github.yunabraska.issuelight"
        if let fileURL = try? SourceStore.defaultFileURL(bundleIdentifier: bundleIdentifier) {
            sourceStore = SourceStore(fileURL: fileURL)
        } else {
            sourceStore = nil
            activity = .failure("Der Speicherort für die Quellen konnte nicht geöffnet werden.")
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
                    password = try await passwordVault.password(for: scope) ?? ""
                }
            } else {
                loadedSource = nil
                sourceID = UUID()
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
        isTestingConnection = true
        defer { isTestingConnection = false }
        activity = .working("Verbindung wird geprüft …")

        let result: ConnectionTestResult
        switch source.authentication {
        case .basic:
            result = await connectionTester.test(source, password: password)
        case .clientCertificate(let identityID):
            do {
                let identity = try await identityCatalog.identity(id: identityID)
                result = await connectionTester.test(source, clientIdentity: identity)
            } catch {
                activity = .failure("Das Client-Zertifikat konnte nicht aus dem Schlüsselbund gelesen werden.")
                return
            }
        }

        activity = message(for: result)
    }

    func save() async {
        guard let source = sourceFromForm(), let sourceStore else { return }
        activity = .working("Quelle wird gespeichert …")

        do {
            let previousScope = try basicCredentialScope(for: loadedSource)
            let newScope = try basicCredentialScope(for: source)
            switch source.authentication {
            case .basic:
                try await passwordVault.store(password, for: BasicCredentialScope(source: source))
            case .clientCertificate:
                break
            }
            do {
                _ = try await sourceStore.upsert(source)
            } catch {
                if newScope != previousScope, let newScope {
                    try? await passwordVault.deletePassword(for: newScope)
                }
                throw error
            }
            if let previousScope, previousScope != newScope {
                try await passwordVault.deletePassword(for: previousScope)
            }
            loadedSource = source
            hasConfiguredSource = true
            activity = .success("Quelle gespeichert. Geheimnisse bleiben im macOS-Schlüsselbund.")
        } catch {
            activity = .failure("Die Quelle konnte nicht gespeichert werden: \(error.localizedDescription)")
        }
    }

    func deleteSource() async {
        guard let source = loadedSource, let sourceStore else { return }
        activity = .working("Quelle wird entfernt …")

        do {
            _ = try await sourceStore.remove(id: source.id)
            let removedBasicPassword: Bool
            if case .basic = source.authentication {
                try await passwordVault.deletePassword(for: BasicCredentialScope(source: source))
                removedBasicPassword = true
            } else {
                removedBasicPassword = false
            }
            loadedSource = nil
            sourceID = UUID()
            name = ""
            endpoint = ""
            authenticationChoice = .basic
            username = ""
            password = ""
            selectedIdentityID = ""
            verifiesServerCertificate = true
            hasConfiguredSource = false
            activity = .success(
                removedBasicPassword
                    ? "Quelle und gespeichertes Basic-Passwort wurden entfernt."
                    : "Quelle entfernt. Das Client-Zertifikat bleibt im macOS-Schlüsselbund."
            )
        } catch {
            activity = .failure("Die Quelle konnte nicht vollständig entfernt werden: \(error.localizedDescription)")
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
            existingSource.providerID = Icinga2Provider.id
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
                providerID: Icinga2Provider.id,
                endpoint: url,
                authentication: authentication,
                serverTrust: verifiesServerCertificate ? .system : .disabled
            )
        }
        let issues = Icinga2Provider().validate(source)
        guard issues.isEmpty else {
            activity = .failure(validationMessage(issues))
            return nil
        }
        if case .basic = source.authentication, password.isEmpty {
            activity = .failure("Gib ein Passwort ein.")
            return nil
        }
        return source
    }

    private func basicCredentialScope(for source: MonitoringSource?) throws -> BasicCredentialScope? {
        guard let source, case .basic = source.authentication else { return nil }
        return try BasicCredentialScope(source: source)
    }

    private func apply(_ source: MonitoringSource) {
        sourceID = source.id
        name = source.name
        endpoint = source.endpoint.absoluteString
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
            if case .unsupportedPath = $0 { return true }
            return false
        }) {
            return "Verwende für Icinga 2 nur die Serveradresse oder den Pfad /v1."
        }
        if issues.contains(where: {
            if case .unsupportedScheme = $0 { return true }
            return false
        }) {
            return "Icinga 2 akzeptiert ausschließlich HTTPS."
        }
        return "Die Quellenkonfiguration ist ungültig."
    }

    private func message(for result: ConnectionTestResult) -> Activity {
        switch result {
        case .connected:
            return .success("Icinga 2 ist erreichbar. Host- und Servicezugriff funktionieren.")
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
            return .failure("Der Server antwortet, liefert aber keine kompatible Icinga-2-API-Antwort.")
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
}
