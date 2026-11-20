import AppKit
import Combine
import Darwin
import Foundation
import IssueLightCore
import Network

struct IssueWebTarget: Equatable {
    let sourceID: UUID
    let url: URL
    let automaticSSHTunnel: SSHTunnelConfiguration?
}

enum AutomaticConnectionPath: Equatable {
    case direct
    case ssh
    case unavailable(String)
}

@MainActor
final class AutomaticConnectionCoordinator {
    private let tunnelManager: SSHTunnelManager
    private let canConnect: (String, Int, Int?) async -> Bool
    private var apiProxyPorts: [UUID: Int] = [:]

    init(
        tunnelManager: SSHTunnelManager? = nil,
        canConnect: @escaping (String, Int, Int?) async -> Bool = { host, port, proxyPort in
            await TCPReachabilityProbe.canConnect(
                host: host,
                port: port,
                socksProxyPort: proxyPort
            )
        }
    ) {
        self.tunnelManager = tunnelManager ?? SSHTunnelManager()
        self.canConnect = canConnect
    }

    func performUsingBestAPIPath<Result>(
        source: MonitoringSource,
        access: ProviderAccess,
        rediscoverDirect: Bool = false,
        operation: (ProviderAccess) async -> Result,
        requiresAlternativeNetworkPath: (Result) -> Bool
    ) async -> (Result, AutomaticConnectionPath) {
        if !rediscoverDirect, let proxyPort = apiProxyPorts[source.id] {
            let proxiedResult = await operation(access.routingThroughSOCKS(port: proxyPort))
            if !requiresAlternativeNetworkPath(proxiedResult) {
                return (proxiedResult, .ssh)
            }
            apiProxyPorts[source.id] = nil
            tunnelManager.stopSOCKS(sourceID: source.id)
        }

        let directResult = await operation(access)
        guard requiresAlternativeNetworkPath(directResult) else {
            apiProxyPorts[source.id] = nil
            tunnelManager.stopSOCKS(sourceID: source.id)
            return (directResult, .direct)
        }

        guard AppDistribution.supportsSSHTunnels else {
            apiProxyPorts[source.id] = nil
            tunnelManager.stopSOCKS(sourceID: source.id)
            return (directResult, .direct)
        }

        if let proxyPort = apiProxyPorts[source.id] {
            let proxiedResult = await operation(access.routingThroughSOCKS(port: proxyPort))
            if !requiresAlternativeNetworkPath(proxiedResult) {
                return (proxiedResult, .ssh)
            }
            apiProxyPorts[source.id] = nil
            tunnelManager.stopSOCKS(sourceID: source.id)
        }

        let configuration = tunnelManager.resolvedConfiguration(for: source)
        guard !configuration.bastionHost.isEmpty else {
            return (directResult, .unavailable("The API host cannot be used as an SSH destination."))
        }
        let fallbackPort = configuration.port != 22 && configuration.port == source.endpoint.port
            ? 22
            : nil
        switch await tunnelManager.startSOCKS(
            sourceID: source.id,
            configuration: configuration,
            fallbackPort: fallbackPort
        ) {
        case .success(let proxyPort):
            let proxiedResult = await operation(access.routingThroughSOCKS(port: proxyPort))
            guard !requiresAlternativeNetworkPath(proxiedResult) else {
                tunnelManager.stopSOCKS(sourceID: source.id)
                return (proxiedResult, .unavailable("SSH connected, but the API connection still failed."))
            }
            apiProxyPorts[source.id] = proxyPort
            return (proxiedResult, .ssh)
        case .failure(.message(let message)):
            return (directResult, .unavailable(message))
        }
    }

