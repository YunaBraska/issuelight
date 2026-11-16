import Foundation
import XCTest

final class LocalizationCatalogTests: XCTestCase {
    private struct StringUnit {
        let state: String
        let value: String
    }

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
            if let germanUnit = stringUnit(in: localizations["de"]) {
                XCTAssertEqual(germanUnit.state, "translated", "de: \(key)")
            }

            for locale in translatedLocales {
                let unit = try XCTUnwrap(
                    stringUnit(in: localizations[locale]),
                    "Missing \(locale) translation for \(key)"
                )
                XCTAssertEqual(unit.state, "translated", "\(locale): \(key)")
                XCTAssertFalse(unit.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                XCTAssertEqual(
                    try formatTokens(in: unit.value),
                    try formatTokens(in: source),
                    "Broken format tokens in \(locale): \(key)"
                )
                for protectedTerm in protectedTerms where source.contains(protectedTerm) {
                    XCTAssertTrue(
                        unit.value.contains(protectedTerm),
                        "Missing \(protectedTerm) in \(locale): \(key)"
                    )
                }
                for sourceLanguageTerm in sourceLanguageTerms {
                    XCTAssertFalse(
                        unit.value.contains(sourceLanguageTerm),
                        "German source text leaked into \(locale): \(key)"
                    )
                }
                XCTAssertFalse(
                    unit.value.range(of: #"(?:\b\w+\b)(?:\s+\1){8,}"#, options: .regularExpression) != nil,
                    "Suspicious repetition in \(locale): \(key)"
                )
            }
        }
    }

    func testCatalogContainsEveryStaticSourceKey() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IssueLightLocalization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceDirectory = catalogURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        let sourceFiles = try FileManager.default.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }
        .map(\.path)
        .sorted()

        let process = Process()
        let diagnostics = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xcstringstool", "extract",
            "--SwiftUI",
            "--modern-localizable-strings",
            "--legacy-localizable-strings",
            "--output-format", "xcstrings",
            "--output-directory", temporaryDirectory.path,
        ] + sourceFiles
        process.standardError = diagnostics
        try process.run()
        process.waitUntilExit()
        let diagnosticText = String(
            decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertEqual(process.terminationStatus, 0, diagnosticText)

        let extractedData = try Data(
            contentsOf: temporaryDirectory.appendingPathComponent("Localizable.xcstrings")
        )
        let extractedCatalog = try XCTUnwrap(
            JSONSerialization.jsonObject(with: extractedData) as? [String: Any]
        )
        let extractedStrings = try XCTUnwrap(extractedCatalog["strings"] as? [String: Any])
        let catalogStrings = try XCTUnwrap(loadCatalog()["strings"] as? [String: Any])
        let missingKeys = Set(extractedStrings.keys)
            .subtracting(catalogStrings.keys)
            .filter { !$0.isEmpty && !$0.contains("%arg") }
            .sorted()

        XCTAssertTrue(missingKeys.isEmpty, "Missing source keys: \(missingKeys)")
    }

    func testCatalogContainsEveryStaticAppLocalizationKey() throws {
        let sourceDirectory = catalogURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        let sourceFiles = try FileManager.default.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.path < $1.path }
        let expression = try NSRegularExpression(
            pattern: #"AppLocalization\s*\.\s*string\s*\(\s*\"((?:\\.|[^\"\\])*)\""#
        )
        var referencedKeys = Set<String>()

        for sourceFile in sourceFiles {
            let source = try String(contentsOf: sourceFile, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in expression.matches(in: source, range: range) {
                guard let captureRange = Range(match.range(at: 1), in: source) else { continue }
                let literal = String(source[captureRange])
                guard !literal.contains(#"\("#) else { continue }
                let encoded = try XCTUnwrap(
                    "\"\(literal)\"".data(using: .utf8),
                    sourceFile.lastPathComponent
                )
                let key = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: encoded, options: .fragmentsAllowed) as? String,
                    "Invalid localized string literal in \(sourceFile.lastPathComponent): \(literal)"
                )
                referencedKeys.insert(key)
            }
        }

        let catalogStrings = try XCTUnwrap(loadCatalog()["strings"] as? [String: Any])
        let missingKeys = referencedKeys.subtracting(catalogStrings.keys).sorted()
        XCTAssertTrue(missingKeys.isEmpty, "Missing AppLocalization keys: \(missingKeys)")
    }

    private var protectedTerms: [String] {
        ["IssueLight", "macOS", "Icinga", "PKCS#12", "SHA-256", "HTTP", "TLS", "API"]
    }

    private var sourceLanguageTerms: [String] {
        [
            "Benutzername", "Einstellungen", "Passwort", "Quelle", "Quellen",
            "Schlüsselbund", "Wartungszeit", "Zertifikat", "auswählen", "entfernt",
            "folgt", "fragt", "gespeichert", "gewählte", "geprüft", "importieren",
            "konfiguriert", "pausiert", "prüft", "verwendet",
        ]
    }

    private func loadCatalog() throws -> [String: Any] {
        let data = try Data(contentsOf: catalogURL)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private var catalogURL: URL {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Localizable.xcstrings")
    }

    private func stringUnit(in rawLocalization: Any?) -> StringUnit? {
        guard
            let localization = rawLocalization as? [String: Any],
            let unit = localization["stringUnit"] as? [String: Any],
            let state = unit["state"] as? String,
            let value = unit["value"] as? String
        else {
            return nil
        }
        return StringUnit(state: state, value: value)
    }

    private func formatTokens(in value: String) throws -> [String] {
        let expression = try NSRegularExpression(
            pattern: #"%(?:\d+\$)?(?:@|lld|ld|d|f)"#
        )
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            Range(match.range, in: value).map { String(value[$0]) }
        }
    }
}
