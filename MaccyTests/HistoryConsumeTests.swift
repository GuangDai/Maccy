import Defaults
import SwiftData
import XCTest
@testable import Maccy

/// Tests for `History.consume(_:)`, the main-thread observer that applies the
/// `StoreEvent`s emitted by the off-main clipboard ingest actor.
///
/// Under the test plan's `enable-testing` launch argument `Storage.shared` is an
/// in-memory SwiftData store, so a save on the main context is immediately
/// observable. These tests simulate the actor's already-committed result by
/// mutating the main context directly (the actor commits on a background context
/// whose saves merge into the main context via SwiftData's shared-store
/// propagation — SwiftData has no `automaticallyMergesChangesFromParent`, so a
/// committed save becomes visible to a subsequent main-context fetch).
///
/// We assert the outcomes `consume` must produce: the right item count,
/// decorator reuse by identity (so decoded images survive), and the merged
/// `numberOfCopies`.
@MainActor
final class HistoryConsumeTests: XCTestCase {
  private let stringType = NSPasteboard.PasteboardType.string.rawValue

  private var history = History.shared
  private var savedSize = 200
  private var savedSortBy = Defaults[.sortBy]

  override func setUp() async throws {
    try await super.setUp()
    // `Storage.shared` is an in-memory singleton shared across every test in
    // this run. Release external decorator references before `clearAll()`
    // deletes their backing models, then let History clear the store and its
    // view-model together so each test starts from a known-empty state.
    AppState.shared.navigator.selectWithoutScrolling(item: nil)
    history.clearAll()
    history.searchQuery = ""

    savedSize = Defaults[.size]
    savedSortBy = Defaults[.sortBy]
    // Make the size limit large enough that the trim path never fires here.
    Defaults[.size] = 200
    Defaults[.sortBy] = .firstCopiedAt
  }

  override func tearDown() async throws {
    AppState.shared.navigator.selectWithoutScrolling(item: nil)
    history.clearAll()
    history.searchQuery = ""
    Defaults[.size] = savedSize
    Defaults[.sortBy] = savedSortBy
    try await super.tearDown()
  }

  // MARK: - .added

  /// Consuming an `.added` event populates `all`/`items` from the merged main context.
  func testConsumeAddedPopulatesAllFromMergedMainContext() {
    let item = insertItem(text: "hello")
    try? Storage.shared.context.save()

    history.consume(.added(snapshot(of: item)))

    XCTAssertEqual(history.all.count, 1)
    XCTAssertEqual(history.items.count, 1)
    XCTAssertEqual(history.all.first?.title, "hello")
  }

  /// A second `.added` consume reuses the existing decorator (by identity) and adds the new one.
  func testConsumeAddedReusesExistingDecoratorAndAddsNewItem() {
    let firstItem = insertItem(text: "first")
    try? Storage.shared.context.save()
    history.consume(.added(snapshot(of: firstItem)))

    guard let reusedDecorator = history.all.first else {
      return XCTFail("Expected one decorator after first consume")
    }

    let secondItem = insertItem(text: "second")
    try? Storage.shared.context.save()
    history.consume(.added(snapshot(of: secondItem)))

    XCTAssertEqual(history.all.count, 2)
    // The pre-existing decorator must be REUSED by persistentModelID (so decoded
    // images survive), not replaced with a freshly-built twin. Identity check.
    XCTAssertTrue(
      history.all.contains(where: { $0 === reusedDecorator }),
      "consume must reuse the existing decorator, not rebuild a new one"
    )
  }

  /// When not searching, an `.added` consume selects the newest item.
  func testConsumeAddedSelectsNewestItemWhenNotSearching() {
    let firstItem = insertItem(text: "first")
    try? Storage.shared.context.save()
    history.consume(.added(snapshot(of: firstItem)))

    guard let firstDecorator = history.all.first else {
      return XCTFail("Expected one decorator after first consume")
    }
    AppState.shared.navigator.select(item: firstDecorator)

    let secondItem = insertItem(text: "second")
    try? Storage.shared.context.save()
    history.consume(.added(snapshot(of: secondItem)))

    XCTAssertEqual(AppState.shared.navigator.selection.first?.title, "second")
  }

