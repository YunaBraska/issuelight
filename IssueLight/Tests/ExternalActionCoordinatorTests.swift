import Darwin
import Foundation
import Security
@testable import IssueLightCore
import XCTest

@MainActor
final class ExternalActionCoordinatorTests: XCTestCase {
    func testOnlyNetworkAndTLSHandshakeFailuresTryAnotherNetworkPath() {
        XCTAssertTrue(ConnectionFailure.unreachable.requiresAlternativeNetworkPath)
        XCTAssertTrue(ConnectionFailure.tls.requiresAlternativeNetworkPath)
        for failure in [
            ConnectionFailure.invalidConfiguration([.missingHost]),
            .unsupportedTrustConfiguration,
            .clientCertificateNotAvailable,
            .serverCertificateNotAvailable,
            .cancelled,
            .serverTrust,
            .clientCertificateRejected,
            .authentication,
            .authorization,
            .incompatibleResponse,
            .server(statusCode: 503),
            .http(statusCode: 429),
        ] {
            XCTAssertFalse(failure.requiresAlternativeNetworkPath, "Unexpected SSH fallback for \(failure)")
        }
    }

    func testTunnelCommandUsesSafeArgumentsAndExplicitIdentity() {
        let configuration = SSHTunnelConfiguration(
            bastionHost: "bastion.example.test",
            username: "operator",
            port: 2_222,
            identityFilePath: "/tmp/key with spaces",
            preferredLocalPort: 8_080
        )

        let command = SSHTunnelManager.Command(
            localPort: 8_081,
            remoteHost: "icinga.internal",
            remotePort: 80,
            configuration: configuration
        )

        XCTAssertEqual(
            command.arguments,
            [
                "-N", "-T",
                "-o", "BatchMode=yes",
                "-o", "ExitOnForwardFailure=yes",
                "-o", "ConnectTimeout=5",
                "-L", "127.0.0.1:8081:icinga.internal:80",
                "-p", "2222",
                "-i", "/tmp/key with spaces",
                "-o", "IdentitiesOnly=yes",
                "-l", "operator",
                "--", "bastion.example.test",
            ]
        )
    }

    func testTunnelCommandUsesOpenSSHDefaultsWithoutSelectedIdentity() {
        let command = SSHTunnelManager.Command(
            localPort: 49_152,
            remoteHost: "icinga.internal",
            remotePort: 80,
            configuration: SSHTunnelConfiguration(
                bastionHost: "bastion.example.test",
                username: "operator"
            )
        )

        XCTAssertFalse(command.arguments.contains("-i"))
        XCTAssertFalse(command.arguments.contains("IdentitiesOnly=yes"))
        XCTAssertFalse(command.arguments.contains("StrictHostKeyChecking=no"))
        XCTAssertFalse(command.arguments.contains("StrictHostKeyChecking=accept-new"))
        XCTAssertEqual(Array(command.arguments.suffix(4)), ["-l", "operator", "--", "bastion.example.test"])
    }

    func testTunnelCommandLeavesDefaultUserAndPortToOpenSSH() {
        let command = SSHTunnelManager.Command(
            localPort: 49_152,
            remoteHost: "icinga.internal",
            remotePort: 443,
            configuration: SSHTunnelConfiguration(
                bastionHost: "monitoring.example.test",
                username: ""
            )
        )

        XCTAssertFalse(command.arguments.contains("-l"))
        XCTAssertFalse(command.arguments.contains("-p"))
        XCTAssertEqual(Array(command.arguments.suffix(2)), ["--", "monitoring.example.test"])
    }

    func testSOCKSCommandUsesSafeDynamicForwardingArguments() {
        let command = SSHTunnelManager.Command(
            socksPort: 49_153,
            configuration: SSHTunnelConfiguration(
                bastionHost: "bastion.example.test",
                username: "operator",
                port: 2_222
            )
        )

        XCTAssertTrue(command.arguments.contains("127.0.0.1:49153"))
        XCTAssertFalse(command.arguments.contains("StrictHostKeyChecking=no"))
        XCTAssertEqual(
            Array(command.arguments.suffix(6)),
            ["-p", "2222", "-l", "operator", "--", "bastion.example.test"]
        )
    }

    func testAutomaticAPIRoutingRetriesTLSHandshakeThroughSSH() async throws {
        let executable = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-ssh-listener.sh")
        let coordinator = AutomaticConnectionCoordinator(
            tunnelManager: SSHTunnelManager(executableURL: executable)
        )
        let source = MonitoringSource(
            name: "Production",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: "https://monitoring.example.test:5665")!,
            authentication: .basic(username: "operator"),
            sshTunnel: SSHTunnelConfiguration(
                bastionHost: "bastion.example.test",
                username: "operator"
            )
        )
        let access = ProviderAccess(credential: .password("test-only"))
        var attempts: [ProviderSOCKSProxy?] = []
        defer { coordinator.stop(sourceID: source.id) }

        let (result, path): (ConnectionTestResult, AutomaticConnectionPath) = await coordinator
            .performUsingBestAPIPath(
                source: source,
                access: access,
                operation: { _, routedAccess in
                    attempts.append(routedAccess.socksProxy)
                    return routedAccess.socksProxy == nil ? .failed(.tls) : .connected
                },
                requiresAlternativeNetworkPath: { result in
                    guard case .failed(let failure) = result else { return false }
                    return failure.requiresAlternativeNetworkPath
                }
            )

