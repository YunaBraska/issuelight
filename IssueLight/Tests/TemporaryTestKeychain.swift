import Foundation
import Security
import XCTest
@testable import IssueLightCore

final class TemporaryTestKeychain: @unchecked Sendable {
    let reference: SecKeychain
    let context: KeychainAccessContext
    let fileURL: URL

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issuelight-app-keychain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let createdFileURL = directory.appendingPathComponent("tests.keychain-db")
        let password = UUID().uuidString
        var createdKeychain: SecKeychain?
        let status = password.withCString { passwordPointer in
            SecKeychainCreate(
                createdFileURL.path,
                UInt32(password.utf8.count),
                passwordPointer,
                false,
                nil,
                &createdKeychain
            )
        }
        guard status == errSecSuccess, let createdKeychain else {
            try? FileManager.default.removeItem(at: directory)
            throw TemporaryTestKeychainError.unexpectedStatus(status)
        }
        fileURL = createdFileURL
        reference = createdKeychain
        context = KeychainAccessContext(keychain: createdKeychain)
    }

    func delete() throws {
        let status = SecKeychainDelete(reference)
        guard status == errSecSuccess || status == errSecNoSuchKeychain else {
            throw TemporaryTestKeychainError.unexpectedStatus(status)
        }
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }
}

private enum TemporaryTestKeychainError: Error {
    case unexpectedStatus(OSStatus)
}
