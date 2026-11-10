import XCTest
@testable import IssueLightCore

final class KeychainPasswordVaultTests: XCTestCase {
    func testRealKeychainInternetPasswordLifecycleIsScopedPerSource() async throws {
        let firstSource = source(id: UUID(), account: "operator")
        let secondSource = source(id: UUID(), account: "operator")
        let firstScope = try BasicCredentialScope(source: firstSource)
        let secondScope = try BasicCredentialScope(source: secondSource)
        let vault = KeychainPasswordVault()

        try await vault.deletePassword(for: firstScope)
        try await vault.deletePassword(for: secondScope)
        addTeardownBlock {
            try? await vault.deletePassword(for: firstScope)
            try? await vault.deletePassword(for: secondScope)
        }

        try await vault.store("first-secret", for: firstScope)
        try await vault.store("second-secret", for: secondScope)

        let firstPassword = try await vault.password(for: firstScope)
        let secondPassword = try await vault.password(for: secondScope)
        XCTAssertEqual(firstPassword, "first-secret")
        XCTAssertEqual(secondPassword, "second-secret")

        try await vault.store("updated-secret", for: firstScope)
        let updatedPassword = try await vault.password(for: firstScope)
        XCTAssertEqual(updatedPassword, "updated-secret")

        try await vault.deletePassword(for: firstScope)
        let deletedPassword = try await vault.password(for: firstScope)
        XCTAssertNil(deletedPassword)
        let retainedPassword = try await vault.password(for: secondScope)
        XCTAssertEqual(retainedPassword, "second-secret")

        try await vault.deletePassword(for: secondScope)
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
