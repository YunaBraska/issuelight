import Security
import XCTest
@testable import IssueLightCore

final class ServerCertificateFingerprintTests: XCTestCase {
    func testFingerprintReadsOneCertificate() throws {
        let fingerprint = try ServerCertificateFingerprint.sha256(at: certificateFixtureURL)

        XCTAssertEqual(fingerprint.split(separator: ":").count, 32)
    }

    func testFingerprintReadsDERCertificate() throws {
        let certificate = try ServerCertificateFingerprint.certificate(at: certificateFixtureURL)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("IssueLightCertificate-\(UUID().uuidString).der")
        try (SecCertificateCopyData(certificate) as Data).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertEqual(
            try ServerCertificateFingerprint.sha256(at: fileURL),
            ServerCertificateFingerprint.sha256(of: certificate)
        )
    }

    func testFingerprintNormalizesCommonRepresentations() throws {
        let fingerprint = try ServerCertificateFingerprint.sha256(at: certificateFixtureURL)

        XCTAssertEqual(
            ServerCertificateFingerprint.normalizedSHA256(fingerprint.lowercased()),
            fingerprint
        )
        XCTAssertEqual(
            ServerCertificateFingerprint.normalizedSHA256(fingerprint.replacingOccurrences(of: ":", with: "")),
            fingerprint
        )
        XCTAssertNil(ServerCertificateFingerprint.normalizedSHA256("not-a-sha256-fingerprint"))
    }

    func testFingerprintRejectsMultipleCertificates() throws {
        let certificateData = try Data(contentsOf: certificateFixtureURL)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("IssueLightMultipleCertificates-\(UUID().uuidString).pem")
        try (certificateData + certificateData).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertThrowsError(try ServerCertificateFingerprint.sha256(at: fileURL)) { error in
            XCTAssertEqual(
                error as? ServerCertificateFingerprintError,
                .multipleCertificatesNotSupported
            )
        }
    }

    private var certificateFixtureURL: URL {
        get throws {
            try XCTUnwrap(
                Bundle.module.url(
                    forResource: "issuelight-test-root",
                    withExtension: "crt",
                    subdirectory: "Fixtures"
                )
            )
        }
    }
}
