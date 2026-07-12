import AppKit
import Defaults
import Foundation
import Logging
import Observation
import Sauce
import SwiftData

/// The main-actor clipboard history model: the in-memory `items`/`all` lists of
/// `HistoryItemDecorator`, persistence, search, pin/delete/clear actions, and
/// reconciliation of `StoreEvent`s emitted by the off-main ingest actor.
@MainActor
@Observable
class History: ItemsContainer {
  static let shared = History()
  let logger = Logger(label: "org.p0deje.Maccy")

  @ObservationIgnored private let listState: HistoryListState
  #if DEBUG
  var items: [HistoryItemDecorator] {
    get { listState.items }
    set { listState.publishVisible(newValue) }
  }
  #else
  var items: [HistoryItemDecorator] { listState.items }
  #endif
  var lastPersistError: Error?

  /// Pinned decorators only.
  var pinnedItems: [HistoryItemDecorator] { items.filter(\.isPinned) }
  /// Unpinned decorators only.
  var unpinnedItems: [HistoryItemDecorator] { items.filter(\.isUnpinned) }

  /// Stable facade for the extracted search session's observable query.
  var searchQuery: String {
    get { searchSession.query }
    set { searchSession.query = newValue }
  }

  /// Re-runs the active search immediately after the configured search mode
  /// (`Defaults[.searchMode]`) changes — from either the search-field mode
  /// button or the Settings picker. No-op when the query is empty (nothing to
  /// refresh). Unlike keystrokes, this is a discrete action that bypasses
  /// the debounced search consumer.
  func refreshForModeChange() {
    guard !searchQuery.isEmpty else { return }
    searchSession.refresh(mode: Defaults[.searchMode])
  }

  /// Awaits the in-flight search task, if any, so a search-then-assert
  /// sequence is deterministic. No-op when no search is running.
  func waitForInFlightSearch() async {
    await searchSession.wait()
  }

  /// The decorator whose keyboard shortcut matches the current event, if any.
  var pressedShortcutItem: HistoryItemDecorator? {
    guard let event = NSApp.currentEvent else {
      return nil
    }

    let modifierFlags = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting(.capsLock)

    guard HistoryItemAction(modifierFlags) != .unknown else {
      return nil
    }

    let key = Sauce.shared.key(for: Int(event.keyCode))
    return items.first { $0.shortcuts.contains(where: { $0.key == key }) }
  }

  private let sorter = Sorter()
  @ObservationIgnored private let searchSession: HistorySearchSession
  @ObservationIgnored private let storeProjector: HistoryStoreProjector
  @ObservationIgnored private let mutations: HistoryMutations
  var searchGeneration: Int { searchSession.generation }

  /// All history decorators, including those hidden by the current search.
  /// `items` holds only the visible (filtered) subset.
  #if DEBUG
  var all: [HistoryItemDecorator] {
    get { listState.all }
    set { listState.replaceAll(newValue) }
  }
  #else
  var all: [HistoryItemDecorator] { listState.all }
  #endif

  @ObservationIgnored
  private let persistence: HistoryPersistence
  @ObservationIgnored
  private let logsPersistenceErrors: Bool
  @ObservationIgnored
  private var uiEffectSink: HistoryUIEffectSink = { _ in }

