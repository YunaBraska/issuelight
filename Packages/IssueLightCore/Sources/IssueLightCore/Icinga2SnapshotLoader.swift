import Foundation
import Security

public enum SnapshotLoadResult: Equatable, Sendable {
    case loaded(MonitoringSnapshot)
    case failed(ConnectionFailure)
}

public final class Icinga2SnapshotLoader: @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let now: @Sendable () -> Date

    public init(
        configuration: URLSessionConfiguration = .ephemeral,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.now = now
    }

    public func load(
        _ source: MonitoringSource,
        password: String?,
        trustedServerCertificate: SecCertificate? = nil
    ) async -> SnapshotLoadResult {
        do {
            return await load(
                source,
                transport: try Icinga2Transport.basic(
                    source: source,
                    password: password,
                    trustedServerCertificate: trustedServerCertificate,
                    configuration: configuration
                )
            )
        } catch let Icinga2TransportError.failure(failure) {
            return .failed(failure)
        } catch {
            return .failed(.unreachable)
        }
    }

    public func load(
        _ source: MonitoringSource,
        clientIdentity: SecIdentity?,
        trustedServerCertificate: SecCertificate? = nil
    ) async -> SnapshotLoadResult {
        do {
            return await load(
                source,
                transport: try Icinga2Transport.clientIdentity(
                    source: source,
                    identity: clientIdentity,
                    trustedServerCertificate: trustedServerCertificate,
                    configuration: configuration
                )
            )
        } catch let Icinga2TransportError.failure(failure) {
            return .failed(failure)
        } catch {
            return .failed(.unreachable)
        }
    }

    private func load(_ source: MonitoringSource, transport: Icinga2Transport) async -> SnapshotLoadResult {
        defer { transport.close() }
        do {
            async let hostData = transport.data(
                for: try transport.request(
                    objectType: "hosts",
                    attributes: Self.hostAttributes,
                    filter: "host.state!=0"
                )
            )
            async let serviceData = transport.data(
                for: try transport.request(
                    objectType: "services",
                    attributes: Self.serviceAttributes,
                    filter: "service.state!=0"
                )
            )
            return .loaded(
                try await Icinga2SnapshotDecoder().decode(
                    sourceID: source.id,
                    observedAt: now(),
                    hostData: hostData,
                    serviceData: serviceData
                )
            )
        } catch let Icinga2TransportError.failure(failure) {
            return .failed(failure)
        } catch is CancellationError {
            return .failed(.cancelled)
        } catch {
            return .failed(.incompatibleResponse)
        }
    }

    private static let hostAttributes = [
        "acknowledgement",
        "display_name",
        "downtime_depth",
        "last_check_result",
        "name",
        "state",
    ]

    private static let serviceAttributes = hostAttributes + ["host_name"]
}
