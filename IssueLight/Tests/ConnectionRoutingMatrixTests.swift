import Foundation
import IssueLightCore
import XCTest

@MainActor
final class ConnectionRoutingMatrixTests: XCTestCase {
    func testDirectAPIRoutingMatrixAcrossProvidersSchemesSuccessAndEveryFailure() async throws {
        let executable = fixture("fake-ssh-listener.sh")
        let providerIDs = [
            Icinga2Provider.id,
            CheckmkProvider.id,
            ThrukProvider.id,
            NagiosCoreProvider.id,
        ]
        let outcomes = [("connected", ConnectionTestResult.connected)] + failureOutcomes

        for providerID in providerIDs {
            for scheme in ["http", "https"] {
                for (outcomeName, directOutcome) in outcomes {
                    let manager = SSHTunnelManager(executableURL: executable)
                    let coordinator = AutomaticConnectionCoordinator(tunnelManager: manager)
                    let source = source(providerID: providerID, scheme: scheme)
                    var usedProxy: [Bool] = []

                    let (result, path): (ConnectionTestResult, AutomaticConnectionPath) = await coordinator
                        .performUsingBestAPIPath(
                            source: source,
                            access: ProviderAccess(credential: .password("test-only")),
                            operation: { access in
                                let isProxied = access.socksProxy != nil
                                usedProxy.append(isProxied)
                                return isProxied ? .connected : directOutcome
                            },
                            requiresAlternativeNetworkPath: needsAlternativePath
                        )

                    let label = "\(providerID.rawValue) \(scheme) \(outcomeName)"
                    if needsAlternativePath(directOutcome) {
                        XCTAssertEqual(result, .connected, label)
                        XCTAssertEqual(path, .ssh, label)
                        XCTAssertEqual(usedProxy, [false, true], label)
                    } else {
                        XCTAssertEqual(result, directOutcome, label)
                        XCTAssertEqual(path, .direct, label)
                        XCTAssertEqual(usedProxy, [false], label)
                    }
                    coordinator.stop(sourceID: source.id)
                }
            }
        }
    }

    func testProxiedAPIResultMatrixPreservesEverySuccessAndFailure() async throws {
        let executable = fixture("fake-ssh-listener.sh")
        let outcomes = [("connected", ConnectionTestResult.connected)] + failureOutcomes

        for (outcomeName, proxiedOutcome) in outcomes {
            let manager = SSHTunnelManager(executableURL: executable)
            let coordinator = AutomaticConnectionCoordinator(tunnelManager: manager)
            let source = source(providerID: Icinga2Provider.id, scheme: "https")
            var usedProxy: [Bool] = []

            let (result, path): (ConnectionTestResult, AutomaticConnectionPath) = await coordinator
                .performUsingBestAPIPath(
                    source: source,
                    access: ProviderAccess(credential: .password("test-only")),
                    operation: { access in
                        let isProxied = access.socksProxy != nil
                        usedProxy.append(isProxied)
                        return isProxied ? proxiedOutcome : .failed(.unreachable)
                    },
                    requiresAlternativeNetworkPath: needsAlternativePath
                )

            XCTAssertEqual(result, proxiedOutcome, outcomeName)
            XCTAssertEqual(usedProxy, [false, true], outcomeName)
            if needsAlternativePath(proxiedOutcome) {
                guard case .unavailable(let message) = path else {
                    coordinator.stop(sourceID: source.id)
                    XCTFail("Repeated network failure must make the route unavailable: \(outcomeName)")
                    continue
                }
                XCTAssertTrue(message.contains("API connection still failed"), outcomeName)
            } else {
                XCTAssertEqual(path, .ssh, outcomeName)
            }
            coordinator.stop(sourceID: source.id)
        }
    }

