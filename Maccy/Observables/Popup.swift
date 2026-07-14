import AppKit.NSRunningApplication
import Defaults
import KeyboardShortcuts
import Observation

/// The popup's high-level behavior mode, driven by the hotkey press sequence.
enum PopupState {
  /// Default; the hotkey toggles the popup open/closed.
  case toggle
  /// Each additional press of the main key cycles to the next item; releasing
  /// the modifier keys accepts the selection and closes the popup.
  case cycle
  /// Transition state when the shortcut is first pressed and the mode
  /// (toggle vs cycle) is not yet determined.
  case opening
}

@MainActor
struct PopupRuntimeServices {
  let selectInitialItem: @MainActor () -> Void
  let openPanel: @MainActor (CGFloat, PopupPosition) -> Void
  let closePanel: @MainActor () -> Void
  let isPanelPresented: @MainActor () -> Bool
  let resizePanel: @MainActor (CGFloat) -> Void
  let prewarmVisibleWindow: @MainActor () -> Void
  let selectPressedShortcut: @MainActor () -> Bool
  let highlightNext: @MainActor () -> Void
  let commitSelection: @MainActor () -> Void

  static let inert = PopupRuntimeServices(
    selectInitialItem: {},
    openPanel: { _, _ in },
    closePanel: {},
    isPanelPresented: { false },
    resizePanel: { _ in },
    prewarmVisibleWindow: {},
    selectPressedShortcut: { false },
    highlightNext: {},
    commitSelection: {}
  )
}

/// Observable model for the popup window: geometry constants, the events
/// monitor, the toggle/cycle state machine, and the hotkey handlers.
@MainActor
@Observable
class Popup {
  static let verticalSeparatorPadding = 6.0
  static let horizontalSeparatorPadding = 6.0
  static let verticalPadding: CGFloat = 5
  static let horizontalPadding: CGFloat = 5

  static func previewMinimumHeight(maximumHeight: CGFloat, percent: Int) -> CGFloat {
    let clampedPercent = min(max(percent, 25), 100)
    return maximumHeight * CGFloat(clampedPercent) / 100
  }

