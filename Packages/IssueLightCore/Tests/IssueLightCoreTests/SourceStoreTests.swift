import XCTest
@testable import IssueLightCore

final class SourceStoreTests: XCTestCase {
    func testStorePersistsAndUpdatesPublicSourceConfiguration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("sources.json")
        let store = SourceStore(fileURL: fileURL)
        var source = makeSource()

        let inserted = try await store.upsert(source)
        XCTAssertEqual(inserted, [source])

        source.name = "Renamed"
        source.serverTrust = .disabled
        let updated = try await store.upsert(source)
        XCTAssertEqual(updated, [source])
        let loaded = try await store.load()
        XCTAssertEqual(loaded, [source])

        let rawJSON = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(rawJSON.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(rawJSON.localizedCaseInsensitiveContains("privateKey"))

        let removed = try await store.remove(id: source.id)
        XCTAssertEqual(removed, [])
    }

    func testStoreRejectsDuplicateSourceIdentifiers() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sources.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = SourceStore(fileURL: fileURL)
        let source = makeSource()

        do {
            _ = try await store.save([source, source])
            XCTFail("Expected duplicate source rejection")
        } catch {
            XCTAssertEqual(error as? SourceStoreError, .duplicateSourceID(source.id))
        }
    }

    private func makeSource() -> MonitoringSource {
        MonitoringSource(
            name: "Production",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: "https://icinga.example.test:5665/v1")!,
            authentication: .basic(username: "operator")
        )
    }
}
