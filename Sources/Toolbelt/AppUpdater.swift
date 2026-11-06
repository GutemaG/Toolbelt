import AppKit
import Sparkle

/// Installs new versions with Sparkle. It reads appcast.xml from the latest
/// GitHub release, and only accepts an update signed with the key in Info.plist.
final class AppUpdater: NSObject, SPUStandardUserDriverDelegate {
    static let shared = AppUpdater()
    private var controller: SPUStandardUpdaterController!

    override private init() {
        super.init()
        // Test runs never check: they stay away from the network and the real app.
        // APP_TEST_UPDATES=1 is for trying an update between throwaway copies.
        let testsUpdates = Store.isOverridden && ProcessInfo.processInfo.environment["APP_TEST_UPDATES"] == "1"
        controller = SPUStandardUpdaterController(startingUpdater: !Store.isOverridden || testsUpdates, updaterDelegate: nil, userDriverDelegate: self)
        if testsUpdates { controller.updater.checkForUpdatesInBackground() }
    }

    var checksAutomatically: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkNow() {
        // A menu bar app isn't in front, and the update window would open behind other apps.
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    /// "0.3 (202611061730)"
    var versionText: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    // MARK: SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if handleShowingUpdate { NSApp.activate() }
    }
}
