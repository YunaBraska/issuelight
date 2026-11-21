import Darwin
import Foundation
import XCTest
@testable import IssueLightCore

final class ProviderTransportBoundaryTests: XCTestCase {
    private static var fixtureResult: Result<TLSBoundaryFixtures, Error>!

    override class func setUp() {
        super.setUp()
        fixtureResult = Result { try TLSBoundaryFixtures() }
    }

    override class func tearDown() {
        if case .success(let fixtures) = fixtureResult {
            fixtures.remove()
        }
        fixtureResult = nil
        super.tearDown()
    }

    func testDisabledTrustAcceptsUnknownCertificateForMismatchedHostname() async throws {
        let fixtures = try Self.fixtureResult.get()
        let server = try OpenSSLTestServer(
            certificate: fixtures.validCertificate,
            privateKey: fixtures.serverPrivateKey
        )
        defer { server.stop() }

        let result = await TLSBoundaryProbe.request(port: server.port, trust: .disabled)

        XCTAssertEqual(result, .success(200))
    }

    func testDisabledTrustAcceptsExpiredCertificate() async throws {
        let fixtures = try Self.fixtureResult.get()
        let server = try OpenSSLTestServer(
            certificate: fixtures.expiredCertificate,
            privateKey: fixtures.serverPrivateKey
        )
        defer { server.stop() }

        let result = await TLSBoundaryProbe.request(port: server.port, trust: .disabled)

        XCTAssertEqual(result, .success(200))
    }

    func testDisabledTrustAcceptsNotYetValidCertificate() async throws {
        let fixtures = try Self.fixtureResult.get()
        let server = try OpenSSLTestServer(
            certificate: fixtures.futureCertificate,
            privateKey: fixtures.serverPrivateKey
        )
        defer { server.stop() }

        let result = await TLSBoundaryProbe.request(port: server.port, trust: .disabled)

        XCTAssertEqual(result, .success(200))
    }

    func testDisabledTrustAcceptsCertificateWithoutServerAuthenticationUsage() async throws {
        let fixtures = try Self.fixtureResult.get()
        let server = try OpenSSLTestServer(
            certificate: fixtures.clientOnlyCertificate,
            privateKey: fixtures.serverPrivateKey
        )
        defer { server.stop() }

        let result = await TLSBoundaryProbe.request(port: server.port, trust: .disabled)

        XCTAssertEqual(result, .success(200))
    }

    func testSystemTrustRejectsCertificateFromUnknownPrivateCA() async throws {
        let fixtures = try Self.fixtureResult.get()
        let server = try OpenSSLTestServer(
            certificate: fixtures.validCertificate,
            privateKey: fixtures.serverPrivateKey
        )
        defer { server.stop() }

        let result = await TLSBoundaryProbe.request(port: server.port, trust: .system)

        XCTAssertEqual(result, .failure(.serverTrust))
    }

    func testHandshakeWithoutServerCertificateIsNotReportedAsTrustRejection() async throws {
        let server = try OpenSSLTestServer(certificate: nil, privateKey: nil)
        defer { server.stop() }

        let result = await TLSBoundaryProbe.request(port: server.port, trust: .disabled)

        XCTAssertEqual(result, .failure(.tls))
    }

    func testPlainHTTPOnConfiguredHTTPSPortIsReportedAsTLSHandshakeFailure() async throws {
        let server = try PlainHTTPTestServer()
        defer { server.stop() }

        let result = await TLSBoundaryProbe.request(port: server.port, trust: .disabled)

        XCTAssertEqual(result, .failure(.tls))
    }