  /// Creates the history model with its persistence backend and config flags,
  /// and starts listeners that react to relevant Defaults changes.
  init(
    persistence: HistoryPersistence = SwiftDataHistoryPersistence(),
    listState: HistoryListState = HistoryListState(),
    logsPersistenceErrors: Bool = true
  ) {
    self.persistence = persistence
    self.listState = listState
    let searchSession = HistorySearchSession(listState: listState)
    self.searchSession = searchSession
    self.storeProjector = HistoryStoreProjector(
      persistence: persistence,
      listState: listState,
      searchSession: searchSession
    )
    let mutationLogger = Logger(label: "org.p0deje.Maccy")
    self.mutations = HistoryMutations(
      persistence: persistence,
      listState: listState,
      searchSession: searchSession,
      sorter: Sorter(),
      clipboard: HistoryClipboardActions(
        clear: { Clipboard.shared.clear() },
        copy: { item, removeFormatting in
          Clipboard.shared.copy(item, removeFormatting: removeFormatting)
        },
        paste: { Clipboard.shared.paste() }
      ),
      modifierFlags: {
        NSApp.currentEvent?.modifierFlags
          .intersection(.deviceIndependentFlagsMask)
          .subtracting([.capsLock, .numericPad, .function]) ?? []
      },
      log: { mutationLogger.info("\($0)") }
    )
    self.logsPersistenceErrors = logsPersistenceErrors

    listState.configureWillMutate { [weak searchSession = self.searchSession] in
      searchSession?.invalidate()
    }
    searchSession.configureUIEffectSink { [weak self] effect in
      self?.emit(effect)
    }
    searchSession.configureDidPublishVisible { [weak self] in
      self?.updateUnpinnedShortcuts()
    }
    storeProjector.configureUIEffectSink { [weak self] effect in
      self?.emit(effect)
    }
    storeProjector.configureErrorSink { [weak self] message, error in
      self?.recordPersistenceError(message, error)
    }
    storeProjector.configureDidPublishVisible { [weak self] in
      self?.updateUnpinnedShortcuts()
    }
    storeProjector.configureStoreEventSink { [weak self] events in
      self?.synchronizeIngestor(with: events)
    }
    mutations.configureUIEffectSink { [weak self] effect in
      self?.emit(effect)
    }
    mutations.configureStoreEventSink { [weak self] events in
      self?.synchronizeIngestor(with: events)
    }
    mutations.configureErrorSink { [weak self] message, error in
      self?.recordPersistenceError(message, error)
    }

    Task { @MainActor in
      for await _ in Defaults.updates(.pasteByDefault, initial: false) {
        updateShortcuts()
      }
    }

    Task { @MainActor in
      for await _ in Defaults.updates(.sortBy, initial: false) {
        await self.loadAfterDefaultsChange()
      }
    }

    Task { @MainActor in
      for await _ in Defaults.updates(.pinTo, initial: false) {
        await self.loadAfterDefaultsChange()
      }
    }

    Task { @MainActor in
      for await _ in Defaults.updates(.showSpecialSymbols, initial: false) {
        for item in items {
          updateTitle(item: item, title: item.item.generateTitle())
        }
      }
    }

    Task { @MainActor in
      for await _ in Defaults.updates(.imageMaxHeight, initial: false) {
        for item in items {
          item.cleanupImages()
        }
      }
    }

    Task { @MainActor in
      for await _ in Defaults.updates(.imageMaxPreviewPixels, initial: false) {
        for item in items {
          item.cleanupImages()
        }
      }
    }

    Task { @MainActor in
      for await _ in Defaults.updates(.searchBodyLimit, initial: false) {
        // The body-scan cap changed; existing corpus entries still hold bodies
        // capped to the old window, so rebuild and re-run the active search.
        searchSession.replaceCorpus(all)
        refreshVisibleItems()
      }
    }
  }

  /// Installs the composition-owned interpreter for outward UI requests.
  /// Tests and non-UI consumers keep the default no-op sink.
  func configureUIEffectSink(_ sink: @escaping HistoryUIEffectSink) {
    uiEffectSink = sink
  }

  /// Emits one request through the output port configured by `AppState`.
  private func emit(_ effect: HistoryUIEffect) {
    uiEffectSink(effect)
  }

  #if DEBUG
  /// Test-only: when set, `load()` fails, simulating a transient store error
  /// so the no-silent-swallow path is exercisable. Compiled out of Release.
  private var forceLoadFailure = false

  /// Error injected by `forceLoadFailure`.
  private enum ForcedLoadFailure: Error {
    case forced
  }

  /// Test-only setter for `forceLoadFailure`.
  func setLoadFailureForTesting(_ enabled: Bool) {
    forceLoadFailure = enabled
  }
  #endif

  /// Fetches all items, sorts them, decorates each, and applies the size limit.
  /// Decorator construction is wrapped in `autoreleasepool` to bound the
  /// AppKit transients (e.g. `ApplicationImageCache` misses) to this call.
  func load() async throws {
    #if DEBUG
    if forceLoadFailure {
      throw ForcedLoadFailure.forced
    }
    #endif
    try storeProjector.load()

    updateShortcuts()
    // Ensure that panel size is proper *after* loading all items.
    Task {
      emit(.resizePopup)
    }
  }

  /// Loads history, recording (not swallowing) any error on `lastPersistError`
  /// — the popup-open and prewarm paths use this instead of `try?` so a load
  /// failure is diagnosable rather than a silent empty list (DS-023).
  /// `loadAfterDefaultsChange` already does the same; this is the shared helper
  /// for the external callers.
  func loadAndRecordError(_ message: String = "History load failed") async {
    do {
      try await load()
    } catch {
      recordPersistenceError(message, error)
    }
  }

  /// Applies a `StoreEvent` emitted by the off-main ingest actor, updating the
  /// in-memory `all`/`items` to match the (now-merged) main context.
  ///
  /// `.added`/`.merged` reconcile incrementally — fetch the one committed
  /// `@Model` on main via `ModelContext.model(for: persistentID)` and
  /// binary-insert it at the sorted position (O(log n)), reusing existing
  /// decorators — instead of refetching + re-sorting the whole table every
  /// copy. `.removed`/`.cleared` (not emitted by the ingest actor today), and
  /// any `nil`-persistentID snapshot or `model(for:)` miss, fall back to the
  /// full `reconcileWithStore`. The final `all` order matches the old full sort.
  func consume(_ event: StoreEvent, trimmedPersistentIDs: [PersistentIdentifier] = []) {
    storeProjector.consume(event, trimmedPersistentIDs: trimmedPersistentIDs)
  }

