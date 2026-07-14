import Sparkle

/// Wraps Sparkle's `SPUUpdater` to drive and reflect automatic update checks.
@MainActor
@Observable
class SoftwareUpdater {
  /// Whether Maccy should check for updates automatically; mirrored to the
  /// underlying `SPUUpdater` and kept in sync with its KVO notifications.
  var automaticallyChecksForUpdates = false {
    didSet {
      if automaticallyChecksForUpdates {
        startUpdaterIfNeeded()
      }
      updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
    }
  }

  private var updater: SPUUpdater
  private var automaticallyChecksForUpdatesObservation: NSKeyValueObservation?
  private let updaterController: SPUStandardUpdaterController
  private let startUpdater: @MainActor () -> Void
  private let performUpdateCheck: @MainActor () -> Void
  private var hasStartedUpdater = false

  /// Creates a stopped updater and observes `SPUUpdater.automaticallyChecksForUpdates`
  /// so external changes propagate into the binding and opt-in starts it on demand.
  init(
    updaterController: SPUStandardUpdaterController = SPUStandardUpdaterController(
      startingUpdater: false,
      updaterDelegate: nil,
      userDriverDelegate: nil
    ),
    startUpdater: (@MainActor () -> Void)? = nil,
    performUpdateCheck: (@MainActor () -> Void)? = nil
  ) {
    self.updaterController = updaterController
    self.startUpdater = startUpdater ?? { updaterController.startUpdater() }
    self.performUpdateCheck = performUpdateCheck ?? { updaterController.updater.checkForUpdates() }
    updater = updaterController.updater
    automaticallyChecksForUpdatesObservation = updater.observe(
      \.automaticallyChecksForUpdates,
      options: [.initial, .new, .old]
    ) { [weak self] updater, change in
      guard change.newValue != change.oldValue else {
        return
      }

      // KVO fires on the registering thread (main, since init runs on main and
      // SPUUpdater is main-affine). Re-enter the main actor via a synchronous
      // assertion (no async hop) so the @Sendable closure can mutate `self`
      // without capturing a non-Sendable `self` across actors.
      let newValue = updater.automaticallyChecksForUpdates
      MainActor.assumeIsolated {
        self?.automaticallyChecksForUpdates = newValue
      }
    }
  }

  /// Prompts Sparkle to check for updates immediately.
  func checkForUpdates() {
    startUpdaterIfNeeded()
    performUpdateCheck()
  }

  private func startUpdaterIfNeeded() {
    guard !hasStartedUpdater else { return }
    hasStartedUpdater = true
    startUpdater()
  }
}
