import AppKit
import Defaults
import Foundation
import Settings
import SwiftUI

/// Runtime effects supplied when composing the top-level application state.
@MainActor
struct AppStateRuntimeServices {
  let copyText: @MainActor (String) -> Void
  let readStorageSize: @MainActor () -> String

  static let inert = AppStateRuntimeServices(
    copyText: { _ in },
    readStorageSize: { "" }
  )
}

/// Top-level app state holding the shared observable models (`History`,
/// `Footer`, `Popup`, `NavigationManager`, `SlideoutController`) and the
/// actions the UI binds to (select, pin, delete, open preferences, …).
@MainActor
@Observable
class AppState {
  static let shared = makeShared()

  private static func makeShared() -> AppState {
    AppState(
      history: History.shared,
      footer: Footer(),
      runtimeServices: AppStateRuntimeServices(
        copyText: { Clipboard.shared.copy($0) },
        readStorageSize: { Storage.shared.size }
      )
    )
  }

  var appDelegate: AppDelegate?
  var popup: Popup
  var history: History
  var footer: Footer
  var navigator: NavigationManager
  var preview: SlideoutController

  /// Whether the search field is shown, from `showSearch` + `searchVisibility`.
  var searchVisible: Bool {
    if !Defaults[.showSearch] { return false }
    switch Defaults[.searchVisibility] {
    case .always: return true
    case .duringSearch: return !history.searchQuery.isEmpty
    }
  }

  /// Shortened text of the most recent unpinned item, for the menu-bar icon.
  var menuIconText: String {
    var title = history.unpinnedItems.first?.text.shortened(to: 100)
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    title.unicodeScalars.removeAll(where: CharacterSet.newlines.contains)
    return title.shortened(to: 20)
  }

  private let about = About()
  private var settingsWindowController: SettingsWindowController?
  /// Token for the close observer that nils the controller (releasing its six
  /// SwiftUI panes) when the settings window closes, so a once-opened Settings
  /// UI doesn't stay resident for the process lifetime. Stored so the observer
  /// removes itself (no accumulation across reopens).
  private var settingsWindowCloseObserver: NSObjectProtocol?
  @ObservationIgnored private let runtimeServices: AppStateRuntimeServices
  @ObservationIgnored let visibilityTracker: VisibilityTracker

  init(
    history: History,
    footer: Footer,
    runtimeServices: AppStateRuntimeServices = .inert,
    visibilityTracker: VisibilityTracker = VisibilityTracker()
  ) {
    self.history = history
    self.footer = footer
    self.runtimeServices = runtimeServices
    self.visibilityTracker = visibilityTracker
    let popup = Popup()
    self.popup = popup
    let preview = SlideoutController(
      onContentResize: { contentWidth in
        Defaults[.windowSize].width = contentWidth
      },
      onSlideoutResize: { previewWidth in
        Defaults[.previewWidth] = previewWidth
      }
    )
    self.preview = preview
    navigator = NavigationManager(
      history: history,
      footer: footer,
      onLeadChange: { current in
        preview.handleLeadChange(current)
      }
    )
    preview.contentWidth = Defaults[.windowSize].width
    preview.slideoutWidth = Defaults[.previewWidth]
    history.configureUIEffectSink { [weak self] effect in
      self?.applyHistoryUIEffect(effect)
    }
    popup.configureRuntimeServices(PopupRuntimeServices(
      selectInitialItem: { [weak self] in
        guard let self else { return }
        self.navigator.select(
          item: self.history.unpinnedItems.first ?? self.history.pinnedItems.first
        )
      },
      openPanel: { [weak self] height, position in
        self?.appDelegate?.panel.open(height: height, at: position)
      },
      closePanel: { [weak self] in self?.appDelegate?.panel.close() },
      isPanelPresented: { [weak self] in self?.appDelegate?.panel.isPresented == true },
      requiresPreviewMinimumHeight: { [weak self] in
        guard let self else { return false }
        return self.preview.state.isOpen && self.navigator.leadSelection != nil
      },
      resizePanel: { [weak self] height in
        self?.appDelegate?.panel.verticallyResize(to: height)
      },
      prewarmVisibleWindow: { [weak self] in self?.prewarmVisibleWindow() },
      selectPressedShortcut: { [weak self] in
        guard let self, let item = self.history.pressedShortcutItem else { return false }
        self.navigator.select(item: item)
        Task { @MainActor [weak self] in self?.history.select(item) }
        return true
      },
      highlightNext: { [weak self] in self?.navigator.highlightNext(allowCycle: true) },
      commitSelection: { [weak self] in self?.select() }
    ))
  }

  /// Interprets outward history requests at the composition boundary.
  private func applyHistoryUIEffect(_ effect: HistoryUIEffect) {
    switch effect {
    case .closePopup:
      popup.close()
    case .resizePopup:
      popup.needsResize = true
    case .select(let item):
      navigator.select(item: item)
    case .highlightFirst:
      navigator.highlightFirst()
    case .scrollTo(let id):
      navigator.scrollTarget = id
    }
  }