  /// Deletes all unpinned items (keeping pins), draining each removed
  /// decorator's AppKit transients in an autorelease pool so a bulk clear
  /// doesn't pile them up.
  func clear() {
    mutations.clear()
  }

  /// Deletes every item (pins included), draining each decorator's transients.
  func clearAll() {
    mutations.clearAll()
  }

  /// Deletes a single decorator's backing item, removes it from `all`/`items`,
  /// and reassigns unpinned shortcuts.
  func delete(_ item: HistoryItemDecorator?) {
    mutations.delete(item)
  }

  /// Forwards committed main-context deletions to the actor-owned dedup index
  /// in one asynchronous batch. Capturing the current ingestor before creating
  /// the task keeps test/runtime replacement deterministic.
  private func synchronizeIngestor(with events: [StoreEvent]) {
    guard !events.isEmpty, let ingestor = Clipboard.shared.ingestor else { return }
    Task { await ingestor.synchronizeStoreEvents(events) }
  }

  /// Copies (and optionally pastes) the item, choosing the copy/paste variant
  /// from the held modifier flags, then clears the search query.
  func select(_ item: HistoryItemDecorator?) {
    mutations.select(item)
  }

  /// Toggles an item's pin, persists it, re-sorts `all`, and clears the query.
  func togglePin(_ item: HistoryItemDecorator?) {
    guard let item else { return }

    let previousPin = item.item.pin
    item.togglePin()
    do {
      try persistence.save()
    } catch {
      item.item.pin = previousPin
      recordPersistenceError("Failed to save pinned history item", error)
      return
    }

    let sortedItems = sorter.sort(all.map(\.item))
    var reordered = all
    if let currentIndex = reordered.firstIndex(of: item),
       let newIndex = sortedItems.firstIndex(of: item.item) {
      reordered.remove(at: currentIndex)
      reordered.insert(item, at: newIndex)
      listState.replaceAll(reordered)
      // The pin change moved the item in `all`; mirror the move in the
      // search-actor corpus so subsequent exact/regexp results keep its place.
      let movedID = item.id
      let session = searchSession
      session.removeCorpus([movedID])
      session.insertCorpus(item, at: newIndex)
    }

    searchQuery = ""
    updateUnpinnedShortcuts()
    if item.isUnpinned {
      emit(.scrollTo(item.id))
    }
  }

  /// Reloads the history after a Defaults change that affects ordering/display
  /// (`.sortBy` / `.pinTo`). Routes through `reconcileWithStore` — which re-sorts
  /// and re-seeds the search corpus while REUSING decorators by `persistentID`
  /// — instead of a full `load()`, so decoded/cached images survive the reload
  /// rather than being discarded and re-decoded (NEW-history-spine-1).
  private func loadAfterDefaultsChange() async {
    storeProjector.reconcile()
  }

  /// Stores `error` on `lastPersistError` and logs it when enabled.
  private func recordPersistenceError(_ message: String, _ error: Error) {
    lastPersistError = error
    if logsPersistenceErrors {
      logger.error("\(message): \(String(describing: error))")
    }
  }

  /// Refreshes `items` after a mutation (add/pin/reconcile): `all` when the
  /// query is empty, otherwise asks the extracted session to re-run its actor
  /// search immediately against the owned corpus.
  private func refreshVisibleItems() {
    if searchQuery.isEmpty {
      listState.publishVisible(all)
      updateUnpinnedShortcuts()
    } else {
      searchSession.refresh(mode: Defaults[.searchMode])
    }
  }

  /// Rebuilds pin shortcuts and then unpinned ones.
  private func updateShortcuts() {
    for item in pinnedItems {
      if let pin = item.item.pin {
        item.shortcuts = KeyShortcut.create(character: pin)
      }
    }

    updateUnpinnedShortcuts()
  }

  /// Sets both the decorator's and model's title.
  private func updateTitle(item: HistoryItemDecorator, title: String) {
    item.title = title
    item.item.title = title
  }

  /// Assigns `1`–`9` shortcuts to the first nine visible unpinned items.
  private func updateUnpinnedShortcuts() {
    let visibleUnpinnedItems = unpinnedItems.filter(\.isVisible)
    for item in visibleUnpinnedItems {
      item.shortcuts = []
    }

    var index = 1
    for item in visibleUnpinnedItems.prefix(9) {
      item.shortcuts = KeyShortcut.create(character: String(index))
      index += 1
    }
  }
}

extension History: HistoryRef {
  /// All decorators (visible or not), for memory-pressure iteration.
  func decorators() -> [HistoryItemDecorator] { all }
}
