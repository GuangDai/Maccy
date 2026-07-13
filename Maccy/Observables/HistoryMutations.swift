import AppKit.NSEvent
import Defaults
import Foundation

/// Clipboard commands supplied by the composition owner to history mutations.
@MainActor
struct HistoryClipboardActions {
  let clear: @MainActor () -> Void
  let copy: @MainActor (HistoryItem, Bool) -> Void
  let paste: @MainActor () -> Void
}

/// Runtime services supplied when composing a History facade.
@MainActor
struct HistoryRuntimeServices {
  let clipboard: HistoryClipboardActions
  let modifierFlags: @MainActor () -> NSEvent.ModifierFlags
  let availablePin: @MainActor () -> String?
  let currentEvent: @MainActor () -> NSEvent?
  let publishStoreEvents: @MainActor ([StoreEvent]) -> Void
  let log: @MainActor (String) -> Void

  static let inert = HistoryRuntimeServices(
    clipboard: HistoryClipboardActions(clear: {}, copy: { _, _ in }, paste: {}),
    modifierFlags: { [] },
    availablePin: { nil },
    currentEvent: { nil },
    publishStoreEvents: { _ in },
    log: { _ in }
  )
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
  private let availablePin: @MainActor () -> String?
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
    availablePin: @escaping @MainActor () -> String?,
    log: @escaping @MainActor (String) -> Void
  ) {
    self.persistence = persistence
    self.listState = listState
    self.searchSession = searchSession
    self.sorter = sorter
    self.clipboard = clipboard
    self.modifierFlags = modifierFlags
    self.availablePin = availablePin
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

  func delete(_ item: HistoryItemDecorator?) {
    guard let item else { return }
    let removedStoreID = storedItemID(for: item.item)

    do {
      try withLogging("Removing history item") {
        try persistence.delete(item.item)
      }
    } catch {
      errorSink("Failed to delete history item", error)
      return
    }

    item.invalidate()
    listState.remove(item)
    searchSession.removeCorpus([item.id])
    storeEventSink([.removed(removedStoreID)])
    updateUnpinnedShortcuts()
    Task { uiEffectSink(.resizePopup) }
  }

  func select(_ item: HistoryItemDecorator?) {
    guard let item else { return }
    searchSession.invalidate()

    let flags = modifierFlags()
    if flags.isEmpty {
      uiEffectSink(.closePopup)
      clipboard.copy(item.item, Defaults[.removeFormattingByDefault])
      if Defaults[.pasteByDefault] {
        clipboard.paste()
      }
    } else {
      switch HistoryItemAction(flags) {
      case .copy:
        uiEffectSink(.closePopup)
        clipboard.copy(item.item, false)
      case .paste:
        uiEffectSink(.closePopup)
        clipboard.copy(item.item, false)
        clipboard.paste()
      case .pasteWithoutFormatting:
        uiEffectSink(.closePopup)
        clipboard.copy(item.item, true)
        clipboard.paste()
      case .unknown:
        return
      }
    }

    Task { searchSession.query = "" }
  }

  func togglePin(_ item: HistoryItemDecorator?) {
    guard let item else { return }

    let previousPin = item.item.pin
    if item.item.pin != nil {
      item.item.pin = nil
    } else if let pin = availablePin() {
      item.item.pin = pin
    }
    do {
      try persistence.save()
    } catch {
      item.item.pin = previousPin
      errorSink("Failed to save pinned history item", error)
      return
    }

    let sortedModels = sorter.sort(listState.all.map(\.item))
    var reordered = listState.all
    if let currentIndex = reordered.firstIndex(of: item),
       let newIndex = sortedModels.firstIndex(of: item.item) {
      reordered.remove(at: currentIndex)
      reordered.insert(item, at: newIndex)
      listState.replaceAll(reordered)
      searchSession.removeCorpus([item.id])
      searchSession.insertCorpus(item, at: newIndex)
    }

    searchSession.query = ""
    updateUnpinnedShortcuts()
    if item.isUnpinned {
      uiEffectSink(.scrollTo(item.id))
    }
  }

  private func finishClear() {
    searchSession.query = ""
    clipboard.clear()
    uiEffectSink(.closePopup)
    Task { uiEffectSink(.resizePopup) }
  }

  func updateUnpinnedShortcuts() {
    let visible = listState.items.filter { $0.isUnpinned && $0.isVisible }
    for item in visible {
      item.shortcuts = []
    }
    for (index, item) in visible.prefix(9).enumerated() {
      item.shortcuts = KeyShortcut.create(character: String(index + 1))
    }
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
