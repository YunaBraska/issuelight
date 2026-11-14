import XCTest

@MainActor
final class AppLanguageTests: XCTestCase {
    func testSupportedLanguagesContainTwentyRankedLanguagesAndSwedishOnce() {
        XCTAssertEqual(
            AppLanguage.supportedLanguages.map(\.rawValue),
            [
                "en", "zh-Hans", "hi", "es", "ar", "fr", "bn", "pt", "id", "ur",
                "ru", "de", "ja", "pcm", "mr", "vi", "te", "sw", "ha", "tr", "sv",
            ]
        )
        XCTAssertEqual(Set(AppLanguage.supportedLanguages.map(\.rawValue)).count, 21)
    }

    func testSystemDefaultIsAChoiceButNotALocalization() {
        XCTAssertEqual(AppLanguage.allCases.count, 22)
        XCTAssertFalse(AppLanguage.supportedLanguages.contains(.system))
    }

    func testOnlyArabicAndUrduUseRightToLeftLayout() {
        XCTAssertEqual(
            Set(AppLanguage.supportedLanguages.filter(\.isRightToLeft)),
            [.arabic, .urdu]
        )
    }

    func testStringCatalogResolvesExplicitRuntimeLocales() {
        XCTAssertEqual(
            AppLocalization.string("Sprache", locale: Locale(identifier: "en")),
            "Language"
        )
        XCTAssertEqual(
            AppLocalization.string("Sprache", locale: Locale(identifier: "sv")),
            "Språk"
        )
        XCTAssertEqual(
            AppLocalization.string("Sprache", locale: Locale(identifier: "ar")),
            "لغة"
        )
    }

    func testSelectionPersistsInInjectedDefaults() throws {
        let suiteName = "berlin.yuna.issuelight.language-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppLanguageSettings(defaults: defaults)

        XCTAssertEqual(settings.selection, .system)
        settings.selection = .swedish

        XCTAssertEqual(AppLanguageSettings(defaults: defaults).selection, .swedish)
    }

    func testUnknownStoredLanguageFallsBackToSystemDefault() throws {
        let suiteName = "berlin.yuna.issuelight.language-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("not-a-language", forKey: AppLanguageSettings.defaultsKey)

        XCTAssertEqual(AppLanguageSettings(defaults: defaults).selection, .system)
    }
}
