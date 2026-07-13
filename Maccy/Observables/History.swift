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
  static let shared = makeShared()

  private static func makeShared() -> History {
    let mutationLogger = Logger(label: "org.p0deje.Maccy")
    let context = Storage.shared.context
    let pinService = PinService(context: context)
    let decoratorFactory = HistoryItemDecoratorFactory.live()
    return History(
      persistence: SwiftDataHistoryPersistence(context: context),
      decoratorFactory: decoratorFactory,
      runtimeServices: HistoryRuntimeServices(
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
        availablePin: { pinService.randomAvailablePin },
        currentEvent: { NSApp.currentEvent },
        publishStoreEvents: { Clipboard.shared.synchronizeStoreEvents($0) },
        log: { mutationLogger.info("\($0)") }
      )
    )
  }

  let logger = Logger(label: "org.p0deje.Maccy")

  @ObservationIgnored private let listState: HistoryListState
  @ObservationIgnored private let runtimeServices: HistoryRuntimeServices
  var items: [HistoryItemDecorator] { listState.items }
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
    guard let event = runtimeServices.currentEvent() else {
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

  @ObservationIgnored private let searchSession: HistorySearchSession
  @ObservationIgnored private let storeProjector: HistoryStoreProjector
  @ObservationIgnored private let mutations: HistoryMutations
  @ObservationIgnored private let decoratorFactory: HistoryItemDecoratorFactory
  var searchGeneration: Int { searchSession.generation }

  /// Processor owned by this History's decorator factory. The application
  /// composition reuses it for ingestion so both paths share one cache.
  var decoratorImageProcessor: any ImageProcessing {
    decoratorFactory.imageProcessor
  }

  /// All history decorators, including those hidden by the current search.
  /// `items` holds only the visible (filtered) subset.
  var all: [HistoryItemDecorator] { listState.all }

  @ObservationIgnored
  private let logsPersistenceErrors: Bool
  @ObservationIgnored
  private var uiEffectSink: HistoryUIEffectSink = { _ in }

  /// Creates the history model with its persistence backend and config flags,
  /// and starts listeners that react to relevant Defaults changes.
  init(
    persistence: HistoryPersistence,
    listState: HistoryListState = HistoryListState(),
    decoratorFactory: HistoryItemDecoratorFactory = .isolated(),
    runtimeServices: HistoryRuntimeServices = .inert,
    logsPersistenceErrors: Bool = true
  ) {
    self.listState = listState
    self.decoratorFactory = decoratorFactory
    self.runtimeServices = runtimeServices
    let searchSession = HistorySearchSession(listState: listState)
    self.searchSession = searchSession
    self.storeProjector = HistoryStoreProjector(
      persistence: persistence,
      listState: listState,
      searchSession: searchSession,
      decoratorFactory: decoratorFactory
    )
    let mutations = HistoryMutations(
      persistence: persistence,
      listState: listState,
      searchSession: searchSession,
      sorter: Sorter(),
      clipboard: runtimeServices.clipboard,
      modifierFlags: runtimeServices.modifierFlags,
      availablePin: runtimeServices.availablePin,
      log: runtimeServices.log
    )
    self.mutations = mutations
    self.logsPersistenceErrors = logsPersistenceErrors

    listState.configureWillMutate { [weak searchSession = self.searchSession] in
      searchSession?.invalidate()
    }
    searchSession.configureUIEffectSink { [weak self] effect in
      self?.emit(effect)
    }
    searchSession.configureDidPublishVisible { [weak mutations] in
      mutations?.updateUnpinnedShortcuts()
    }
    storeProjector.configureUIEffectSink { [weak self] effect in
      self?.emit(effect)
    }
    storeProjector.configureErrorSink { [weak self] message, error in
      self?.recordPersistenceError(message, error)
    }
    storeProjector.configureDidPublishVisible { [weak mutations] in
      mutations?.updateUnpinnedShortcuts()
    }
    storeProjector.configureStoreEventSink(runtimeServices.publishStoreEvents)
    mutations.configureUIEffectSink { [weak self] effect in
      self?.emit(effect)
    }
    mutations.configureStoreEventSink(runtimeServices.publishStoreEvents)
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
        self.resortAfterDefaultsChange()
      }
    }

    Task { @MainActor in
      for await _ in Defaults.updates(.pinTo, initial: false) {
        self.resortAfterDefaultsChange()
      }
    }

    Task { @MainActor in
      for await _ in Defaults.updates(.showSpecialSymbols, initial: false) {
        for item in all {
          updateTitle(item: item, title: item.item.generateTitle())
        }
        searchSession.replaceCorpus(all)
        refreshVisibleItems()
      }
    }

    observeAdaptiveRowSizingDefaults()

    Task { @MainActor in
      for await _ in Defaults.updates(.imageMaxPreviewPixels, initial: false) {
        for item in all {
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

  /// Observes the two settings that change realized history-row geometry.
  private func observeAdaptiveRowSizingDefaults() {
    Task { @MainActor in
      for await _ in Defaults.updates(.imageMaxHeight, initial: false) {
        for item in all {
          item.cleanupImages()
        }
        emit(.resizePopup)
      }
    }

    Task { @MainActor in
      for await _ in Defaults.updates(.textRowLines, initial: false) {
        emit(.resizePopup)
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

  /// Fetches all items, sorts them, decorates each, and applies the size limit.
  /// Decorator construction is wrapped in `autoreleasepool` to bound the
  /// AppKit transients (e.g. `ApplicationImageCache` misses) to this call.
  func load() async throws {
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

  /// Copies (and optionally pastes) the item, choosing the copy/paste variant
  /// from the held modifier flags, then clears the search query.
  func select(_ item: HistoryItemDecorator?) {
    mutations.select(item)
  }

  /// Toggles an item's pin, persists it, re-sorts `all`, and clears the query.
  func togglePin(_ item: HistoryItemDecorator?) {
    mutations.togglePin(item)
  }

  /// Reorders the already-complete projection after `.sortBy` / `.pinTo`
  /// changes. No store state changed, so this keeps decorator identity and
  /// avoids an unnecessary full fetch through SwiftData.
  private func resortAfterDefaultsChange() {
    storeProjector.resort()
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
      mutations.updateUnpinnedShortcuts()
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

    mutations.updateUnpinnedShortcuts()
  }

  /// Sets both the decorator's and model's title.
  private func updateTitle(item: HistoryItemDecorator, title: String) {
    item.title = title
    item.item.title = title
  }

}

extension History: MemoryGovernanceHistory {
  /// All decorators (visible or not), for memory-pressure iteration.
  func decorators() -> [HistoryItemDecorator] { all }

  /// Purges the icon cache owned by this History's decorator factory.
  func purgeApplicationImages() {
    decoratorFactory.purgeApplicationImages()
  }
}
