enum AppDistribution {
#if ISSUELIGHT_APP_STORE
    static let supportsSSHTunnels = false
    static let supportsRemoteAccess = false
    static let usesAppStoreUpdates = true
#else
    static let supportsSSHTunnels = true
    static let supportsRemoteAccess = true
    static let usesAppStoreUpdates = false
#endif
}
