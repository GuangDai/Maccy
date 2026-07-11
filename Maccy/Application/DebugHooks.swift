#if DEBUG
import Defaults
import Foundation
import Sparkle

/// DEBUG-only UI-test and performance notification bridge.
@MainActor
final class DebugHooks {
  /// Distributed-notification names driven by UI tests (test process → app).
  private enum UITestNotification {
    static let hotKeyDown = Notification.Name("org.p0deje.Maccy.UITest.hotKeyDown")
    static let modifiersReleased = Notification.Name("org.p0deje.Maccy.UITest.modifiersReleased")
    static let clearHistory = Notification.Name("org.p0deje.Maccy.UITest.clearHistory")
    static let clearAllHistory = Notification.Name("org.p0deje.Maccy.UITest.clearAllHistory")
    static let pinHistoryItem = Notification.Name("org.p0deje.Maccy.UITest.pinHistoryItem")
  }

  /// Distributed-notification names driving the performance benchmarks (see
  /// `PerfRecorder`). Posted by the UI test process; observed here only when
  /// launched with `MaccyPerfRecord`.
  private enum PerfNotification {
    static let reset = Notification.Name("org.p0deje.Maccy.Perf.reset")
    static let dump = Notification.Name("org.p0deje.Maccy.Perf.dump")
    static let openPreview = Notification.Name("org.p0deje.Maccy.Perf.openPreview")
    static let bulkLoad = Notification.Name("org.p0deje.Maccy.Perf.bulkLoad")
  }

  private var uiTestNotificationObservers: [Any] = []
  private var perfNotificationObservers: [Any] = []

  /// Applies DEBUG-only configuration that must precede application wiring.
  func prepareForLaunch() {
    if CommandLine.arguments.contains("enable-testing") {
      SPUUpdater(hostBundle: Bundle.main,
                 applicationBundle: Bundle.main,
                 userDriver: SPUStandardUserDriver(hostBundle: Bundle.main, delegate: nil),
                 delegate: nil)
      .automaticallyChecksForUpdates = false
    }
  }

  /// Installs the notification bridges selected by the process arguments.
  func install() {
    if CommandLine.arguments.contains("enable-testing") {
      Defaults[.suppressClearAlert] = true
      installUITestNotificationHooks()
    }
    if CommandLine.arguments.contains("MaccyPerfRecord") {
      installPerfNotificationHooks()
    }
  }

  /// Removes observers and emits the performance fallback dump on termination.
  func applicationWillTerminate() {
    removeUITestNotificationHooks()
    if CommandLine.arguments.contains("MaccyPerfRecord") {
      // Fallback dump so a forgotten `MaccyPerfDump` still lands the recorded
      // events. Safe no-op when nothing was recorded or the log path is unset.
      MainActor.assumeIsolated {
        PerfRecorder.shared.dump(category: "terminate")
      }
      removePerfNotificationHooks()
    }
  }

  /// Registers the distributed-notification observers that drive UI tests.
  private func installUITestNotificationHooks() {
    guard uiTestNotificationObservers.isEmpty else {
      return
    }

    let center = DistributedNotificationCenter.default()
    uiTestNotificationObservers.append(
      center.addObserver(forName: UITestNotification.hotKeyDown, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated {
          AppState.shared.popup.handleTestingHotKeyDown()
        }
      }
    )
    uiTestNotificationObservers.append(
      center.addObserver(forName: UITestNotification.modifiersReleased, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated {
          AppState.shared.popup.handleTestingModifiersReleased()
        }
      }
    )
    uiTestNotificationObservers.append(
      center.addObserver(forName: UITestNotification.clearHistory, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated {
          AppState.shared.history.clear()
        }
      }
    )
    uiTestNotificationObservers.append(
      center.addObserver(forName: UITestNotification.clearAllHistory, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated {
          AppState.shared.history.clearAll()
        }
      }
    )
    uiTestNotificationObservers.append(
      center.addObserver(forName: UITestNotification.pinHistoryItem, object: nil, queue: .main) { notification in
        // Extract Sendable values BEFORE the @MainActor block so the non-Sendable
        // `notification` is not sent across isolation. The observer fires on
        // .main; assumeIsolated is a synchronous no-op assertion.
        let title = notification.userInfo?["title"] as? String
        MainActor.assumeIsolated {
          guard let title else {
            return
          }

          let item = AppState.shared.history.all.first { $0.title == title }
          AppState.shared.history.togglePin(item)
        }
      }
    )
  }

  private func removeUITestNotificationHooks() {
    let center = DistributedNotificationCenter.default()
    uiTestNotificationObservers.forEach { center.removeObserver($0) }
    uiTestNotificationObservers = []
  }

  /// Registers the perf-benchmark notification observers (only when launched
  /// with `MaccyPerfRecord`). Mirrors `installUITestNotificationHooks`: the UI
  /// test drives the benchmarks over the distributed-notification bridge.
  private func installPerfNotificationHooks() {
    guard perfNotificationObservers.isEmpty else {
      return
    }

    let center = DistributedNotificationCenter.default()
    perfNotificationObservers.append(
      center.addObserver(forName: PerfNotification.reset, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated {
          PerfRecorder.shared.reset()
        }
      }
    )
    perfNotificationObservers.append(
      center.addObserver(forName: PerfNotification.dump, object: nil, queue: .main) { notification in
        let category = notification.userInfo?["category"] as? String ?? "unknown"
        MainActor.assumeIsolated {
          PerfRecorder.shared.dump(category: category)
        }
      }
    )
    perfNotificationObservers.append(
      center.addObserver(forName: PerfNotification.openPreview, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated {
          // Opens the preview pane deterministically (avoids the flaky
          // control+space keyboard toggle on the headless runner). Lead item is
          // already selected on popup open, so `togglePreview` will open.
          AppState.shared.preview.togglePreview()
        }
      }
    )
    perfNotificationObservers.append(
      center.addObserver(forName: PerfNotification.bulkLoad, object: nil, queue: .main) { notification in
        let count = notification.userInfo?["count"] as? Int ?? 0
        let category = notification.userInfo?["category"] as? String ?? "image"
        MainActor.assumeIsolated {
          PerfFixtures.populate(count: count, category: category)
        }
      }
    )
  }

  /// Removes the perf-benchmark notification observers.
  private func removePerfNotificationHooks() {
    let center = DistributedNotificationCenter.default()
    perfNotificationObservers.forEach { center.removeObserver($0) }
    perfNotificationObservers = []
  }
}
#endif