  // MARK: - .merged

  /// Consuming a `.merged` event replaces the prior decorator with the merged
  /// item. The actor deletes the duplicate in `commit` and reports its
  /// persistent id in `trimmedPersistentIDs`; the consumer drops that orphan
  /// (which `insertIncrementally`'s own id check can't match — the merged
  /// successor has a fresh id).
  func testConsumeMergedReflectsReplacedItem() {
    let original = insertItem(text: "dup")
    original.numberOfCopies = 1
    try? Storage.shared.context.save()
    history.consume(.added(snapshot(of: original)))

    // Simulate the actor's merge: delete the old item, insert the merged
    // successor (same content, incremented numberOfCopies), commit on the
    // (now-merged) main context.
    Storage.shared.context.delete(original)
    let merged = insertItem(text: "dup")
    merged.numberOfCopies = 3
    try? Storage.shared.context.save()

    history.consume(
      .merged(snapshot(of: merged)),
      trimmedPersistentIDs: [original.persistentModelID]
    )

    XCTAssertEqual(history.all.count, 1, "Merge must produce a single decorator, not two")
    XCTAssertEqual(history.all.first?.item.numberOfCopies, 3)
    XCTAssertEqual(history.all.first?.title, "dup")
  }

  // MARK: - Incremental insert

  /// Incremental consume must produce the same order as a fresh full sort of the
  /// store — the binary-insertion ordering invariant.
  func testConsumeIncrementalOrderMatchesFullSort() {
    let timestamps: [TimeInterval] = [100, 300, 200, 500, 400]
    var items: [HistoryItem] = []
    for (index, timestamp) in timestamps.enumerated() {
      let item = insertItem(text: "item\(index)")
      item.firstCopiedAt = Date(timeIntervalSince1970: timestamp)
      items.append(item)
    }
    try? Storage.shared.context.save()

    // Consume in the given (out-of-sort) order.
    for item in items {
      history.consume(.added(snapshot(of: item)))
    }

    let sorter = Sorter()
    let fullSortTitles = sorter
      .sort((try? Storage.shared.context.fetch(FetchDescriptor<HistoryItem>())) ?? [])
      .map(\.title)
    XCTAssertEqual(history.all.map(\.title), fullSortTitles)
  }

  /// A consume must drop the decorators the ingest actor reports deleting —
  /// supplied in `trimmedPersistentIDs`. At steady state the actor trims
  /// oldest-unpinned every copy (by `lastCopiedAt`, not the UI sort, so `all`
  /// can't trim itself); it reports each eviction so the consumer drops it.
  func testConsumeRemovesDecoratorWhenStoreItemDeleted() {
    let itemA = insertItem(text: "a")
    let itemB = insertItem(text: "b")
    try? Storage.shared.context.save()
    history.consume(.added(snapshot(of: itemA)))
    history.consume(.added(snapshot(of: itemB)))
    XCTAssertEqual(history.all.count, 2)

    // The actor trims A (oldest-unpinned) when adding C, and reports A in the
    // trimmed set alongside C's `.added` event.
    Storage.shared.context.delete(itemA)
    let itemC = insertItem(text: "c")
    try? Storage.shared.context.save()
    history.consume(
      .added(snapshot(of: itemC)),
      trimmedPersistentIDs: [itemA.persistentModelID]
    )

    let titles = Set(history.all.map(\.title))
    XCTAssertFalse(titles.contains("a"), "trimmed item must be removed from all")
    XCTAssertEqual(history.all.count, 2, "A dropped, C added → still 2")
  }

  // MARK: - D4: actor-supplied trimmed persistent IDs (NEW-history-spine-2)

