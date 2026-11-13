import Security
import XCTest
@testable import IssueLightCore

final class Icinga2LiveConnectionTests: XCTestCase {
    private var testKeychain: TemporaryTestKeychain!

    override func setUpWithError() throws {
        testKeychain = try TemporaryTestKeychain()
    }

    override func tearDownWithError() throws {
        try testKeychain.delete()
        testKeychain = nil
    }

    func testPinnedLiveServerCertificateAcceptsExactLeaf() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpointValue = environment["ISSUELIGHT_LIVE_ICINGA_URL"],
              let endpoint = URL(string: endpointValue),
              let password = environment["ISSUELIGHT_ICINGA_BASIC_PASSWORD"],
              let certificatePath = environment["ISSUELIGHT_LIVE_ICINGA_SERVER_CERT_PATH"] else {
            throw XCTSkip("Live Icinga 2 environment is not configured")
        }
        let fingerprint = try ServerCertificateFingerprint.sha256(
            at: URL(fileURLWithPath: certificatePath)
        )
        let source = MonitoringSource(
            name: "Pinned live server",
            providerID: Icinga2Provider.id,
            endpoint: endpoint,
            authentication: .basic(username: "issuelight-basic"),
            serverTrust: .pinnedCertificate(sha256: fingerprint)
        )
        let provider = try XCTUnwrap(ProviderRegistry.builtIn().provider(for: source.providerID))

        let result = await provider.testConnection(
            to: source,
            access: ProviderAccess(credential: .password(password))
        )

