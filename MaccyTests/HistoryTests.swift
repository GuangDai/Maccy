import XCTest
import Defaults
@testable import Maccy

/// Behavior tests for `History` projection, clear/sort/max-size, commands, and
/// navigator-highlight semantics against the shared in-memory store.
@MainActor
class HistoryTests: XCTestCase {
  let savedSize = Defaults[.size]
  let savedSortBy = Defaults[.sortBy]
  let history = History.shared

  override func setUp() async throws {
    try await super.setUp()
    history.clearAll()
    AppState.shared.navigator.selectWithoutScrolling(item: nil)
    Defaults[.size] = 10
    Defaults[.sortBy] = .firstCopiedAt
  }

  override func tearDown() async throws {
    history.clearAll()
    history.searchQuery = ""
    Defaults[.size] = savedSize
    Defaults[.sortBy] = savedSortBy
    try await super.tearDown()
  }

  func testDefaultIsEmpty() {
    XCTAssertEqual(history.items, [])
  }

  func testAdding() throws {
    let first = try HistoryTestDriver.seed(historyItem("foo"), in: history)
    let second = try HistoryTestDriver.seed(historyItem("bar"), in: history)
    XCTAssertEqual(history.items, [second, first])
  }

  func testAddingDuringSearchKeepsFilteredItems() async throws {
    let first = try HistoryTestDriver.seed(historyItem("foo"), in: history)
    history.searchQuery = "foo"
    let second = try HistoryTestDriver.seed(historyItem("bar"), in: history)
    await history.waitForInFlightSearch()
    XCTAssertEqual(history.items, [first])
    XCTAssertFalse(history.items.contains(second))
  }

  /// Adding an item during an active (non-empty) query re-runs the search
  /// through `performSearch` — the actor path — so the result reflects the owned
  /// corpus (including body matches) rather than a synchronous title-only filter.
  /// `performSearch` bumps `searchGeneration` synchronously, the oracle that this
  /// routing changed (a legacy-filter refresh leaves the generation untouched).
  func testAddingDuringActiveSearchBumpsSearchGeneration() throws {
    _ = try HistoryTestDriver.seed(historyItem("foo"), in: history)
    history.searchQuery = "foo"
    let generationBefore = history.searchGeneration

    _ = try HistoryTestDriver.seed(historyItem("bar"), in: history)

    XCTAssertGreaterThan(history.searchGeneration, generationBefore)
  }

  func testNavigatorHighlightFirstSkipsInvisibleItems() throws {
    let first = try HistoryTestDriver.seed(historyItem("foo"), in: history)
    let second = try HistoryTestDriver.seed(historyItem("bar"), in: history)
    second.isVisible = false

    AppState.shared.navigator.highlightFirst()

    XCTAssertEqual(AppState.shared.navigator.selection.first, first)
  }

  func testNavigatorHighlightNextSkipsInvisibleItems() throws {
    let first = try HistoryTestDriver.seed(historyItem("foo"), in: history)
    let second = try HistoryTestDriver.seed(historyItem("bar"), in: history)
    let third = try HistoryTestDriver.seed(historyItem("baz"), in: history)
    second.isVisible = false
    AppState.shared.navigator.select(item: third)

    AppState.shared.navigator.highlightNext()

    XCTAssertEqual(AppState.shared.navigator.selection.first, first)
  }

  func testClearingUnpinned() throws {
    let pinned = try HistoryTestDriver.seed(historyItem("foo"), in: history)
    history.togglePin(pinned)
    _ = try HistoryTestDriver.seed(historyItem("bar"), in: history)
    history.clear()
    XCTAssertEqual(history.items, [pinned])
  }

  func testClearingAll() throws {
    _ = try HistoryTestDriver.seed(historyItem("foo"), in: history)
    history.clear()
    XCTAssertEqual(history.items, [])
  }

  func testMaxSize() async throws {
    try persistHistoryItems(0...10)
    try await history.load()

    XCTAssertEqual(history.items.count, 10)
    XCTAssertTrue(history.items.contains { $0.title == "10" })
    XCTAssertFalse(history.items.contains { $0.title == "0" })
  }

  func testMaxSizeIgnoresPinned() async throws {
    let pinned = historyItem("0", copiedAt: 0)
    pinned.pin = "a"
    try persist([pinned] + (1...11).map { historyItem(String($0), copiedAt: $0) })
    try await history.load()

    XCTAssertEqual(history.items.count, 11)
    XCTAssertTrue(history.items.contains { $0.title == "11" })
    XCTAssertTrue(history.items.contains { $0.title == "0" })
    XCTAssertFalse(history.items.contains { $0.title == "1" })
  }

  func testMaxSizeIsChanged() async throws {
    Defaults[.size] = 5
    try persistHistoryItems(0...11)
    try await history.load()

    XCTAssertEqual(history.items.count, 5)
    XCTAssertTrue(history.items.contains { $0.title == "11" })
    XCTAssertFalse(history.items.contains { $0.title == "6" })
  }

  func testInvalidMaxSizeFallsBackToOne() async throws {
    Defaults[.size] = 0
    try persist([
      historyItem("foo", copiedAt: 0),
      historyItem("bar", copiedAt: 1)
    ])
    try await history.load()

    XCTAssertEqual(history.items.map(\.title), ["bar"])
  }