    func checkWeb(source: MonitoringSource, url: URL) async -> AutomaticConnectionPath {
        guard let host = url.host else {
            return .unavailable("The web URL has no host.")
        }
        let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        if await canConnect(host, port, nil) {
            if apiProxyPorts[source.id] == nil {
                tunnelManager.stopSOCKS(sourceID: source.id)
            }
            return .direct
        }

        guard AppDistribution.supportsSSHTunnels else {
            return .unavailable("The web interface is not reachable directly.")
        }

        let configuration = tunnelManager.resolvedConfiguration(for: source)
        guard !configuration.bastionHost.isEmpty else {
            return .unavailable("The API host cannot be used as an SSH destination.")
        }
        let fallbackPort = configuration.port != 22 && configuration.port == source.endpoint.port
            ? 22
            : nil
        switch await tunnelManager.startSOCKS(
            sourceID: source.id,
            configuration: configuration,
            fallbackPort: fallbackPort
        ) {
        case .success(let proxyPort):
            if await canConnect(host, port, proxyPort) {
                return .ssh
            }
            if apiProxyPorts[source.id] == nil {
                tunnelManager.stopSOCKS(sourceID: source.id)
            }
            return .unavailable("SSH connected, but the web interface is not reachable through it.")
        case .failure(.message(let message)):
            return .unavailable(message)
        }
    }

    func reconcileSources(_ sources: [MonitoringSource]) {
        tunnelManager.reconcileSources(sources)
        let sourceIDs = Set(sources.filter(\.isEnabled).map(\.id))
        apiProxyPorts = apiProxyPorts.filter { sourceIDs.contains($0.key) }
    }

    func stop(sourceID: UUID) {
        apiProxyPorts[sourceID] = nil
        tunnelManager.stop(sourceID: sourceID)
    }
}

enum ExternalActionError: Error, Equatable {
    case applicationUnavailable
    case tunnelCouldNotStart(String)
    case secureTunnelUnsupported
}

@MainActor
final class ExternalActionCoordinator: ObservableObject {
    private let openURL: (URL) -> Bool
    private let canConnect: (String, Int) async -> Bool
    private let tunnelManager: SSHTunnelManager
    private var terminationObserver: NSObjectProtocol?
    private var sourceObservation: AnyCancellable?

    init(
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        canConnect: @escaping (String, Int) async -> Bool = {
            await TCPReachabilityProbe.canConnect(host: $0, port: $1)
        },
        tunnelManager: SSHTunnelManager? = nil
    ) {
        self.openURL = openURL
        self.canConnect = canConnect
        self.tunnelManager = tunnelManager ?? SSHTunnelManager()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tunnelManager.stopAll()
            }
        }
    }

    func openWeb(_ target: IssueWebTarget) async -> Result<URL, ExternalActionError> {
        guard target.automaticSSHTunnel != nil else {
            return openURL(target.url) ? .success(target.url) : .failure(.applicationUnavailable)
        }
        let directPort = target.url.port ?? (target.url.scheme?.lowercased() == "https" ? 443 : 80)
        if await canConnect(target.url.host ?? "", directPort) {
            tunnelManager.stopWeb(sourceID: target.sourceID)
            return openURL(target.url) ? .success(target.url) : .failure(.applicationUnavailable)
        }

        guard target.url.scheme?.lowercased() == "http" else {
            return .failure(.secureTunnelUnsupported)
        }
        guard let tunnel = target.automaticSSHTunnel else {
            return openURL(target.url) ? .success(target.url) : .failure(.applicationUnavailable)
        }

        switch await tunnelManager.start(sourceID: target.sourceID, targetURL: target.url, configuration: tunnel) {
        case .success(let localPort):
            var components = URLComponents(url: target.url, resolvingAgainstBaseURL: false)
            components?.host = "127.0.0.1"
            components?.port = localPort
            guard let tunneledURL = components?.url, openURL(tunneledURL) else {
                tunnelManager.stopWeb(sourceID: target.sourceID)
                return .failure(.applicationUnavailable)
            }
            return .success(tunneledURL)
        case .failure(.message(let message)):
            return .failure(.tunnelCouldNotStart(message))
        }
    }

    func openRemote(_ url: URL) -> Result<URL, ExternalActionError> {
        openURL(url) ? .success(url) : .failure(.applicationUnavailable)
    }

    func observeSources(_ model: IssueLightModel) {
        sourceObservation = model.$sources.sink { [weak self] sources in
            MainActor.assumeIsolated {
                self?.tunnelManager.reconcileSources(sources)
            }
        }
    }

    isolated deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        tunnelManager.stopAll()
    }
}

