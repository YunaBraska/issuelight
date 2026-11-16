import XCTest
@testable import IssueLightCore

final class KeychainPasswordVaultTests: XCTestCase {
    private var testKeychain: TemporaryTestKeychain!

    override func setUpWithError() throws {
        testKeychain = try TemporaryTestKeychain()
    }

    override func tearDownWithError() throws {
        try testKeychain.delete()
        testKeychain = nil
    }

    func testRealKeychainInternetPasswordLifecycleIsScopedPerSource() async throws {
        let firstSource = source(id: UUID(), account: "operator")
        let secondSource = source(id: UUID(), account: "operator")
        let firstScope = try BasicCredentialScope(source: firstSource)
        let secondScope = try BasicCredentialScope(source: secondSource)
        let vault = KeychainPasswordVault(keychainContext: testKeychain.context)

        try await vault.deletePassword(for: firstScope)
        try await vault.deletePassword(for: secondScope)
        addTeardownBlock {
            try? await vault.deletePassword(for: firstScope)
            try? await vault.deletePassword(for: secondScope)
        }

        try await vault.store("first-secret", for: firstScope)
        try await vault.store("second-secret", for: secondScope)

        let containsFirstPassword = try await vault.containsPassword(for: firstScope)
        let containsSecondPassword = try await vault.containsPassword(for: secondScope)
        XCTAssertTrue(containsFirstPassword)
        XCTAssertTrue(containsSecondPassword)

        let firstPassword = try await vault.password(for: firstScope)
        let secondPassword = try await vault.password(for: secondScope)
        XCTAssertEqual(firstPassword, "first-secret")
        XCTAssertEqual(secondPassword, "second-secret")

        try await vault.store("updated-secret", for: firstScope)
        let updatedPassword = try await vault.password(for: firstScope)
        XCTAssertEqual(updatedPassword, "updated-secret")

        try await vault.deletePassword(for: firstScope)
        let containsDeletedPassword = try await vault.containsPassword(for: firstScope)
        XCTAssertFalse(containsDeletedPassword)
        let deletedPassword = try await vault.password(for: firstScope)
        XCTAssertNil(deletedPassword)
        let retainedPassword = try await vault.password(for: secondScope)
        XCTAssertEqual(retainedPassword, "second-secret")

        try await vault.deletePassword(for: secondScope)
    }

    func testRealKeychainAPIKeyLifecycleIsSeparateFromBasicPassword() async throws {
        let sourceID = UUID()
        let basicSource = source(id: sourceID, account: "operator")
        let apiKeySource = MonitoringSource(
            id: sourceID,
            name: "Thruk",
            providerID: ThrukProvider.id,
            endpoint: URL(string: "https://keychain-test.invalid/thruk/r/v1")!,
            authentication: .apiKey(username: "automation")
        )
        let basicScope = try BasicCredentialScope(source: basicSource)
        let apiKeyScope = try APIKeyCredentialScope(source: apiKeySource)
        let vault = KeychainPasswordVault(keychainContext: testKeychain.context)
        addTeardownBlock {
            try? await vault.deletePassword(for: basicScope)
            try? await vault.deleteAPIKey(for: apiKeyScope)
        }

        try await vault.store("basic-secret", for: basicScope)
        try await vault.store("api-key-secret", for: apiKeyScope)

        let storedPassword = try await vault.password(for: basicScope)
        let storedAPIKey = try await vault.apiKey(for: apiKeyScope)
        let containsAPIKey = try await vault.containsAPIKey(for: apiKeyScope)
        XCTAssertEqual(storedPassword, "basic-secret")
        XCTAssertEqual(storedAPIKey, "api-key-secret")
        XCTAssertTrue(containsAPIKey)

        try await vault.deleteAPIKey(for: apiKeyScope)
        let deletedAPIKey = try await vault.apiKey(for: apiKeyScope)
        let retainedPassword = try await vault.password(for: basicScope)
        XCTAssertNil(deletedAPIKey)
        XCTAssertEqual(retainedPassword, "basic-secret")
    }

