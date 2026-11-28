import Foundation
import IssueLightCore
import XCTest

@MainActor
final class ConnectionRoutingMatrixTests: XCTestCase {
    func testDirectAPIRoutingMatrixAcrossProvidersSchemesSuccessAndEveryFailure() async throws {
        let executable = fixture("fake-ssh-listener.sh")
        let outcomes = [("connected", ConnectionTestResult.connected)] + failureOutcomes
        var executedScenarios = 0

        for provider in providerScenarios {
            for scheme in ["http", "https"] {
                for (outcomeName, directOutcome) in outcomes {
                    let manager = SSHTunnelManager(executableURL: executable)
                    let coordinator = AutomaticConnectionCoordinator(tunnelManager: manager)
                    let source = source(provider: provider, scheme: scheme, target: .remote)
                    var usedProxy: [Bool] = []

                    let (result, path): (ConnectionTestResult, AutomaticConnectionPath) = await coordinator
                        .performUsingBestAPIPath(
                            source: source,
                            access: provider.access,
                            operation: { _, access in
                                let isProxied = access.socksProxy != nil
                                usedProxy.append(isProxied)
                                return isProxied ? .connected : directOutcome
                            },
                            requiresAlternativeNetworkPath: needsAlternativePath
                        )

                    let label = "\(provider.label) \(scheme) \(outcomeName)"
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
                    executedScenarios += 1
                }
            }
        }
        XCTAssertEqual(executedScenarios, providerScenarios.count * 2 * outcomes.count)
    }

    func testRoutedAPIResultMatrixAcrossProvidersSchemesTargetsAndEveryOutcome() async throws {
        let executable = fixture("fake-ssh-listener.sh")
        let outcomes = [("connected", ConnectionTestResult.connected)] + failureOutcomes
        var executedScenarios = 0

        for provider in providerScenarios {
            for scheme in ["http", "https"] {
                for target in EndpointTarget.allCases {
                    for (outcomeName, routedOutcome) in outcomes {
                        let manager = SSHTunnelManager(executableURL: executable)
                        let coordinator = AutomaticConnectionCoordinator(tunnelManager: manager)
                        let source = source(provider: provider, scheme: scheme, target: target)
                        var attempts: [(MonitoringSource, ProviderAccess)] = []

                        let (result, path): (ConnectionTestResult, AutomaticConnectionPath) = await coordinator
                            .performUsingBestAPIPath(
                                source: source,
                                access: provider.access,
                                operation: { routedSource, access in
                                    attempts.append((routedSource, access))
                                    return attempts.count == 1 ? .failed(.unreachable) : routedOutcome
                                },
                                requiresAlternativeNetworkPath: needsAlternativePath
                            )

                        let label = "\(provider.label) \(scheme) \(target) \(outcomeName)"
                        XCTAssertEqual(result, routedOutcome, label)
                        XCTAssertEqual(attempts.count, 2, label)
                        XCTAssertEqual(attempts[0].0, source, label)
                        XCTAssertNil(attempts[0].1.socksProxy, label)
                        XCTAssertEqual(attempts[1].0.serverTrust, source.serverTrust, label)
                        XCTAssertEqual(attempts[1].0.authentication, source.authentication, label)
                        provider.assertCredential(attempts[1].1, label: label)
                        switch target {
                        case .remote:
                            XCTAssertEqual(attempts[1].0.endpoint, source.endpoint, label)
                            XCTAssertNotNil(attempts[1].1.socksProxy, label)
                        case .ipv4Loopback, .localhost:
                            XCTAssertEqual(attempts[1].0.endpoint.host, source.endpoint.host, label)
                            XCTAssertNotEqual(attempts[1].0.endpoint.port, source.endpoint.port, label)
                            XCTAssertNil(attempts[1].1.socksProxy, label)
                        }

                        if needsAlternativePath(routedOutcome) {
                            guard case .unavailable(let message) = path else {
                                coordinator.stop(sourceID: source.id)
                                XCTFail("Repeated network failure must make the route unavailable: \(label)")
                                continue
                            }
                            XCTAssertTrue(message.contains("API connection still failed"), label)
                        } else {
                            XCTAssertEqual(path, .ssh, label)
                        }
                        coordinator.stop(sourceID: source.id)
                        executedScenarios += 1
                    }
                }
            }
        }
        XCTAssertEqual(
            executedScenarios,
            providerScenarios.count * 2 * EndpointTarget.allCases.count * outcomes.count
        )
    }

