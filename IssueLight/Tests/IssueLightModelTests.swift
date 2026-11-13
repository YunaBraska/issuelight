import Foundation
import XCTest
@testable import IssueLightCore

@MainActor
final class IssueLightModelTests: XCTestCase {
    private var testKeychain: TemporaryTestKeychain!

    override func setUpWithError() throws {
        testKeychain = try TemporaryTestKeychain()
    }

    override func tearDownWithError() throws {
        try testKeychain.delete()
        testKeychain = nil
    }

    func testStartRefreshesEveryEnabledSourceAndAggregatesIssues() async throws {
        let script = SnapshotScript()
        let harness = try await makeHarness(sourceCount: 2, script: script)
        let firstSnapshot = snapshot(source: harness.sources[0], observedAt: 1, summary: "Critical")
        let secondSnapshot = snapshot(
            source: harness.sources[1],
            observedAt: 2,
            summary: "Warning",
            severity: .warning
        )
        await script.enqueue(.result(.loaded(firstSnapshot)), for: harness.sources[0].id)
        await script.enqueue(.result(.loaded(secondSnapshot)), for: harness.sources[1].id)

        await harness.model.start()

        XCTAssertEqual(harness.model.snapshots[harness.sources[0].id], firstSnapshot)
        XCTAssertEqual(harness.model.snapshots[harness.sources[1].id], secondSnapshot)
        XCTAssertEqual(harness.model.actionableIssues.map(\.summary), ["Critical", "Warning"])
        XCTAssertEqual(harness.model.refreshState, .current)
    }

    func testManualRefreshCancelsAndReplacesOnlyThatSourcesActiveRefresh() async throws {
        let script = SnapshotScript()
        let harness = try await makeHarness(sourceCount: 2, script: script)
        for source in harness.sources {
            await script.enqueue(.result(.loaded(snapshot(source: source, observedAt: 1, summary: source.name))), for: source.id)
        }
        await harness.model.start()

        let firstSource = harness.sources[0]
        await script.enqueue(.waitForCancellation, for: firstSource.id)
        let replaced = try XCTUnwrap(harness.model.refresh(sourceID: firstSource.id))
        try await waitForLoads(2, sourceID: firstSource.id, script: script)
        let current = snapshot(source: firstSource, observedAt: 2, summary: "Current")
        await script.enqueue(.result(.loaded(current)), for: firstSource.id)

        let replacement = try XCTUnwrap(harness.model.refresh(sourceID: firstSource.id))
        await replacement.value
        await replaced.value

        XCTAssertEqual(harness.model.snapshots[firstSource.id], current)
        XCTAssertEqual(harness.model.sourceRefreshState(for: firstSource.id), .current)
        let firstMetrics = await script.metrics(for: firstSource.id)
        let secondMetrics = await script.metrics(for: harness.sources[1].id)
        XCTAssertEqual(firstMetrics.cancellations, 1)
        XCTAssertEqual(secondMetrics.cancellations, 0)
        XCTAssertEqual(secondMetrics.loads, 1)
    }