  /// When the ingest actor supplies `trimmedPersistentIDs`, `consume` drops
  /// exactly those decorators (the duplicate plus size-trim evictions) in
  /// O(deleted) — replacing the old per-copy full-identifier fetch.
  func testConsumeTrimmedPersistentIDsRemovesOnlyThoseDecorators() {
    let itemA = insertItem(text: "a")
    try? Storage.shared.context.save()
    history.consume(.added(snapshot(of: itemA)))
    XCTAssertEqual(history.all.count, 1)

    let itemB = insertItem(text: "b")
    try? Storage.shared.context.save()
    // The actor hands the consumer the persistent IDs it just deleted. Here it
    // "deleted" A, so A's decorator must be trimmed — without touching B.
    history.consume(.added(snapshot(of: itemB)), trimmedPersistentIDs: [itemA.persistentModelID])

    XCTAssertEqual(history.all.count, 1, "B inserted; A trimmed")
    XCTAssertEqual(history.all.first?.title, "b")
  }

  /// An empty `trimmedPersistentIDs` means the actor deleted nothing this copy,
  /// so there is nothing to reconcile — a no-op. The common plain-copy path (no
  /// duplicate, no size-trim) is O(1): the D4 win versus the old per-copy fetch.
  func testConsumeEmptyTrimmedIsNoOp() {
    let itemA = insertItem(text: "a")
    try? Storage.shared.context.save()
    history.consume(.added(snapshot(of: itemA)))

    let itemB = insertItem(text: "b")
    try? Storage.shared.context.save()
    history.consume(.added(snapshot(of: itemB)))  // default trimmedPersistentIDs == []

    XCTAssertEqual(history.all.count, 2, "Nothing deleted → nothing trimmed")
    XCTAssertTrue(Set(history.all.map(\.title)).isSuperset(of: ["a", "b"]))
  }

  /// A `.merged` ingest: the dup's orphan decorator — whose persistent id the
  /// merged survivor cannot match — is removed because the actor included it in
  /// `trimmedPersistentIDs`. The actor deletes `dup` from the store (simulated
  /// here) and inserts a fresh survivor.
  func testConsumeMergedTrimsDupDecorator() {
    let dup = insertItem(text: "dup")
    try? Storage.shared.context.save()
    history.consume(.added(snapshot(of: dup)))
    XCTAssertEqual(history.all.count, 1)

    // The actor's commit deleted `dup` and inserted a fresh `survivor`.
    Storage.shared.context.delete(dup)
    let survivor = insertItem(text: "dup")
    try? Storage.shared.context.save()
    history.consume(
      .merged(snapshot(of: survivor)),
      trimmedPersistentIDs: [dup.persistentModelID]
    )

    XCTAssertEqual(history.all.count, 1, "dup trimmed; survivor inserted")
    XCTAssertEqual(history.all.first?.item.persistentModelID, survivor.persistentModelID)
  }

  // MARK: - Search-generation discipline (DS-013 / NEW-history-spine-3/4)

  /// `load()` replaces `all` with fresh decorators; it must bump
  /// `searchGeneration` so an in-flight search can't apply against the stale ids
  /// and render an empty result list (NEW-history-spine-3).
  func testLoadBumpsSearchGeneration() async throws {
    let genBefore = history.searchGeneration
    try await history.load()
    XCTAssertGreaterThan(history.searchGeneration, genBefore)
  }

  /// `togglePin` reorders `all`; it must invalidate in-flight search like
  /// `clear`/`clearAll`/`delete` do, so a stale apply can't render the pre-pin
  /// order (DS-013).
  func testTogglePinBumpsSearchGeneration() async {
    let item = insertItem(text: "pinme")
    try? Storage.shared.context.save()
    history.consume(.added(snapshot(of: item)))
    guard let decorator = history.all.first else {
      return XCTFail("Expected one decorator after consume")
    }

    let genBefore = history.searchGeneration
    history.togglePin(decorator)
    XCTAssertGreaterThan(history.searchGeneration, genBefore)
  }

  // MARK: - Helpers

  /// Inserts a single-string-content `HistoryItem` into the shared main context
  /// (mirrors the `historyItem(_:)` helper in HistoryTests).
  private func insertItem(text: String) -> HistoryItem {
    let contents = [
      HistoryItemContent(
        type: stringType,
        value: text.data(using: .utf8)
      )
    ]
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = contents
    item.numberOfCopies = 1
    item.title = item.generateTitle()
    return item
  }
}
