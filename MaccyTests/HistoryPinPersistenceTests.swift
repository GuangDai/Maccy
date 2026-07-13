import Defaults
import SwiftData
import XCTest
@testable import Maccy

/// Verifies that pinning an item survives a clear-unpinned operation, both in memory and in the committed store.
@MainActor
final class HistoryPinPersistenceTests: XCTestCase {
  private let history = History.shared
  private let savedSize = Defaults[.size]
  private let savedSortBy = Defaults[.sortBy]

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

  /// A pinned item persists across `clear()` (which removes only unpinned items), and its pin value round-trips through the committed store.
  func testClearingUnpinnedAfterPinPersistsPinnedItem() throws {
    let pinned = try HistoryTestDriver.seed(historyItem("foo"), in: history)
    _ = try HistoryTestDriver.seed(historyItem("bar"), in: history)

    history.togglePin(pinned)
    let pin = pinned.item.pin
    history.clear()

    XCTAssertEqual(history.items, [pinned])
    XCTAssertEqual(pinned.item.pin, pin)

    let stored = (try? Storage.shared.context.fetch(FetchDescriptor<HistoryItem>())) ?? []
    XCTAssertEqual(stored.map(\.title), ["foo"])
    XCTAssertEqual(stored.first?.pin, pin)
  }

  /// Predicate deletion must include inserts that are pending on the main
  /// context: remove the unpinned row while preserving the pending pinned row.
  func testDeleteUnpinnedHandlesPendingInserts() throws {
    let unpinned = historyItem("pending-unpinned")
    let pinned = historyItem("pending-pinned")
    Storage.shared.context.insert(unpinned)
    Storage.shared.context.insert(pinned)
    pinned.pin = "a"
    XCTAssertTrue(Storage.shared.context.hasChanges)

    try SwiftDataHistoryPersistence(context: Storage.shared.context).deleteUnpinned()

    let stored = try Storage.shared.context.fetch(FetchDescriptor<HistoryItem>())
    XCTAssertEqual(stored.map(\.title), ["pending-pinned"])
    XCTAssertEqual(stored.first?.pin, "a")
  }

  /// Persistence operations target the context supplied at construction,
  /// not global storage.
  func testPersistenceUsesInjectedContext() throws {
    let isolatedStorage = Storage(storedInMemoryForTesting: true)
    let context = isolatedStorage.context
    context.insert(historyItem("isolated"))
    try context.save()

    try SwiftDataHistoryPersistence(context: context).deleteAll()

    XCTAssertEqual(try context.fetchCount(FetchDescriptor<HistoryItem>()), 0)
  }

  /// Pin availability is queried through the caller-provided context and excludes assigned keys.
  func testPinServiceExcludesAssignedPins() throws {
    let assigned = historyItem("assigned")
    Storage.shared.context.insert(assigned)
    assigned.pin = "b"
    try Storage.shared.context.save()

    let service = PinService(context: Storage.shared.context)

    XCTAssertEqual(Set(service.availablePins), PinService.supportedPins.subtracting(["b"]))
  }

  /// With every supported key but one assigned, random selection returns the sole free key.
  func testPinServiceReturnsOnlyRemainingPin() throws {
    let expected = try XCTUnwrap(PinService.supportedPins.sorted().first)
    for pin in PinService.supportedPins.subtracting([expected]) {
      let assigned = historyItem("assigned-\(pin)")
      Storage.shared.context.insert(assigned)
      assigned.pin = pin
    }
    try Storage.shared.context.save()

    let service = PinService(context: Storage.shared.context)

    XCTAssertEqual(service.availablePins, [expected])
    XCTAssertEqual(service.randomAvailablePin, expected)
  }

  /// Builds a single-string-content `HistoryItem` inserted into the shared context, with title derived from its content.
  private func historyItem(_ value: String) -> HistoryItem {
    let item = HistoryItem()
    item.contents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: value.data(using: .utf8)
      )
    ]
    item.numberOfCopies = 1
    item.title = item.generateTitle()
    return item
  }
}