    func testCachedSSHFailureRecoversDirectlyAndClearsTheCachedRoute() async throws {
        let manager = SSHTunnelManager(executableURL: fixture("fake-ssh-listener.sh"))
        let coordinator = AutomaticConnectionCoordinator(tunnelManager: manager)
        let source = source(providerID: Icinga2Provider.id, scheme: "https")
        var usedProxy: [Bool] = []

        let (initialResult, initialPath): (ConnectionTestResult, AutomaticConnectionPath) = await coordinator
            .performUsingBestAPIPath(
                source: source,
                access: ProviderAccess(credential: .password("test-only")),
                operation: { access in
                    let isProxied = access.socksProxy != nil
                    usedProxy.append(isProxied)
                    return isProxied ? .connected : .failed(.unreachable)
                },
                requiresAlternativeNetworkPath: needsAlternativePath
            )

        XCTAssertEqual(initialResult, .connected)
        XCTAssertEqual(initialPath, .ssh)
        XCTAssertEqual(usedProxy, [false, true])

        usedProxy.removeAll()
        let (recoveredResult, recoveredPath): (ConnectionTestResult, AutomaticConnectionPath) = await coordinator
            .performUsingBestAPIPath(
                source: source,
                access: ProviderAccess(credential: .password("test-only")),
                operation: { access in
                    let isProxied = access.socksProxy != nil
                    usedProxy.append(isProxied)
                    return isProxied ? .failed(.unreachable) : .connected
                },
                requiresAlternativeNetworkPath: needsAlternativePath
            )

        XCTAssertEqual(recoveredResult, .connected)
        XCTAssertEqual(recoveredPath, .direct)
        XCTAssertEqual(usedProxy, [true, false])

        usedProxy.removeAll()
        let (stableResult, stablePath): (ConnectionTestResult, AutomaticConnectionPath) = await coordinator
            .performUsingBestAPIPath(
                source: source,
                access: ProviderAccess(credential: .password("test-only")),
                operation: { access in
                    usedProxy.append(access.socksProxy != nil)
                    return .connected
                },
                requiresAlternativeNetworkPath: needsAlternativePath
            )

        XCTAssertEqual(stableResult, .connected)
        XCTAssertEqual(stablePath, .direct)
        XCTAssertEqual(usedProxy, [false])
        coordinator.stop(sourceID: source.id)
    }

    func testWebRoutingMatrixAcrossProvidersSchemesAndReachabilityStates() async throws {
        let executable = fixture("fake-ssh-listener.sh")
        let providerIDs = [
            Icinga2Provider.id,
            CheckmkProvider.id,
            ThrukProvider.id,
            NagiosCoreProvider.id,
        ]
        let reachability = [
            ("direct", true, false, AutomaticConnectionPath.direct),
            ("ssh", false, true, AutomaticConnectionPath.ssh),
            ("unavailable", false, false, nil),
        ]

        for providerID in providerIDs {
            for scheme in ["http", "https"] {
                for (state, direct, proxied, expected) in reachability {
                    let manager = SSHTunnelManager(executableURL: executable)
                    var probes: [Bool] = []
                    let coordinator = AutomaticConnectionCoordinator(
                        tunnelManager: manager,
                        canConnect: { _, _, proxyPort in
                            let isProxied = proxyPort != nil
                            probes.append(isProxied)
                            return isProxied ? proxied : direct
                        }
                    )
                    let source = source(providerID: providerID, scheme: scheme)
                    let url = try XCTUnwrap(
                        URL(string: "\(scheme)://web.\(providerID.rawValue).example.test/status")
                    )

                    let path = await coordinator.checkWeb(source: source, url: url)
                    let label = "\(providerID.rawValue) \(scheme) \(state)"

                    if let expected {
                        XCTAssertEqual(path, expected, label)
                    } else {
                        guard case .unavailable = path else {
                            coordinator.stop(sourceID: source.id)
                            XCTFail("Expected unavailable: \(label)")
                            continue
                        }
                    }
                    XCTAssertEqual(probes, direct ? [false] : [false, true], label)
                    coordinator.stop(sourceID: source.id)
                }
            }
        }
    }

    func testSSHPortRecoveryReportsBothFailuresAndAutomaticDefaultsRemainUsable() async throws {
        let executable = fixture("fake-ssh-api-port-fallback.sh")
        let manager = SSHTunnelManager(executableURL: executable)
        let coordinator = AutomaticConnectionCoordinator(tunnelManager: manager)
        let failingSource = MonitoringSource(
            name: "Failing",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: "https://monitoring.example.test:5665")!,
            authentication: .basic(username: "operator"),
            sshTunnel: SSHTunnelConfiguration(
                bastionHost: "always-fail.example.test",
                username: "operator",
                port: 5_665
            )
        )

