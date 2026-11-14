import CryptoKit
import Foundation
import Security

public enum ServerCertificateFingerprintError: Error, Equatable {
    case certificateFileTooLarge
    case invalidCertificate
    case multipleCertificatesNotSupported
}

public enum ServerCertificateFingerprint {
    public static func sha256(at fileURL: URL) throws -> String {
        sha256(of: try certificate(at: fileURL))
    }

    public static func sha256(of certificate: SecCertificate) -> String {
        SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
    }

    public static func normalizedSHA256(_ value: String) -> String? {
        var hexadecimal = ""
        for byte in value.utf8 {
            switch byte {
            case 48...57, 65...70, 97...102:
                hexadecimal.append(Character(UnicodeScalar(byte)))
            case 9, 10, 13, 32, 45, 58:
                continue
            default:
                return nil
            }
        }
        guard hexadecimal.count == 64 else { return nil }
        let uppercase = hexadecimal.uppercased()
        return stride(from: 0, to: uppercase.count, by: 2)
            .map { offset in
                let start = uppercase.index(uppercase.startIndex, offsetBy: offset)
                let end = uppercase.index(start, offsetBy: 2)
                return String(uppercase[start..<end])
            }
            .joined(separator: ":")
    }

    static func certificate(at fileURL: URL) throws -> SecCertificate {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize, fileSize > 1_048_576 {
            throw ServerCertificateFingerprintError.certificateFileTooLarge
        }
        let fileData = try Data(contentsOf: fileURL)
        guard fileData.count <= 1_048_576 else {
            throw ServerCertificateFingerprintError.certificateFileTooLarge
        }

        let certificateData: Data
        if let text = String(data: fileData, encoding: .utf8),
           let begin = text.range(of: "-----BEGIN CERTIFICATE-----"),
           let end = text.range(
               of: "-----END CERTIFICATE-----",
               range: begin.upperBound..<text.endIndex
           ) {
            if text.range(
                of: "-----BEGIN CERTIFICATE-----",
                range: end.upperBound..<text.endIndex
            ) != nil {
                throw ServerCertificateFingerprintError.multipleCertificatesNotSupported
            }
            let encoded = String(text[begin.upperBound..<end.lowerBound])
            guard let decoded = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
                throw ServerCertificateFingerprintError.invalidCertificate
            }
            certificateData = decoded
        } else {
            certificateData = fileData
        }
        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else {
            throw ServerCertificateFingerprintError.invalidCertificate
        }
        return certificate
    }
}