#if ISSUELIGHT_APP_STORE
@MainActor
final class SSHTunnelManager {
    enum StartError: Error, Equatable {
        case message(String)
    }

    func start(
        sourceID: UUID,
        targetURL: URL,
        configuration: SSHTunnelConfiguration
    ) async -> Result<Int, StartError> {
        .failure(.message("SSH tunnelling is unavailable in the App Store edition."))
    }

    func startSOCKS(
        sourceID: UUID,
        configuration: SSHTunnelConfiguration,
        fallbackPort _: Int? = nil
    ) async -> Result<Int, StartError> {
        .failure(.message("SSH tunnelling is unavailable in the App Store edition."))
    }

    func reconcileSources(_: [MonitoringSource]) {}

    func stopAll() {}

    func stop(sourceID _: UUID) {}

    func stopSOCKS(sourceID _: UUID) {}

    func stopWeb(sourceID _: UUID) {}

    func resolvedConfiguration(for source: MonitoringSource) -> SSHTunnelConfiguration {
        SSHTunnelConfiguration(
            bastionHost: source.endpoint.host ?? "",
            username: ""
        )
    }
}

final class TCPReachabilityCompletion: @unchecked Sendable {
    private let connection: NWConnection
    private let continuation: CheckedContinuation<Bool, Never>
    private let lock = NSLock()
    private var completed = false

    init(connection: NWConnection, continuation: CheckedContinuation<Bool, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func complete(_ result: Bool) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        connection.cancel()
        continuation.resume(returning: result)
    }
}

enum TCPReachabilityProbe {
    static func canConnect(
        host: String,
        port: Int,
        timeout: Int = 2,
        socksProxyPort: Int? = nil
    ) async -> Bool {
        guard socksProxyPort == nil,
              !host.isEmpty,
              (1...65_535).contains(port),
              let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return false
        }

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: endpointPort,
                using: .tcp
            )
            let completion = TCPReachabilityCompletion(
                connection: connection,
                continuation: continuation
            )
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    completion.complete(true)
                case .failed, .cancelled:
                    completion.complete(false)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(timeout)) {
                completion.complete(false)
            }
        }
    }
}
#else
@MainActor
final class SSHTunnelManager {
    enum StartError: Error, Equatable {
        case message(String)
    }

    struct Command: Equatable {
        let arguments: [String]