        let (failure, failedPath): (ConnectionTestResult, AutomaticConnectionPath) = await coordinator
            .performUsingBestAPIPath(
                source: failingSource,
                access: ProviderAccess(credential: .password("test-only")),
                operation: { _ in .failed(.unreachable) },
                requiresAlternativeNetworkPath: needsAlternativePath
            )

        XCTAssertEqual(failure, .failed(.unreachable))
        guard case .unavailable(let message) = failedPath else {
            return XCTFail("Both failed SSH candidates must be reported")
        }
        XCTAssertTrue(message.contains("SSH port 5665"))
        XCTAssertTrue(message.contains("SSH port 22"))

        let automaticSource = MonitoringSource(
            name: "Automatic",
            providerID: CheckmkProvider.id,
            endpoint: URL(string: "https://automatic.example.test")!,
            authentication: .apiKey(username: "automation")
        )
        let (success, successfulPath): (ConnectionTestResult, AutomaticConnectionPath) = await coordinator
            .performUsingBestAPIPath(
                source: automaticSource,
                access: ProviderAccess(credential: .apiKey("test-only")),
                operation: { access in
                    access.socksProxy == nil ? .failed(.unreachable) : .connected
                },
                requiresAlternativeNetworkPath: needsAlternativePath
            )

        XCTAssertEqual(success, .connected)
        XCTAssertEqual(successfulPath, .ssh)
        coordinator.stop(sourceID: failingSource.id)
        coordinator.stop(sourceID: automaticSource.id)
    }

    func testWebRoutingReportsSSHStartFailureForHTTPAndHTTPS() async throws {
        for scheme in ["http", "https"] {
            let manager = SSHTunnelManager(executableURL: URL(fileURLWithPath: "/usr/bin/false"))
            let coordinator = AutomaticConnectionCoordinator(
                tunnelManager: manager,
                canConnect: { _, _, _ in false }
            )
            let source = source(providerID: ThrukProvider.id, scheme: scheme)
            let url = try XCTUnwrap(URL(string: "\(scheme)://web.example.test/status"))

            let path = await coordinator.checkWeb(source: source, url: url)

            guard case .unavailable(let message) = path else {
                return XCTFail("SSH start failure must remain visible for \(scheme)")
            }
            XCTAssertFalse(message.isEmpty, scheme)
            coordinator.stop(sourceID: source.id)
        }
    }

    private var failureOutcomes: [(String, ConnectionTestResult)] {
        [
            ("invalid configuration", .failed(.invalidConfiguration([.missingHost]))),
            ("unsupported trust", .failed(.unsupportedTrustConfiguration)),
            ("missing client certificate", .failed(.clientCertificateNotAvailable)),
            ("missing server certificate", .failed(.serverCertificateNotAvailable)),
            ("cancelled", .failed(.cancelled)),
            ("unreachable", .failed(.unreachable)),
            ("server trust", .failed(.serverTrust)),
            ("TLS handshake", .failed(.tls)),
            ("client certificate rejected", .failed(.clientCertificateRejected)),
            ("authentication", .failed(.authentication)),
            ("authorization", .failed(.authorization)),
            ("incompatible response", .failed(.incompatibleResponse)),
            ("server", .failed(.server(statusCode: 503))),
            ("HTTP", .failed(.http(statusCode: 429))),
        ]
    }

    private func needsAlternativePath(_ result: ConnectionTestResult) -> Bool {
        guard case .failed(let failure) = result else { return false }
        return failure.requiresAlternativeNetworkPath
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
    }

    private func source(providerID: ProviderID, scheme: String) -> MonitoringSource {
        MonitoringSource(
            name: "Matrix",
            providerID: providerID,
            endpoint: URL(string: "\(scheme)://\(providerID.rawValue).example.test:8443")!,
            authentication: .basic(username: "operator"),
            sshTunnel: SSHTunnelConfiguration(
                bastionHost: "bastion.example.test",
                username: "operator"
            )
        )
    }
}