        XCTAssertEqual(result, .connected)
    }

    func testPinnedLiveServerCertificateRejectsDifferentCertificate() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpointValue = environment["ISSUELIGHT_LIVE_ICINGA_URL"],
              let endpoint = URL(string: endpointValue),
              let password = environment["ISSUELIGHT_ICINGA_BASIC_PASSWORD"] else {
            throw XCTSkip("Live Icinga 2 environment is not configured")
        }
        let unrelatedCertificate = try XCTUnwrap(
            Bundle.module.url(
                forResource: "issuelight-test-root",
                withExtension: "crt",
                subdirectory: "Fixtures"
            )
        )
        let fingerprint = try ServerCertificateFingerprint.sha256(at: unrelatedCertificate)
        let source = MonitoringSource(
            name: "Mismatched pinned server",
            providerID: Icinga2Provider.id,
            endpoint: endpoint,
            authentication: .basic(username: "issuelight-basic"),
            serverTrust: .pinnedCertificate(sha256: fingerprint)
        )
        let provider = try XCTUnwrap(ProviderRegistry.builtIn().provider(for: source.providerID))

        let result = await provider.testConnection(
            to: source,
            access: ProviderAccess(credential: .password(password))
        )

        XCTAssertEqual(result, .failed(.tls))
    }

    func testPinnedLiveServerCertificateRetainsHostnameVerification() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpointValue = environment["ISSUELIGHT_LIVE_ICINGA_URL"],
              var endpointComponents = URLComponents(string: endpointValue),
              let password = environment["ISSUELIGHT_ICINGA_BASIC_PASSWORD"],
              let certificatePath = environment["ISSUELIGHT_LIVE_ICINGA_SERVER_CERT_PATH"] else {
            throw XCTSkip("Live Icinga 2 environment is not configured")
        }
        endpointComponents.host = "127.0.0.1"
        let endpoint = try XCTUnwrap(endpointComponents.url)
        let fingerprint = try ServerCertificateFingerprint.sha256(
            at: URL(fileURLWithPath: certificatePath)
        )
        let source = MonitoringSource(
            name: "Pinned server with mismatched host",
            providerID: Icinga2Provider.id,
            endpoint: endpoint,
            authentication: .basic(username: "issuelight-basic"),
            serverTrust: .pinnedCertificate(sha256: fingerprint)
        )
        let provider = try XCTUnwrap(ProviderRegistry.builtIn().provider(for: source.providerID))

        let result = await provider.testConnection(
            to: source,
            access: ProviderAccess(credential: .password(password))
        )

        XCTAssertEqual(result, .failed(.tls))
    }

    func testUnrelatedPrivateCAIsRejectedAsTLSFailure() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpointValue = environment["ISSUELIGHT_LIVE_ICINGA_URL"],
              let endpoint = URL(string: endpointValue),
              let password = environment["ISSUELIGHT_ICINGA_BASIC_PASSWORD"] else {
            throw XCTSkip("Live Icinga 2 environment is not configured")
        }
        try requireUnlockedDefaultKeychain()
        let fileURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "issuelight-test-root",
                withExtension: "crt",
                subdirectory: "Fixtures"
            )
        )
        let certificateCatalog = KeychainServerCertificateCatalog(
            ownershipScope: "berlin.yuna.issuelight.live-core-tests.\(UUID().uuidString)"
        )
        let descriptor = try await certificateCatalog.importCertificate(at: fileURL)
        addTeardownBlock {
            try? await certificateCatalog.deleteCertificate(id: descriptor.id)
        }
        let resolvedCertificate = try await certificateCatalog.certificate(id: descriptor.id)
        let certificate = try XCTUnwrap(resolvedCertificate)
        let source = MonitoringSource(
            name: "Unrelated private CA",
            providerID: Icinga2Provider.id,
            endpoint: endpoint,
            authentication: .basic(username: "issuelight-basic"),
            serverTrust: .customCertificate(certificateID: descriptor.id)
        )
        let provider = try XCTUnwrap(ProviderRegistry.builtIn().provider(for: source.providerID))

        let result = await provider.testConnection(
            to: source,
            access: ProviderAccess(
                credential: .password(password),
                trustedServerCertificate: certificate
            )
        )

        XCTAssertEqual(result, .failed(.tls))
    }

    func testImportedPrivateCAKeepsVerificationEnabledForLiveIcingaSnapshot() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpointValue = environment["ISSUELIGHT_LIVE_ICINGA_URL"],
              let endpoint = URL(string: endpointValue),
              let password = environment["ISSUELIGHT_ICINGA_BASIC_PASSWORD"],
              let certificatePath = environment["ISSUELIGHT_LIVE_ICINGA_CA_PATH"] else {
            throw XCTSkip("Live Icinga 2 environment is not configured")
        }
        try requireUnlockedDefaultKeychain()
        let certificateCatalog = KeychainServerCertificateCatalog(
            ownershipScope: "berlin.yuna.issuelight.live-core-tests.\(UUID().uuidString)"
        )
        let descriptor = try await certificateCatalog.importCertificate(
            at: URL(fileURLWithPath: certificatePath)
        )
        addTeardownBlock {
            try? await certificateCatalog.deleteCertificate(id: descriptor.id)
        }
        let source = MonitoringSource(
            name: "Live private CA",
            providerID: Icinga2Provider.id,
            endpoint: endpoint,
            authentication: .basic(username: "issuelight-basic"),
            serverTrust: .customCertificate(certificateID: descriptor.id)
        )
        let passwordVault = KeychainPasswordVault(keychainContext: testKeychain.context)
        let passwordScope = try BasicCredentialScope(source: source)
        addTeardownBlock {
            try? await passwordVault.deletePassword(for: passwordScope)
        }
        try await passwordVault.store(password, for: passwordScope)
        let resolver = ProviderAccessResolver(
            passwordVault: passwordVault,
            identityCatalog: KeychainIdentityCatalog(),
            certificateCatalog: certificateCatalog
        )
        let resolution = await resolver.resolve(source: source)
        guard case .resolved(let access) = resolution else {
            return XCTFail("Expected Keychain-backed provider access")
        }
        let provider = try XCTUnwrap(ProviderRegistry.builtIn().provider(for: source.providerID))

        let connection = await provider.testConnection(to: source, access: access)
        guard connection == .connected else {
            return XCTFail("Expected private-CA connection, got \(connection)")
        }
        let result = await provider.loadSnapshot(from: source, access: access)

        guard case .loaded(let snapshot) = result else {
            return XCTFail("Expected the private-CA snapshot to load, got \(result)")
        }
        XCTAssertEqual(snapshot.sourceID, source.id)
        XCTAssertEqual(snapshot.highestAttentionSeverity, .critical)
    }

    func testLiveBasicAuthenticationLoadsHostAndServiceProblems() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpointValue = environment["ISSUELIGHT_LIVE_ICINGA_URL"],
              let endpoint = URL(string: endpointValue),
              let password = environment["ISSUELIGHT_ICINGA_BASIC_PASSWORD"] else {
            throw XCTSkip("Live Icinga 2 environment is not configured")
        }
        let source = MonitoringSource(
            name: "Live Basic",
            providerID: Icinga2Provider.id,
            endpoint: endpoint,
            authentication: .basic(username: "issuelight-basic"),
            serverTrust: .disabled
        )

        let provider = try XCTUnwrap(ProviderRegistry.builtIn().provider(for: source.providerID))
        let result = await provider.loadSnapshot(
            from: source,
            access: ProviderAccess(credential: .password(password))
        )

        guard case .loaded(let snapshot) = result else {
            return XCTFail("Expected the live Icinga 2 snapshot to load, got \(result)")
        }
        XCTAssertEqual(snapshot.sourceID, source.id)
        XCTAssertEqual(snapshot.issues.count, 2)
        XCTAssertTrue(snapshot.issues.contains {
            $0.kind == .host && $0.hostName == "down-host" && $0.severity == .critical
        })
        XCTAssertTrue(snapshot.issues.contains {
            $0.kind == .service
                && $0.hostName == "down-host"
                && $0.serviceName == "cascaded-service"
                && $0.severity == .critical
        })
        XCTAssertEqual(snapshot.highestAttentionSeverity, .critical)
    }

    func testImportedKeychainIdentityConnectsToLiveIcingaAPI() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpointValue = environment["ISSUELIGHT_LIVE_ICINGA_URL"],
              let endpoint = URL(string: endpointValue),
              let identityPath = environment["ISSUELIGHT_LIVE_ICINGA_PKCS12_PATH"],
              let identityPassword = environment["ISSUELIGHT_ICINGA_PKCS12_PASSWORD"],
              let certificatePath = environment["ISSUELIGHT_LIVE_ICINGA_CA_PATH"] else {
            throw XCTSkip("Live Icinga 2 environment is not configured")
        }
        try requireUnlockedDefaultKeychain()

        let catalog = KeychainIdentityCatalog()
        let descriptor = try await catalog.importPKCS12(
            at: URL(fileURLWithPath: identityPath),
            password: identityPassword
        )
        let resolvedIdentity = try await catalog.identity(id: descriptor.id)
        let identity = try XCTUnwrap(resolvedIdentity)
        let cleanupReferences = try Self.cleanupReferences(
            identity: identity,
            id: descriptor.id
        )
        addTeardownBlock {
            try? Self.deleteImportedIdentity(cleanupReferences)
        }
        let certificateCatalog = KeychainServerCertificateCatalog(
            ownershipScope: "berlin.yuna.issuelight.live-core-tests.\(UUID().uuidString)"
        )
        let certificateDescriptor = try await certificateCatalog.importCertificate(
            at: URL(fileURLWithPath: certificatePath)
        )
        addTeardownBlock {
            try? await certificateCatalog.deleteCertificate(id: certificateDescriptor.id)
        }
        let resolvedServerCertificate = try await certificateCatalog.certificate(
            id: certificateDescriptor.id
        )
        let serverCertificate = try XCTUnwrap(resolvedServerCertificate)
        let source = MonitoringSource(
            name: "Live mTLS",
            providerID: Icinga2Provider.id,
            endpoint: endpoint,
            authentication: .clientCertificate(identityID: descriptor.id),
            serverTrust: .customCertificate(certificateID: certificateDescriptor.id)
        )

        let provider = try XCTUnwrap(ProviderRegistry.builtIn().provider(for: source.providerID))
        let result = await provider.testConnection(
            to: source,
            access: ProviderAccess(
                credential: .clientIdentity(identity),
                trustedServerCertificate: serverCertificate
            )
        )

        XCTAssertEqual(result, .connected)
        try Self.deleteImportedIdentity(cleanupReferences)
        let removedIdentity = try await catalog.identity(id: descriptor.id)
        XCTAssertNil(removedIdentity)
        XCTAssertFalse(Self.itemExists(
            class: kSecClassCertificate,
            reference: cleanupReferences.certificate
        ))
    }

    func testUnregisteredClientIdentityIsRejectedByLiveIcingaAPI() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpointValue = environment["ISSUELIGHT_LIVE_ICINGA_URL"],
              let endpoint = URL(string: endpointValue),
              let identityPath = environment["ISSUELIGHT_LIVE_ICINGA_REJECTED_PKCS12_PATH"],
              let identityPassword = environment["ISSUELIGHT_ICINGA_PKCS12_PASSWORD"],
              let certificatePath = environment["ISSUELIGHT_LIVE_ICINGA_CA_PATH"] else {
            throw XCTSkip("Live Icinga 2 environment is not configured")
        }
        try requireUnlockedDefaultKeychain()

        let catalog = KeychainIdentityCatalog()
        let descriptor = try await catalog.importPKCS12(
            at: URL(fileURLWithPath: identityPath),
            password: identityPassword
        )
        let resolvedIdentity = try await catalog.identity(id: descriptor.id)
        let identity = try XCTUnwrap(resolvedIdentity)
        let cleanupReferences = try Self.cleanupReferences(
            identity: identity,
            id: descriptor.id
        )
        addTeardownBlock {
            try? Self.deleteImportedIdentity(cleanupReferences)
        }
        let certificateCatalog = KeychainServerCertificateCatalog(
            ownershipScope: "berlin.yuna.issuelight.live-core-tests.\(UUID().uuidString)"
        )
        let certificateDescriptor = try await certificateCatalog.importCertificate(
            at: URL(fileURLWithPath: certificatePath)
        )
        addTeardownBlock {
            try? await certificateCatalog.deleteCertificate(id: certificateDescriptor.id)
        }
        let resolvedServerCertificate = try await certificateCatalog.certificate(
            id: certificateDescriptor.id
        )
        let serverCertificate = try XCTUnwrap(resolvedServerCertificate)
        let source = MonitoringSource(
            name: "Rejected live mTLS",
            providerID: Icinga2Provider.id,
            endpoint: endpoint,
            authentication: .clientCertificate(identityID: descriptor.id),
            serverTrust: .customCertificate(certificateID: certificateDescriptor.id)
        )

        let provider = try XCTUnwrap(ProviderRegistry.builtIn().provider(for: source.providerID))
        let result = await provider.testConnection(
            to: source,
            access: ProviderAccess(
                credential: .clientIdentity(identity),
                trustedServerCertificate: serverCertificate
            )
        )

        XCTAssertEqual(result, .failed(.authentication))
        try Self.deleteImportedIdentity(cleanupReferences)
        let removedIdentity = try await catalog.identity(id: descriptor.id)
        XCTAssertNil(removedIdentity)
        XCTAssertFalse(Self.itemExists(
            class: kSecClassCertificate,
            reference: cleanupReferences.certificate
        ))
    }

    private static func cleanupReferences(
        identity: SecIdentity?,
        id: String
    ) throws -> ImportedIdentityReferences {
        guard let identityReference = Data(base64Encoded: id), let identity else {
            throw LiveIdentityCleanupError.invalidPersistentReference
        }
        var certificate: SecCertificate?
        let certificateStatus = SecIdentityCopyCertificate(identity, &certificate)
        guard certificateStatus == errSecSuccess, let certificate else {
            throw LiveIdentityCleanupError.unexpectedStatus(certificateStatus)
        }
        let certificateQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let referenceStatus = SecItemCopyMatching(certificateQuery as CFDictionary, &result)
        guard referenceStatus == errSecSuccess, let certificateReference = result as? Data else {
            throw LiveIdentityCleanupError.unexpectedStatus(referenceStatus)
        }
        return ImportedIdentityReferences(identity: identityReference, certificate: certificateReference)
    }

    private static func deleteImportedIdentity(_ references: ImportedIdentityReferences) throws {
        try deleteItem(
            class: kSecClassIdentity,
            reference: references.identity
        )
        try deleteItem(
            class: kSecClassCertificate,
            reference: references.certificate
        )
    }

    private static func deleteItem(
        class itemClass: CFTypeRef,
        reference: Data
    ) throws {
        let query: [String: Any] = [
            kSecClass as String: itemClass,
            kSecValuePersistentRef as String: reference,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LiveIdentityCleanupError.unexpectedStatus(status)
        }
    }

    private static func itemExists(
        class itemClass: CFTypeRef,
        reference: Data
    ) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: itemClass,
            kSecValuePersistentRef as String: reference,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}

private struct ImportedIdentityReferences: Sendable {
    let identity: Data
    let certificate: Data
}

private enum LiveIdentityCleanupError: Error {
    case invalidPersistentReference
    case unexpectedStatus(OSStatus)
}