    func testFailedSourceRetainsItsSnapshotWhileAnotherSourceUpdates() async throws {
        let script = SnapshotScript()
        let harness = try await makeHarness(sourceCount: 2, script: script)
        let firstSnapshot = snapshot(source: harness.sources[0], observedAt: 1, summary: "Last known")
        let secondSnapshot = snapshot(source: harness.sources[1], observedAt: 1, summary: "Before")
        await script.enqueue(.result(.loaded(firstSnapshot)), for: harness.sources[0].id)
        await script.enqueue(.result(.loaded(secondSnapshot)), for: harness.sources[1].id)
        await harness.model.start()

        let updatedSecond = snapshot(source: harness.sources[1], observedAt: 2, summary: "Current")
        await script.enqueue(.result(.failed(.unreachable)), for: harness.sources[0].id)
        await script.enqueue(.result(.loaded(updatedSecond)), for: harness.sources[1].id)
        let refresh = try XCTUnwrap(harness.model.refresh())
        await refresh.value

        XCTAssertEqual(harness.model.snapshots[harness.sources[0].id], firstSnapshot)
        XCTAssertEqual(harness.model.snapshots[harness.sources[1].id], updatedSecond)
        XCTAssertEqual(harness.model.failedSources.map(\.source.id), [harness.sources[0].id])
        XCTAssertTrue(harness.model.hasPartialRefreshFailure)
        XCTAssertEqual(harness.model.refreshState, .failed("Source 1: Der Server ist nicht erreichbar."))
        XCTAssertEqual(Set(harness.model.actionableIssues.map(\.summary)), ["Last known", "Current"])
        XCTAssertEqual(harness.model.menuBarSymbol, "exclamationmark.octagon.fill")
    }

    func testRemovingSourceCancelsItsRefreshAndPreservesOtherSourceAndCredential() async throws {
        let script = SnapshotScript()
        let harness = try await makeHarness(sourceCount: 2, script: script)
        for source in harness.sources {
            await script.enqueue(.result(.loaded(snapshot(source: source, observedAt: 1, summary: source.name))), for: source.id)
        }
        await harness.model.start()

        let removedSource = harness.sources[0]
        let retainedSource = harness.sources[1]
        await script.enqueue(.waitForCancellation, for: removedSource.id)
        let refresh = try XCTUnwrap(harness.model.refresh(sourceID: removedSource.id))
        try await waitForLoads(2, sourceID: removedSource.id, script: script)

        await harness.model.deleteSource()
        await refresh.value

        XCTAssertEqual(harness.model.sources, [retainedSource])
        XCTAssertEqual(harness.model.selectedSourceID, retainedSource.id)
        XCTAssertNil(harness.model.snapshots[removedSource.id])
        XCTAssertNotNil(harness.model.snapshots[retainedSource.id])
        let removedPassword = try await harness.vault.password(for: harness.scopes[0])
        let retainedPassword = try await harness.vault.password(for: harness.scopes[1])
        let persistedSources = try await harness.store.load()
        XCTAssertNil(removedPassword)
        XCTAssertEqual(retainedPassword, "test-only-password-2")
        XCTAssertEqual(persistedSources, [retainedSource])
        let metrics = await script.metrics(for: removedSource.id)
        XCTAssertEqual(metrics.cancellations, 1)
    }

    func testSavingLastPrivateCAReferenceRemovesOnlyIssueLightManagedCertificate() async throws {
        try requireUnlockedDefaultKeychain()
        let catalog = KeychainServerCertificateCatalog(
            ownershipScope: "berlin.yuna.issuelight.model-tests.\(UUID().uuidString)"
        )
        let descriptor = try await catalog.importCertificate(at: serverCertificateFixtureURL)
        addTeardownBlock {
            try? await catalog.deleteCertificate(id: descriptor.id)
        }
        let script = SnapshotScript()
        let harness = try await makeHarness(
            sourceCount: 2,
            script: script,
            serverTrust: .customCertificate(certificateID: descriptor.id),
            certificateCatalog: catalog
        )
        await harness.model.load()

        harness.model.serverTrustChoice = .system
        await harness.model.save()

        let retainedCertificate = try await catalog.certificate(id: descriptor.id)
        let oneReferencePersisted = try await harness.store.load()
        XCTAssertNotNil(retainedCertificate)
        XCTAssertNil(harness.model.selectedServerCertificate)
        XCTAssertEqual(
            oneReferencePersisted.compactMap(\.customServerCertificateID),
            [descriptor.id]
        )

        await harness.model.selectSource(id: harness.sources[1].id)
        harness.model.serverTrustChoice = .system
        await harness.model.save()

        let removedCertificate = try await catalog.certificate(id: descriptor.id)
        let noReferencesPersisted = try await harness.store.load()
        XCTAssertNil(removedCertificate)
        XCTAssertEqual(noReferencesPersisted.compactMap(\.customServerCertificateID), [])
    }

