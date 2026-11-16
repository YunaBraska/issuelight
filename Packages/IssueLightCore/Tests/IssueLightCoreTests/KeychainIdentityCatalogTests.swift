import XCTest
@testable import IssueLightCore

final class KeychainIdentityCatalogTests: XCTestCase {
    func testGeneratedPKCS12IdentityCanBeListedResolvedAndRemoved() async throws {
        let keychain = try TemporaryTestKeychain()
        addTeardownBlock { try? keychain.delete() }
        let commonName = "IssueLight Test \(UUID().uuidString)"
        let fixture = try makePKCS12(commonName: commonName)

        let catalog = KeychainIdentityCatalog(accessContext: keychain.context)
        let descriptor = try await catalog.importPKCS12(
            at: fixture.identityURL,
            password: fixture.password
        )
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

    func testProtectedPrivateKeyFailsWithoutDisplayingAuthenticationUI() async throws {
        let keychain = try TemporaryTestKeychain()
        addTeardownBlock { try? keychain.delete() }
        let fixture = try makePKCS12(commonName: "IssueLight Protected \(UUID().uuidString)")

        try Self.runSecurity([
            "import", fixture.identityURL.path,
            "-k", keychain.fileURL.path,
            "-f", "pkcs12",
            "-P", fixture.password,
            "-T", "",
        ])

        let catalog = KeychainIdentityCatalog(accessContext: keychain.context)
        let identities = try await catalog.identities()
        let descriptor = try XCTUnwrap(identities.first)
        let interactionBeforeResolution = try Self.keychainInteractionAllowed()

        do {
            _ = try await catalog.identity(id: descriptor.id, interaction: .fail)
            XCTFail("Expected protected private-key access to fail without interaction")
        } catch {
            XCTAssertEqual(error as? KeychainIdentityCatalogError, .interactionNotAllowed)
        }
        XCTAssertEqual(
            try Self.keychainInteractionAllowed(),
            interactionBeforeResolution
        )

        let source = MonitoringSource(
            name: "Protected identity",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: "https://protected-identity.example.test:5665")!,
            authentication: .clientCertificate(identityID: descriptor.id)
        )
        let resolver = ProviderAccessResolver(
            passwordVault: KeychainPasswordVault(keychainContext: keychain.context),
            identityCatalog: catalog,
            certificateCatalog: KeychainServerCertificateCatalog(
                ownershipScope: "berlin.yuna.issuelight.protected-key-tests",
                accessContext: keychain.context
            )
        )
        let resolution = await resolver.resolve(source: source)

        guard case .failed(let failure) = resolution else {
            return XCTFail("Expected protected identity approval to be required")
        }
        XCTAssertEqual(failure, .clientIdentityInteractionRequired)
    }

    func testTrustedPrivateKeyCanBeResolvedWithoutAuthenticationUI() async throws {
        let keychain = try TemporaryTestKeychain()
        addTeardownBlock { try? keychain.delete() }
        let fixture = try makePKCS12(commonName: "IssueLight Trusted \(UUID().uuidString)")

        try Self.runSecurity([
            "import", fixture.identityURL.path,
            "-k", keychain.fileURL.path,
            "-f", "pkcs12",
            "-P", fixture.password,
            "-T", CommandLine.arguments[0],
        ])

        let catalog = KeychainIdentityCatalog(accessContext: keychain.context)
        let identities = try await catalog.identities()
        let descriptor = try XCTUnwrap(identities.first)
        let identity = try await catalog.identity(id: descriptor.id, interaction: .fail)

        XCTAssertNotNil(identity)
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

    private static func runSecurity(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            throw KeychainIdentityTestError.securityFailed(
                String(data: errorData, encoding: .utf8) ?? "Unknown Security failure"
            )
        }
    }

    private static func keychainInteractionAllowed() throws -> Bool {
        var allowed: DarwinBoolean = false
        let status = SecKeychainGetUserInteractionAllowed(&allowed)
        guard status == errSecSuccess else {
            throw KeychainIdentityTestError.unexpectedStatus(status)
        }
        return allowed.boolValue
    }

    private func makePKCS12(commonName: String) throws -> IdentityFixture {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issuelight-protected-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let keyURL = temporaryDirectory.appendingPathComponent("identity.key")
        let certificateURL = temporaryDirectory.appendingPathComponent("identity.crt")
        let identityURL = temporaryDirectory.appendingPathComponent("identity.p12")
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
        return IdentityFixture(identityURL: identityURL, password: password)
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

private struct IdentityFixture: Sendable {
    let identityURL: URL
    let password: String
}

private enum KeychainIdentityTestError: Error {
    case invalidPersistentReference
    case openSSLFailed(String)
    case securityFailed(String)
    case unexpectedStatus(OSStatus)
}
