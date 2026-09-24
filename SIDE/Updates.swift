import AppKit
import Sparkle

/// Side's updater (docs/SIDE_DISTRIBUTION.md, D1): Sparkle 2, reading a signed appcast from the
/// public releases repository. An update is verified against the EdDSA key in Info.plist and the
/// Developer ID signature before it installs.
@MainActor
final class Updates {
    static let shared = Updates()

    /// Debug builds and test runs don't check: they'd offer the released app over the one being
    /// worked on.
    let controller: SPUStandardUpdaterController

    private init() {
        #if DEBUG
        let starts = false
        #else
        let starts = !AppDelegate.isUITesting
        #endif
        controller = SPUStandardUpdaterController(startingUpdater: starts, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var updater: SPUUpdater { controller.updater }

    var checksAutomatically: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    var canCheck: Bool { updater.canCheckForUpdates }

    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }
}