    func testForeignLegacyCredentialFailsWithoutRequestingItsSecret() async throws {
        let source = source(id: UUID(), account: "foreign-operator")
        let scope = try BasicCredentialScope(source: source)
        let label = "IssueLight foreign credential \(source.id.uuidString.lowercased())"
        let path = "/issuelight/sources/\(source.id.uuidString.lowercased())"
        let keychainPath = testKeychain.fileURL.path
        let add = Process()
        add.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        add.arguments = [
            "add-internet-password",
            "-a", scope.account,
            "-s", scope.server,
            "-P", String(scope.port),
            "-r", "htps",
            "-t", "http",
            "-p", path,
            "-l", label,
            "-w", "foreign-test-secret",
            "-T", "/usr/bin/security",
            keychainPath,
        ]
        add.standardOutput = FileHandle.nullDevice
        add.standardError = FileHandle.nullDevice
        try add.run()
        add.waitUntilExit()
        XCTAssertEqual(add.terminationStatus, 0)

        addTeardownBlock {
            let delete = Process()
            delete.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            delete.arguments = ["delete-internet-password", "-l", label, keychainPath]
            delete.standardOutput = FileHandle.nullDevice
            delete.standardError = FileHandle.nullDevice
            try? delete.run()
            delete.waitUntilExit()
        }

        let vault = KeychainPasswordVault(keychainContext: testKeychain.context)
        do {
            _ = try await vault.password(for: scope)
            XCTFail("Expected the foreign Keychain item to be rejected")
        } catch {
            XCTAssertEqual(error as? KeychainPasswordVaultError, .interactionNotAllowed)
        }
    }

    func testCredentialScopeRequiresBasicAuthentication() {
        let source = MonitoringSource(
            name: "mTLS",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: "https://keychain-test.invalid:5665/v1")!,
            authentication: .clientCertificate(identityID: "identity")
        )

        XCTAssertThrowsError(try BasicCredentialScope(source: source)) { error in
            XCTAssertEqual(error as? CredentialScopeError, .basicAuthenticationRequired)
        }
    }

    func testAPIKeyScopeRequiresAPIKeyAuthentication() {
        let source = MonitoringSource(
            name: "Basic",
            providerID: ThrukProvider.id,
            endpoint: URL(string: "https://keychain-test.invalid/thruk/r/v1")!,
            authentication: .basic(username: "operator")
        )

        XCTAssertThrowsError(try APIKeyCredentialScope(source: source)) { error in
            XCTAssertEqual(error as? CredentialScopeError, .apiKeyAuthenticationRequired)
        }
    }

    func testCredentialScopesRejectEndpointsWithoutAHost() {
        let sourceID = UUID()
        let basicSource = MonitoringSource(
            id: sourceID,
            name: "Invalid basic endpoint",
            providerID: Icinga2Provider.id,
            endpoint: URL(fileURLWithPath: "/tmp/icinga"),
            authentication: .basic(username: "operator")
        )
        let apiKeySource = MonitoringSource(
            id: sourceID,
            name: "Invalid API endpoint",
            providerID: ThrukProvider.id,
            endpoint: URL(fileURLWithPath: "/tmp/thruk"),
            authentication: .apiKey(username: "automation")
        )

        XCTAssertThrowsError(try BasicCredentialScope(source: basicSource)) { error in
            XCTAssertEqual(error as? CredentialScopeError, .invalidEndpoint)
        }
        XCTAssertThrowsError(try APIKeyCredentialScope(source: apiKeySource)) { error in
            XCTAssertEqual(error as? CredentialScopeError, .invalidEndpoint)
        }
    }

    private func source(id: UUID, account: String) -> MonitoringSource {
        MonitoringSource(
            id: id,
            name: "Keychain Test",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: "https://keychain-test.invalid:5665/v1")!,
            authentication: .basic(username: account)
        )
    }
}