    func testEveryRoutePreservesProviderAuthenticationAndTrustPolicy() throws {
        var executedScenarios = 0

        for provider in providerScenarios {
            for scheme in ["http", "https"] {
                for explicitEndpointPort in [nil, 5_665] as [Int?] {
                    for target in EndpointTarget.allCases {
                        for trust in trustConfigurations {
                            for sshPort in [22, 2_222, explicitEndpointPort ?? (scheme == "http" ? 80 : 443)] {
                                for preferredLocalPort in [nil, 49_152] as [Int?] {
                                    let source = source(
                                        provider: provider,
                                        scheme: scheme,
                                        target: target,
                                        trust: trust,
                                        explicitPort: explicitEndpointPort,
                                        sshPort: sshPort,
                                        preferredLocalPort: preferredLocalPort
                                    )
                                    let configuration = try XCTUnwrap(source.sshTunnel)
                                    let route: ActiveAPIConnectionRoute = target == .remote
                                        ? .socks(port: 49_153, configuration: configuration)
                                        : .localForward(
                                            port: 49_153,
                                            targetHost: source.endpoint.host!,
                                            targetPort: source.endpoint.effectiveHTTPPort!,
                                            configuration: configuration
                                        )
                                    let (routedSource, routedAccess) = route.routing(
                                        source: source,
                                        access: provider.access
                                    )
                                    let label = "\(provider.label) \(scheme) port=\(explicitEndpointPort.map(String.init) ?? "default") \(target) \(trust) ssh=\(sshPort) local=\(preferredLocalPort.map(String.init) ?? "automatic")"

                                    XCTAssertTrue(route.matches(source: source, configuration: configuration), label)
                                    XCTAssertEqual(routedSource.id, source.id, label)
                                    XCTAssertEqual(routedSource.providerID, source.providerID, label)
                                    XCTAssertEqual(routedSource.authentication, source.authentication, label)
                                    XCTAssertEqual(routedSource.serverTrust, trust, label)
                                    provider.assertCredential(routedAccess, label: label)
                                    if target == .remote {
                                        XCTAssertEqual(routedSource.endpoint, source.endpoint, label)
                                        XCTAssertEqual(
                                            routedAccess.socksProxy,
                                            ProviderSOCKSProxy(port: 49_153),
                                            label
                                        )
                                    } else {
                                        XCTAssertEqual(routedSource.endpoint.scheme, source.endpoint.scheme, label)
                                        XCTAssertEqual(routedSource.endpoint.host, source.endpoint.host, label)
                                        XCTAssertEqual(routedSource.endpoint.port, 49_153, label)
                                        XCTAssertNil(routedAccess.socksProxy, label)
                                    }
                                    executedScenarios += 1
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(
            executedScenarios,
            providerScenarios.count
                * 2
                * 2
                * EndpointTarget.allCases.count
                * trustConfigurations.count
                * 3
                * 2
        )
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
                operation: { _, access in
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
                operation: { _, access in
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
                operation: { _, access in
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
                operation: { _, _ in .failed(.unreachable) },
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
                operation: { _, access in
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

    private var providerScenarios: [ProviderScenario] {
        [
            ProviderScenario(
                label: "icinga2-basic",
                providerID: Icinga2Provider.id,
                authentication: .basic(username: "operator"),
                credential: .password("icinga-password")
            ),
            ProviderScenario(
                label: "checkmk-api-key",
                providerID: CheckmkProvider.id,
                authentication: .apiKey(username: "automation"),
                credential: .apiKey("checkmk-secret")
            ),
            ProviderScenario(
                label: "thruk-basic",
                providerID: ThrukProvider.id,
                authentication: .basic(username: "operator"),
                credential: .password("thruk-password")
            ),
            ProviderScenario(
                label: "thruk-api-key",
                providerID: ThrukProvider.id,
                authentication: .apiKey(username: "automation"),
                credential: .apiKey("thruk-secret")
            ),
            ProviderScenario(
                label: "nagios-basic",
                providerID: NagiosCoreProvider.id,
                authentication: .basic(username: "operator"),
                credential: .password("nagios-password")
            ),
        ]
    }

    private var trustConfigurations: [ServerTrustConfiguration] {
        [
            .system,
            .customCertificate(certificateID: "matrix-private-ca"),
            .pinnedCertificate(sha256: String(repeating: "AA", count: 32)),
            .disabled,
        ]
    }

    private func source(
        provider: ProviderScenario,
        scheme: String,
        target: EndpointTarget,
        trust: ServerTrustConfiguration = .disabled,
        explicitPort: Int? = 8_443,
        sshPort: Int = 22,
        preferredLocalPort: Int? = 49_152
    ) -> MonitoringSource {
        let portText = explicitPort.map { ":\($0)" } ?? ""
        return MonitoringSource(
            name: "Matrix",
            providerID: provider.providerID,
            endpoint: URL(string: "\(scheme)://\(target.host(for: provider.providerID))\(portText)")!,
            authentication: provider.authentication,
            serverTrust: trust,
            sshTunnel: SSHTunnelConfiguration(
                bastionHost: "bastion.example.test",
                username: "operator",
                port: sshPort,
                preferredLocalPort: preferredLocalPort
            )
        )
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

private enum EndpointTarget: CaseIterable, Equatable {
    case remote
    case ipv4Loopback
    case localhost

    func host(for providerID: ProviderID) -> String {
        switch self {
        case .remote:
            return "\(providerID.rawValue).example.test"
        case .ipv4Loopback:
            return "127.0.0.1"
        case .localhost:
            return "localhost"
        }
    }
}

private struct ProviderScenario {
    let label: String
    let providerID: ProviderID
    let authentication: AuthenticationConfiguration
    let credential: TestCredential

    var access: ProviderAccess {
        ProviderAccess(credential: credential.providerCredential)
    }

    func assertCredential(_ access: ProviderAccess, label: String) {
        credential.assert(access.credential, label: label)
    }
}

private enum TestCredential {
    case password(String)
    case apiKey(String)

    var providerCredential: ProviderCredential {
        switch self {
        case .password(let value): return .password(value)
        case .apiKey(let value): return .apiKey(value)
        }
    }

    func assert(_ credential: ProviderCredential, label: String) {
        switch (self, credential) {
        case (.password(let expected), .password(let actual)):
            XCTAssertEqual(actual, expected, label)
        case (.apiKey(let expected), .apiKey(let actual)):
            XCTAssertEqual(actual, expected, label)
        default:
            XCTFail("Credential kind changed while routing: \(label)")
        }
    }
}