  /// Radius for items inset by the padding, so they visually share the menu's curvature.
  static let cornerRadius: CGFloat = if #available(macOS 26.0, *) {
    7
  } else {
    4
  }

  /// Compact single-line row height (version-dependent).
  static var itemHeight: CGFloat { HistoryRowLayout.baseHeight }

  var needsResize = false
  var height: CGFloat = 0
  var headerHeight: CGFloat = 0
  var extraTopHeight: CGFloat = 0
  var extraBottomHeight: CGFloat = 0
  var footerHeight: CGFloat = 0

  // The `NSEvent` local-monitor token (opaque `Any`). Added on main in
  // `initEventsMonitor`, removed in `deinitEventsMonitor`. The token never leaves
  // the main actor (added/removed/fired on main), so it is a plain `@MainActor`
  // instance var — no lock, no `@unchecked`, no `nonisolated(unsafe)`. The
  // nonisolated deinit reaches it via `MainActor.assumeIsolated`, a synchronous
  // runtime assertion (not an async hop) — safe on macOS 14 (no SE-0371 hop).
  private var eventsMonitor: Any?

  private var state: PopupState = .toggle
  @ObservationIgnored private var runtimeServices: PopupRuntimeServices

  /// Registers the global `.popup` hotkey and the local events monitor.
  init(
    runtimeServices: PopupRuntimeServices = .inert,
    installsEventHandlers: Bool = true
  ) {
    self.runtimeServices = runtimeServices
    if installsEventHandlers {
      KeyboardShortcuts.onKeyDown(for: .popup, action: handleFirstKeyDown)
      initEventsMonitor()
    }
  }

  func configureRuntimeServices(_ runtimeServices: PopupRuntimeServices) {
    self.runtimeServices = runtimeServices
  }

  /// Removes the events monitor.
  deinit {
    deinitEventsMonitor()
  }

  /// Installs the local `flagsChanged`/`keyDown` monitor (no-op if installed).
  func initEventsMonitor() {
    guard eventsMonitor == nil else { return }
    eventsMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.flagsChanged, .keyDown]
    ) { [weak self] event in
      // Local NSEvent monitors fire on the main run loop, so this nonisolated
      // closure runs on main and MainActor.assumeIsolated is a runtime no-op
      // assertion. NSEvent is NOT Sendable, so it must not cross the isolation
      // boundary — extract Sendable properties (type / all-released Bool) on
      // this side, decide on main via assumeIsolated, and return nil/event
      // here without ever moving `event` across actors. No @unchecked, no
      // nonisolated(unsafe).
      switch event.type {
      case .flagsChanged:
        let allReleased = event.modifierFlags.isDisjoint(with: .deviceIndependentFlagsMask)
        let consume = MainActor.assumeIsolated {
          self?.shouldConsumeFlagsChanged(allReleased: allReleased) ?? false
        }
        return consume ? nil : event
      case .keyDown:
        // The global `.popup` Carbon hotkey consumes its keyDown, so in-popup
        // hotkey behavior is routed via `handleFirstKeyDown`; pass non-hotkey
        // keyDowns through unchanged.
        return event
      default:
        return event
      }
    }
  }

  /// Removes the events monitor from this nonisolated deinit.
  nonisolated func deinitEventsMonitor() {
    // `removeMonitor` is thread-safe (AppKit docs). The token is main-isolated;
    // reach it from this nonisolated deinit via `MainActor.assumeIsolated` — a
    // synchronous runtime assertion, NOT an async hop, so the macOS-14 "deinit
    // cannot actor-hop" restriction does not apply. The no-unsafe isolation
    // must be correct regardless of the instance's lifetime.
    MainActor.assumeIsolated {
      if let monitor = eventsMonitor {
        eventsMonitor = nil
        NSEvent.removeMonitor(monitor)
      }
    }
  }

  /// Selects the first item and opens the panel at `popupPosition`.
  func open(height: CGFloat, at popupPosition: PopupPosition = Defaults[.popupPosition]) {
    runtimeServices.selectInitialItem()
    runtimeServices.openPanel(height, popupPosition)
  }

  /// Returns the popup to its default toggle state on close.
  ///
  /// The global `.popup` hotkey is registered once in `init` and stays
  /// registered for the process lifetime; `enable(.popup)`/`disable(.popup)`
  /// are NOT toggled per open/close. That enable/disable cycle called
  /// `RegisterEventHotKey` with a new id each time, and the Carbon backing was
  /// not reclaimed by `UnregisterEventHotKey`, leaking per cycle. In-popup
  /// hotkey presses now route through the always-on global handler (the Carbon
  /// handler returns `noErr`, consuming the event so it never reaches the local
  /// monitor), preserving cycle/select/toggle-close behavior.
  func reset() {
    state = .toggle
  }

  /// Closes the panel (which calls `reset`).
  func close() {
    runtimeServices.closePanel()  // close() calls reset
  }

  /// Whether the panel is currently closed.
  func isClosed() -> Bool {
    !runtimeServices.isPanelPresented()
  }

  /// Floor-clamps to the configured minimum height and ceiling-clamps to the
  /// drag-persisted window height. The floor applies unconditionally — not only
  /// when the slideout preview is open — so popup height never depends on search
  /// or preview state (stability invariant for the resize-on-search fix).
  func preferredHeight(for newHeight: CGFloat) -> CGFloat {
    let maximumHeight = Defaults[.windowSize].height
    let minimumHeight = max(
      headerHeight + Self.verticalPadding,
      Self.previewMinimumHeight(
        maximumHeight: maximumHeight,
        percent: Defaults[.previewMinimumHeightPercent]
      )
    )
    return min(max(newHeight, minimumHeight), maximumHeight)
  }

  /// Resizes the panel to fit `height` (the measured scroll-content height),
  /// then floor/ceiling-clamps via `preferredHeight(for:)`. The ceiling is the
  /// drag-persisted `windowSize.height`, so long histories scroll instead of
  /// growing the window unbounded; the floor is `previewMinimumHeightPercent`.
  func resize(height: CGFloat) {
    self.height = height + headerHeight + extraTopHeight + extraBottomHeight + footerHeight
    runtimeServices.resizePanel(preferredHeight(for: self.height))
    needsResize = false
  }

  /// Global hotkey handler. Opens the popup on a closed state (after warming the
  /// history); otherwise routes the press to the in-popup cycle/select/toggle
  /// behavior.
  private func handleFirstKeyDown() {
    if isClosed() {
      // Warm the history before opening so the data is ready (or loading) when
      // the popup appears. No-op if already loaded.
      runtimeServices.prewarmVisibleWindow()
      open(height: height)
      state = .opening
      // The global hotkey stays registered (see `reset`): the Carbon handler
      // consumes the event (returns `noErr`), so while the popup is open the
      // hotkey press is dispatched here — not to the local monitor — and we
      // route it to `handleRepeatedHotKeyDown` for the same cycle/select/
      // toggle-close behavior the local monitor used to perform.
      return
    }

    // Popup is open and the hotkey was pressed. Route to the in-popup behavior the
    // local `eventsMonitor` used to own (cycle / select-pressed-shortcut /
    // toggle-close). The Carbon global hotkey only fires when the full
    // key+modifiers match, so the `state == .toggle` toggle-close path applies.
    _ = handleRepeatedHotKeyDown()
  }

  #if DEBUG
  /// Test hook simulating a hotkey press.
  func handleTestingHotKeyDown() {
    if isClosed() || state == .toggle {
      handleFirstKeyDown()
    } else {
      _ = handleRepeatedHotKeyDown()
    }
  }

  /// Test hook simulating all modifiers released.
  func handleTestingModifiersReleased() {
    _ = handleAllModifiersReleased()
  }
  #endif

  /// Decides (on main) whether a flagsChanged event should be consumed, given
  /// whether all modifiers were released. Extracted from the old
  /// `handleFlagsChanged` so the NSEvent monitor handler can pass only a Sendable
  /// Bool across the isolation boundary (NSEvent itself is not Sendable).
  @MainActor
  private func shouldConsumeFlagsChanged(allReleased: Bool) -> Bool {
    // If we are in cycle mode, releasing modifiers triggers a selection
    if state == .cycle && allReleased {
      _ = handleAllModifiersReleased()
      return true
    }

    // Otherwise if in opening mode, enter toggle mode
    if state == .opening && allReleased {
      state = .toggle
      return false
    }

    return false
  }

  /// Handles a repeated hotkey press while open: select a pressed-shortcut
  /// item, cycle to the next item, or toggle-close.
  private func handleRepeatedHotKeyDown(_ event: NSEvent? = nil) -> NSEvent? {
    if runtimeServices.selectPressedShortcut() { return nil }

    if state == .opening {
      state = .cycle
    }
    if state == .cycle {
      runtimeServices.highlightNext()
      return nil
    }
    if state == .toggle {
      close()
      return nil
    }

    return event
  }

  /// Handles all-modifiers-released: accept the cycle selection, or settle an
  /// opening state back to toggle.
  private func handleAllModifiersReleased(_ event: NSEvent? = nil) -> NSEvent? {
    if state == .cycle {
      Task { @MainActor [runtimeServices] in
        runtimeServices.commitSelection()
      }
      return nil
    }

    if state == .opening {
      state = .toggle
    }

    return event
  }
}
