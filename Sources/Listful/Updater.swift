import Foundation
import Sparkle

/// Sparkle's updater, for Check for Updates and the Settings toggle. The feed
/// URL and signing key come from Info.plist, so this only exists for the
/// packaged app: under `swift run` there's no bundle and `isAvailable` is false.
@MainActor @Observable final class Updater {
    private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    /// False while a check is already in progress (Sparkle's own rule).
    private(set) var canCheckForUpdates = false

    var automaticallyChecks: Bool {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    var isAvailable: Bool { controller != nil }

    init() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            controller = nil
            automaticallyChecks = false
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] updater, _ in
            // Sparkle changes this on the main thread.
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
