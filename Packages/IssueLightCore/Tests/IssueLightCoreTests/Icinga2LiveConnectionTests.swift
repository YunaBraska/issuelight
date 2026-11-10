import Security
import XCTest
@testable import IssueLightCore

final class Icinga2LiveConnectionTests: XCTestCase {
    func testImportedKeychainIdentityConnectsToLiveIcingaAPI() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpointValue = environment["ISSUELIGHT_LIVE_ICINGA_URL"],
              let endpoint = URL(string: endpointValue),
              let identityPath = environment["ISSUELIGHT_LIVE_ICINGA_PKCS12_PATH"],
              let identityPassword = environment["ISSUELIGHT_ICINGA_PKCS12_PASSWORD"] else {
            throw XCTSkip("Live Icinga 2 environment is not configured")
        }

        let catalog = KeychainIdentityCatalog()
        let descriptor = try await catalog.importPKCS12(
            at: URL(fileURLWithPath: identityPath),
            password: identityPassword
        )
        let identity = try await catalog.identity(id: descriptor.id)
        let cleanupReferences = try Self.cleanupReferences(identity: identity, id: descriptor.id)
        addTeardownBlock {
            try? Self.deleteImportedIdentity(cleanupReferences)
        }
        let source = MonitoringSource(
            name: "Live mTLS",
            providerID: Icinga2Provider.id,
            endpoint: endpoint,
            authentication: .clientCertificate(identityID: descriptor.id),
            serverTrust: .disabled
        )

        let result = await Icinga2ConnectionTester().test(source, clientIdentity: identity)

        XCTAssertEqual(result, .connected)
        try Self.deleteImportedIdentity(cleanupReferences)
        let removedIdentity = try await catalog.identity(id: descriptor.id)
        XCTAssertNil(removedIdentity)
        XCTAssertFalse(Self.itemExists(class: kSecClassCertificate, reference: cleanupReferences.certificate))
    }

    func testUnregisteredClientIdentityIsRejectedByLiveIcingaAPI() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpointValue = environment["ISSUELIGHT_LIVE_ICINGA_URL"],
              let endpoint = URL(string: endpointValue),
              let identityPath = environment["ISSUELIGHT_LIVE_ICINGA_REJECTED_PKCS12_PATH"],
              let identityPassword = environment["ISSUELIGHT_ICINGA_PKCS12_PASSWORD"] else {
            throw XCTSkip("Live Icinga 2 environment is not configured")
        }

        let catalog = KeychainIdentityCatalog()
        let descriptor = try await catalog.importPKCS12(
            at: URL(fileURLWithPath: identityPath),
            password: identityPassword
        )
        let identity = try await catalog.identity(id: descriptor.id)
        let cleanupReferences = try Self.cleanupReferences(identity: identity, id: descriptor.id)
        addTeardownBlock {
            try? Self.deleteImportedIdentity(cleanupReferences)
        }
        let source = MonitoringSource(
            name: "Rejected live mTLS",
            providerID: Icinga2Provider.id,
            endpoint: endpoint,
            authentication: .clientCertificate(identityID: descriptor.id),
            serverTrust: .disabled
        )

        let result = await Icinga2ConnectionTester().test(source, clientIdentity: identity)

        XCTAssertEqual(result, .failed(.authentication))
        try Self.deleteImportedIdentity(cleanupReferences)
        let removedIdentity = try await catalog.identity(id: descriptor.id)
        XCTAssertNil(removedIdentity)
        XCTAssertFalse(Self.itemExists(class: kSecClassCertificate, reference: cleanupReferences.certificate))
    }

    private static func cleanupReferences(identity: SecIdentity?, id: String) throws -> ImportedIdentityReferences {
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
        try deleteItem(class: kSecClassIdentity, reference: references.identity)
        try deleteItem(class: kSecClassCertificate, reference: references.certificate)
    }

    private static func deleteItem(class itemClass: CFTypeRef, reference: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: itemClass,
            kSecValuePersistentRef as String: reference,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LiveIdentityCleanupError.unexpectedStatus(status)
        }
    }

    private static func itemExists(class itemClass: CFTypeRef, reference: Data) -> Bool {
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
