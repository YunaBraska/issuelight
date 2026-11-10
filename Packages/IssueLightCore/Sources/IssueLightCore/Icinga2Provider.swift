import Foundation

public struct Icinga2Provider: MonitoringProvider {
    public static let id = ProviderID(rawValue: "icinga2")

    public let descriptor = ProviderDescriptor(
        id: Icinga2Provider.id,
        displayName: "Icinga 2",
        capabilities: ProviderCapabilities(
            authenticationMethods: [.basic, .clientCertificate],
            serverTrustMethods: [.system, .disabled],
            supportsAcknowledgement: false,
            supportsDowntime: false
        )
    )

    public init() {}

    public func validate(_ source: MonitoringSource) -> [SourceValidationIssue] {
        var issues = MonitoringSourceValidator.validateSharedFields(source)
        let components = URLComponents(url: source.endpoint, resolvingAgainstBaseURL: false)

        if components?.scheme?.lowercased() != "https",
           !issues.contains(where: { issue in
               if case .unsupportedScheme = issue { return true }
               return false
           }) {
            issues.append(.unsupportedScheme(components?.scheme?.lowercased()))
        }

        if !descriptor.capabilities.authenticationMethods.contains(source.authentication.method) {
            issues.append(.unsupportedAuthentication(source.authentication.method))
        }

        let path = components?.percentEncodedPath ?? ""
        if !["", "/", "/v1", "/v1/"].contains(path) {
            issues.append(.unsupportedPath(path))
        }

        return issues
    }

    public func statusURL(for source: MonitoringSource) throws -> URL {
        let issues = validate(source)
        guard issues.isEmpty else {
            throw Icinga2ProviderError.invalidSource(issues)
        }

        var components = URLComponents(url: source.endpoint, resolvingAgainstBaseURL: false)!
        components.path = "/v1/status"
        components.query = nil
        components.fragment = nil
        return components.url!
    }
}

public enum Icinga2ProviderError: Error, Equatable {
    case invalidSource([SourceValidationIssue])
}
