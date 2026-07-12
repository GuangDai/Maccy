import SwiftUI

/// Closed application intents exposed by the fixed footer menu.
enum FooterAction: Equatable {
  case clearHistory
  case clearAllHistory
  case openPreferences
  case openAbout
  case quit
}

/// A single footer action (clear, clear all, preferences, about, quit): its
/// title, keyboard shortcut, optional confirmation prompt, and closed action
/// value for the composition owner to interpret.
@MainActor
@Observable
class FooterItem: Equatable, Identifiable, HasVisibility {
  /// Localized strings for an optional confirm-before-action alert.
  struct Confirmation {
    var message: LocalizedStringKey
    var comment: LocalizedStringKey
    var confirm: LocalizedStringKey
    var cancel: LocalizedStringKey
  }

  /// Identity-only equality. `nonisolated` so it satisfies `Equatable` from a
  /// `@MainActor` type; reads only the `let` UUID `id` (Sendable), never the
  /// main-mutated title/state.
  nonisolated static func == (lhs: FooterItem, rhs: FooterItem) -> Bool {
    return lhs.id == rhs.id
  }

  let id = UUID()

  var title: String
  var shortcuts: [KeyShortcut] = []
  var help: LocalizedStringKey?
  var isSelected: Bool = false
  var confirmation: Confirmation?
  var showConfirmation: Bool = false
  var suppressConfirmation: Binding<Bool>?
  var isVisible: Bool = true
  let action: FooterAction

  /// Creates a footer item with its title, optional shortcut/confirmation, and
  /// closed action value.
  init(
    title: String,
    shortcuts: [KeyShortcut] = [],
    help: LocalizedStringKey? = nil,
    confirmation: Confirmation? = nil,
    suppressConfirmation: Binding<Bool>? = nil,
    action: FooterAction
  ) {
    self.title = title
    self.shortcuts = shortcuts
    self.help = help
    self.confirmation = confirmation
    self.suppressConfirmation = suppressConfirmation
    self.action = action
  }
}