  func testRemoving() throws {
    let foo = try HistoryTestDriver.seed(historyItem("foo"), in: history)
    let bar = try HistoryTestDriver.seed(historyItem("bar"), in: history)
    history.delete(foo)
    XCTAssertEqual(history.items, [bar])
  }

  func testRemovingSynchronizesIngestorIndex() async throws {
    let foo = try HistoryTestDriver.seed(historyItem("foo"), in: history)
    let expectedID = snapshot(of: foo.item).id
    let spy = IngestorSpy()
    let savedIngestor = Clipboard.shared.ingestor
    Clipboard.shared.ingestor = spy
    defer { Clipboard.shared.ingestor = savedIngestor }

    history.delete(foo)

    let events = await waitForStoreEvents(in: spy, count: 1)
    XCTAssertEqual(events, [.removed(expectedID)])
  }

  func testClearingUnpinnedSynchronizesOnlyRemovedItems() async throws {
    let pinned = try HistoryTestDriver.seed(historyItem("pinned"), in: history)
    history.togglePin(pinned)
    let unpinned = try HistoryTestDriver.seed(historyItem("unpinned"), in: history)
    let expectedID = snapshot(of: unpinned.item).id
    let spy = IngestorSpy()
    let savedIngestor = Clipboard.shared.ingestor
    Clipboard.shared.ingestor = spy
    defer { Clipboard.shared.ingestor = savedIngestor }

    history.clear()

    let events = await waitForStoreEvents(in: spy, count: 1)
    XCTAssertEqual(events, [.removed(expectedID)])
  }

  func testClearingAllSynchronizesIngestorIndex() async throws {
    _ = try HistoryTestDriver.seed(historyItem("foo"), in: history)
    let spy = IngestorSpy()
    let savedIngestor = Clipboard.shared.ingestor
    Clipboard.shared.ingestor = spy
    defer { Clipboard.shared.ingestor = savedIngestor }

    history.clearAll()

    let events = await waitForStoreEvents(in: spy, count: 1)
    XCTAssertEqual(events, [.cleared])
  }

  func testHistoryCommandServiceUsesFullHistoryWhileItemsAreFiltered() async throws {
    let older = try HistoryTestDriver.seed(historyItem("older"), in: history)
    let newer = try HistoryTestDriver.seed(historyItem("newer"), in: history)
    history.searchQuery = "older"
    history.refreshForModeChange()
    await history.waitForInFlightSearch()
    XCTAssertEqual(history.items, [older])
    let service = AppHistoryCommandService(
      history: history,
      navigator: AppState.shared.navigator
    )

    XCTAssertTrue(try service.item(at: 1) === newer.item)
    XCTAssertTrue(try service.item(at: 2) === older.item)
  }

  func testHistoryCommandServiceRejectsInvalidPositions() throws {
    _ = try HistoryTestDriver.seed(historyItem("only"), in: history)
    let service = AppHistoryCommandService(
      history: history,
      navigator: AppState.shared.navigator
    )

    assertNotFound { _ = try service.item(at: 0) }
    assertNotFound { _ = try service.item(at: -1) }
    assertNotFound { _ = try service.item(at: 2) }
  }

  func testHistoryCommandServiceResolvesNavigatorSelection() throws {
    let item = try HistoryTestDriver.seed(historyItem("selected"), in: history)
    AppState.shared.navigator.selectWithoutScrolling(item: item)
    let service = AppHistoryCommandService(
      history: history,
      navigator: AppState.shared.navigator
    )

    XCTAssertTrue(try service.selectedItem() === item.item)
  }

  /// Builds an uninserted single-string `HistoryItem` with a derived title.
  private func historyItem(_ value: String, copiedAt: Int? = nil) -> HistoryItem {
    let contents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: value.data(using: .utf8)
      )
    ]
    let item = HistoryItem()
    item.contents = contents
    item.numberOfCopies = 1
    if let copiedAt {
      let date = Date(timeIntervalSince1970: TimeInterval(copiedAt))
      item.firstCopiedAt = date
      item.lastCopiedAt = date
    }
    item.title = item.generateTitle()

    return item
  }

  /// Persists deterministic numbered rows without projecting them into History.
  private func persistHistoryItems(_ indexes: ClosedRange<Int>) throws {
    try persist(indexes.map { historyItem(String($0), copiedAt: $0) })
  }

  /// Commits a batch once; `load()` then exercises production sort/limit logic.
  private func persist(_ items: [HistoryItem]) throws {
    for item in items {
      Storage.shared.context.insert(item)
    }
    Storage.shared.context.processPendingChanges()
    try Storage.shared.context.save()
  }

  private func waitForStoreEvents(in spy: IngestorSpy, count: Int) async -> [StoreEvent] {
    for _ in 0..<100 {
      let events = await spy.storeEvents
      if events.count >= count {
        return events
      }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return await spy.storeEvents
  }

  private func assertNotFound(_ operation: () throws -> Void) {
    XCTAssertThrowsError(try operation()) { error in
      guard case .some(.notFound) = error as? AppIntentError else {
        XCTFail("Expected AppIntentError.notFound, got \(error)")
        return
      }
    }
  }
}
