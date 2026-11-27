import AppKit
import Sparkle

/// Automatic updates through Sparkle. The feed (SUFeedURL) and the EdDSA public key (SUPublicEDKey) are in
/// Info.plist (see build.sh); updates are only installed if signed with the matching private key.
/// Automatic checks are on by default (SUEnableAutomaticChecks), once a day; the user can turn them off in Settings.
final class Updates: NSObject, SPUStandardUserDriverDelegate {
    static let shared = Updates()
    private var controller: SPUStandardUpdaterController?

    /// Starts the updater. Only for a normal launch of a bundled app with a feed: never in test or CLI modes.
    func start() {
        guard controller == nil, Settings.shared.persist,
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        log("updates: automatic checks \(automaticallyChecks ? "on" : "off")")
    }

    var isAvailable: Bool { controller != nil }

    @objc func checkForUpdates(_ sender: Any?) {
        guard let controller else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(sender)
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    // A menu-bar app has no Dock icon to badge: let Sparkle show a found update itself, in front.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if handleShowingUpdate { NSApp.activate(ignoringOtherApps: true) }
    }
}
