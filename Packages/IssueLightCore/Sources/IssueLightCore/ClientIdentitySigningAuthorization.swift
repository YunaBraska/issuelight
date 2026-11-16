import Foundation
import Security

enum ClientIdentitySigningAuthorization {
    private static let interactionLock = NSLock()

    static func requireNonInteractiveAccess(to identity: SecIdentity) throws {
        interactionLock.lock()
        defer { interactionLock.unlock() }

        // LAContext blocks modern access-control prompts but does not suppress
        // legacy Keychain ACL dialogs. Keep this deprecated process-wide switch
        // disabled only around the synchronous signing probe.
        var previousInteractionState: DarwinBoolean = true
        let stateStatus = SecKeychainGetUserInteractionAllowed(&previousInteractionState)
        guard stateStatus == errSecSuccess else {
            throw KeychainIdentityCatalogError.unexpectedStatus(stateStatus)
        }

        let disableStatus = SecKeychainSetUserInteractionAllowed(false)
        guard disableStatus == errSecSuccess else {
            throw KeychainIdentityCatalogError.unexpectedStatus(disableStatus)
        }

        let accessResult = Result<Void, Error> {
            var privateKey: SecKey?
            let privateKeyStatus = SecIdentityCopyPrivateKey(identity, &privateKey)
            if privateKeyStatus != errSecSuccess {
                switch privateKeyStatus {
                case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
                    throw KeychainIdentityCatalogError.interactionNotAllowed
                default:
                    throw KeychainIdentityCatalogError.unexpectedStatus(privateKeyStatus)
                }
            }
            guard let privateKey else {
                throw KeychainIdentityCatalogError.malformedKeychainResult
            }

            let algorithms: [SecKeyAlgorithm] = [
                .rsaSignatureMessagePKCS1v15SHA256,
                .ecdsaSignatureMessageX962SHA256,
            ]
            guard let algorithm = algorithms.first(where: {
                SecKeyIsAlgorithmSupported(privateKey, .sign, $0)
            }) else {
                throw KeychainIdentityCatalogError.unexpectedStatus(errSecUnimplemented)
            }

            var signingError: Unmanaged<CFError>?
            let signature = SecKeyCreateSignature(
                privateKey,
                algorithm,
                Data("IssueLight client identity access check".utf8) as CFData,
                &signingError
            )
            guard signature != nil else {
                let status = signingError
                    .map { OSStatus(CFErrorGetCode($0.takeRetainedValue())) }
                    ?? errSecAuthFailed
                switch status {
                case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
                    throw KeychainIdentityCatalogError.interactionNotAllowed
                default:
                    throw KeychainIdentityCatalogError.unexpectedStatus(status)
                }
            }
        }

        let restoreStatus = SecKeychainSetUserInteractionAllowed(previousInteractionState.boolValue)
        guard restoreStatus == errSecSuccess else {
            throw KeychainIdentityCatalogError.unexpectedStatus(restoreStatus)
        }
        try accessResult.get()
    }
}
