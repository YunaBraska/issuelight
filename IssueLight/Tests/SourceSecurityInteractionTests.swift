import IssueLightCore
import SwiftUI
import XCTest

@MainActor
final class SourceSecurityInteractionTests: XCTestCase {
    func testPresentedCertificateReviewRendersFingerprintWithoutClipping() throws {
        let certificate = PresentedServerCertificate(
            endpoint: URL(string: "https://monitoring.example.test:5665")!,
            subject: "monitoring.example.test",
            sha256Fingerprint: String(repeating: "A1:", count: 31) + "A1"
        )
        let view = PresentedServerCertificateTrustView(
            certificate: certificate,
            cancel: {},
            trust: {}
        )
        .environment(\.locale, Locale(identifier: "de_DE"))
        .environment(\.colorScheme, .light)
        let size = NativeViewRenderer.fittingSize(
            for: view,
            maximumSize: CGSize(width: 600, height: 500)
        )

        XCTAssertEqual(size.width, 520, accuracy: 1)
        XCTAssertGreaterThan(size.height, 240)
        XCTAssertLessThan(size.height, 500)
        XCTAssertTrue(NativeViewRenderer.exerciseWindow(for: view, size: size))
        if let outputPath = ProcessInfo.processInfo.environment[
            "ISSUELIGHT_CERTIFICATE_REVIEW_SCREENSHOT_PATH"
        ] {
            let pngData = try NativeViewRenderer.pngData(for: view, size: size)
            XCTAssertGreaterThan(pngData.count, 20_000)
            try pngData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
    }
}