  /// Resolves the current selection into an action: a single history item is
  /// selected (copy/paste), a footer item runs its action (optionally after
  /// confirmation), and an empty selection with a search query copies the query.
  @MainActor
  func select() {
    if let item = navigator.selection.first {
      history.select(item)
    } else if let item = footer.selectedItem {
      // item.suppressConfirmation is not yet wired to the live checkbox state.
      if item.confirmation != nil, Defaults[.suppressClearAlert] == false {
        item.showConfirmation = true
      } else {
        performFooterAction(item.action)
      }
    } else if !history.searchQuery.isEmpty {
      runtimeServices.copyText(history.searchQuery)
      history.searchQuery = ""
    }
  }

  /// Interprets a footer value at the application composition seam while
  /// preserving the original deferred timing of main-actor window/history
  /// commands.
  func performFooterAction(_ action: FooterAction) {
    switch action {
    case .clearHistory:
      let history = history
      Task { @MainActor in history.clear() }
    case .clearAllHistory:
      let history = history
      Task { @MainActor in history.clearAll() }
    case .openPreferences:
      Task { @MainActor [weak self] in self?.openPreferences() }
    case .openAbout:
      openAbout()
    case .quit:
      quit()
    }
  }

  /// Pre-warm the history on hotkey-down so the data is ready (or loading) by
  /// the time the popup opens. No-op when items are already loaded; otherwise
  /// kicks `History.load()` on a main-actor task. Safe to call repeatedly —
  /// `load()` is idempotent and `ContentView.task` only loads when items are
  /// still empty.
  func prewarmVisibleWindow() {
    let history = history
    Task { @MainActor in
      guard history.items.isEmpty else { return }
      await history.loadAndRecordError("History prewarm load failed")
    }
  }

  /// Toggles the pin state of every selected history item in one transaction.
  @MainActor
  func togglePin() {
    withTransaction(Transaction()) {
      navigator.selection.forEach { item in
        history.togglePin(item)
      }
    }
  }

  /// Deletes every selected history item and moves selection to the nearest
  /// remaining unselected item, all in one transaction.
  @MainActor
  func deleteSelection() {
    guard let leadItem = navigator.leadHistoryItem else { return }
    let nextUnselectedItem = history.visibleItems.nearest(to: leadItem) { !$0.isSelected }

    withTransaction(Transaction()) {
      navigator.selection.forEach { item in
        history.delete(item)
      }
      navigator.select(item: nextUnselectedItem)
    }
  }

  /// Opens the About window.
  func openAbout() {
    about.openAbout(nil)
  }

  /// Lazily builds (once) and shows the Settings window, registering a
  /// close observer that releases its controller and SwiftUI panes on close.
  @MainActor
  func openPreferences() {
    if settingsWindowController == nil {
      let readStorageSize = runtimeServices.readStorageSize
      settingsWindowController = SettingsWindowController(
        panes: [
          Settings.Pane(
            identifier: Settings.PaneIdentifier.general,
            title: NSLocalizedString("Title", tableName: "GeneralSettings", comment: ""),
            toolbarIcon: NSImage.gearshape ?? NSImage()
          ) {
            GeneralSettingsPane { [popup] hasShortcut in
              if hasShortcut {
                popup.initEventsMonitor()
              } else {
                popup.deinitEventsMonitor()
              }
            }
          },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.storage,
            title: NSLocalizedString("Title", tableName: "StorageSettings", comment: ""),
            toolbarIcon: NSImage.externaldrive ?? NSImage()
          ) {
            StorageSettingsPane(readStorageSize: readStorageSize)
          },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.appearance,
            title: NSLocalizedString("Title", tableName: "AppearanceSettings", comment: ""),
            toolbarIcon: NSImage.paintpalette ?? NSImage()
          ) {
            AppearanceSettingsPane()
          },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.pins,
            title: NSLocalizedString("Title", tableName: "PinsSettings", comment: ""),
            toolbarIcon: NSImage.pincircle ?? NSImage()
          ) {
            PinsSettingsPane()
              .environment(self)
              .modelContainer(Storage.shared.container)
          },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.ignore,
            title: NSLocalizedString("Title", tableName: "IgnoreSettings", comment: ""),
            toolbarIcon: NSImage.nosign ?? NSImage()
          ) {
            IgnoreSettingsPane()
          },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.advanced,
            title: NSLocalizedString("Title", tableName: "AdvancedSettings", comment: ""),
            toolbarIcon: NSImage.gearshape2 ?? NSImage()
          ) {
            AdvancedSettingsPane()
          }
        ]
      )
    }
    settingsWindowController?.show()
    settingsWindowController?.window?.orderFrontRegardless()

    // Release the controller and its six `Settings.Pane` SwiftUI trees when the
    // window closes (otherwise they stay resident after first open). Keyed on
    // the specific window; the observer removes itself on fire so reopens don't
    // accumulate.
    if let window = settingsWindowController?.window, settingsWindowCloseObserver == nil {
      settingsWindowCloseObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        // queue: .main + the observer fires on the main run loop, so
        // MainActor.assumeIsolated is a runtime no-op assertion (never traps).
        // Avoids @unchecked / nonisolated(unsafe): the @Sendable closure hops
        // back into the @MainActor domain to mutate this composed AppState.
        MainActor.assumeIsolated {
          self?.settingsWindowController = nil
          if let observer = self?.settingsWindowCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            self?.settingsWindowCloseObserver = nil
          }
        }
      }
    }
  }

  /// Terminates the application.
  func quit() {
    NSApp.terminate(self)
  }
}
