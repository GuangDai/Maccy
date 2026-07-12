import AppKit.NSEvent

/// Clipboard commands supplied by the composition owner to history mutations.
@MainActor
struct HistoryClipboardActions {
  let clear: @MainActor () -> Void
  let copy: @MainActor (HistoryItem, Bool) -> Void
  let paste: @MainActor () -> Void
}

/// Owns user-initiated history commands and their post-commit projections.
@MainActor
final class HistoryMutations {
  init(
    persistence: HistoryPersistence,
    listState: HistoryListState,
    searchSession: HistorySearchSession,
    sorter: Sorter,
    clipboard: HistoryClipboardActions,
    modifierFlags: @escaping @MainActor () -> NSEvent.ModifierFlags,
    log: @escaping @MainActor (String) -> Void
  ) {}

  func configureUIEffectSink(_ sink: @escaping HistoryUIEffectSink) {}

  func configureStoreEventSink(_ sink: @escaping @MainActor ([StoreEvent]) -> Void) {}

  func configureErrorSink(_ sink: @escaping @MainActor (String, Error) -> Void) {}

  func clear() {}

  func clearAll() {}

  func delete(_ item: HistoryItemDecorator?) {}

  func select(_ item: HistoryItemDecorator?) {}

  func togglePin(_ item: HistoryItemDecorator?) {}
}
