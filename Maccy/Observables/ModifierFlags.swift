import AppKit.NSEvent

/// Observable wrapper around the live modifier-flag state, updated via a local
/// `flagsChanged` event monitor.
@MainActor
@Observable
final class ModifierFlags {
  /// The current device-independent modifier flags.
  var flags: NSEvent.ModifierFlags = []
  private var monitor: Any?

  /// Installs a local `flagsChanged` monitor that keeps `flags` in sync.
  init() {
    monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      // AppKit delivers local monitors on the main event loop. Express the
      // synchronous executor fact before mutating main-isolated observable
      // state instead of leaving the class implicitly nonisolated.
      MainActor.assumeIsolated {
        self?.flags = flags
      }
      return event
    }
  }

  /// Removes the event monitor.
  deinit {
    removeEventMonitor()
  }

  /// The SwiftUI-owned instance is created and released on main. `deinit`
  /// itself is nonisolated, so assert that lifetime invariant synchronously
  /// before touching the AppKit monitor token.
  nonisolated private func removeEventMonitor() {
    MainActor.assumeIsolated {
      if let monitor {
        NSEvent.removeMonitor(monitor)
      }
    }
  }
}