    func testIcingaBasicConnectionUsesRealPlainHTTPTransport() async throws {
        let server = try PlainHTTPTestServer(body: Data(#"{"results":[]}"#.utf8))
        defer { server.stop() }
        let source = MonitoringSource(
            name: "HTTP boundary",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: "http://127.0.0.1:\(server.port)")!,
            authentication: .basic(username: "fixture")
        )

        let result = await Icinga2Provider().testConnection(
            to: source,
            access: ProviderAccess(credential: .password("test-only"))
        )

        XCTAssertEqual(result, .connected)
    }

    func testPlainHTTPDoesNotRequireATLSCertificateForACustomTrustSetting() async throws {
        let server = try PlainHTTPTestServer(body: Data(#"{"results":[]}"#.utf8))
        defer { server.stop() }
        let source = MonitoringSource(
            name: "HTTP ignores TLS trust",
            providerID: Icinga2Provider.id,
            endpoint: URL(string: "http://127.0.0.1:\(server.port)")!,
            authentication: .basic(username: "fixture"),
            serverTrust: .customCertificate(certificateID: "unused-over-http")
        )

        let result = await Icinga2Provider().testConnection(
            to: source,
            access: ProviderAccess(credential: .password("test-only"))
        )

        XCTAssertEqual(result, .connected)
    }

    func testRequiredClientCertificateIsReportedSeparately() async throws {
        let fixtures = try Self.fixtureResult.get()
        let server = try OpenSSLTestServer(
            certificate: fixtures.validCertificate,
            privateKey: fixtures.serverPrivateKey,
            requiredClientCA: fixtures.rootCertificate
        )
        defer { server.stop() }

        let result = await TLSBoundaryProbe.request(port: server.port, trust: .disabled)

        XCTAssertEqual(result, .failure(.clientCertificateRejected))
    }
}

private enum TLSBoundaryProbe {
    static func request(
        port: Int,
        trust: ServerTrustConfiguration
    ) async -> Result<Int, ConnectionFailure> {
        let endpoint = URL(string: "https://127.0.0.1:\(port)/")!
        let source = MonitoringSource(
            name: "TLS boundary",
            providerID: Icinga2Provider.id,
            endpoint: endpoint,
            authentication: .basic(username: "fixture"),
            serverTrust: trust
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3

        do {
            let session = try ProviderHTTPSession(
                source: source,
                authentication: .none,
                trustedServerCertificate: nil,
                configuration: configuration
            )
            defer { session.close() }
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 3
            let response = try await session.response(for: request)
            return .success(response.statusCode)
        } catch let ProviderHTTPError.failure(failure) {
            return .failure(failure)
        } catch {
            return .failure(.unreachable)
        }
    }
}

private final class TLSBoundaryFixtures {
    let directory: URL

    var rootCertificate: URL { directory.appendingPathComponent("root.crt") }
    var validCertificate: URL { directory.appendingPathComponent("valid.crt") }
    var expiredCertificate: URL { directory.appendingPathComponent("expired.crt") }
    var futureCertificate: URL { directory.appendingPathComponent("future.crt") }
    var clientOnlyCertificate: URL { directory.appendingPathComponent("client-only.crt") }
    var serverPrivateKey: URL { directory.appendingPathComponent("server.key") }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issuelight-tls-boundaries-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        do {
            let script = try XCTUnwrap(
                Bundle.module.url(
                    forResource: "generate-tls-boundary-fixtures",
                    withExtension: "sh",
                    subdirectory: "Fixtures"
                )
            )
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path, directory.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(
                    decoding: output.fileHandleForReading.readDataToEndOfFile(),
                    as: UTF8.self
                )
                throw TLSBoundaryFixtureError.generationFailed(message)
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private enum TLSBoundaryFixtureError: Error {
    case generationFailed(String)
    case serverDidNotStart
}

private final class OpenSSLTestServer {
    let port: Int
    private let process: Process

    init(
        certificate: URL?,
        privateKey: URL?,
        requiredClientCA: URL? = nil
    ) throws {
        port = try LocalTestPort.available()
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var arguments = [
            "openssl", "s_server",
            "-4",
            "-accept", "127.0.0.1:\(port)",
            "-www",
            "-quiet",
        ]
        if let certificate, let privateKey {
            arguments.append(contentsOf: [
                "-cert", certificate.path,
                "-key", privateKey.path,
            ])
        } else {
            arguments.append("-nocert")
        }
        if let requiredClientCA {
            arguments.append(contentsOf: [
                "-Verify", "1",
                "-verify_return_error",
                "-CAfile", requiredClientCA.path,
            ])
        }
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            try LocalTestPort.waitUntilListening(process: process, port: port)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        for _ in 0..<20 where process.isRunning {
            usleep(10_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    deinit {
        stop()
    }
}

private final class PlainHTTPTestServer {
    let port: Int
    private let lock = NSLock()
    private let response: Data
    private var listeningDescriptor: Int32

    init(body: Data = Data()) throws {
        response = Data(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8
        ) + body
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw TLSBoundaryFixtureError.serverDidNotStart
        }
        var reuseAddress: Int32 = 1
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddress,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var address = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: 0,
            sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )
        let didBind = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard didBind, listen(descriptor, 4) == 0 else {
            close(descriptor)
            throw TLSBoundaryFixtureError.serverDidNotStart
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let didRead = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length) == 0
            }
        }
        guard didRead else {
            close(descriptor)
            throw TLSBoundaryFixtureError.serverDidNotStart
        }
        port = Int(in_port_t(bigEndian: address.sin_port))
        listeningDescriptor = descriptor
        DispatchQueue(label: "berlin.yuna.issuelight.tests.plain-http").async { [weak self] in
            self?.serve()
        }
    }

    func stop() {
        lock.lock()
        let descriptor = listeningDescriptor
        listeningDescriptor = -1
        lock.unlock()
        guard descriptor >= 0 else { return }
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
    }

    deinit {
        stop()
    }

    private func serve() {
        while true {
            lock.lock()
            let descriptor = listeningDescriptor
            lock.unlock()
            guard descriptor >= 0 else { return }
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            var noSignal: Int32 = 1
            setsockopt(
                client,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSignal,
                socklen_t(MemoryLayout<Int32>.size)
            )
            response.withUnsafeBytes { bytes in
                _ = send(client, bytes.baseAddress, bytes.count, 0)
            }
            usleep(50_000)
            close(client)
        }
    }
}

private enum LocalTestPort {
    static func available() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw TLSBoundaryFixtureError.serverDidNotStart
        }
        defer { close(descriptor) }
        var address = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: 0,
            sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )
        let didBind = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard didBind else {
            throw TLSBoundaryFixtureError.serverDidNotStart
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let didRead = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length) == 0
            }
        }
        guard didRead else {
            throw TLSBoundaryFixtureError.serverDidNotStart
        }
        return Int(in_port_t(bigEndian: address.sin_port))
    }

    static func waitUntilListening(process: Process, port: Int) throws {
        for _ in 0..<100 {
            guard process.isRunning else {
                throw TLSBoundaryFixtureError.serverDidNotStart
            }
            if canConnect(to: port) {
                return
            }
            usleep(20_000)
        }
        throw TLSBoundaryFixtureError.serverDidNotStart
    }

    static func canConnect(to port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: in_port_t(port).bigEndian,
            sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