    func testDeletingLastPrivateCASourceRemovesIssueLightManagedCertificate() async throws {
        try requireUnlockedDefaultKeychain()
        let catalog = KeychainServerCertificateCatalog(
            ownershipScope: "berlin.yuna.issuelight.model-tests.\(UUID().uuidString)"
        )
        let descriptor = try await catalog.importCertificate(at: serverCertificateFixtureURL)
        addTeardownBlock {
            try? await catalog.deleteCertificate(id: descriptor.id)
        }
        let harness = try await makeHarness(
            sourceCount: 1,
            script: SnapshotScript(),
            serverTrust: .customCertificate(certificateID: descriptor.id),
            certificateCatalog: catalog
        )
        await harness.model.load()

        await harness.model.deleteSource()

        let removedCertificate = try await catalog.certificate(id: descriptor.id)
        let persistedSources = try await harness.store.load()
        XCTAssertNil(removedCertificate)
        XCTAssertEqual(persistedSources, [])
    }

    func testLoadingRemovesOrphanedManagedCertificateFromSameAppProfile() async throws {
        try requireUnlockedDefaultKeychain()
        let catalog = KeychainServerCertificateCatalog(
            ownershipScope: "berlin.yuna.issuelight.model-tests.\(UUID().uuidString)"
        )
        let descriptor = try await catalog.importCertificate(at: serverCertificateFixtureURL)
        addTeardownBlock {
            try? await catalog.deleteCertificate(id: descriptor.id)
        }
        let harness = try await makeHarness(
            sourceCount: 1,
            script: SnapshotScript(),
            certificateCatalog: catalog
        )

        await harness.model.load()

        let removedCertificate = try await catalog.certificate(id: descriptor.id)
        XCTAssertNil(removedCertificate)
    }

    func testDisablingSourcePersistsChoiceAndExcludesItsSnapshotWithoutDeletingCredential() async throws {
        let script = SnapshotScript()
        let harness = try await makeHarness(sourceCount: 2, script: script)
        for source in harness.sources {
            await script.enqueue(.result(.loaded(snapshot(source: source, observedAt: 1, summary: source.name))), for: source.id)
        }
        await harness.model.start()

        harness.model.isSourceEnabled = false
        await harness.model.save()

        XCTAssertEqual(harness.model.sourceRefreshState(for: harness.sources[0].id), .disabled)
        XCTAssertEqual(harness.model.actionableIssues.map(\.sourceID), [harness.sources[1].id])
        let retainedPassword = try await harness.vault.password(for: harness.scopes[0])
        XCTAssertEqual(retainedPassword, "test-only-password-1")
        let persisted = try await harness.store.load()
        XCTAssertFalse(try XCTUnwrap(persisted.first).isEnabled)
        XCTAssertTrue(persisted[1].isEnabled)
    }

    func testNewDraftDoesNotPersistUntilSaveAndAppendsStableSource() async throws {
        let script = SnapshotScript()
        let harness = try await makeHarness(sourceCount: 1, script: script)
        await script.enqueue(
            .result(.loaded(snapshot(source: harness.sources[0], observedAt: 1, summary: "Existing"))),
            for: harness.sources[0].id
        )
        await harness.model.start()

        harness.model.beginAddingSource()
        harness.model.name = "New source"
        harness.model.endpoint = "https://new-source.example.test"
        harness.model.username = "operator"
        harness.model.password = "test-only-new-password"
        XCTAssertTrue(harness.model.hasUnsavedChanges)
        let sourcesBeforeSave = try await harness.store.load()
        XCTAssertEqual(sourcesBeforeSave, harness.sources)

        await harness.model.save()

        XCTAssertEqual(harness.model.sources.count, 2)
        let added = try XCTUnwrap(harness.model.sources.last)
        XCTAssertEqual(added.name, "New source")
        XCTAssertEqual(harness.model.selectedSourceID, added.id)
        let sourcesAfterSave = try await harness.store.load()
        XCTAssertEqual(sourcesAfterSave, harness.model.sources)
        let addedScope = try BasicCredentialScope(source: added)
        let addedPassword = try await harness.vault.password(for: addedScope)
        XCTAssertEqual(addedPassword, "test-only-new-password")
        addTeardownBlock {
            try? await harness.vault.deletePassword(for: addedScope)
        }
    }

