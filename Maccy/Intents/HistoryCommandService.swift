/// Main-actor application port used by App Intents that read or mutate history.
@MainActor
protocol HistoryCommandService: AnyObject {
  func item(at position: Int) throws -> HistoryItem
  func selectedItem() throws -> HistoryItem
  func select(at position: Int) throws -> String
  func delete(at position: Int) throws
  func clear()
}

/// Composition-owned service slot. AppDelegate configures it before Intent
/// execution; tests can supply a protocol implementation without AppState.
@MainActor
enum HistoryCommandServices {
  static var current: (any HistoryCommandService)?

  static func require() throws -> any HistoryCommandService {
    guard let current else {
      throw AppIntentError.notFound
    }
    return current
  }
}

/// Live history command implementation with one 1-based full-history resolver.
@MainActor
final class AppHistoryCommandService: HistoryCommandService {
  private let history: History
  private let navigator: NavigationManager

  init(history: History, navigator: NavigationManager) {
    self.history = history
    self.navigator = navigator
  }

  func item(at position: Int) throws -> HistoryItem {
    try decorator(at: position).item
  }

  func selectedItem() throws -> HistoryItem {
    guard let item = navigator.selection.first?.item else {
      throw AppIntentError.notFound
    }
    return item
  }

  func select(at position: Int) throws -> String {
    let item = try decorator(at: position)
    let title = item.title
    history.select(item)
    return title
  }

  func delete(at position: Int) throws {
    history.delete(try decorator(at: position))
  }

  func clear() {
    history.clear()
  }

  private func decorator(at position: Int) throws -> HistoryItemDecorator {
    guard position > 0 else {
      throw AppIntentError.notFound
    }
    let index = position - 1
    guard history.all.indices.contains(index) else {
      throw AppIntentError.notFound
    }
    return history.all[index]
  }
}