        init(
            localPort: Int,
            remoteHost: String,
            remotePort: Int,
            configuration: SSHTunnelConfiguration
        ) {
            var values = [
                "-N",
                "-T",
                "-o", "BatchMode=yes",
                "-o", "ExitOnForwardFailure=yes",
                "-o", "ConnectTimeout=5",
                "-L", "127.0.0.1:\(localPort):\(remoteHost):\(remotePort)",
            ]
            if configuration.port != 22 {
                values.append(contentsOf: ["-p", String(configuration.port)])
            }
            if let identityFilePath = configuration.identityFilePath,
               !identityFilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                values.append(contentsOf: ["-i", identityFilePath, "-o", "IdentitiesOnly=yes"])
            }
            if !configuration.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                values.append(contentsOf: ["-l", configuration.username])
            }
            values.append(contentsOf: ["--", configuration.bastionHost])
            arguments = values
        }

        init(socksPort: Int, configuration: SSHTunnelConfiguration) {
            var values = [
                "-N",
                "-T",
                "-o", "BatchMode=yes",
                "-o", "ExitOnForwardFailure=yes",
                "-o", "ConnectTimeout=5",
                "-D", "127.0.0.1:\(socksPort)",
            ]
            if configuration.port != 22 {
                values.append(contentsOf: ["-p", String(configuration.port)])
            }
            if let identityFilePath = configuration.identityFilePath,
               !identityFilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                values.append(contentsOf: ["-i", identityFilePath, "-o", "IdentitiesOnly=yes"])
            }
            if !configuration.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                values.append(contentsOf: ["-l", configuration.username])
            }
            values.append(contentsOf: ["--", configuration.bastionHost])
            arguments = values
        }
    }

    private enum Purpose: Hashable {
        case web
        case proxy
    }

    private struct TunnelKey: Hashable {
        let sourceID: UUID
        let purpose: Purpose
    }

    private struct ActiveTunnel {
        let process: Process
        let localPort: Int
        let targetHost: String?
        let targetPort: Int?
        let configuration: SSHTunnelConfiguration
    }

    private var activeTunnels: [TunnelKey: ActiveTunnel] = [:]
    private let executableURL: URL
    private let additionalArguments: [String]

    init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        additionalArguments: [String] = []
    ) {
        self.executableURL = executableURL
        self.additionalArguments = additionalArguments
    }

    func start(
        sourceID: UUID,
        targetURL: URL,
        configuration: SSHTunnelConfiguration
    ) async -> Result<Int, StartError> {
        guard let targetHost = targetURL.host else {
            return .failure(.message("The web target has no host."))
        }
        let targetPort = targetURL.port ?? 80
        let key = TunnelKey(sourceID: sourceID, purpose: .web)
        if let active = activeTunnels[key],
           active.process.isRunning,
           active.targetHost == targetHost,
           active.targetPort == targetPort,
           active.configuration == configuration {
            return await awaitReadiness(key: key, active: active)
        }

        stop(key: key)
        guard let localPort = LocalPortAllocator.availablePort(preferred: configuration.preferredLocalPort) else {
            return .failure(.message("No local port is available."))
        }

        let process = Process()
        let standardError = Pipe()
        process.executableURL = executableURL
        process.arguments = additionalArguments + Command(
            localPort: localPort,
            remoteHost: targetHost,
            remotePort: targetPort,
            configuration: configuration
        ).arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError
        do {
            try process.run()
        } catch {
            return .failure(.message(error.localizedDescription))
        }
        let active = ActiveTunnel(
            process: process,
            localPort: localPort,
            targetHost: targetHost,
            targetPort: targetPort,
            configuration: configuration
        )
        activeTunnels[key] = active
        return await awaitReadiness(key: key, active: active, standardError: standardError)
    }

    func startSOCKS(
        sourceID: UUID,
        configuration: SSHTunnelConfiguration,
        fallbackPort: Int? = nil
    ) async -> Result<Int, StartError> {
        let key = TunnelKey(sourceID: sourceID, purpose: .proxy)
        if let active = activeTunnels[key],
           active.process.isRunning,
           active.configuration == configuration {
            return await awaitReadiness(key: key, active: active)
        }
        var candidates = [configuration]
        if let fallbackPort,
           fallbackPort != configuration.port,
           (1...65_535).contains(fallbackPort) {
            var fallback = configuration
            fallback.port = fallbackPort
            candidates.append(fallback)
        }

        var failures: [String] = []
        for candidate in candidates {
            stop(key: key)
            guard let localPort = LocalPortAllocator.availablePort(
                preferred: configuration.preferredLocalPort
            ) else {
                return .failure(.message("No local port is available."))
            }

            let process = Process()
            let standardError = Pipe()
            process.executableURL = executableURL
            process.arguments = additionalArguments + Command(
                socksPort: localPort,
                configuration: candidate
            ).arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = standardError
            do {
                try process.run()
            } catch {
                failures.append(error.localizedDescription)
                continue
            }
            let active = ActiveTunnel(
                process: process,
                localPort: localPort,
                targetHost: nil,
                targetPort: nil,
                configuration: configuration
            )
            activeTunnels[key] = active
            switch await awaitReadiness(key: key, active: active, standardError: standardError) {
            case .success(let port):
                return .success(port)
            case .failure(.message(let message)):
                failures.append(
                    candidates.count == 1 ? message : "SSH port \(candidate.port): \(message)"
                )
            }
        }

        return .failure(.message(failures.joined(separator: "\n")))
    }

    func reconcileSources(_ sources: [MonitoringSource]) {
        let sourceByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        for (key, active) in Array(activeTunnels) {
            guard let source = sourceByID[key.sourceID], source.isEnabled else {
                stop(key: key)
                continue
            }
            let tunnel = resolvedConfiguration(for: source)
            if tunnel != active.configuration {
                stop(key: key)
                continue
            }
            if key.purpose == .web {
                guard let web = source.web,
                      web.baseURL.scheme?.lowercased() == "http" else {
                    stop(key: key)
                    continue
                }
                let targetPort = web.baseURL.port ?? 80
                if web.baseURL.host != active.targetHost || targetPort != active.targetPort {
                    stop(key: key)
                }
            }
        }
    }

    func stopAll() {
        for key in Array(activeTunnels.keys) {
            stop(key: key)
        }
    }

    func stop(sourceID: UUID) {
        for key in activeTunnels.keys.filter({ $0.sourceID == sourceID }) {
            stop(key: key)
        }
    }

    func stopSOCKS(sourceID: UUID) {
        stop(key: TunnelKey(sourceID: sourceID, purpose: .proxy))
    }

    func stopWeb(sourceID: UUID) {
        stop(key: TunnelKey(sourceID: sourceID, purpose: .web))
    }

    func resolvedConfiguration(for source: MonitoringSource) -> SSHTunnelConfiguration {
        let overrides = source.sshTunnel ?? source.web?.automaticSSHTunnel
        let configuredHost = overrides?.bastionHost.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return SSHTunnelConfiguration(
            bastionHost: configuredHost.isEmpty ? source.endpoint.host ?? "" : configuredHost,
            username: overrides?.username ?? "",
            port: overrides?.port ?? 22,
            identityFilePath: overrides?.identityFilePath,
            preferredLocalPort: overrides?.preferredLocalPort
        )
    }

    private func stop(key: TunnelKey) {
        guard let active = activeTunnels.removeValue(forKey: key) else { return }
        if active.process.isRunning {
            active.process.terminate()
        }
    }

    private func awaitReadiness(
        key: TunnelKey,
        active: ActiveTunnel,
        standardError: Pipe? = nil
    ) async -> Result<Int, StartError> {
        for _ in 0..<50 {
            guard activeTunnels[key]?.process === active.process else {
                return .failure(.message("SSH tunnel was replaced before it became ready."))
            }
            if !active.process.isRunning {
                activeTunnels.removeValue(forKey: key)
                let data = standardError?.fileHandleForReading.readDataToEndOfFile() ?? Data()
                let message = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(.message(message.isEmpty ? "SSH exited before the tunnel was ready." : message))
            }
            if await TCPReachabilityProbe.canConnect(host: "127.0.0.1", port: active.localPort, timeout: 1) {
                return .success(active.localPort)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        if activeTunnels[key]?.process === active.process {
            stop(key: key)
        }
        return .failure(.message("SSH did not open the local port within five seconds."))
    }
}

enum TCPReachabilityProbe {
    static func canConnect(
        host: String,
        port: Int,
        timeout: Int = 2,
        socksProxyPort: Int? = nil
    ) async -> Bool {
        guard !host.isEmpty, (1...65_535).contains(port) else { return false }
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
            var arguments = ["-z", "-G", String(timeout)]
            if let socksProxyPort {
                arguments.append(contentsOf: [
                    "-X", "5",
                    "-x", "127.0.0.1:\(socksProxyPort)",
                ])
            }
            arguments.append(contentsOf: [host, String(port)])
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }
}

enum LocalPortAllocator {
    static func availablePort(preferred: Int?) -> Int? {
        if let preferred {
            for port in preferred...min(preferred + 100, 65_535) where canBind(port) {
                return port
            }
        }
        return randomAvailablePort()
    }

    private static func canBind(_ port: Int) -> Bool {
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
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private static func randomAvailablePort() -> Int? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
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
        guard didBind else { return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let didRead = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length) == 0
            }
        }
        return didRead ? Int(in_port_t(bigEndian: address.sin_port)) : nil
    }
}
#endif
