import XCTest
@testable import Maccy

/// Verifies that `History` surfaces persistence errors via `lastPersistError` instead of crashing, and leaves its in-memory state untouched on failure.
@MainActor
class IngestErrorPropagationTests: XCTestCase {
  /// A failed `clear()` records the error and preserves the existing in-memory items.
  func testClearSurfacesDeleteErrorAndKeepsMemoryState() {
    let persistence = FailingHistoryPersistence()
    persistence.deleteUnpinnedError = TestPersistenceError.expected
    let history = History(persistence: persistence, logsPersistenceErrors: false)
    let item = HistoryItemDecorator(HistoryItem())
    history.all = [item]
    history.items = [item]

    history.clear()

    XCTAssertEqual(history.all, [item])
    XCTAssertEqual(history.items, [item])
    XCTAssertNotNil(history.lastPersistError)
  }
}

/// Stand-in error type used to inject deterministic failures into the fake persistence.
private enum TestPersistenceError: Error {
  case expected
}

/// A persistence double whose unpinned delete can fail deterministically.
@MainActor
private final class FailingHistoryPersistence: HistoryPersistence {
  var deleteUnpinnedError: Error?

  func delete(_ item: HistoryItem) throws {}

  func deleteUnpinned() throws {
    if let deleteUnpinnedError {
      throw deleteUnpinnedError
    }
  }

  func deleteAll() throws {}

  func save() throws {}

  func fetchAll() throws -> [HistoryItem] {
    []
  }

  func countHistoryItems() throws -> Int {
    0
  }

  func countHistoryItemContents() throws -> Int {
    0
  }
}
