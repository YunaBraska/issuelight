import XCTest
@testable import IssueLightCore

final class KeychainIdentityCatalogTests: XCTestCase {
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
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".p12")
        try Data("not a certificate".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let catalog = KeychainIdentityCatalog()

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
}