    func testSelectingSourceLoadsItsIndependentFormAndStoredPasswordState() async throws {
        let script = SnapshotScript()
        let harness = try await makeHarness(sourceCount: 2, script: script)
        await harness.model.load()

        harness.model.name = "Unsaved"
        XCTAssertTrue(harness.model.hasUnsavedChanges)
        await harness.model.selectSource(id: harness.sources[1].id)

        XCTAssertEqual(harness.model.selectedSourceID, harness.sources[1].id)
        XCTAssertEqual(harness.model.name, "Source 2")
        XCTAssertEqual(harness.model.endpoint, harness.sources[1].endpoint.absoluteString)
        XCTAssertEqual(harness.model.username, "operator-2")
        XCTAssertTrue(harness.model.hasStoredBasicPassword)
        XCTAssertFalse(harness.model.hasUnsavedChanges)
    }

    func testSelectingPinnedSourceLoadsReviewedFingerprint() async throws {
        let script = SnapshotScript()
        let fingerprint = String(repeating: "AA:", count: 31) + "AA"
        let harness = try await makeHarness(
            sourceCount: 1,
            script: script,
            serverTrust: .pinnedCertificate(sha256: fingerprint)
        )

        await harness.model.load()

        XCTAssertEqual(harness.model.serverTrustChoice, .pinnedCertificate)
        XCTAssertEqual(harness.model.pinnedServerCertificateSHA256, fingerprint)
        XCTAssertFalse(harness.model.hasUnsavedChanges)
    }

    func testSelectingServerCertificateCreatesPinAndMarksFormUnsaved() async throws {
        let harness = try await makeHarness(sourceCount: 1, script: SnapshotScript())
        await harness.model.load()

        XCTAssertTrue(harness.model.pinServerCertificate(at: serverCertificateFixtureURL))

        XCTAssertEqual(harness.model.serverTrustChoice, .pinnedCertificate)
        XCTAssertEqual(
            harness.model.pinnedServerCertificateSHA256,
            try ServerCertificateFingerprint.sha256(at: serverCertificateFixtureURL)
        )
        XCTAssertTrue(harness.model.hasUnsavedChanges)
    }

    func testAllDisabledSourcesRemainPausedAndPerformNoRefreshWork() async throws {
        let script = SnapshotScript()
        let harness = try await makeHarness(
            sourceCount: 2,
            script: script,
            disabledIndexes: [1, 2]
        )

        await harness.model.start()

        XCTAssertEqual(harness.model.refreshState, .disabled)
        XCTAssertFalse(harness.model.hasEnabledSource)
        XCTAssertEqual(harness.model.actionableIssues, [])
        for source in harness.sources {
            let metrics = await script.metrics(for: source.id)
            XCTAssertEqual(metrics.loads, 0)
        }
    }

