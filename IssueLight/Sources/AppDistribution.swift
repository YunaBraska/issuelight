enum AppDistribution {
#if ISSUELIGHT_APP_STORE
    static let supportsSSHTunnels = false
    static let supportsRemoteAccess = false
#else
    static let supportsSSHTunnels = true
    static let supportsRemoteAccess = true
#endif
}
