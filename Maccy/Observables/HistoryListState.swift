import Observation
import SwiftData

/// Owns the complete and currently visible history lists behind one structural
/// mutation boundary. Structural changes invalidate search through `willMutate`;
/// publishing a completed search result intentionally does not.
@MainActor
@Observable
final class HistoryListState {
  private(set) var items: [HistoryItemDecorator]
  @ObservationIgnored private(set) var all: [HistoryItemDecorator]
  @ObservationIgnored private var willMutate: @MainActor () -> Void

  init(
    decorators: [HistoryItemDecorator] = [],
    willMutate: @escaping @MainActor () -> Void = {}
  ) {
    items = decorators
    all = decorators
    self.willMutate = willMutate
  }

  /// Installs the owning facade's search-invalidation hook after initialization.
  func configureWillMutate(_ action: @escaping @MainActor () -> Void) {
    willMutate = action
  }

  /// Replaces the complete list and publishes it as the visible list.
  func replaceAll(_ decorators: [HistoryItemDecorator]) {
    willMutate()
    all = decorators
    items = decorators
  }

  /// Inserts one decorator into the complete list.
  func insert(_ decorator: HistoryItemDecorator, at index: Int) {
    willMutate()
    all.insert(decorator, at: index)
  }

  /// Removes matching stored models from both lists, preserving removal order.
  @discardableResult
  func removeStoredIDs(_ ids: Set<PersistentIdentifier>) -> [HistoryItemDecorator] {
    let removed = all.filter { ids.contains($0.item.persistentModelID) }
    guard !removed.isEmpty else { return [] }

    willMutate()
    all.removeAll { ids.contains($0.item.persistentModelID) }
    items.removeAll { ids.contains($0.item.persistentModelID) }
    return removed
  }

  /// Removes one decorator from both lists when it is present in `all`.
  @discardableResult
  func remove(_ decorator: HistoryItemDecorator) -> Bool {
    guard all.contains(decorator) else { return false }

    willMutate()
    all.removeAll { $0 == decorator }
    items.removeAll { $0 == decorator }
    return true
  }

  /// Publishes a visible projection without invalidating the search producing it.
  func publishVisible(_ decorators: [HistoryItemDecorator]) {
    items = decorators
  }
}
