import CryptoKit
import Foundation
import Security

public struct ServerCertificateDescriptor: Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let sha256Fingerprint: String

    public init(id: String, displayName: String, sha256Fingerprint: String) {
        self.id = id
        self.displayName = displayName
        self.sha256Fingerprint = sha256Fingerprint
    }
}

public enum KeychainServerCertificateCatalogError: Error, Equatable {
    case certificateFileTooLarge
    case invalidCertificate
    case invalidPersistentReference
    case malformedKeychainResult
    case multipleCertificatesNotSupported
    case unexpectedStatus(OSStatus)
}

public actor KeychainServerCertificateCatalog {
    private static let anyManagedLabelPrefix = "IssueLight CA ["
    private let managedLabelPrefix: String

    /// Creates a certificate catalog with cleanup ownership isolated to one app profile.
    ///
    /// Use a stable bundle or profile identifier. Catalogs with different scopes cannot
    /// delete each other's imported certificates.
    ///
    /// - Parameter ownershipScope: Stable identifier for the source store using this catalog.
    public init(ownershipScope: String = "io.github.yunabraska.issuelight") {
        let scopeFingerprint = SHA256.hash(data: Data(ownershipScope.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
        managedLabelPrefix = "IssueLight CA [\(scopeFingerprint)] — "
    }

    public func importCertificate(at fileURL: URL) throws -> ServerCertificateDescriptor {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize, fileSize > 1_048_576 {
            throw KeychainServerCertificateCatalogError.certificateFileTooLarge
        }
        let fileData = try Data(contentsOf: fileURL)
        guard fileData.count <= 1_048_576 else {
            throw KeychainServerCertificateCatalogError.certificateFileTooLarge
        }
        let certificateData = try Self.certificateData(from: fileData)
        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else {
            throw KeychainServerCertificateCatalogError.invalidCertificate
        }

        let ownershipFingerprint = SHA256.hash(data: certificateData)
            .map { String(format: "%02x", $0) }
            .joined()
        let certificateName = SecCertificateCopySubjectSummary(certificate) as String? ?? "Unbenannte CA"
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        let wasAdded: Bool
        switch addStatus {
        case errSecSuccess:
            wasAdded = true
        case errSecDuplicateItem:
            wasAdded = false
        default:
            throw KeychainServerCertificateCatalogError.unexpectedStatus(addStatus)
        }

        let reference: Data
        do {
            reference = try persistentReference(for: certificate)
        } catch {
            if wasAdded {
                _ = SecItemDelete(addQuery as CFDictionary)
            }
            throw error
        }
        let ownershipQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValuePersistentRef as String: reference,
        ]
        let expectedLabel = managedLabelPrefix + certificateName + " — " + ownershipFingerprint
        if wasAdded {
            let ownershipAttributes: [String: Any] = [
                kSecAttrLabel as String: expectedLabel,
            ]
            let updateStatus = SecItemUpdate(
                ownershipQuery as CFDictionary,
                ownershipAttributes as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                try? deleteCertificate(id: reference.base64EncodedString())
                throw KeychainServerCertificateCatalogError.unexpectedStatus(updateStatus)
            }
        } else {
            var existingResult: CFTypeRef?
            var existingQuery = ownershipQuery
            existingQuery[kSecReturnAttributes as String] = true
            existingQuery[kSecMatchLimit as String] = kSecMatchLimitOne
            let existingStatus = SecItemCopyMatching(existingQuery as CFDictionary, &existingResult)
            guard existingStatus == errSecSuccess else {
                throw KeychainServerCertificateCatalogError.unexpectedStatus(existingStatus)
            }
            guard let existingAttributes = existingResult as? [String: Any] else {
                throw KeychainServerCertificateCatalogError.malformedKeychainResult
            }
            if let existingLabel = existingAttributes[kSecAttrLabel as String] as? String,
               existingLabel.hasPrefix(Self.anyManagedLabelPrefix),
               existingLabel != expectedLabel {
                let sharedAttributes: [String: Any] = [
                    kSecAttrLabel as String: "IssueLight Shared CA — \(certificateName) — \(ownershipFingerprint)",
                ]
                let updateStatus = SecItemUpdate(
                    ownershipQuery as CFDictionary,
                    sharedAttributes as CFDictionary
                )
                guard updateStatus == errSecSuccess else {
                    throw KeychainServerCertificateCatalogError.unexpectedStatus(updateStatus)
                }
            }
        }
        return Self.descriptor(certificate: certificate, reference: reference)
    }

    public func certificate(id: String) throws -> SecCertificate? {
        guard let reference = Data(base64Encoded: id) else {
            throw KeychainServerCertificateCatalogError.invalidPersistentReference
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
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
            throw KeychainServerCertificateCatalogError.unexpectedStatus(status)
        }
        guard let result, CFGetTypeID(result) == SecCertificateGetTypeID() else {
            throw KeychainServerCertificateCatalogError.malformedKeychainResult
        }
        return unsafeBitCast(result, to: SecCertificate.self)
    }

    public func descriptor(id: String) throws -> ServerCertificateDescriptor? {
        guard let certificate = try certificate(id: id),
              let reference = Data(base64Encoded: id) else {
            return nil
        }
        return Self.descriptor(certificate: certificate, reference: reference)
    }

    public func deleteCertificate(id: String) throws {
        guard let reference = Data(base64Encoded: id) else {
            throw KeychainServerCertificateCatalogError.invalidPersistentReference
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValuePersistentRef as String: reference,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainServerCertificateCatalogError.unexpectedStatus(status)
        }
    }

    /// Deletes certificates created and marked by IssueLight when no source references them.
    ///
    /// Certificates that existed before import or have lost the IssueLight ownership marker
    /// remain untouched.
    ///
    /// - Parameter referencedCertificateIDs: Persistent Keychain references retained by sources.
    /// - Returns: Persistent references deleted during this cleanup pass.
    public func deleteUnreferencedManagedCertificates(
        referencedCertificateIDs: Set<String>
    ) throws -> Set<String> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw KeychainServerCertificateCatalogError.unexpectedStatus(status)
        }
        guard let items = result as? [[String: Any]] else {
            throw KeychainServerCertificateCatalogError.malformedKeychainResult
        }
        let managedReferences = items.compactMap { item -> Data? in
            guard let label = item[kSecAttrLabel as String] as? String,
                  label.hasPrefix(managedLabelPrefix),
                  let reference = item[kSecValuePersistentRef as String] as? Data else {
                return nil
            }
            return reference
        }
        var deletedIDs = Set<String>()
        for reference in managedReferences {
            let id = reference.base64EncodedString()
            guard !referencedCertificateIDs.contains(id) else { continue }
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassCertificate,
                kSecValuePersistentRef as String: reference,
            ]
            let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
            if deleteStatus == errSecSuccess {
                deletedIDs.insert(id)
            } else if deleteStatus != errSecItemNotFound {
                throw KeychainServerCertificateCatalogError.unexpectedStatus(deleteStatus)
            }
        }
        return deletedIDs
    }

    private func persistentReference(for certificate: SecCertificate) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw KeychainServerCertificateCatalogError.unexpectedStatus(status)
        }
        guard let reference = result as? Data else {
            throw KeychainServerCertificateCatalogError.malformedKeychainResult
        }
        return reference
    }

    private static func certificateData(from fileData: Data) throws -> Data {
        guard let text = String(data: fileData, encoding: .utf8),
              let begin = text.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = text.range(of: "-----END CERTIFICATE-----", range: begin.upperBound..<text.endIndex) else {
            return fileData
        }
        if text.range(of: "-----BEGIN CERTIFICATE-----", range: end.upperBound..<text.endIndex) != nil {
            throw KeychainServerCertificateCatalogError.multipleCertificatesNotSupported
        }
        let encoded = String(text[begin.upperBound..<end.lowerBound])
        guard let decoded = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            throw KeychainServerCertificateCatalogError.invalidCertificate
        }
        return decoded
    }

    private static func descriptor(
        certificate: SecCertificate,
        reference: Data
    ) -> ServerCertificateDescriptor {
        let certificateData = SecCertificateCopyData(certificate) as Data
        let fingerprint = SHA256.hash(data: certificateData)
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
        return ServerCertificateDescriptor(
            id: reference.base64EncodedString(),
            displayName: SecCertificateCopySubjectSummary(certificate) as String? ?? "Unbenannte CA",
            sha256Fingerprint: fingerprint
        )
    }
}
