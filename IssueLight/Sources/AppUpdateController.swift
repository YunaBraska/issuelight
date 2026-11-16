import Foundation

#if canImport(Sparkle) && !ISSUELIGHT_APP_STORE
import Sparkle
#endif

@MainActor
final class AppUpdateController {
#if canImport(Sparkle) && !ISSUELIGHT_APP_STORE
    private let controller: SPUStandardUpdaterController?

    var canCheckForUpdates: Bool {
        controller != nil
    }

    init(bundle: Bundle = .main) {
        guard let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !publicKey.isEmpty,
              let feedValue = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let feedURL = URL(string: feedValue),
              feedURL.scheme == "https" else {
            controller = nil
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.automaticallyDownloadsUpdates = false
        controller.startUpdater()
        self.controller = controller
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
#else
    init(bundle _: Bundle = .main) {}

    var canCheckForUpdates: Bool { false }

    func checkForUpdates() {}
#endif
}