    func testLiveIcingaRefreshesMultiplePersistedSourcesThroughAppModel() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpointValue = environment["ISSUELIGHT_LIVE_ICINGA_URL"],
              let endpoint = URL(string: endpointValue),
              let password = environment["ISSUELIGHT_ICINGA_BASIC_PASSWORD"],
              let certificatePath = environment["ISSUELIGHT_LIVE_ICINGA_CA_PATH"] else {
            if environment["ISSUELIGHT_REQUIRE_LIVE_ICINGA"] == "1" {
                XCTFail("The required live Icinga 2 environment is incomplete")
                return
            }
            throw XCTSkip("Live Icinga 2 environment is not configured")
        }
        try requireUnlockedDefaultKeychain()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IssueLightLiveModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let certificateCatalog = KeychainServerCertificateCatalog(
            ownershipScope: "berlin.yuna.issuelight.live-model-tests.\(UUID().uuidString)"
        )
        let certificate = try await certificateCatalog.importCertificate(
            at: URL(fileURLWithPath: certificatePath)
        )
        let sources = ["Live primary", "Live secondary"].map { name in
            MonitoringSource(
                name: name,
                providerID: Icinga2Provider.id,
                endpoint: endpoint,
                authentication: .basic(username: "issuelight-basic"),
                serverTrust: .customCertificate(certificateID: certificate.id)
            )
        }
        let store = SourceStore(fileURL: directory.appendingPathComponent("sources.json"))
        let vault = KeychainPasswordVault(keychainContext: testKeychain.context)
        let scopes = try sources.map(BasicCredentialScope.init(source:))
        addTeardownBlock {
            for scope in scopes {
                try? await vault.deletePassword(for: scope)
            }
            try? await certificateCatalog.deleteCertificate(id: certificate.id)
            try? FileManager.default.removeItem(at: directory)
        }
        _ = try await store.save(sources)
        for scope in scopes {
            try await vault.store(password, for: scope)
        }
        let model = IssueLightModel(
            sourceStore: store,
            providerRegistry: .builtIn(),
            passwordVault: vault,
            identityCatalog: KeychainIdentityCatalog(),
            certificateCatalog: certificateCatalog,
            startsAutomatically: false
        )

        await model.start()

