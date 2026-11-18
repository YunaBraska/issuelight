import XCTest

final class SourceNameSuggestionTests: XCTestCase {
    func testCreativeDefaultsProvideAtLeastTwentyDistinctNames() {
        XCTAssertGreaterThanOrEqual(Set(SourceNameSuggestion.creativeDefaults).count, 20)
    }

    func testHostnameTakesPrecedenceOverCreativeFallback() {
        XCTAssertEqual(
            SourceNameSuggestion.name(
                rawEndpoint: "https://prod-icinga.ops.example:5665/v1",
                providerName: "Icinga 2",
                sourceID: UUID()
            ),
            "Production Icinga"
        )
        XCTAssertEqual(
            SourceNameSuggestion.name(
                rawEndpoint: "monitoring.example.test/thruk",
                providerName: "Thruk",
                sourceID: UUID()
            ),
            "Monitoring"
        )
    }

    func testLocalhostIncludesTheProviderName() {
        XCTAssertEqual(
            SourceNameSuggestion.name(
                rawEndpoint: "http://localhost:8080/cmk",
                providerName: "Checkmk",
                sourceID: UUID()
            ),
            "Local Checkmk"
        )
    }

    func testFallbackIsStableForOneDraft() {
        let sourceID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let first = SourceNameSuggestion.name(
            rawEndpoint: "",
            providerName: "Icinga 2",
            sourceID: sourceID
        )
        let second = SourceNameSuggestion.name(
            rawEndpoint: "not a URL %",
            providerName: "Icinga 2",
            sourceID: sourceID
        )

        XCTAssertEqual(first, second)
        XCTAssertTrue(SourceNameSuggestion.creativeDefaults.contains(first))
    }
}
