import Foundation
import Security

public enum ConnectionFailure: Error, Equatable, Sendable {
    case invalidConfiguration([SourceValidationIssue])
    case unsupportedTrustConfiguration
    case clientCertificateNotAvailable
    case cancelled
    case unreachable
    case tls
    case authentication
    case authorization
    case incompatibleResponse
    case server(statusCode: Int)
    case http(statusCode: Int)
}

public enum ConnectionTestResult: Equatable, Sendable {
    case connected
    case failed(ConnectionFailure)
}

public final class Icinga2ConnectionTester: @unchecked Sendable {
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    public func test(_ source: MonitoringSource, password: String?) async -> ConnectionTestResult {
        do {
            let transport = try Icinga2Transport.basic(
                source: source,
                password: password,
                configuration: configuration
            )
            return await test(source, transport: transport)
        } catch let Icinga2TransportError.failure(failure) {
            return .failed(failure)
        } catch {
            return .failed(.unreachable)
        }
    }

    public func test(_ source: MonitoringSource, clientIdentity: SecIdentity?) async -> ConnectionTestResult {
        do {
            let transport = try Icinga2Transport.clientIdentity(
                source: source,
                identity: clientIdentity,
                configuration: configuration
            )
            return await test(source, transport: transport)
        } catch let Icinga2TransportError.failure(failure) {
            return .failed(failure)
        } catch {
            return .failed(.unreachable)
        }
    }

    private func test(_ source: MonitoringSource, transport: Icinga2Transport) async -> ConnectionTestResult {
        defer { transport.close() }
        for objectType in ["hosts", "services"] {
            let request: URLRequest
            do {
                request = try transport.request(
                    objectType: objectType,
                    attributes: ["name"],
                    limit: 1
                )
            } catch let Icinga2TransportError.failure(failure) {
                return .failed(failure)
            } catch {
                return .failed(.incompatibleResponse)
            }

            do {
                let data = try await transport.data(for: request)
                guard responseContainsIcingaResults(data) else {
                    return .failed(.incompatibleResponse)
                }
            } catch let Icinga2TransportError.failure(failure) {
                return .failed(failure)
            } catch {
                return .failed(.unreachable)
            }
        }

        return .connected
    }

    private func responseContainsIcingaResults(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["results"] is [Any]
    }

}
