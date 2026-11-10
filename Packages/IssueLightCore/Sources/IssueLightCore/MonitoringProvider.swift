import Foundation

public struct ProviderCapabilities: Equatable, Sendable {
    public let authenticationMethods: Set<AuthenticationMethod>
    public let serverTrustMethods: Set<ServerTrustMethod>
    public let supportsAcknowledgement: Bool
    public let supportsDowntime: Bool

    public init(
        authenticationMethods: Set<AuthenticationMethod>,
        serverTrustMethods: Set<ServerTrustMethod>,
        supportsAcknowledgement: Bool,
        supportsDowntime: Bool
    ) {
        self.authenticationMethods = authenticationMethods
        self.serverTrustMethods = serverTrustMethods
        self.supportsAcknowledgement = supportsAcknowledgement
        self.supportsDowntime = supportsDowntime
    }
}

public struct ProviderDescriptor: Equatable, Sendable {
    public let id: ProviderID
    public let displayName: String
    public let capabilities: ProviderCapabilities

    public init(id: ProviderID, displayName: String, capabilities: ProviderCapabilities) {
        self.id = id
        self.displayName = displayName
        self.capabilities = capabilities
    }
}

public protocol MonitoringProvider: Sendable {
    var descriptor: ProviderDescriptor { get }
    func validate(_ source: MonitoringSource) -> [SourceValidationIssue]
}

public enum ProviderRegistryError: Error, Equatable {
    case duplicateProvider(ProviderID)
}

public struct ProviderRegistry: Sendable {
    private let providers: [ProviderID: any MonitoringProvider]

    public init(_ providers: [any MonitoringProvider]) throws {
        var indexed: [ProviderID: any MonitoringProvider] = [:]
        for provider in providers {
            let id = provider.descriptor.id
            guard indexed[id] == nil else {
                throw ProviderRegistryError.duplicateProvider(id)
            }
            indexed[id] = provider
        }
        self.providers = indexed
    }

    public func provider(for id: ProviderID) -> (any MonitoringProvider)? {
        providers[id]
    }

    public var descriptors: [ProviderDescriptor] {
        providers.values
            .map(\.descriptor)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public static func builtIn() -> ProviderRegistry {
        try! ProviderRegistry([Icinga2Provider()])
    }
}
