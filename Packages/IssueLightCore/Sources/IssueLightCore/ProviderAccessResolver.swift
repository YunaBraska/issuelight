import Foundation
import Security

public enum ProviderAccessFailure: Equatable, Sendable {
    case passwordNotAvailable
    case passwordAccessFailed
    case clientIdentityNotAvailable
    case clientIdentityAccessFailed
    case serverCertificateNotAvailable
    case serverCertificateAccessFailed
}

public enum ProviderAccessResolution: @unchecked Sendable {
    case resolved(ProviderAccess)
    case failed(ProviderAccessFailure)
}

public struct ProviderAccessResolver: Sendable {
    private let passwordVault: KeychainPasswordVault
    private let identityCatalog: KeychainIdentityCatalog
    private let certificateCatalog: KeychainServerCertificateCatalog

    public init(
        passwordVault: KeychainPasswordVault,
        identityCatalog: KeychainIdentityCatalog,
        certificateCatalog: KeychainServerCertificateCatalog
    ) {
        self.passwordVault = passwordVault
        self.identityCatalog = identityCatalog
        self.certificateCatalog = certificateCatalog
    }

    public func resolve(
        source: MonitoringSource,
        passwordOverride: String? = nil,
        allowsStoredPassword: Bool = true
    ) async -> ProviderAccessResolution {
        let trustedServerCertificate: SecCertificate?
        switch source.serverTrust {
        case .customCertificate(let certificateID):
            do {
                guard let certificate = try await certificateCatalog.certificate(id: certificateID) else {
                    return .failed(.serverCertificateNotAvailable)
                }
                trustedServerCertificate = certificate
            } catch {
                return .failed(.serverCertificateAccessFailed)
            }
        case .system, .pinnedCertificate, .disabled:
            trustedServerCertificate = nil
        }

        switch source.authentication {
        case .basic:
            let password: String
            if let passwordOverride, !passwordOverride.isEmpty {
                password = passwordOverride
            } else {
                guard allowsStoredPassword else {
                    return .failed(.passwordNotAvailable)
                }
                do {
                    guard let storedPassword = try await passwordVault.password(
                        for: BasicCredentialScope(source: source)
                    ) else {
                        return .failed(.passwordNotAvailable)
                    }
                    password = storedPassword
                } catch {
                    return .failed(.passwordAccessFailed)
                }
            }
            return .resolved(
                ProviderAccess(
                    credential: .password(password),
                    trustedServerCertificate: trustedServerCertificate
                )
            )
        case .clientCertificate(let identityID):
            do {
                guard let identity = try await identityCatalog.identity(id: identityID) else {
                    return .failed(.clientIdentityNotAvailable)
                }
                return .resolved(
                    ProviderAccess(
                        credential: .clientIdentity(identity),
                        trustedServerCertificate: trustedServerCertificate
                    )
                )
            } catch {
                return .failed(.clientIdentityAccessFailed)
            }
        }
    }
}
