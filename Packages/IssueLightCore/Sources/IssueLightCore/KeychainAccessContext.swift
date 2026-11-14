import Security

/// Restricts Keychain test operations to one isolated macOS Keychain.
struct KeychainAccessContext: @unchecked Sendable {
    let keychain: SecKeychain

    init(keychain: SecKeychain) {
        self.keychain = keychain
    }

    func matching(_ query: [String: Any]) -> [String: Any] {
        var scopedQuery = query
        scopedQuery[kSecMatchSearchList as String] = [keychain]
        return scopedQuery
    }

    func adding(_ query: [String: Any]) -> [String: Any] {
        var scopedQuery = query
        scopedQuery[kSecUseKeychain as String] = keychain
        return scopedQuery
    }
}