        XCTAssertEqual(result, .connected)
        XCTAssertEqual(path, .ssh)
        XCTAssertEqual(attempts.count, 2)
        XCTAssertNil(attempts[0])
        XCTAssertNotNil(attempts[1])
    }

    func testAutomaticAPIRoutingFallsBackToSSHOnlyAfterDirectUnreachable() async throws {
        let executable = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-ssh-listener.sh")
        let manager = SSHTunnelManager(executableURL: executable)
        let coordinator = AutomaticConnectionCoordinator(tunnelManager: manager)
        let source = MonitoringSource(
            name: "Production",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: "http://monitoring.example.test:5665")!,
            authentication: .basic(username: "operator"),
            sshTunnel: SSHTunnelConfiguration(
                bastionHost: "bastion.example.test",
                username: "operator"
            )
        )
        let access = ProviderAccess(credential: .password("test-only"))
        var attempts: [ProviderSOCKSProxy?] = []
        defer { coordinator.stop(sourceID: source.id) }

        let (result, path): (ConnectionTestResult, AutomaticConnectionPath) = await coordinator
            .performUsingBestAPIPath(
                source: source,
                access: access,
                operation: { _, routedAccess in
                    attempts.append(routedAccess.socksProxy)
                    return routedAccess.socksProxy == nil ? .failed(.unreachable) : .connected
                },
                requiresAlternativeNetworkPath: { $0 == .failed(.unreachable) }
            )

        XCTAssertEqual(result, .connected)
        XCTAssertEqual(path, .ssh)
        XCTAssertEqual(attempts.count, 2)
        XCTAssertNil(attempts[0])
        XCTAssertNotNil(attempts[1])
    }

    func testAutomaticAPIRoutingRecoversAcrossProvidersWhenTheAPIPortWasStoredAsTheSSHPort() async throws {
        let executable = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-ssh-api-port-fallback.sh")
        let scenarios = [
            (Icinga2Provider.id, "https://icinga.example.test:5665", 5_665),
            (CheckmkProvider.id, "https://checkmk.example.test", 443),
            (ThrukProvider.id, "https://thruk.example.test:8443", 8_443),
            (NagiosCoreProvider.id, "http://nagios.example.test", 80),
        ]

        for (providerID, endpointText, apiPort) in scenarios {
            let manager = SSHTunnelManager(executableURL: executable)
            let coordinator = AutomaticConnectionCoordinator(tunnelManager: manager)
            let endpoint = try XCTUnwrap(URL(string: endpointText))
            let source = MonitoringSource(
                name: "Production",
                providerID: providerID,
                endpoint: endpoint,
                authentication: .basic(username: "operator"),
                sshTunnel: SSHTunnelConfiguration(
                    bastionHost: "bastion.example.test",
                    username: "operator",
                    port: apiPort
                )
            )
            let (result, path): (ConnectionTestResult, AutomaticConnectionPath) = await coordinator
                .performUsingBestAPIPath(
                    source: source,
                    access: ProviderAccess(credential: .password("test-only")),
                    operation: { _, routedAccess in
                        routedAccess.socksProxy == nil ? .failed(.unreachable) : .connected
                    },
                    requiresAlternativeNetworkPath: { $0 == .failed(.unreachable) }
                )

            XCTAssertEqual(result, .connected, providerID.rawValue)
            XCTAssertEqual(path, .ssh, providerID.rawValue)
            coordinator.stop(sourceID: source.id)
        }
    }

    func testAutomaticAPIRoutingDoesNotReplaceADistinctCustomSSHPort() async throws {
        let executable = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-ssh-api-port-fallback.sh")
        let manager = SSHTunnelManager(executableURL: executable)
        let coordinator = AutomaticConnectionCoordinator(tunnelManager: manager)
        let source = MonitoringSource(
            name: "Production",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: "https://monitoring.example.test:5665")!,
            authentication: .basic(username: "operator"),
            sshTunnel: SSHTunnelConfiguration(
                bastionHost: "bastion.example.test",
                username: "operator",
                port: 2_222
            )
        )
        defer { coordinator.stop(sourceID: source.id) }

        let (_, path): (ConnectionTestResult, AutomaticConnectionPath) = await coordinator
            .performUsingBestAPIPath(
                source: source,
                access: ProviderAccess(credential: .password("test-only")),
                operation: { _, _ in .failed(.unreachable) },
                requiresAlternativeNetworkPath: { $0 == .failed(.unreachable) }
            )

        guard case .unavailable(let message) = path else {
            return XCTFail("A distinct custom SSH port must not be silently replaced")
        }
        XCTAssertTrue(message.contains("port 2222"))
        XCTAssertFalse(message.contains("port 22:"))
    }

    func testRemoteLoopbackAPIRecoversWhenTheAPIPortWasStoredAsTheSSHPort() async throws {
        let executable = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-ssh-api-port-fallback.sh")
        let manager = SSHTunnelManager(executableURL: executable)
        let coordinator = AutomaticConnectionCoordinator(tunnelManager: manager)
        let source = MonitoringSource(
            name: "Production",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: "https://127.0.0.1:5665")!,
            authentication: .basic(username: "operator"),
            sshTunnel: SSHTunnelConfiguration(
                bastionHost: "bastion.example.test",
                username: "operator",
                port: 5_665,
                preferredLocalPort: 49_152
            )
        )
        var attempts: [(URL, ProviderSOCKSProxy?)] = []
        defer { coordinator.stop(sourceID: source.id) }

        let (result, path): (ConnectionTestResult, AutomaticConnectionPath) = await coordinator
            .performUsingBestAPIPath(
                source: source,
                access: ProviderAccess(credential: .password("test-only")),
                operation: { routedSource, access in
                    attempts.append((routedSource.endpoint, access.socksProxy))
                    return attempts.count == 1 ? .failed(.unreachable) : .connected
                },
                requiresAlternativeNetworkPath: { $0 == .failed(.unreachable) }
            )

        XCTAssertEqual(result, .connected)
        XCTAssertEqual(path, .ssh)
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts[1].0.scheme, "https")
        XCTAssertEqual(attempts[1].0.host, "127.0.0.1")
        XCTAssertNotEqual(attempts[1].0.port, 5_665)
        XCTAssertTrue((1...65_535).contains(try XCTUnwrap(attempts[1].0.port)))
        XCTAssertNil(attempts[1].1)
    }

    func testAutomaticAPIRoutingReusesSuccessfulSSHUntilConnectionTestRediscoversDirect() async throws {
        let executable = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-ssh-listener.sh")
        let manager = SSHTunnelManager(executableURL: executable)
        let coordinator = AutomaticConnectionCoordinator(tunnelManager: manager)
        let source = MonitoringSource(
            name: "Production",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: "https://monitoring.example.test:5665")!,
            authentication: .basic(username: "operator"),
            sshTunnel: SSHTunnelConfiguration(
                bastionHost: "bastion.example.test",
                username: "operator"
            )
        )
        let access = ProviderAccess(credential: .password("test-only"))
        var attempts: [ProviderSOCKSProxy?] = []
        defer { coordinator.stop(sourceID: source.id) }

        let first: (ConnectionTestResult, AutomaticConnectionPath) = await coordinator
            .performUsingBestAPIPath(
                source: source,
                access: access,
                rediscoverDirect: true,
                operation: { _, routedAccess in
                    attempts.append(routedAccess.socksProxy)
                    return routedAccess.socksProxy == nil ? .failed(.unreachable) : .connected
                },
                requiresAlternativeNetworkPath: { $0 == .failed(.unreachable) }
            )
        let second: (ConnectionTestResult, AutomaticConnectionPath) = await coordinator
            .performUsingBestAPIPath(
                source: source,
                access: access,
                operation: { _, routedAccess in
                    attempts.append(routedAccess.socksProxy)
                    return routedAccess.socksProxy == nil ? .failed(.unreachable) : .connected
                },
                requiresAlternativeNetworkPath: { $0 == .failed(.unreachable) }
            )
        let third: (ConnectionTestResult, AutomaticConnectionPath) = await coordinator
            .performUsingBestAPIPath(
                source: source,
                access: access,
                rediscoverDirect: true,
                operation: { _, routedAccess in
                    attempts.append(routedAccess.socksProxy)
                    return routedAccess.socksProxy == nil ? .connected : .failed(.unreachable)
                },
                requiresAlternativeNetworkPath: { $0 == .failed(.unreachable) }
            )

        XCTAssertEqual(first.1, .ssh)
        XCTAssertEqual(second.1, .ssh)
        XCTAssertEqual(third.1, .direct)
        XCTAssertEqual(attempts.count, 4)
        XCTAssertNil(attempts[0])
        XCTAssertNotNil(attempts[1])
        XCTAssertNotNil(attempts[2])
        XCTAssertNil(attempts[3])
    }

    func testWebRoutingFallsBackToSSHOnlyAfterDirectUnreachable() async throws {
        let executable = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-ssh-listener.sh")
        let manager = SSHTunnelManager(executableURL: executable)
        var proxyPorts: [Int?] = []
        let coordinator = AutomaticConnectionCoordinator(
            tunnelManager: manager,
            canConnect: { _, _, proxyPort in
                proxyPorts.append(proxyPort)
                return proxyPort != nil
            }
        )
        let source = MonitoringSource(
            name: "Production",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: "https://monitoring.example.test:5665")!,
            authentication: .basic(username: "operator"),
            sshTunnel: SSHTunnelConfiguration(
                bastionHost: "bastion.example.test",
                username: "operator"
            )
        )
        defer { coordinator.stop(sourceID: source.id) }

        let path = await coordinator.checkWeb(
            source: source,
            url: URL(string: "https://icinga-web.internal/icingaweb2")!
        )

        XCTAssertEqual(path, .ssh)
        XCTAssertEqual(proxyPorts.count, 2)
        XCTAssertNil(proxyPorts[0])
        XCTAssertNotNil(proxyPorts[1])
    }

    func testWebRoutingRecoversWhenTheAPIPortWasStoredAsTheSSHPort() async throws {
        let executable = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-ssh-api-port-fallback.sh")
        let manager = SSHTunnelManager(executableURL: executable)
        let coordinator = AutomaticConnectionCoordinator(
            tunnelManager: manager,
            canConnect: { _, _, proxyPort in proxyPort != nil }
        )
        let source = MonitoringSource(
            name: "Production",
            providerID: CheckmkProvider.id,
            endpoint: URL(string: "https://checkmk.example.test")!,
            authentication: .apiKey(username: "automation"),
            sshTunnel: SSHTunnelConfiguration(
                bastionHost: "bastion.example.test",
                username: "operator",
                port: 443
            )
        )
        defer { coordinator.stop(sourceID: source.id) }

        let path = await coordinator.checkWeb(
            source: source,
            url: URL(string: "https://checkmk-web.example.test/site/check_mk")!
        )

        XCTAssertEqual(path, .ssh)
    }

    func testWebRoutingDoesNotReplaceADistinctCustomSSHPort() async throws {
        let executable = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-ssh-api-port-fallback.sh")
        let manager = SSHTunnelManager(executableURL: executable)
        let coordinator = AutomaticConnectionCoordinator(
            tunnelManager: manager,
            canConnect: { _, _, _ in false }
        )
        let source = MonitoringSource(
            name: "Production",
            providerID: NagiosCoreProvider.id,
            endpoint: URL(string: "http://nagios.example.test")!,
            authentication: .basic(username: "operator"),
            sshTunnel: SSHTunnelConfiguration(
                bastionHost: "bastion.example.test",
                username: "operator",
                port: 2_222
            )
        )
        defer { coordinator.stop(sourceID: source.id) }

        let path = await coordinator.checkWeb(
            source: source,
            url: URL(string: "http://nagios-web.example.test/nagios")!
        )

        guard case .unavailable(let message) = path else {
            return XCTFail("A distinct custom SSH port must not be silently replaced")
        }
        XCTAssertTrue(message.contains("port 2222"))
        XCTAssertFalse(message.contains("port 22:"))
    }

    func testRemoteActionReportsWhetherWorkspaceAcceptedURL() {
        var openedURL: URL?
        let coordinator = ExternalActionCoordinator { url in
            openedURL = url
            return true
        }
        let url = URL(string: "ssh://operator@host.example.test:22")!

        let result = coordinator.openRemote(url)

        XCTAssertEqual(try? result.get(), url)
        XCTAssertEqual(openedURL, url)
    }

    func testWebActionWithoutTunnelOpensImmediatelyWithoutReachabilityProbe() async throws {
        var openedURL: URL?
        var didProbe = false
        let coordinator = ExternalActionCoordinator(
            openURL: { url in
                openedURL = url
                return true
            },
            canConnect: { _, _ in
                didProbe = true
                return false
            }
        )
        let url = try XCTUnwrap(URL(string: "https://icinga.example/icingaweb2"))

        let result = await coordinator.openWeb(
            IssueWebTarget(sourceID: UUID(), url: url, automaticSSHTunnel: nil)
        )

        XCTAssertEqual(try result.get(), url)
        XCTAssertEqual(openedURL, url)
        XCTAssertFalse(didProbe)
    }

    func testDirectHTTPSWebWithTunnelConfiguredOpensTheOriginalURL() async throws {
        var openedURL: URL?
        let coordinator = ExternalActionCoordinator(
            openURL: { url in
                openedURL = url
                return true
            },
            canConnect: { _, _ in true },
            tunnelManager: SSHTunnelManager(executableURL: fixture("fake-ssh-listener.sh"))
        )
        let url = try XCTUnwrap(URL(string: "https://icinga.example/icingaweb2"))

        let result = await coordinator.openWeb(
            IssueWebTarget(
                sourceID: UUID(),
                url: url,
                automaticSSHTunnel: SSHTunnelConfiguration(
                    bastionHost: "bastion.example.test",
                    username: "operator"
                )
            )
        )

        XCTAssertEqual(try result.get(), url)
        XCTAssertEqual(openedURL, url)
    }

    func testUnreachableHTTPWebUsesLocalForwardAndPreservesItsPath() async throws {
        var openedURL: URL?
        let sourceID = UUID()
        let manager = SSHTunnelManager(executableURL: fixture("fake-ssh-listener.sh"))
        let coordinator = ExternalActionCoordinator(
            openURL: { url in
                openedURL = url
                return true
            },
            canConnect: { _, _ in false },
            tunnelManager: manager
        )
        let originalURL = try XCTUnwrap(
            URL(string: "http://icinga-web.internal:8080/icingaweb2/icingadb/hosts?state=down")
        )

        let result = await coordinator.openWeb(
            IssueWebTarget(
                sourceID: sourceID,
                url: originalURL,
                automaticSSHTunnel: SSHTunnelConfiguration(
                    bastionHost: "bastion.example.test",
                    username: "operator",
                    preferredLocalPort: 49_152
                )
            )
        )
        manager.stop(sourceID: sourceID)

        let forwardedURL = try result.get()
        XCTAssertEqual(forwardedURL, openedURL)
        XCTAssertEqual(forwardedURL.scheme, "http")
        XCTAssertEqual(forwardedURL.host, "127.0.0.1")
        XCTAssertEqual(forwardedURL.path, originalURL.path)
        XCTAssertEqual(forwardedURL.query, originalURL.query)
        XCTAssertNotEqual(forwardedURL.port, originalURL.port)
    }

    func testUnreachableHTTPSWebFailsClosedWithoutRewritingCertificateHost() async throws {
        var didOpen = false
        let coordinator = ExternalActionCoordinator(
            openURL: { _ in
                didOpen = true
                return true
            },
            canConnect: { _, _ in false },
            tunnelManager: SSHTunnelManager(executableURL: fixture("fake-ssh-listener.sh"))
        )
        let url = try XCTUnwrap(URL(string: "https://icinga.example/icingaweb2"))

        let result = await coordinator.openWeb(
            IssueWebTarget(
                sourceID: UUID(),
                url: url,
                automaticSSHTunnel: SSHTunnelConfiguration(
                    bastionHost: "bastion.example.test",
                    username: "operator"
                )
            )
        )

        XCTAssertEqual(result, .failure(.secureTunnelUnsupported))
        XCTAssertFalse(didOpen)
    }

    func testPreferredLocalPortFallsForwardWhenTheRequestedPortIsOccupied() throws {
        let reservation = try LoopbackPortReservation()

        let selectedPort = try XCTUnwrap(
            LocalPortAllocator.availablePort(preferred: reservation.port)
        )

        XCTAssertGreaterThan(selectedPort, reservation.port)
        XCTAssertLessThanOrEqual(selectedPort, min(reservation.port + 100, 65_535))
    }

    func testLiveSSHTunnelForwardsHTTPAndClosesItsPort() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let portText = environment["ISSUELIGHT_LIVE_SSH_PORT"],
              let port = Int(portText),
              let identityFilePath = environment["ISSUELIGHT_LIVE_SSH_KEY_PATH"],
              let knownHostsPath = environment["ISSUELIGHT_LIVE_SSH_KNOWN_HOSTS_PATH"] else {
            if environment["ISSUELIGHT_REQUIRE_LIVE_SSH"] == "1" {
                XCTFail("Required live SSH fixture environment is incomplete")
                return
            }
            throw XCTSkip("Live SSH fixture is not configured")
        }

        let manager = SSHTunnelManager(
            additionalArguments: [
                "-o", "UserKnownHostsFile=\(knownHostsPath)",
                "-o", "StrictHostKeyChecking=yes",
            ]
        )
        let sourceID = UUID()
        let targetURL = try XCTUnwrap(URL(string: "http://127.0.0.1:8080/"))
        async let firstResult = manager.start(
            sourceID: sourceID,
            targetURL: targetURL,
            configuration: SSHTunnelConfiguration(
                bastionHost: "127.0.0.1",
                username: "operator",
                port: port,
                identityFilePath: identityFilePath
            )
        )
        async let secondResult = manager.start(
            sourceID: sourceID,
            targetURL: targetURL,
            configuration: SSHTunnelConfiguration(
                bastionHost: "127.0.0.1",
                username: "operator",
                port: port,
                identityFilePath: identityFilePath
            )
        )
        let (first, second) = await (firstResult, secondResult)
        let localPort = try first.get()

        XCTAssertEqual(try second.get(), localPort)
        let localURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(localPort)/"))

        let (data, response) = try await URLSession.shared.data(from: localURL)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "IssueLight SSH tunnel fixture\n")

        let socksResult = await manager.startSOCKS(
            sourceID: sourceID,
            configuration: SSHTunnelConfiguration(
                bastionHost: "127.0.0.1",
                username: "operator",
                port: port,
                identityFilePath: identityFilePath
            )
        )
        let socksPort = try socksResult.get()
        let isReachableThroughSOCKS = await TCPReachabilityProbe.canConnect(
            host: "127.0.0.1",
            port: 8_080,
            socksProxyPort: socksPort
        )
        XCTAssertTrue(isReachableThroughSOCKS)

        manager.reconcileSources([
            MonitoringSource(
                id: sourceID,
                name: "Disabled fixture",
                providerID: Icinga2Provider.id,
                endpoint: URL(string: "https://127.0.0.1:5665/v1")!,
                isEnabled: false,
                authentication: .basic(username: "fixture"),
                web: MonitoringWebConfiguration(
                    baseURL: targetURL,
                    automaticSSHTunnel: SSHTunnelConfiguration(
                        bastionHost: "127.0.0.1",
                        username: "operator",
                        port: port,
                        identityFilePath: identityFilePath
                    )
                )
            ),
        ])
        var didClose = false
        for _ in 0..<40 {
            if !(await TCPReachabilityProbe.canConnect(host: "127.0.0.1", port: localPort, timeout: 1)) {
                didClose = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(didClose, "The owned SSH forwarding port remained open after disabling its source")
    }

    func testLiveAutomaticRoutingLoadsRemoteLoopbackIcingaAPIThroughSSH() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpointText = environment["ISSUELIGHT_LIVE_ICINGA_SSH_URL"],
              let endpoint = URL(string: endpointText),
              let password = environment["ISSUELIGHT_ICINGA_BASIC_PASSWORD"],
              let portText = environment["ISSUELIGHT_LIVE_SSH_PORT"],
              let port = Int(portText),
              let identityFilePath = environment["ISSUELIGHT_LIVE_SSH_KEY_PATH"],
              let knownHostsPath = environment["ISSUELIGHT_LIVE_SSH_KNOWN_HOSTS_PATH"] else {
            if environment["ISSUELIGHT_REQUIRE_LIVE_SSH"] == "1" {
                XCTFail("Required live SSH and Icinga fixture environment is incomplete")
                return
            }
            throw XCTSkip("Live SSH and Icinga fixtures are not configured")
        }

        let manager = SSHTunnelManager(
            additionalArguments: [
                "-o", "UserKnownHostsFile=\(knownHostsPath)",
                "-o", "StrictHostKeyChecking=yes",
            ]
        )
        let coordinator = AutomaticConnectionCoordinator(tunnelManager: manager)
        let source = MonitoringSource(
            name: "SSH-only Icinga",
            providerID: Icinga2Provider.id,
            endpoint: endpoint,
            authentication: .basic(username: "issuelight-basic"),
            serverTrust: .disabled,
            sshTunnel: SSHTunnelConfiguration(
                bastionHost: "127.0.0.1",
                username: "operator",
                port: port,
                identityFilePath: identityFilePath,
                preferredLocalPort: 5_665
            )
        )
        defer { coordinator.stop(sourceID: source.id) }

        let (result, path) = await coordinator.performUsingBestAPIPath(
            source: source,
            access: ProviderAccess(credential: .password(password)),
            rediscoverDirect: true,
            operation: { routedSource, access in
                await Icinga2Provider().testConnection(to: routedSource, access: access)
            },
            requiresAlternativeNetworkPath: { $0 == .failed(.unreachable) }
        )

        XCTAssertEqual(result, .connected)
        XCTAssertEqual(path, .ssh)
    }

    func testLiveIcingaServerTrustMatrixAcrossSOCKSAndLoopbackForward() async throws {
        let fixture = try liveSSHFixture()
        let caCertificate = try ServerCertificateFingerprint.certificate(at: fixture.caCertificate)
        let fingerprint = try ServerCertificateFingerprint.sha256(at: fixture.serverCertificate)
        let routes = [
            ("local-forward", fixture.localForwardEndpoint),
            ("socks", fixture.socksEndpoint),
        ]
        let trustCases: [(
            String,
            ServerTrustConfiguration,
            SecCertificate?,
            ConnectionTestResult
        )] = [
            ("system", .system, nil, .failed(.serverTrust)),
            ("disabled", .disabled, nil, .connected),
            (
                "private-ca",
                .customCertificate(certificateID: "live-private-ca"),
                caCertificate,
                .connected
            ),
            ("pinned", .pinnedCertificate(sha256: fingerprint), nil, .connected),
            (
                "wrong-pin",
                .pinnedCertificate(sha256: String(repeating: "00", count: 32)),
                nil,
                .failed(.serverTrust)
            ),
        ]
        var executedScenarios = 0

        for (routeName, endpoint) in routes {
            for (trustName, trust, trustedCertificate, expected) in trustCases {
                let manager = fixture.manager()
                let coordinator = AutomaticConnectionCoordinator(tunnelManager: manager)
                let source = fixture.source(
                    name: "\(routeName)-\(trustName)",
                    endpoint: endpoint,
                    authentication: .basic(username: "issuelight-basic"),
                    trust: trust
                )
                let (result, path) = await coordinator.performUsingBestAPIPath(
                    source: source,
                    access: ProviderAccess(
                        credential: .password(fixture.basicPassword),
                        trustedServerCertificate: trustedCertificate
                    ),
                    rediscoverDirect: true,
                    operation: { routedSource, access in
                        await Icinga2Provider().testConnection(to: routedSource, access: access)
                    },
                    requiresAlternativeNetworkPath: needsAlternativePath
                )
                coordinator.stop(sourceID: source.id)

                let label = "\(routeName) \(trustName)"
                XCTAssertEqual(result, expected, label)
                XCTAssertEqual(path, .ssh, label)
                if trust == .disabled {
                    XCTAssertNotEqual(result, .failed(.serverTrust), label)
                }
                executedScenarios += 1
            }
        }
        XCTAssertEqual(executedScenarios, routes.count * trustCases.count)
    }

    func testLivePlainHTTPIgnoresTLSTrustAcrossSOCKSAndLoopbackForward() async throws {
        let fixture = try liveSSHFixture()
        let caCertificate = try ServerCertificateFingerprint.certificate(at: fixture.caCertificate)
        let fingerprint = try ServerCertificateFingerprint.sha256(at: fixture.serverCertificate)
        let routes = [
            ("local-forward", fixture.httpLocalForwardEndpoint),
            ("socks", fixture.httpSOCKSEndpoint),
        ]
        let trustCases: [(String, ServerTrustConfiguration, SecCertificate?)] = [
            ("system", .system, nil),
            ("disabled", .disabled, nil),
            ("private-ca", .customCertificate(certificateID: "unused-over-http"), caCertificate),
            ("pinned", .pinnedCertificate(sha256: fingerprint), nil),
            ("wrong-pin", .pinnedCertificate(sha256: String(repeating: "00", count: 32)), nil),
        ]
        var executedScenarios = 0

        for (routeName, endpoint) in routes {
            for (trustName, trust, trustedCertificate) in trustCases {
                let manager = fixture.manager()
                let coordinator = AutomaticConnectionCoordinator(tunnelManager: manager)
                let source = fixture.source(
                    name: "http-\(routeName)-\(trustName)",
                    endpoint: endpoint,
                    authentication: .basic(username: "issuelight-basic"),
                    trust: trust
                )
                let (result, path) = await coordinator.performUsingBestAPIPath(
                    source: source,
                    access: ProviderAccess(
                        credential: .password(fixture.basicPassword),
                        trustedServerCertificate: trustedCertificate
                    ),
                    rediscoverDirect: true,
                    operation: { routedSource, access in
                        await Icinga2Provider().testConnection(to: routedSource, access: access)
                    },
                    requiresAlternativeNetworkPath: needsAlternativePath
                )
                coordinator.stop(sourceID: source.id)

                let label = "HTTP \(routeName) \(trustName)"
                XCTAssertEqual(result, .connected, label)
                XCTAssertEqual(path, .ssh, label)
                executedScenarios += 1
            }
        }
        XCTAssertEqual(executedScenarios, routes.count * trustCases.count)
    }

    func testLiveIcingaMutualTLSMatrixAcrossSOCKSAndLoopbackForward() async throws {
        let fixture = try liveSSHFixture()
        let keychain = try TemporaryTestKeychain()
        defer { try? keychain.delete() }
        let catalog = KeychainIdentityCatalog(accessContext: keychain.context)
        let acceptedDescriptor = try await catalog.importPKCS12(
            at: fixture.acceptedIdentity,
            password: fixture.identityPassword
        )
        let rejectedDescriptor = try await catalog.importPKCS12(
            at: fixture.rejectedIdentity,
            password: fixture.identityPassword
        )
        let resolvedAcceptedIdentity = try await catalog.identity(id: acceptedDescriptor.id)
        let resolvedRejectedIdentity = try await catalog.identity(id: rejectedDescriptor.id)
        let acceptedIdentity = try XCTUnwrap(resolvedAcceptedIdentity)
        let rejectedIdentity = try XCTUnwrap(resolvedRejectedIdentity)
        let caCertificate = try ServerCertificateFingerprint.certificate(at: fixture.caCertificate)
        let routes = [
            ("local-forward", fixture.localForwardEndpoint),
            ("socks", fixture.socksEndpoint),
        ]
        let identities: [(String, ClientIdentityDescriptor, SecIdentity, ConnectionTestResult)] = [
            ("accepted", acceptedDescriptor, acceptedIdentity, .connected),
            ("rejected", rejectedDescriptor, rejectedIdentity, .failed(.authentication)),
        ]
        var executedScenarios = 0

        for (routeName, endpoint) in routes {
            for (identityName, descriptor, identity, expected) in identities {
                let manager = fixture.manager()
                let coordinator = AutomaticConnectionCoordinator(tunnelManager: manager)
                let source = fixture.source(
                    name: "\(routeName)-mtls-\(identityName)",
                    endpoint: endpoint,
                    authentication: .clientCertificate(identityID: descriptor.id),
                    trust: .customCertificate(certificateID: "live-private-ca")
                )
                let (result, path) = await coordinator.performUsingBestAPIPath(
                    source: source,
                    access: ProviderAccess(
                        credential: .clientIdentity(identity),
                        trustedServerCertificate: caCertificate
                    ),
                    rediscoverDirect: true,
                    operation: { routedSource, access in
                        await Icinga2Provider().testConnection(to: routedSource, access: access)
                    },
                    requiresAlternativeNetworkPath: needsAlternativePath
                )
                coordinator.stop(sourceID: source.id)

                let label = "\(routeName) mTLS \(identityName)"
                XCTAssertEqual(result, expected, label)
                XCTAssertEqual(path, .ssh, label)
                executedScenarios += 1
            }
        }
        XCTAssertEqual(executedScenarios, routes.count * identities.count)
    }

    func testLiveDisabledTrustNeverTurnsTransportFailuresIntoTrustFailuresAcrossSSHRoutes() async throws {
        let fixture = try liveSSHFixture()
        let routes = [
            ("local-forward", URL(string: "https://localhost:8080")!),
            ("socks", URL(string: "https://ssh-gateway:8080")!),
        ]

        for (routeName, endpoint) in routes {
            let manager = fixture.manager()
            let coordinator = AutomaticConnectionCoordinator(tunnelManager: manager)
            let source = fixture.source(
                name: "\(routeName)-plain-http-on-https",
                endpoint: endpoint,
                authentication: .basic(username: "issuelight-basic"),
                trust: .disabled
            )
            let (result, path) = await coordinator.performUsingBestAPIPath(
                source: source,
                access: ProviderAccess(credential: .password(fixture.basicPassword)),
                rediscoverDirect: true,
                operation: { routedSource, access in
                    await Icinga2Provider().testConnection(to: routedSource, access: access)
                },
                requiresAlternativeNetworkPath: needsAlternativePath
            )
            coordinator.stop(sourceID: source.id)

            guard case .failed(let failure) = result else {
                return XCTFail("Plain HTTP on an HTTPS endpoint must fail: \(routeName)")
            }
            XCTAssertTrue(
                failure == .tls || failure == .unreachable,
                "Expected a transport failure, got \(failure): \(routeName)"
            )
            guard case .unavailable = path else {
                return XCTFail("A transport failure must remain unavailable: \(routeName)")
            }
            XCTAssertNotEqual(result, .failed(.serverTrust), routeName)
        }
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

    private func liveSSHFixture() throws -> LiveSSHFixture {
        let environment = ProcessInfo.processInfo.environment
        guard let localEndpointText = environment["ISSUELIGHT_LIVE_ICINGA_SSH_URL"],
              let localEndpoint = URL(string: localEndpointText),
              let socksEndpointText = environment["ISSUELIGHT_LIVE_ICINGA_SOCKS_URL"],
              let socksEndpoint = URL(string: socksEndpointText),
              let httpLocalEndpointText = environment["ISSUELIGHT_LIVE_ICINGA_HTTP_SSH_URL"],
              let httpLocalEndpoint = URL(string: httpLocalEndpointText),
              let httpSOCKSEndpointText = environment["ISSUELIGHT_LIVE_ICINGA_HTTP_SOCKS_URL"],
              let httpSOCKSEndpoint = URL(string: httpSOCKSEndpointText),
              let basicPassword = environment["ISSUELIGHT_ICINGA_BASIC_PASSWORD"],
              let identityPassword = environment["ISSUELIGHT_ICINGA_PKCS12_PASSWORD"],
              let sshPortText = environment["ISSUELIGHT_LIVE_SSH_PORT"],
              let sshPort = Int(sshPortText),
              let identityFilePath = environment["ISSUELIGHT_LIVE_SSH_KEY_PATH"],
              let knownHostsPath = environment["ISSUELIGHT_LIVE_SSH_KNOWN_HOSTS_PATH"],
              let caPath = environment["ISSUELIGHT_LIVE_ICINGA_CA_PATH"],
              let serverPath = environment["ISSUELIGHT_LIVE_ICINGA_SERVER_CERT_PATH"],
              let acceptedIdentityPath = environment["ISSUELIGHT_LIVE_ICINGA_PKCS12_PATH"],
              let rejectedIdentityPath = environment["ISSUELIGHT_LIVE_ICINGA_REJECTED_PKCS12_PATH"] else {
            if environment["ISSUELIGHT_REQUIRE_LIVE_ICINGA"] == "1"
                || environment["ISSUELIGHT_REQUIRE_LIVE_SSH"] == "1" {
                throw LiveSSHFixtureError.incompleteEnvironment
            }
            throw XCTSkip("Live SSH and Icinga fixtures are not configured")
        }
        return LiveSSHFixture(
            localForwardEndpoint: localEndpoint,
            socksEndpoint: socksEndpoint,
            httpLocalForwardEndpoint: httpLocalEndpoint,
            httpSOCKSEndpoint: httpSOCKSEndpoint,
            basicPassword: basicPassword,
            identityPassword: identityPassword,
            sshPort: sshPort,
            identityFilePath: identityFilePath,
            knownHostsPath: knownHostsPath,
            caCertificate: URL(fileURLWithPath: caPath),
            serverCertificate: URL(fileURLWithPath: serverPath),
            acceptedIdentity: URL(fileURLWithPath: acceptedIdentityPath),
            rejectedIdentity: URL(fileURLWithPath: rejectedIdentityPath)
        )
    }
}

