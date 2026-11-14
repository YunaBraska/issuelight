import Foundation
import Security

public enum ProviderCredential: @unchecked Sendable {
    case password(String)
    case clientIdentity(SecIdentity)
}

public struct ProviderAccess: @unchecked Sendable {
    public let credential: ProviderCredential
    public let trustedServerCertificate: SecCertificate?

    public init(
        credential: ProviderCredential,
        trustedServerCertificate: SecCertificate? = nil
    ) {
        self.credential = credential
        self.trustedServerCertificate = trustedServerCertificate
    }
}

public struct ProviderCapabilities: Equatable, Sendable {
    public let authenticationMethods: Set<AuthenticationMethod>
    public let serverTrustMethods: Set<ServerTrustMethod>
    public let actions: Set<MonitoringActionKind>

    public init(
        authenticationMethods: Set<AuthenticationMethod>,
        serverTrustMethods: Set<ServerTrustMethod>,
        actions: Set<MonitoringActionKind> = []
    ) {
        self.authenticationMethods = authenticationMethods
        self.serverTrustMethods = serverTrustMethods
        self.actions = actions
    }
}

public enum MonitoringActionKind: String, Hashable, Sendable {
    case recheck
    case acknowledge
    case scheduleDowntime
}

public enum MonitoringAction: Equatable, Sendable {
    case recheck
    case acknowledge(author: String, comment: String)
    case scheduleDowntime(author: String, comment: String, start: Date, end: Date)

    public var kind: MonitoringActionKind {
        switch self {
        case .recheck:
            return .recheck
        case .acknowledge:
            return .acknowledge
        case .scheduleDowntime:
            return .scheduleDowntime
        }
    }
}

public enum MonitoringActionResult: Equatable, Sendable {
    case completed
    case rejected(String)
    case failed(ConnectionFailure)
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
    func testConnection(
        to source: MonitoringSource,
        access: ProviderAccess
    ) async -> ConnectionTestResult
    func loadSnapshot(
        from source: MonitoringSource,
        access: ProviderAccess
    ) async -> SnapshotLoadResult
    func perform(
        _ action: MonitoringAction,
        on issue: MonitoringIssue,
        from source: MonitoringSource,
        access: ProviderAccess
    ) async -> MonitoringActionResult
    func webURL(for issue: MonitoringIssue, from source: MonitoringSource) -> URL?
}

public extension MonitoringProvider {
    func webURL(for issue: MonitoringIssue, from source: MonitoringSource) -> URL? {
        nil
    }

    func perform(
        _ action: MonitoringAction,
        on issue: MonitoringIssue,
        from source: MonitoringSource,
        access: ProviderAccess
    ) async -> MonitoringActionResult {
        .rejected("This provider does not support the requested action.")
    }
}

public enum ProviderRegistryError: Error, Equatable {
    case duplicateProvider(ProviderID)
}

public struct ProviderRegistry: Sendable {
    private let providers: [ProviderID: any MonitoringProvider]

    private init(indexedProviders: [ProviderID: any MonitoringProvider]) {
        providers = indexedProviders
    }

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
        let provider = Icinga2Provider()
        return ProviderRegistry(indexedProviders: [provider.descriptor.id: provider])
    }
}
