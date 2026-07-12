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
  var searchGeneration: Int { searchSession.generation }
  private var historySizeLimit: Int { max(1, Defaults[.size]) }

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
    self.searchSession = HistorySearchSession(listState: listState)
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
    let descriptor = FetchDescriptor<HistoryItem>()
    let results = try Storage.shared.context.fetch(descriptor)
    let decorators = autoreleasepool {
      sorter.sort(results).map { HistoryItemDecorator($0) }
    }
    listState.replaceAll(decorators)

    limitHistorySize(to: historySizeLimit)

    updateShortcuts()
    // Seed the search actor's corpus once, after the size trim, so the first
    // keystroke searches a corpus that already matches `all`.
    searchSession.replaceCorpus(all)
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

  /// Trims unpinned decorators past `maxSize`, deleting the overflow.
  private func limitHistorySize(to maxSize: Int) {
    let maxSize = max(0, maxSize)
    let unpinned = all.filter(\.isUnpinned)
    if unpinned.count > maxSize {
      unpinned[maxSize...].forEach(delete)
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
    switch event {
    case .added(let snapshot), .merged(let snapshot):
      insertIncrementally(snapshot, trimmedPersistentIDs: trimmedPersistentIDs)
    case .removed, .cleared:
      // The ingest actor only emits .added/.merged today; handle the others
      // defensively by full reconcile, so a future emitter stays correct.
      reconcileWithStore()
    }
  }

  /// Incremental path for `.added`/`.merged`: fetch the one committed @Model on
  /// main, remove any existing decorator for it (`.merged` re-insert + duplicate
  /// safety), binary-insert it at the sorted position, then drop the decorators
  /// the ingestor deleted this ingest (the duplicate plus size-trim evictions)
  /// via the actor-supplied `trimmedPersistentIDs` in O(deleted) — instead of
  /// re-fetching every row identifier on each copy (D4 / `NEW-history-spine-2`).
  /// An empty set (the actor deleted nothing this copy — the common plain-copy
  /// case) is a no-op. Falls back to `reconcileWithStore` on any guard failure
  /// (nil persistentID, `model(for:)` miss, title mismatch) so correctness never
  /// depends on the fast path.
  private func insertIncrementally(_ snapshot: ItemSnapshotDTO, trimmedPersistentIDs: [PersistentIdentifier]) {
    guard let persistentID = snapshot.persistentID else {
      reconcileWithStore()
      return
    }
    // A `.merged` re-insert replaces the prior decorator (a fresh id) for the
    // same persistentID; capture its id so the search-actor corpus drops it.
    var supersededSearchID: UUID?
    if let existing = all.firstIndex(where: { $0.item.persistentModelID == persistentID }) {
      let existingDecorator = all[existing]
      supersededSearchID = existingDecorator.id
      cleanup(existingDecorator)
      listState.remove(existingDecorator)
    }
    // `model(for:)` returns the faulted model for a committed id; the title check
    // guards against an un-faulted shell (it returns an unsaved shell for ids it
    // doesn't know). Fall back to the full reconcile if either fails.
    guard let model = Storage.shared.context.model(for: persistentID) as? HistoryItem,
          model.title == snapshot.title else {
      reconcileWithStore()
      return
    }
    let decorator = HistoryItemDecorator(model)
    let position = BinaryInsertion.index(
      for: decorator,
      in: all,
      by: { sorter.areInIncreasingOrder($0.item, $1.item) }
    )
    listState.insert(decorator, at: position)
    let superseded = supersededSearchID
    let session = searchSession
    // Drop the superseded id (if any) then register the new entry at the same
    // index its decorator occupies in `all`. The session updates its lookup
    // synchronously and serializes actor updates ahead of the next search.
    if let superseded {
      session.removeCorpus([superseded])
    }
    session.insertCorpus(decorator, at: position)
    // D4: drop exactly the decorators the ingest actor deleted this ingest (the
    // duplicate plus size-trim evictions), in O(deleted). An empty set means the
    // actor deleted nothing this copy, so there is nothing to reconcile — a
    // no-op, which is the win on the common plain-copy path (the old code
    // re-fetched every row identifier here on every copy). For a `.merged`
    // ingest this also removes the dup's orphan decorator, which the
    // persistentID check above cannot (the merged survivor has a fresh id; the
    // dup's is only in `trimmedPersistentIDs`). Guard failures above already
    // fell through to `reconcileWithStore`.
    if !trimmedPersistentIDs.isEmpty {
      removeDecorators(forPersistentIDs: Set(trimmedPersistentIDs))
    }
    refreshVisibleItems()
    if searchQuery.isEmpty {
      emit(.select(unpinnedItems.first ?? pinnedItems.first))
    }
    emit(.resizePopup)
  }

  /// Drops `all` decorators whose backing item the ingest actor deleted this
  /// ingest — the O(deleted) replacement for `syncAllToStore`'s full id-set
  /// fetch + scan (D4 / `NEW-history-spine-2`). Same removal + corpus-drop +
  /// cleanup as `syncAllToStore`, but matches a known set instead of re-fetching
  /// the store, so per-copy cost is O(deleted) (usually 0–1) not O(rows).
  private func removeDecorators(forPersistentIDs ids: Set<PersistentIdentifier>) {
    let removed = listState.removeStoredIDs(ids)
    for decorator in removed {
      cleanup(decorator)
    }
    let removedSearchIDs = removed.map(\.id)
    if !removedSearchIDs.isEmpty {
      searchSession.removeCorpus(removedSearchIDs)
    }
  }

  /// Rebuilds `all` from a fresh main-context fetch, reusing decorators whose
  /// `persistentModelID` is still present (so decoded images survive) and
  /// decorating only items that are new or changed.
  private func reconcileWithStore() {
    let visibleBeforeReconcile = items
    let sorted: [HistoryItem]
    do {
      sorted = sorter.sort(try Storage.shared.context.fetch(FetchDescriptor<HistoryItem>()))
    } catch {
      recordPersistenceError("Failed to fetch history items for consume", error)
      return
    }

    let existingByID = Dictionary(
      all.map { ($0.item.persistentModelID, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var rebuilt: [HistoryItemDecorator] = []
    for item in sorted {
      if let decorator = existingByID[item.persistentModelID] {
        rebuilt.append(decorator)
      } else {
        rebuilt.append(HistoryItemDecorator(item))
      }
    }
    // Invalidate decorators whose backing items were removed/merged away so
    // their decoded images release.
    let rebuiltIDs = Set(rebuilt.map { $0.item.persistentModelID })
    for decorator in all where !rebuiltIDs.contains(decorator.item.persistentModelID) {
      cleanup(decorator)
    }
    listState.replaceAll(rebuilt)
    if !searchQuery.isEmpty {
      let rebuiltDecoratorIDs = Set(rebuilt.map(\.id))
      listState.publishVisible(
        visibleBeforeReconcile.filter { rebuiltDecoratorIDs.contains($0.id) }
      )
    }
    // Full reconcile rebuilt `all` from the store; rebuild the search-actor
    // corpus to match.
    searchSession.replaceCorpus(all)
    refreshVisibleItems()
    if searchQuery.isEmpty {
      emit(.select(unpinnedItems.first ?? pinnedItems.first))
    }
    emit(.resizePopup)
  }

  /// Runs `block` under DEBUG-only before/after row-count logging. The count
  /// round-trips are diagnostics only, so release builds skip them and run just
  /// the operation.
  private func withLogging(_ msg: String, _ block: () throws -> Void) rethrows {
    #if DEBUG
    func dataCounts() -> String {
      do {
        let historyItemCount = try persistence.countHistoryItems()
        let historyContentCount = try persistence.countHistoryItemContents()
        return "HistoryItem=\(historyItemCount) HistoryItemContent=\(historyContentCount)"
      } catch {
        recordPersistenceError("Failed to count history items", error)
        return "HistoryItem=0 HistoryItemContent=0"
      }
    }

    logger.info("\(msg) Before: \(dataCounts())")
    try block()
    logger.info("\(msg) After: \(dataCounts())")
    #else
    try block()
    #endif
  }

  /// Deletes all unpinned items (keeping pins), draining each removed
  /// decorator's AppKit transients in an autorelease pool so a bulk clear
  /// doesn't pile them up.
  func clear() {
    let removed = all.filter(\.isUnpinned)
    let removedStoreIDs = removed.map { storedItemID(for: $0.item) }
    let removedPersistentIDs = Set(removed.map { $0.item.persistentModelID })

    do {
      try withLogging("Clearing history") {
        try persistence.deleteUnpinned()
      }
      let removedIDs = removed.map(\.id)
      for item in removed {
        autoreleasepool {
          cleanup(item)
        }
      }
      listState.removeStoredIDs(removedPersistentIDs)
      listState.publishVisible(all)
      searchSession.removeCorpus(removedIDs)
      synchronizeIngestor(with: removedStoreIDs.map(StoreEvent.removed))
    } catch {
      recordPersistenceError("Failed to clear history", error)
      return
    }

    Clipboard.shared.clear()
    emit(.closePopup)
    Task {
      emit(.resizePopup)
    }
  }

  /// Deletes every item (pins included), draining each decorator's transients.
  func clearAll() {
    let removed = all

    do {
      try withLogging("Clearing all history") {
        try persistence.deleteAll()
      }
      for item in removed {
        autoreleasepool {
          cleanup(item)
        }
      }
      listState.replaceAll([])
      searchSession.clearCorpus()
      synchronizeIngestor(with: [.cleared])
    } catch {
      recordPersistenceError("Failed to clear all history", error)
      return
    }

    Clipboard.shared.clear()
    emit(.closePopup)
    Task {
      emit(.resizePopup)
    }
  }

  /// Deletes a single decorator's backing item, removes it from `all`/`items`,
  /// and reassigns unpinned shortcuts.
  func delete(_ item: HistoryItemDecorator?) {
    guard let item else { return }

    let removedStoreID = storedItemID(for: item.item)
    do {
      try withLogging("Removing history item") {
        try persistence.delete(item.item)
      }
    } catch {
      recordPersistenceError("Failed to delete history item", error)
      return
    }

    cleanup(item)
    let removedID = item.id
    listState.remove(item)
    searchSession.removeCorpus([removedID])
    synchronizeIngestor(with: [.removed(removedStoreID)])
    updateUnpinnedShortcuts()
    Task {
      emit(.resizePopup)
    }
  }

  /// Invalidates a decorator, releasing its transient images.
  private func cleanup(_ item: HistoryItemDecorator) {
    item.invalidate()
  }

  /// Forwards committed main-context deletions to the actor-owned dedup index
  /// in one asynchronous batch. Capturing the current ingestor before creating
  /// the task keeps test/runtime replacement deterministic.
  private func synchronizeIngestor(with events: [StoreEvent]) {
    guard !events.isEmpty, let ingestor = Clipboard.shared.ingestor else { return }
    Task { await ingestor.synchronizeStoreEvents(events) }
  }

  /// The current event's relevant modifier flags (device-independent, caps/num/fn stripped).
  /// Relocated from the removed `History+PasteStack.swift` (its only live caller is `select`).
  private func currentModifierFlags() -> NSEvent.ModifierFlags {
    return NSApp.currentEvent?.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function]) ?? []
  }

  /// Copies (and optionally pastes) the item, choosing the copy/paste variant
  /// from the held modifier flags, then clears the search query.
  func select(_ item: HistoryItemDecorator?) {
    guard let item else {
      return
    }
    searchSession.invalidate()

    let modifierFlags = currentModifierFlags()

    if modifierFlags.isEmpty {
      emit(.closePopup)
      Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
      if Defaults[.pasteByDefault] {
        Clipboard.shared.paste()
      }
    } else {
      switch HistoryItemAction(modifierFlags) {
      case .copy:
        emit(.closePopup)
        Clipboard.shared.copy(item.item)
      case .paste:
        emit(.closePopup)
        Clipboard.shared.copy(item.item)
        Clipboard.shared.paste()
      case .pasteWithoutFormatting:
        emit(.closePopup)
        Clipboard.shared.copy(item.item, removeFormatting: true)
        Clipboard.shared.paste()
      case .unknown:
        return
      }
    }

    Task {
      searchQuery = ""
    }
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
    reconcileWithStore()
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
