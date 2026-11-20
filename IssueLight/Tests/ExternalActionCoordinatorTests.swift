import Foundation
import IssueLightCore
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
                operation: { routedAccess in
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
                operation: { routedAccess in
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
            (Icinga2Provider.id, "https://icinga.example.test:5665"),
            (CheckmkProvider.id, "https://checkmk.example.test:443"),
            (ThrukProvider.id, "https://thruk.example.test:8443"),
            (NagiosCoreProvider.id, "http://nagios.example.test:8080"),
        ]

        for (providerID, endpointText) in scenarios {
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
                    port: try XCTUnwrap(endpoint.port)
                )
            )
            let (result, path): (ConnectionTestResult, AutomaticConnectionPath) = await coordinator
                .performUsingBestAPIPath(
                    source: source,
                    access: ProviderAccess(credential: .password("test-only")),
                    operation: { routedAccess in
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
                operation: { _ in .failed(.unreachable) },
                requiresAlternativeNetworkPath: { $0 == .failed(.unreachable) }
            )

        guard case .unavailable(let message) = path else {
            return XCTFail("A distinct custom SSH port must not be silently replaced")
        }
        XCTAssertTrue(message.contains("port 2222"))
        XCTAssertFalse(message.contains("port 22:"))
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
                operation: { routedAccess in
                    attempts.append(routedAccess.socksProxy)
                    return routedAccess.socksProxy == nil ? .failed(.unreachable) : .connected
                },
                requiresAlternativeNetworkPath: { $0 == .failed(.unreachable) }
            )
        let second: (ConnectionTestResult, AutomaticConnectionPath) = await coordinator
            .performUsingBestAPIPath(
                source: source,
                access: access,
                operation: { routedAccess in
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
                operation: { routedAccess in
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
            endpoint: URL(string: "https://checkmk.example.test:443")!,
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

    func testLiveAutomaticRoutingLoadsIcingaAPIThroughSOCKS() async throws {
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
                identityFilePath: identityFilePath
            )
        )
        defer { coordinator.stop(sourceID: source.id) }

        let (result, path) = await coordinator.performUsingBestAPIPath(
            source: source,
            access: ProviderAccess(credential: .password(password)),
            rediscoverDirect: true,
            operation: { access in
                await Icinga2Provider().testConnection(to: source, access: access)
            },
            requiresAlternativeNetworkPath: { $0 == .failed(.unreachable) }
        )

        XCTAssertEqual(result, .connected)
        XCTAssertEqual(path, .ssh)
    }
}
