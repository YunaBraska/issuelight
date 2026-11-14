import Foundation
import IssueLightCore
import XCTest

@MainActor
final class ExternalActionCoordinatorTests: XCTestCase {
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
}
