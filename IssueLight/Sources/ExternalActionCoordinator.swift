import AppKit
import Combine
import Darwin
import Foundation
import IssueLightCore

struct IssueWebTarget: Equatable {
    let sourceID: UUID
    let url: URL
    let automaticSSHTunnel: SSHTunnelConfiguration?
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
        }
    ) {
        self.openURL = openURL
        self.canConnect = canConnect
        tunnelManager = SSHTunnelManager()
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
            tunnelManager.stop(sourceID: target.sourceID)
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
                tunnelManager.stop(sourceID: target.sourceID)
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
                "-p", String(configuration.port),
            ]
            if let identityFilePath = configuration.identityFilePath,
               !identityFilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                values.append(contentsOf: ["-i", identityFilePath, "-o", "IdentitiesOnly=yes"])
            }
            values.append(contentsOf: ["-l", configuration.username, "--", configuration.bastionHost])
            arguments = values
        }
    }

    private struct ActiveTunnel {
        let process: Process
        let localPort: Int
        let targetHost: String
        let targetPort: Int
        let configuration: SSHTunnelConfiguration
    }

    private var activeTunnels: [UUID: ActiveTunnel] = [:]
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
        if let active = activeTunnels[sourceID],
           active.process.isRunning,
           active.targetHost == targetHost,
           active.targetPort == targetPort,
           active.configuration == configuration {
            return await awaitReadiness(sourceID: sourceID, active: active)
        }

        stop(sourceID: sourceID)
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
        activeTunnels[sourceID] = active
        return await awaitReadiness(sourceID: sourceID, active: active, standardError: standardError)
    }

    func reconcileSources(_ sources: [MonitoringSource]) {
        let sourceByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        for (sourceID, active) in Array(activeTunnels) {
            guard let source = sourceByID[sourceID],
                  source.isEnabled,
                  let web = source.web,
                  web.baseURL.scheme?.lowercased() == "http",
                  let tunnel = web.automaticSSHTunnel else {
                stop(sourceID: sourceID)
                continue
            }
            let targetPort = web.baseURL.port ?? (web.baseURL.scheme?.lowercased() == "https" ? 443 : 80)
            if web.baseURL.host != active.targetHost
                || targetPort != active.targetPort
                || tunnel != active.configuration {
                stop(sourceID: sourceID)
            }
        }
    }

    func stopAll() {
        for sourceID in Array(activeTunnels.keys) {
            stop(sourceID: sourceID)
        }
    }

    func stop(sourceID: UUID) {
        guard let active = activeTunnels.removeValue(forKey: sourceID) else { return }
        if active.process.isRunning {
            active.process.terminate()
        }
    }

    private func awaitReadiness(
        sourceID: UUID,
        active: ActiveTunnel,
        standardError: Pipe? = nil
    ) async -> Result<Int, StartError> {
        for _ in 0..<50 {
            guard activeTunnels[sourceID]?.process === active.process else {
                return .failure(.message("SSH tunnel was replaced before it became ready."))
            }
            if !active.process.isRunning {
                activeTunnels.removeValue(forKey: sourceID)
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

        if activeTunnels[sourceID]?.process === active.process {
            stop(sourceID: sourceID)
        }
        return .failure(.message("SSH did not open the local port within five seconds."))
    }
}

enum TCPReachabilityProbe {
    static func canConnect(host: String, port: Int, timeout: Int = 2) async -> Bool {
        guard !host.isEmpty, (1...65_535).contains(port) else { return false }
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
            process.arguments = ["-z", "-G", String(timeout), host, String(port)]
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
