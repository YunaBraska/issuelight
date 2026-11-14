import Foundation
import XCTest

final class LocalizationCatalogTests: XCTestCase {
    func testEverySupportedLanguageHasACompleteSafeCatalog() throws {
        let catalog = try loadCatalog()
        XCTAssertEqual(catalog["sourceLanguage"] as? String, "de")
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        XCTAssertGreaterThan(strings.count, 150)
        let translatedLocales = Set(
            AppLanguage.supportedLanguages
                .filter { $0 != .german }
                .map(\.rawValue)
        )

        for (key, rawEntry) in strings {
            let entry = try XCTUnwrap(rawEntry as? [String: Any], key)
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                "Missing localizations for \(key)"
            )
            let source = stringUnit(in: localizations["de"])?.value ?? key

            for locale in translatedLocales {
                let unit = try XCTUnwrap(
                    stringUnit(in: localizations[locale]),
                    "Missing \(locale) translation for \(key)"
                )
                XCTAssertEqual(unit.state, "machine_translated", "\(locale): \(key)")
                XCTAssertFalse(unit.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                XCTAssertEqual(
                    formatTokens(in: unit.value),
                    formatTokens(in: source),
                    "Broken format tokens in \(locale): \(key)"
                )
                for protectedTerm in protectedTerms where source.contains(protectedTerm) {
                    XCTAssertTrue(
                        unit.value.contains(protectedTerm),
                        "Missing \(protectedTerm) in \(locale): \(key)"
                    )
                }
                XCTAssertFalse(
                    unit.value.range(of: #"(?:\b\w+\b)(?:\s+\1){8,}"#, options: .regularExpression) != nil,
                    "Suspicious repetition in \(locale): \(key)"
                )
            }
        }
    }

    private var protectedTerms: [String] {
        ["IssueLight", "macOS", "Icinga", "PKCS#12", "SHA-256", "HTTP", "TLS", "API"]
    }

    private func loadCatalog() throws -> [String: Any] {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let catalogURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func stringUnit(in rawLocalization: Any?) -> (state: String, value: String)? {
        guard
            let localization = rawLocalization as? [String: Any],
            let unit = localization["stringUnit"] as? [String: Any],
            let state = unit["state"] as? String,
            let value = unit["value"] as? String
        else {
            return nil
        }
        return (state, value)
    }

    private func formatTokens(in value: String) -> [String] {
        let expression = try! NSRegularExpression(
            pattern: #"%(?:\d+\$)?(?:@|lld|ld|d|f)"#
        )
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            Range(match.range, in: value).map { String(value[$0]) }
        }
    }
}
