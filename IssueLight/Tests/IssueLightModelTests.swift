import Foundation
import IssueLightCore
import XCTest

@MainActor
final class IssueLightModelTests: XCTestCase {
    func testManualRefreshCancelsAndReplacesActiveRefresh() async throws {
        let script = SnapshotScript()
        let harness = try await makeHarness(script: script)
        let initial = snapshot(source: harness.source, observedAt: 1, summary: "Initial")
        await script.enqueue(.result(.loaded(initial)))
        await harness.model.start()
        XCTAssertEqual(harness.model.snapshot, initial)

        await script.enqueue(.waitForCancellation)
        let replaced = try XCTUnwrap(harness.model.refresh())
        try await waitForLoads(2, script: script)
        let current = snapshot(source: harness.source, observedAt: 2, summary: "Current")
        await script.enqueue(.result(.loaded(current)))

        let replacement = try XCTUnwrap(harness.model.refresh())
        await replacement.value
        await replaced.value

        XCTAssertEqual(harness.model.snapshot, current)
        XCTAssertEqual(harness.model.refreshState, .current)
        let metrics = await script.metrics()
        XCTAssertEqual(metrics.cancellations, 1)
    }

    func testFailedRefreshRetainsLastSnapshotAsStale() async throws {
        let script = SnapshotScript()
        let harness = try await makeHarness(script: script)
        let initial = snapshot(source: harness.source, observedAt: 1, summary: "Last known")
        await script.enqueue(.result(.loaded(initial)))
        await harness.model.start()
        await script.enqueue(.result(.failed(.unreachable)))

        let refresh = try XCTUnwrap(harness.model.refresh())
        await refresh.value

        XCTAssertEqual(harness.model.snapshot, initial)
        XCTAssertEqual(harness.model.refreshState, .failed("Der Server ist nicht erreichbar."))
    }

    func testRemovingSourceCancelsRefreshAndDeletesStoredPassword() async throws {
        let script = SnapshotScript()
        let harness = try await makeHarness(script: script)
        await script.enqueue(.result(.loaded(snapshot(source: harness.source, observedAt: 1, summary: "Initial"))))
        await harness.model.start()
        await script.enqueue(.waitForCancellation)
        let refresh = try XCTUnwrap(harness.model.refresh())
        try await waitForLoads(2, script: script)

        await harness.model.deleteSource()
        await refresh.value

        XCTAssertFalse(harness.model.hasConfiguredSource)
        XCTAssertNil(harness.model.snapshot)
        XCTAssertEqual(harness.model.refreshState, .notConfigured)
        let storedSources = try await harness.store.load()
        let storedPassword = try await harness.vault.password(for: harness.scope)
        XCTAssertEqual(storedSources, [])
        XCTAssertNil(storedPassword)
        let metrics = await script.metrics()
        XCTAssertEqual(metrics.cancellations, 1)
    }

    private func makeHarness(script: SnapshotScript) async throws -> ModelHarness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IssueLightModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = MonitoringSource(
            name: "Test source",
            providerID: TestProvider.id,
            endpoint: URL(string: "https://monitoring.example.test")!,
            authentication: .basic(username: "operator")
        )
        let store = SourceStore(fileURL: directory.appendingPathComponent("sources.json"))
        _ = try await store.upsert(source)
        let vault = KeychainPasswordVault()
        let scope = try BasicCredentialScope(source: source)
        try await vault.store("test-only-password", for: scope)
        addTeardownBlock {
            try? await vault.deletePassword(for: scope)
            try? FileManager.default.removeItem(at: directory)
        }
        let registry = try ProviderRegistry([TestProvider(script: script)])
        let model = IssueLightModel(
            sourceStore: store,
            providerRegistry: registry,
            passwordVault: vault,
            identityCatalog: KeychainIdentityCatalog(),
            startsAutomatically: false
        )
        return ModelHarness(
            model: model,
            source: source,
            store: store,
            vault: vault,
            scope: scope
        )
    }

    private func snapshot(source: MonitoringSource, observedAt: TimeInterval, summary: String) -> MonitoringSnapshot {
        MonitoringSnapshot(
            sourceID: source.id,
            observedAt: Date(timeIntervalSince1970: observedAt),
            issues: [
                MonitoringIssue(
                    sourceID: source.id,
                    nativeID: "host-1",
                    kind: .host,
                    hostName: "host-1",
                    serviceName: nil,
                    displayName: "Host 1",
                    severity: .critical,
                    summary: summary,
                    isAcknowledged: false,
                    isInDowntime: false
                ),
            ]
        )
    }

    private func waitForLoads(_ expected: Int, script: SnapshotScript) async throws {
        for _ in 0..<200 {
            if await script.metrics().loads >= expected {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw ModelTestError.timeout
    }
}

private struct ModelHarness {
    let model: IssueLightModel
    let source: MonitoringSource
    let store: SourceStore
    let vault: KeychainPasswordVault
    let scope: BasicCredentialScope
}

private struct TestProvider: MonitoringProvider {
    static let id = ProviderID(rawValue: "model-test")

    let script: SnapshotScript
    let descriptor = ProviderDescriptor(
        id: TestProvider.id,
        displayName: "Model Test",
        capabilities: ProviderCapabilities(
            authenticationMethods: [.basic],
            serverTrustMethods: [.system],
            supportsAcknowledgement: false,
            supportsDowntime: false
        )
    )

    func validate(_ source: MonitoringSource) -> [SourceValidationIssue] {
        MonitoringSourceValidator.validateSharedFields(source)
    }

    func testConnection(
        to source: MonitoringSource,
        credential: ProviderCredential
    ) async -> ConnectionTestResult {
        .connected
    }

    func loadSnapshot(
        from source: MonitoringSource,
        credential: ProviderCredential
    ) async -> SnapshotLoadResult {
        await script.load()
    }
}

private actor SnapshotScript {
    enum Behavior: Sendable {
        case result(SnapshotLoadResult)
        case waitForCancellation
    }

    private var behaviors: [Behavior] = []
    private var loadCount = 0
    private var cancellationCount = 0

    func enqueue(_ behavior: Behavior) {
        behaviors.append(behavior)
    }

    func load() async -> SnapshotLoadResult {
        loadCount += 1
        guard !behaviors.isEmpty else {
            return .failed(.incompatibleResponse)
        }
        switch behaviors.removeFirst() {
        case .result(let result):
            return result
        case .waitForCancellation:
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            cancellationCount += 1
            return .failed(.cancelled)
        }
    }

    func metrics() -> (loads: Int, cancellations: Int) {
        (loadCount, cancellationCount)
    }
}

private enum ModelTestError: Error {
    case timeout
}
