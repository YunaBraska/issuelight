import XCTest
@testable import IssueLightCore

final class KeychainIdentityCatalogTests: XCTestCase {
    func testGeneratedPKCS12IdentityCanBeListedResolvedAndRemoved() async throws {
        let keychain = try TemporaryTestKeychain()
        addTeardownBlock { try? keychain.delete() }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issuelight-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let keyURL = temporaryDirectory.appendingPathComponent("identity.key")
        let certificateURL = temporaryDirectory.appendingPathComponent("identity.crt")
        let identityURL = temporaryDirectory.appendingPathComponent("identity.p12")
        let commonName = "IssueLight Test \(UUID().uuidString)"
        let password = "temporary-test-password"

        try Self.runOpenSSL([
            "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", keyURL.path,
            "-out", certificateURL.path,
            "-days", "1",
            "-subj", "/CN=\(commonName)",
            "-addext", "basicConstraints=critical,CA:FALSE",
            "-addext", "keyUsage=critical,digitalSignature,keyEncipherment",
        ])
        try Self.runOpenSSL([
            "pkcs12", "-export",
            "-inkey", keyURL.path,
            "-in", certificateURL.path,
            "-out", identityURL.path,
            "-name", commonName,
            "-passout", "pass:\(password)",
        ])

        let catalog = KeychainIdentityCatalog(accessContext: keychain.context)
        let descriptor = try await catalog.importPKCS12(at: identityURL, password: password)
        let resolvedIdentity = try await catalog.identity(id: descriptor.id)
        let identity = try XCTUnwrap(resolvedIdentity)
        let cleanupReferences = try Self.keychainReferences(
            identity: identity,
            id: descriptor.id
        )
        addTeardownBlock {
            try? Self.deleteImportedIdentity(cleanupReferences)
        }

        XCTAssertEqual(descriptor.displayName, commonName)
        let identities = try await catalog.identities()
        XCTAssertTrue(identities.contains(descriptor))

        try Self.deleteImportedIdentity(cleanupReferences)
        let removedIdentity = try await catalog.identity(id: descriptor.id)
        XCTAssertNil(removedIdentity)
    }

    func testInvalidPersistentReferenceIsRejected() async {
        let catalog = KeychainIdentityCatalog()

        do {
            _ = try await catalog.identity(id: "not base64")
            XCTFail("Expected invalid reference rejection")
        } catch {
            XCTAssertEqual(error as? KeychainIdentityCatalogError, .invalidPersistentReference)
        }
    }

    func testMalformedPKCS12DoesNotCreateAnIdentity() async throws {
        let keychain = try TemporaryTestKeychain()
        addTeardownBlock { try? keychain.delete() }
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".p12")
        try Data("not a certificate".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let catalog = KeychainIdentityCatalog(accessContext: keychain.context)

        do {
            _ = try await catalog.importPKCS12(at: fileURL, password: "temporary")
            XCTFail("Expected malformed PKCS#12 rejection")
        } catch let error as KeychainIdentityCatalogError {
            guard case .unexpectedStatus(let status) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertNotEqual(status, errSecSuccess)
        }
    }

    private static func runOpenSSL(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            throw KeychainIdentityTestError.openSSLFailed(
                String(data: errorData, encoding: .utf8) ?? "Unknown OpenSSL failure"
            )
        }
    }

    private static func keychainReferences(
        identity: SecIdentity,
        id: String
    ) throws -> IdentityReferences {
        guard let identityReference = Data(base64Encoded: id) else {
            throw KeychainIdentityTestError.invalidPersistentReference
        }
        var certificate: SecCertificate?
        let certificateStatus = SecIdentityCopyCertificate(identity, &certificate)
        guard certificateStatus == errSecSuccess, let certificate else {
            throw KeychainIdentityTestError.unexpectedStatus(certificateStatus)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let referenceStatus = SecItemCopyMatching(query as CFDictionary, &result)
        guard referenceStatus == errSecSuccess, let certificateReference = result as? Data else {
            throw KeychainIdentityTestError.unexpectedStatus(referenceStatus)
        }
        return IdentityReferences(identity: identityReference, certificate: certificateReference)
    }

    private static func deleteImportedIdentity(_ references: IdentityReferences) throws {
        for (itemClass, reference) in [
            (kSecClassIdentity, references.identity),
            (kSecClassCertificate, references.certificate),
        ] {
            let query: [String: Any] = [
                kSecClass as String: itemClass as Any,
                kSecValuePersistentRef as String: reference,
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainIdentityTestError.unexpectedStatus(status)
            }
        }
    }
}

private struct IdentityReferences: Sendable {
    let identity: Data
    let certificate: Data
}

private enum KeychainIdentityTestError: Error {
    case invalidPersistentReference
    case openSSLFailed(String)
    case unexpectedStatus(OSStatus)
}
