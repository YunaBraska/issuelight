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
    public init() {}

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

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess, errSecDuplicateItem:
            break
        default:
            throw KeychainServerCertificateCatalogError.unexpectedStatus(addStatus)
        }

        let reference = try persistentReference(for: certificate)
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