        XCTAssertEqual(model.refreshState, .current)
        XCTAssertEqual(Set(model.snapshots.keys), Set(sources.map(\.id)))
        for source in sources {
            let snapshot = try XCTUnwrap(model.snapshots[source.id])
            XCTAssertEqual(snapshot.issues.count, 2)
            XCTAssertTrue(snapshot.issues.contains {
                $0.kind == .host && $0.hostName == "down-host" && $0.severity == .critical
            })
            XCTAssertTrue(snapshot.issues.contains {
                $0.kind == .service
                    && $0.hostName == "down-host"
                    && $0.serviceName == "cascaded-service"
            })
        }
    }

    private func makeHarness(
        sourceCount: Int,
        script: SnapshotScript,
        disabledIndexes: Set<Int> = [],
        serverTrust: ServerTrustConfiguration = .system,
        certificateCatalog: KeychainServerCertificateCatalog? = nil
    ) async throws -> ModelHarness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IssueLightModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sources = (1...sourceCount).map { index in
            MonitoringSource(
                name: "Source \(index)",
                providerID: TestProvider.id,
                endpoint: URL(string: "https://monitoring\(index).example.test")!,
                isEnabled: !disabledIndexes.contains(index),
                authentication: .basic(username: "operator-\(index)"),
                serverTrust: serverTrust
            )
        }
        let store = SourceStore(fileURL: directory.appendingPathComponent("sources.json"))
        _ = try await store.save(sources)
        let vault = KeychainPasswordVault(keychainContext: testKeychain.context)
        let scopes = try sources.map(BasicCredentialScope.init(source:))
        for (index, scope) in scopes.enumerated() {
            try await vault.store("test-only-password-\(index + 1)", for: scope)
        }
        addTeardownBlock {
            for scope in scopes {
                try? await vault.deletePassword(for: scope)
            }
            try? FileManager.default.removeItem(at: directory)
        }
        let registry = try ProviderRegistry([TestProvider(script: script)])
        let resolvedCertificateCatalog = certificateCatalog ?? KeychainServerCertificateCatalog(
            ownershipScope: "berlin.yuna.issuelight.model-tests.\(UUID().uuidString)"
        )
        let model = IssueLightModel(
            sourceStore: store,
            providerRegistry: registry,
            passwordVault: vault,
            identityCatalog: KeychainIdentityCatalog(),
            certificateCatalog: resolvedCertificateCatalog,
            startsAutomatically: false
        )
        return ModelHarness(
            model: model,
            sources: sources,
            store: store,
            vault: vault,
            scopes: scopes
        )
    }

    private var serverCertificateFixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Packages/IssueLightCore/Tests/IssueLightCoreTests/Fixtures/issuelight-test-root.crt"
            )
    }

    private func snapshot(
        source: MonitoringSource,
        observedAt: TimeInterval,
        summary: String,
        severity: MonitoringSeverity = .critical
    ) -> MonitoringSnapshot {
        MonitoringSnapshot(
            sourceID: source.id,
            observedAt: Date(timeIntervalSince1970: observedAt),
            issues: [
                MonitoringIssue(
                    sourceID: source.id,
                    nativeID: "host-\(source.id.uuidString)",
                    kind: .host,
                    hostName: "host-1",
                    serviceName: nil,
                    displayName: "Host 1",
                    severity: severity,
                    summary: summary,
                    isAcknowledged: false,
                    isInDowntime: false
                ),
            ]
        )
    }

    private func waitForLoads(_ expected: Int, sourceID: UUID, script: SnapshotScript) async throws {
        for _ in 0..<200 {
            if await script.metrics(for: sourceID).loads >= expected {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw ModelTestError.timeout
    }
}

private struct ModelHarness {
    let model: IssueLightModel
    let sources: [MonitoringSource]
    let store: SourceStore
    let vault: KeychainPasswordVault
    let scopes: [BasicCredentialScope]
}

private struct TestProvider: MonitoringProvider {
    static let id = ProviderID(rawValue: "model-test")

    let script: SnapshotScript
    let descriptor = ProviderDescriptor(
        id: TestProvider.id,
        displayName: "Model Test",
        capabilities: ProviderCapabilities(
            authenticationMethods: [.basic],
            serverTrustMethods: [.system, .customCertificate, .pinnedCertificate],
            supportsAcknowledgement: false,
            supportsDowntime: false
        )
    )

    func validate(_ source: MonitoringSource) -> [SourceValidationIssue] {
        MonitoringSourceValidator.validateSharedFields(source)
    }

    func testConnection(
        to source: MonitoringSource,
        access: ProviderAccess
    ) async -> ConnectionTestResult {
        .connected
    }

    func loadSnapshot(
        from source: MonitoringSource,
        access: ProviderAccess
    ) async -> SnapshotLoadResult {
        await script.load(sourceID: source.id)
    }
}

private actor SnapshotScript {
    enum Behavior: Sendable {
        case result(SnapshotLoadResult)
        case waitForCancellation
    }

    private var behaviors: [UUID: [Behavior]] = [:]
    private var loadCounts: [UUID: Int] = [:]
    private var cancellationCounts: [UUID: Int] = [:]

    func enqueue(_ behavior: Behavior, for sourceID: UUID) {
        behaviors[sourceID, default: []].append(behavior)
    }

    func load(sourceID: UUID) async -> SnapshotLoadResult {
        loadCounts[sourceID, default: 0] += 1
        guard !behaviors[sourceID, default: []].isEmpty else {
            return .failed(.incompatibleResponse)
        }
        switch behaviors[sourceID, default: []].removeFirst() {
        case .result(let result):
            return result
        case .waitForCancellation:
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            cancellationCounts[sourceID, default: 0] += 1
            return .failed(.cancelled)
        }
    }

    func metrics(for sourceID: UUID) -> (loads: Int, cancellations: Int) {
        (loadCounts[sourceID, default: 0], cancellationCounts[sourceID, default: 0])
    }
}

private enum ModelTestError: Error {
    case timeout
}