private enum LiveSSHFixtureError: Error {
    case incompleteEnvironment
}

private enum LoopbackPortReservationError: Error {
    case unavailable
}

private final class LoopbackPortReservation {
    let port: Int
    private let descriptor: Int32

    init() throws {
        var selectedDescriptor: Int32?
        var selectedPort: Int?
        for candidate in 45_000...64_000 {
            let candidateDescriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard candidateDescriptor >= 0 else { continue }
            var address = sockaddr_in(
                sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
                sin_family: sa_family_t(AF_INET),
                sin_port: in_port_t(candidate).bigEndian,
                sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
                sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
            )
            let didBind = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(candidateDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            if didBind, listen(candidateDescriptor, 1) == 0 {
                selectedDescriptor = candidateDescriptor
                selectedPort = candidate
                break
            }
            close(candidateDescriptor)
        }
        guard let selectedDescriptor, let selectedPort else {
            throw LoopbackPortReservationError.unavailable
        }
        descriptor = selectedDescriptor
        port = selectedPort
    }

    deinit {
        close(descriptor)
    }
}

@MainActor
private struct LiveSSHFixture {
    let localForwardEndpoint: URL
    let socksEndpoint: URL
    let httpLocalForwardEndpoint: URL
    let httpSOCKSEndpoint: URL
    let basicPassword: String
    let identityPassword: String
    let sshPort: Int
    let identityFilePath: String
    let knownHostsPath: String
    let caCertificate: URL
    let serverCertificate: URL
    let acceptedIdentity: URL
    let rejectedIdentity: URL

    func manager() -> SSHTunnelManager {
        SSHTunnelManager(
            additionalArguments: [
                "-o", "UserKnownHostsFile=\(knownHostsPath)",
                "-o", "StrictHostKeyChecking=yes",
            ]
        )
    }

    func source(
        name: String,
        endpoint: URL,
        authentication: AuthenticationConfiguration,
        trust: ServerTrustConfiguration
    ) -> MonitoringSource {
        MonitoringSource(
            name: name,
            providerID: Icinga2Provider.id,
            endpoint: endpoint,
            authentication: authentication,
            serverTrust: trust,
            sshTunnel: SSHTunnelConfiguration(
                bastionHost: "127.0.0.1",
                username: "operator",
                port: sshPort,
                identityFilePath: identityFilePath
            )
        )
    }
}
