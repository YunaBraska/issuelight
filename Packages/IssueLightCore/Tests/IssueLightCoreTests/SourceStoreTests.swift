import XCTest
@testable import IssueLightCore

final class SourceStoreTests: XCTestCase {
    func testDefaultFileURLUsesBundleSpecificApplicationSupportLocation() throws {
        let bundleIdentifier = "io.github.yunabraska.issuelight.store-tests.\(UUID().uuidString)"

        let fileURL = try SourceStore.defaultFileURL(bundleIdentifier: bundleIdentifier)

        XCTAssertEqual(fileURL.lastPathComponent, "sources.json")
        XCTAssertEqual(fileURL.deletingLastPathComponent().lastPathComponent, bundleIdentifier)
        XCTAssertTrue(fileURL.path.contains("Application Support"))
    }

    func testStoreRejectsMalformedPersistedJSON() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("sources.json")
        try Data("not JSON".utf8).write(to: fileURL)
        let store = SourceStore(fileURL: fileURL)

        do {
            _ = try await store.load()
            XCTFail("Expected malformed source persistence rejection")
        } catch {
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testStoreRejectsDuplicateIdentifiersWhenLoadingExistingData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("sources.json")
        let source = makeSource()
        try JSONEncoder().encode([source, source]).write(to: fileURL)
        let store = SourceStore(fileURL: fileURL)

        do {
            _ = try await store.load()
            XCTFail("Expected duplicate source rejection")
        } catch {
            XCTAssertEqual(error as? SourceStoreError, .duplicateSourceID(source.id))
        }
    }

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
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)

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
