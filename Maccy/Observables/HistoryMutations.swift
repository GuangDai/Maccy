import AppKit.NSEvent
import Foundation

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
  private let persistence: HistoryPersistence
  private let listState: HistoryListState
  private let searchSession: HistorySearchSession
  private let sorter: Sorter
  private let clipboard: HistoryClipboardActions
  private let modifierFlags: @MainActor () -> NSEvent.ModifierFlags
  private let log: @MainActor (String) -> Void
  private var uiEffectSink: HistoryUIEffectSink = { _ in }
  private var storeEventSink: @MainActor ([StoreEvent]) -> Void = { _ in }
  private var errorSink: @MainActor (String, Error) -> Void = { _, _ in }

  init(
    persistence: HistoryPersistence,
    listState: HistoryListState,
    searchSession: HistorySearchSession,
    sorter: Sorter,
    clipboard: HistoryClipboardActions,
    modifierFlags: @escaping @MainActor () -> NSEvent.ModifierFlags,
    log: @escaping @MainActor (String) -> Void
  ) {
    self.persistence = persistence
    self.listState = listState
    self.searchSession = searchSession
    self.sorter = sorter
    self.clipboard = clipboard
    self.modifierFlags = modifierFlags
    self.log = log
  }

  func configureUIEffectSink(_ sink: @escaping HistoryUIEffectSink) {
    uiEffectSink = sink
  }

  func configureStoreEventSink(_ sink: @escaping @MainActor ([StoreEvent]) -> Void) {
    storeEventSink = sink
  }

  func configureErrorSink(_ sink: @escaping @MainActor (String, Error) -> Void) {
    errorSink = sink
  }

  func clear() {
    let removed = listState.all.filter(\.isUnpinned)
    let removedStoreIDs = removed.map { storedItemID(for: $0.item) }
    let removedPersistentIDs = Set(removed.map { $0.item.persistentModelID })

    do {
      try withLogging("Clearing history") {
        try persistence.deleteUnpinned()
      }
    } catch {
      errorSink("Failed to clear history", error)
      return
    }

    for decorator in removed {
      autoreleasepool {
        decorator.invalidate()
      }
    }
    listState.removeStoredIDs(removedPersistentIDs)
    listState.publishVisible(listState.all)
    searchSession.removeCorpus(removed.map(\.id))
    storeEventSink(removedStoreIDs.map(StoreEvent.removed))
    finishClear()
  }

  func clearAll() {
    let removed = listState.all
    do {
      try withLogging("Clearing all history") {
        try persistence.deleteAll()
      }
    } catch {
      errorSink("Failed to clear all history", error)
      return
    }

    for decorator in removed {
      autoreleasepool {
        decorator.invalidate()
      }
    }
    listState.replaceAll([])
    searchSession.clearCorpus()
    storeEventSink([.cleared])
    finishClear()
  }

  func delete(_ item: HistoryItemDecorator?) {}

  func select(_ item: HistoryItemDecorator?) {}

  func togglePin(_ item: HistoryItemDecorator?) {}

  private func finishClear() {
    clipboard.clear()
    uiEffectSink(.closePopup)
    Task { uiEffectSink(.resizePopup) }
  }

  private func withLogging(_ message: String, _ operation: () throws -> Void) rethrows {
    #if DEBUG
    func dataCounts() -> String {
      do {
        let items = try persistence.countHistoryItems()
        let contents = try persistence.countHistoryItemContents()
        return "HistoryItem=\(items) HistoryItemContent=\(contents)"
      } catch {
        errorSink("Failed to count history items", error)
        return "HistoryItem=0 HistoryItemContent=0"
      }
    }

    log("\(message) Before: \(dataCounts())")
    try operation()
    log("\(message) After: \(dataCounts())")
    #else
    try operation()
    #endif
  }
}
