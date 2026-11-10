import Foundation
import Security

public struct ClientIdentityDescriptor: Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public enum KeychainIdentityCatalogError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case malformedKeychainResult
    case invalidPersistentReference
    case noIdentityInPKCS12
}

public actor KeychainIdentityCatalog {
    public init() {}

    public func identities() throws -> [ClientIdentityDescriptor] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw KeychainIdentityCatalogError.unexpectedStatus(status)
        }
        guard let identities = result as? [SecIdentity] else {
            throw KeychainIdentityCatalogError.malformedKeychainResult
        }

        return try identities.map { identity in
            ClientIdentityDescriptor(
                id: try persistentReference(for: identity).base64EncodedString(),
                displayName: displayName(for: identity)
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public func identity(id: String) throws -> SecIdentity? {
        guard let reference = Data(base64Encoded: id) else {
            throw KeychainIdentityCatalogError.invalidPersistentReference
        }
        let query: [String: Any] = [
            kSecValuePersistentRef as String: reference,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainIdentityCatalogError.unexpectedStatus(status)
        }
        guard let result, CFGetTypeID(result) == SecIdentityGetTypeID() else {
            throw KeychainIdentityCatalogError.malformedKeychainResult
        }
        let identity = unsafeBitCast(result, to: SecIdentity.self)
        return identity
    }

    public func importPKCS12(at fileURL: URL, password: String) throws -> ClientIdentityDescriptor {
        let data = try Data(contentsOf: fileURL)
        let options = [kSecImportExportPassphrase as String: password]
        var rawItems: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &rawItems)
        guard status == errSecSuccess else {
            throw KeychainIdentityCatalogError.unexpectedStatus(status)
        }
        guard let items = rawItems as? [[String: Any]],
              let identityValue = items.compactMap({ $0[kSecImportItemIdentity as String] }).first,
              CFGetTypeID(identityValue as CFTypeRef) == SecIdentityGetTypeID() else {
            throw KeychainIdentityCatalogError.noIdentityInPKCS12
        }
        let identity = unsafeBitCast(identityValue as CFTypeRef, to: SecIdentity.self)

        return ClientIdentityDescriptor(
            id: try persistentReference(for: identity).base64EncodedString(),
            displayName: displayName(for: identity)
        )
    }

    private func persistentReference(for identity: SecIdentity) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecValueRef as String: identity,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw KeychainIdentityCatalogError.unexpectedStatus(status)
        }
        guard let reference = result as? Data else {
            throw KeychainIdentityCatalogError.malformedKeychainResult
        }
        return reference
    }

    private func displayName(for identity: SecIdentity) -> String {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate,
              let summary = SecCertificateCopySubjectSummary(certificate) as String? else {
            return "Unbenanntes Zertifikat"
        }
        return summary
    }
}
