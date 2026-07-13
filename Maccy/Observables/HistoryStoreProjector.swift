import Defaults
import Foundation
import SwiftData

/// Projects persisted history rows into the main-actor list/search domains.
@MainActor
final class HistoryStoreProjector {
  private let persistence: HistoryPersistence
  private let listState: HistoryListState
  private let searchSession: HistorySearchSession
  private let sorter: Sorter
  private var uiEffectSink: HistoryUIEffectSink = { _ in }
  private var errorSink: @MainActor (String, Error) -> Void = { _, _ in }
  private var didPublishVisible: @MainActor () -> Void = {}
  private var storeEventSink: @MainActor ([StoreEvent]) -> Void = { _ in }

  init(
    persistence: HistoryPersistence,
    listState: HistoryListState,
    searchSession: HistorySearchSession,
    sorter: Sorter = Sorter()
  ) {
    self.persistence = persistence
    self.listState = listState
    self.searchSession = searchSession
    self.sorter = sorter
  }

  func configureUIEffectSink(_ sink: @escaping HistoryUIEffectSink) {
    uiEffectSink = sink
  }

  func configureErrorSink(_ sink: @escaping @MainActor (String, Error) -> Void) {
    errorSink = sink
  }

  func configureDidPublishVisible(_ action: @escaping @MainActor () -> Void) {
    didPublishVisible = action
  }

  func configureStoreEventSink(_ sink: @escaping @MainActor ([StoreEvent]) -> Void) {
    storeEventSink = sink
  }

  /// Replaces the complete projection and commits size overflow in one batch.
  func load() throws {
    let models = try persistence.fetchAll()
    let decorators = autoreleasepool {
      sorter.sort(models).map { HistoryItemDecorator($0) }
    }
    let unpinnedOverflow = Array(
      decorators.filter(\.isUnpinned).dropFirst(max(1, Defaults[.size]))
    )
    let events = unpinnedOverflow.map { StoreEvent.removed(storedItemID(for: $0.item)) }
    if !unpinnedOverflow.isEmpty {
      try persistence.delete(unpinnedOverflow.map(\.item))
    }

    let overflowIDs = Set(unpinnedOverflow.map(\.id))
    for decorator in unpinnedOverflow {
      decorator.invalidate()
    }
    let retained = decorators.filter { !overflowIDs.contains($0.id) }
    listState.replaceAll(retained)
    searchSession.replaceCorpus(retained)
    if !events.isEmpty {
      storeEventSink(events)
    }
  }

  /// Applies one committed store event, falling back to fake-backed reconcile.
  func consume(_ event: StoreEvent, trimmedPersistentIDs: [PersistentIdentifier] = []) {
    switch event {
    case .added(let snapshot), .merged(let snapshot):
      insertIncrementally(snapshot, trimmedPersistentIDs: trimmedPersistentIDs)
    case .removed, .cleared:
      reconcile()
    }
  }

  /// Reorders the complete in-memory projection after a sort or pin-position
  /// preference changes. The projection already owns every history row, so a
  /// Defaults-only change must not fetch the store again.
  func resort() {
    let visibleIDs = Set(listState.items.map(\.id))
    let sorted = listState.all.sorted {
      sorter.areInIncreasingOrder($0.item, $1.item)
    }

    listState.replaceAll(sorted)
    if !searchSession.query.isEmpty {
      listState.publishVisible(sorted.filter { visibleIDs.contains($0.id) })
    }
    searchSession.replaceCorpus(sorted)
    refreshVisibleItems()
    emitSelectionAndResize()
  }

  /// Rebuilds from persistence while reusing decorators by persistent identity.
  func reconcile() {
    let sorted: [HistoryItem]
    do {
      sorted = sorter.sort(try persistence.fetchAll())
    } catch {
      errorSink("Failed to fetch history items for consume", error)
      return
    }

    let visibleBeforeReconcile = listState.items
    let existingByID = Dictionary(
      listState.all.map { ($0.item.persistentModelID, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let rebuilt = sorted.map { model in
      existingByID[model.persistentModelID] ?? HistoryItemDecorator(model)
    }
    let rebuiltIDs = Set(rebuilt.map { $0.item.persistentModelID })
    for decorator in listState.all where !rebuiltIDs.contains(decorator.item.persistentModelID) {
      decorator.invalidate()
    }

    listState.replaceAll(rebuilt)
    if !searchSession.query.isEmpty {
      let decoratorIDs = Set(rebuilt.map(\.id))
      listState.publishVisible(
        visibleBeforeReconcile.filter { decoratorIDs.contains($0.id) }
      )
    }
    searchSession.replaceCorpus(rebuilt)
    refreshVisibleItems()
    emitSelectionAndResize()
  }

  private func insertIncrementally(
    _ snapshot: ItemSnapshotDTO,
    trimmedPersistentIDs: [PersistentIdentifier]
  ) {
    guard let persistentID = snapshot.persistentID else {
      reconcile()
      return
    }

    var supersededSearchID: UUID?
    if let existing = listState.all.first(where: { $0.item.persistentModelID == persistentID }) {
      supersededSearchID = existing.id
      existing.invalidate()
      listState.remove(existing)
    }

    guard let model = persistence.model(for: persistentID),
          model.title == snapshot.title else {
      reconcile()
      return
    }

    let decorator = HistoryItemDecorator(model)
    let position = BinaryInsertion.index(
      for: decorator,
      in: listState.all,
      by: { sorter.areInIncreasingOrder($0.item, $1.item) }
    )
    listState.insert(decorator, at: position)
    if let supersededSearchID {
      searchSession.removeCorpus([supersededSearchID])
    }
    searchSession.insertCorpus(decorator, at: position)

    if !trimmedPersistentIDs.isEmpty {
      removeDecorators(storedIDs: Set(trimmedPersistentIDs))
    }
    refreshVisibleItems()
    emitSelectionAndResize()
  }

  private func removeDecorators(storedIDs: Set<PersistentIdentifier>) {
    let removed = listState.removeStoredIDs(storedIDs)
    for decorator in removed {
      decorator.invalidate()
    }
    searchSession.removeCorpus(removed.map(\.id))
  }

  private func refreshVisibleItems() {
    if searchSession.query.isEmpty {
      listState.publishVisible(listState.all)
      didPublishVisible()
    } else {
      searchSession.refresh(mode: Defaults[.searchMode])
    }
  }

  private func emitSelectionAndResize() {
    if searchSession.query.isEmpty {
      let first = listState.items.first(where: \.isUnpinned)
        ?? listState.items.first(where: \.isPinned)
      uiEffectSink(.select(first))
    }
    uiEffectSink(.resizePopup)
  }
}
