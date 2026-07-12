import XCTest
import Defaults
@testable import Maccy

/// Behavior tests for `History` add/clear/sort/max-size and navigator-highlight semantics against the shared in-memory store.
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

  func testAddingSame() {
    let first = historyItem("foo")
    first.title = "xyz"
    first.application = "iTerm.app"
    let firstDecorator = history.add(first)
    first.pin = "f"

    let secondDecorator = history.add(historyItem("bar"))

    let third = historyItem("foo")
    third.application = "Xcode.app"
    history.add(third)

    XCTAssertEqual(history.items.count, 2)
    XCTAssertEqual(history.items[1], secondDecorator)
    XCTAssertNotEqual(history.items[0], firstDecorator)
    XCTAssertTrue(history.items[0].item.lastCopiedAt > history.items[0].item.firstCopiedAt)
    // TODO: This works in reality but fails in tests?!
    // XCTAssertEqual(history.items[0].item.numberOfCopies, 2)
    XCTAssertEqual(history.items[0].item.pin, "f")
    XCTAssertEqual(history.items[0].item.title, "xyz")
    XCTAssertEqual(history.items[0].item.application, "iTerm.app")
  }

  func testAddingItemThatIsSupersededByExisting() {
    let firstContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)!
      ),
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.rtf.rawValue,
        value: "two".data(using: .utf8)!
      )
    ]
    let firstItem = HistoryItem()
    Storage.shared.context.insert(firstItem)
    firstItem.application = "Maccy.app"
    firstItem.contents = firstContents
    firstItem.title = firstItem.generateTitle()
    history.add(firstItem)

    let secondContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)!
      )
    ]
    let secondItem = HistoryItem()
    Storage.shared.context.insert(secondItem)
    secondItem.application = "Maccy.app"
    secondItem.contents = secondContents
    secondItem.title = secondItem.generateTitle()
    let second = history.add(secondItem)

    XCTAssertEqual(history.items, [second])
    assertContents(history.items[0].item.contents, equalTo: firstContents)
  }

  func testAddingItemWithDifferentModifiedType() {
    let firstContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)!
      ),
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.modified.rawValue,
        value: "1".data(using: .utf8)!
      )
    ]
    let firstItem = HistoryItem()
    Storage.shared.context.insert(firstItem)
    firstItem.contents = firstContents
    history.add(firstItem)

    let secondContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)!
      ),
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.modified.rawValue,
        value: "2".data(using: .utf8)!
      )
    ]
    let secondItem = HistoryItem()
    Storage.shared.context.insert(secondItem)
    secondItem.contents = secondContents
    let second = history.add(secondItem)

    XCTAssertEqual(history.items, [second])
    assertContents(history.items[0].item.contents, equalTo: firstContents)
  }

  func testAddingItemFromMaccy() {
    let firstContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)
      )
    ]
    let first = HistoryItem()
    Storage.shared.context.insert(first)
    first.application = "Xcode.app"
    first.contents = firstContents
    history.add(first)

    let secondContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)
      ),
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.fromMaccy.rawValue,
        value: "".data(using: .utf8)
      )
    ]
    let second = HistoryItem()
    Storage.shared.context.insert(second)
    second.application = "Maccy.app"
    second.contents = secondContents
    let secondDecorator = history.add(second)

    XCTAssertEqual(history.items, [secondDecorator])
    XCTAssertEqual(history.items[0].item.application, "Xcode.app")
    assertContents(history.items[0].item.contents, equalTo: firstContents)
  }

  func testModifiedAfterCopying() {
    history.add(historyItem("foo"))

    let modifiedItem = historyItem("bar")
    modifiedItem.contents.append(HistoryItemContent(
      type: NSPasteboard.PasteboardType.modified.rawValue,
      value: String(Clipboard.shared.changeCount).data(using: .utf8)
    ))
    let modifiedItemDecorator = history.add(modifiedItem)

    XCTAssertEqual(history.items, [modifiedItemDecorator])
    XCTAssertEqual(history.items[0].text, "bar")
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

  func testMaxSize() {
    var items: [HistoryItemDecorator] = []
    for index in 0...10 {
      items.append(history.add(historyItem(String(index))))
    }

    XCTAssertEqual(history.items.count, 10)
    XCTAssertTrue(history.items.contains(items[10]))
    XCTAssertFalse(history.items.contains(items[0]))
  }

  func testMaxSizeIgnoresPinned() {
    var items: [HistoryItemDecorator] = []

    let item = history.add(historyItem("0"))
    items.append(item)
    item.togglePin()

    for index in 1...11 {
      items.append(history.add(historyItem(String(index))))
    }

    XCTAssertEqual(history.items.count, 11)
    XCTAssertTrue(history.items.contains(items[10]))
    XCTAssertTrue(history.items.contains(items[0]))
    XCTAssertFalse(history.items.contains(items[1]))
  }

  func testMaxSizeIsChanged() {
    var items: [HistoryItemDecorator] = []
    for index in 0...10 {
      items.append(history.add(historyItem(String(index))))
    }
    Defaults[.size] = 5
    history.add(historyItem("11"))

    XCTAssertEqual(history.items.count, 5)
    XCTAssertTrue(history.items.contains(items[10]))
    XCTAssertFalse(history.items.contains(items[5]))
  }

  func testInvalidMaxSizeFallsBackToOne() {
    Defaults[.size] = 0

    let first = history.add(historyItem("foo"))
    let second = history.add(historyItem("bar"))

    XCTAssertEqual(history.items, [second])
    XCTAssertFalse(history.items.contains(first))
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

  func testHistoryCommandServiceUsesFullHistoryWhileItemsAreFiltered() throws {
    let older = try HistoryTestDriver.seed(historyItem("older"), in: history)
    let newer = try HistoryTestDriver.seed(historyItem("newer"), in: history)
    history.items = [older]
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

  /// Builds a single-string-content `HistoryItem` inserted into the shared context, with title derived from its content.
  private func historyItem(_ value: String) -> HistoryItem {
    let contents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: value.data(using: .utf8)
      )
    ]
    let item = HistoryItem()
    item.contents = contents
    item.numberOfCopies = 1
    item.title = item.generateTitle()

    return item
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

private extension HistoryTests {
  /// Asserts two content arrays match element-for-element (type and value), ignoring order.
  func assertContents(_ actual: [HistoryItemContent], equalTo expected: [HistoryItemContent]) {
    XCTAssertEqual(actual.count, expected.count)

    for expectedContent in expected {
      XCTAssertTrue(actual.contains {
        $0.type == expectedContent.type && $0.value == expectedContent.value
      })
    }
  }
}
