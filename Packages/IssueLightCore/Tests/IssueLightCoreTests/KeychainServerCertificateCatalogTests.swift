import Security
import XCTest
@testable import IssueLightCore

final class KeychainServerCertificateCatalogTests: XCTestCase {
    override func setUpWithError() throws {
        try requireUnlockedDefaultKeychain()
    }

    func testCertificateImportResolvesStableKeychainReferenceAndDeletesExactItem() async throws {
        let fileURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "issuelight-test-root",
                withExtension: "crt",
                subdirectory: "Fixtures"
            )
        )
        let catalog = KeychainServerCertificateCatalog(
            ownershipScope: "berlin.yuna.issuelight.catalog-tests.\(UUID().uuidString)"
        )
        let descriptor = try await catalog.importCertificate(at: fileURL)
        addTeardownBlock {
            try? await catalog.deleteCertificate(id: descriptor.id)
        }

        let repeatedDescriptor = try await catalog.importCertificate(at: fileURL)
        let certificate = try await catalog.certificate(id: descriptor.id)

        XCTAssertEqual(repeatedDescriptor, descriptor)
        XCTAssertEqual(descriptor.displayName, "IssueLight Test Root CA")
        XCTAssertEqual(descriptor.sha256Fingerprint.split(separator: ":").count, 32)
        XCTAssertNotNil(certificate)

        let referencedCleanup = try await catalog.deleteUnreferencedManagedCertificates(
            referencedCertificateIDs: [descriptor.id]
        )
        XCTAssertEqual(referencedCleanup, [])
        let referencedCertificate = try await catalog.certificate(id: descriptor.id)
        XCTAssertNotNil(referencedCertificate)

        let cleanupResult = try await catalog.deleteUnreferencedManagedCertificates(
            referencedCertificateIDs: []
        )
        XCTAssertEqual(cleanupResult, [descriptor.id])
        let removedCertificate = try await catalog.certificate(id: descriptor.id)
        XCTAssertNil(removedCertificate)
    }

    func testReferenceAwareCleanupRetainsCertificateWithoutIssueLightOwnership() async throws {
        let fileURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "issuelight-test-root",
                withExtension: "crt",
                subdirectory: "Fixtures"
            )
        )
        let catalog = KeychainServerCertificateCatalog(
            ownershipScope: "berlin.yuna.issuelight.catalog-tests.\(UUID().uuidString)"
        )
        let descriptor = try await catalog.importCertificate(at: fileURL)
        addTeardownBlock {
            try? await catalog.deleteCertificate(id: descriptor.id)
        }
        let reference = try XCTUnwrap(Data(base64Encoded: descriptor.id))
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValuePersistentRef as String: reference,
        ]
        let attributes: [String: Any] = [
            kSecAttrLabel as String: "Extern verwaltete Test-CA",
        ]
        XCTAssertEqual(
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary),
            errSecSuccess
        )

        let cleanupResult = try await catalog.deleteUnreferencedManagedCertificates(
            referencedCertificateIDs: []
        )

        XCTAssertEqual(cleanupResult, [])
        let retainedCertificate = try await catalog.certificate(id: descriptor.id)
        XCTAssertNotNil(retainedCertificate)
    }

    func testCleanupOwnershipScopeCannotDeleteAnotherAppProfilesCertificate() async throws {
        let fileURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "issuelight-test-root",
                withExtension: "crt",
                subdirectory: "Fixtures"
            )
        )
        let ownerCatalog = KeychainServerCertificateCatalog(
            ownershipScope: "berlin.yuna.issuelight.owner-tests.\(UUID().uuidString)"
        )
        let otherCatalog = KeychainServerCertificateCatalog(
            ownershipScope: "berlin.yuna.issuelight.other-tests.\(UUID().uuidString)"
        )
        let descriptor = try await ownerCatalog.importCertificate(at: fileURL)
        addTeardownBlock {
            try? await ownerCatalog.deleteCertificate(id: descriptor.id)
        }
        let duplicateDescriptor = try await otherCatalog.importCertificate(at: fileURL)

        let otherCleanup = try await otherCatalog.deleteUnreferencedManagedCertificates(
            referencedCertificateIDs: []
        )

        XCTAssertEqual(duplicateDescriptor, descriptor)
        XCTAssertEqual(otherCleanup, [])
        let retainedCertificate = try await ownerCatalog.certificate(id: descriptor.id)
        XCTAssertNotNil(retainedCertificate)

        let ownerCleanup = try await ownerCatalog.deleteUnreferencedManagedCertificates(
            referencedCertificateIDs: []
        )
        XCTAssertEqual(ownerCleanup, [])
        let sharedCertificate = try await ownerCatalog.certificate(id: descriptor.id)
        XCTAssertNotNil(sharedCertificate)
    }

    func testInvalidPersistentReferenceAndMalformedCertificateAreRejected() async throws {
        let catalog = KeychainServerCertificateCatalog(
            ownershipScope: "berlin.yuna.issuelight.catalog-tests.\(UUID().uuidString)"
        )
        do {
            _ = try await catalog.certificate(id: "not base64")
            XCTFail("Expected invalid reference rejection")
        } catch {
            XCTAssertEqual(
                error as? KeychainServerCertificateCatalogError,
                .invalidPersistentReference
            )
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("IssueLightMalformedCertificate-\(UUID().uuidString).crt")
        try Data("not a certificate".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        do {
            _ = try await catalog.importCertificate(at: fileURL)
            XCTFail("Expected malformed certificate rejection")
        } catch {
            XCTAssertEqual(
                error as? KeychainServerCertificateCatalogError,
                .invalidCertificate
            )
        }
    }

    func testOversizedCertificateFileIsRejectedBeforeParsing() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("IssueLightOversizedCertificate-\(UUID().uuidString).crt")
        try Data(repeating: 0, count: 1_048_577).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let catalog = KeychainServerCertificateCatalog(
            ownershipScope: "berlin.yuna.issuelight.catalog-tests.\(UUID().uuidString)"
        )

        do {
            _ = try await catalog.importCertificate(at: fileURL)
            XCTFail("Expected oversized certificate rejection")
        } catch {
            XCTAssertEqual(
                error as? KeychainServerCertificateCatalogError,
                .certificateFileTooLarge
            )
        }
    }
}
