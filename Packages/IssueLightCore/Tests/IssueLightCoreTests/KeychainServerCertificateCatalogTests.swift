import Security
import XCTest
@testable import IssueLightCore

final class KeychainServerCertificateCatalogTests: XCTestCase {
    func testCertificateImportResolvesStableKeychainReferenceAndDeletesExactItem() async throws {
        let fileURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "issuelight-test-root",
                withExtension: "crt",
                subdirectory: "Fixtures"
            )
        )
        let catalog = KeychainServerCertificateCatalog()
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

        try await catalog.deleteCertificate(id: descriptor.id)
        let removedCertificate = try await catalog.certificate(id: descriptor.id)
        XCTAssertNil(removedCertificate)
    }

    func testInvalidPersistentReferenceAndMalformedCertificateAreRejected() async throws {
        let catalog = KeychainServerCertificateCatalog()
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
        let catalog = KeychainServerCertificateCatalog()

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
