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
        let includePending = source.issueFilter?.showPendingChecks == true
        let hostFilter = includePending ? "host.state!=0||host.last_check<=0" : "host.state!=0"
        let serviceFilter = includePending ? "service.state!=0||service.last_check<=0" : "service.state!=0"
        do {
            async let hostData = transport.data(
                for: try transport.request(
                    objectType: "hosts",
                    attributes: Self.hostAttributes,
                    filter: hostFilter
                )
            )
            async let serviceData = transport.data(
                for: try transport.request(
                    objectType: "services",
                    attributes: Self.serviceAttributes,
                    filter: serviceFilter,
                    joins: ["host.downtime_depth"]
                )
            )
            return .loaded(
                try await Icinga2SnapshotDecoder().decode(
                    sourceID: source.id,
                    observedAt: now(),
                    hostData: hostData,
                    serviceData: serviceData,
                    includePending: includePending
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

    private static let commonAttributes = [
        "acknowledgement",
        "check_attempt",
        "display_name",
        "downtime_depth",
        "enable_notifications",
        "flapping",
        "last_check",
        "last_check_result",
        "last_state_change",
        "max_check_attempts",
        "name",
        "state",
        "state_type",
    ]

    private static let hostAttributes = commonAttributes + ["last_reachable"]
    private static let serviceAttributes = commonAttributes + ["host_name"]
}
