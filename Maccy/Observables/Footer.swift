import AppKit.NSEvent
import Defaults
import SwiftUI

/// The bottom action bar (clear, clear all, preferences, about, quit), modeled
/// as an `ItemsContainer` so it shares selection/navigation logic with `History`.
@MainActor
@Observable
class Footer: ItemsContainer {
  var items: [FooterItem] = []

  /// The currently highlighted footer item, keeping `isSelected` in sync.
  var selectedItem: FooterItem? {
    willSet {
      selectedItem?.isSelected = false
      newValue?.isSelected = true
    }
  }

  /// Binding to the persisted "suppress clear alert" default.
  var suppressClearAlert = Binding<Bool>(
    get: { Defaults[.suppressClearAlert] },
    set: { Defaults[.suppressClearAlert] = $0 }
  )

  private var showFooter: Bool {
    return Defaults[.showFooter]
  }
  /// Whether the footer is visible (from `showFooter`).
  var containerVisible: Bool {
    return showFooter
  }

  /// Resolves which destructive footer action the currently held modifiers describe.
  func clearAction(for pressedModifiers: NSEvent.ModifierFlags) -> FooterAction {
    let clearModifiers = items.first(where: { $0.action == .clearHistory })?
      .shortcuts.first?.modifierFlags ?? []
    let clearAllModifiers = items.first(where: { $0.action == .clearAllHistory })?
      .shortcuts.first?.modifierFlags ?? []
    let selectsClearAll = !pressedModifiers.isEmpty
      && !pressedModifiers.isSubset(of: clearModifiers)
      && pressedModifiers.isSubset(of: clearAllModifiers)
    return selectsClearAll ? .clearAllHistory : .clearHistory
  }

  /// Builds the fixed set of footer actions (clear, clear all, preferences,
  /// about, quit).
  init() {
    items = [
      FooterItem(
        title: "clear",
        shortcuts: [KeyShortcut(key: .delete, modifierFlags: [.command, .option])],
        help: "clear_tooltip",
        confirmation: .init(
          message: "clear_alert_message",
          comment: "clear_alert_comment",
          confirm: "clear_alert_confirm",
          cancel: "clear_alert_cancel"
        ),
        suppressConfirmation: suppressClearAlert,
        action: .clearHistory
      ),
      FooterItem(
        title: "clear_all",
        shortcuts: [KeyShortcut(key: .delete, modifierFlags: [.command, .option, .shift])],
        help: "clear_all_tooltip",
        confirmation: .init(
          message: "clear_alert_message",
          comment: "clear_alert_comment",
          confirm: "clear_alert_confirm",
          cancel: "clear_alert_cancel"
        ),
        suppressConfirmation: suppressClearAlert,
        action: .clearAllHistory
      ),
      FooterItem(
        title: "preferences",
        shortcuts: [KeyShortcut(key: .comma)],
        action: .openPreferences
      ),
      FooterItem(
        title: "about",
        help: "about_tooltip",
        action: .openAbout
      ),
      FooterItem(
        title: "quit",
        shortcuts: [KeyShortcut(key: .q)],
        help: "quit_tooltip",
        action: .quit
      )
    ]
  }
}
