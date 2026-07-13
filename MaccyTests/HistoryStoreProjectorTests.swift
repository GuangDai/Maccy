import Defaults
import Foundation
import SwiftData
import XCTest
@testable import Maccy

/// Defines the fake-backed store projection seam before projection leaves the
/// History facade. No test here relies on Storage.shared for reads.
@MainActor
final class HistoryStoreProjectorTests: XCTestCase {
  override func setUp() async throws {
    try await super.setUp()
    History.shared.clearAll()
  }

  override func tearDown() async throws {
    History.shared.clearAll()
    try await super.tearDown()
  }

  func testLoadFailurePreservesOldListAndRecordsError() async {
    let persistence = RecordingProjectorPersistence()
    persistence.fetchError = ProjectorTestError.expected
    let existing = decorator(item(title: "existing"))
    let listState = HistoryListState(decorators: [existing])
    let history = History(
      persistence: persistence,
      listState: listState,
      logsPersistenceErrors: false
    )

    await history.loadAndRecordError()

    XCTAssertEqual(history.all, [existing])
    XCTAssertNotNil(history.lastPersistError)
    XCTAssertEqual(persistence.fetchAllCalls, 1)
  }

  func testModelMissFallsBackToInjectedFetch() {
    let persistence = RecordingProjectorPersistence()
    let fallback = item(title: "fallback")
    persistence.fetchedItems = [fallback]
    let history = History(persistence: persistence, logsPersistenceErrors: false)
    let missing = item(title: "missing")

    history.consume(.added(snapshot(of: missing)))

    XCTAssertEqual(persistence.modelCalls, [missing.persistentModelID])
    XCTAssertEqual(persistence.fetchAllCalls, 1)
    XCTAssertEqual(history.all.map(\.title), ["fallback"])
  }

  func testMergedEventRemovesActorReportedDuplicateID() {
    let persistence = RecordingProjectorPersistence()
    let duplicate = item(title: "duplicate")
    let survivor = item(title: "survivor")
    persistence.models[survivor.persistentModelID] = survivor
    let listState = HistoryListState(decorators: [decorator(duplicate)])
    let history = History(
      persistence: persistence,
      listState: listState,
      logsPersistenceErrors: false
    )

    history.consume(
      .merged(snapshot(of: survivor)),
      trimmedPersistentIDs: [duplicate.persistentModelID]
    )

    XCTAssertEqual(history.all.count, 1)
    XCTAssertTrue(history.all.first?.item === survivor)
  }

  func testReconcileReusesDecoratorByPersistentIdentity() {
    let persistence = RecordingProjectorPersistence()
    let stored = item(title: "stored")
    persistence.fetchedItems = [stored]
    let existing = decorator(stored)
    let listState = HistoryListState(decorators: [existing])
    let history = History(
      persistence: persistence,
      listState: listState,
      logsPersistenceErrors: false
    )

    history.consume(.cleared)

    XCTAssertEqual(persistence.fetchAllCalls, 1)
    XCTAssertTrue(history.all.first === existing)
  }

  func testSortDefaultChangeResortsExistingProjectionWithoutFetchingStore() async throws {
    let savedSortBy = Defaults[.sortBy]
    defer { Defaults[.sortBy] = savedSortBy }
    Defaults[.sortBy] = .lastCopiedAt

    let firstCopiedNewest = item(title: "first-newest")
    firstCopiedNewest.firstCopiedAt = Date(timeIntervalSince1970: 300)
    firstCopiedNewest.lastCopiedAt = Date(timeIntervalSince1970: 100)
    let lastCopiedNewest = item(title: "last-newest")
    lastCopiedNewest.firstCopiedAt = Date(timeIntervalSince1970: 100)
    lastCopiedNewest.lastCopiedAt = Date(timeIntervalSince1970: 300)
    let firstDecorator = decorator(firstCopiedNewest)
    let lastDecorator = decorator(lastCopiedNewest)
    let persistence = RecordingProjectorPersistence()
    let listState = HistoryListState(decorators: [lastDecorator, firstDecorator])
    let history = History(
      persistence: persistence,
      listState: listState,
      logsPersistenceErrors: false
    )
    await Task.yield()

    Defaults[.sortBy] = .firstCopiedAt
    try await Task.sleep(for: .milliseconds(100))

    XCTAssertEqual(history.all, [firstDecorator, lastDecorator])
    XCTAssertEqual(persistence.fetchAllCalls, 0)
  }

  func testLoadDeletesExactUnpinnedOverflowInOneBatch() async throws {
    let savedSize = Defaults[.size]
    defer { Defaults[.size] = savedSize }
    Defaults[.size] = 1

    let newest = item(title: "newest", copiedAt: 4)
    let firstOverflow = item(title: "first-overflow", copiedAt: 3)
    let secondOverflow = item(title: "second-overflow", copiedAt: 2)
    let pinned = item(title: "pinned", copiedAt: 1, pin: "p")
    let persistence = RecordingProjectorPersistence()
    persistence.fetchedItems = [secondOverflow, pinned, newest, firstOverflow]
    var eventBatches: [[StoreEvent]] = []
    let history = History(
      persistence: persistence,
      runtimeServices: HistoryRuntimeServices(
        clipboard: HistoryClipboardActions(clear: {}, copy: { _, _ in }, paste: {}),
        modifierFlags: { [] },
        currentEvent: { nil },
        publishStoreEvents: { eventBatches.append($0) },
        log: { _ in }
      ),
      logsPersistenceErrors: false
    )

    try await history.load()

    XCTAssertEqual(Set(history.all.map(\.title)), ["newest", "pinned"])
    XCTAssertEqual(
      persistence.deletedBatches.map { $0.map(\.title) },
      [["first-overflow", "second-overflow"]]
    )
    XCTAssertEqual(eventBatches, [[
      .removed(storedItemID(for: firstOverflow)),
      .removed(storedItemID(for: secondOverflow))
    ]])
  }

  private func item(
    title: String,
    copiedAt: TimeInterval = 0,
    pin: String? = nil
  ) -> HistoryItem {
    HistoryBuilder()
      .withContent(type: "public.utf8-plain-text", value: Data(title.utf8))
      .withCopiedAt(Date(timeIntervalSince1970: copiedAt))
      .withPin(pin)
      .withTitle(title)
      .build()
  }

  private func decorator(_ item: HistoryItem) -> HistoryItemDecorator {
    HistoryItemDecorator(item)
  }

}

private enum ProjectorTestError: Error {
  case expected
}

@MainActor
private final class RecordingProjectorPersistence: HistoryPersistence {
  var fetchError: Error?
  var fetchedItems: [HistoryItem] = []
  var models: [PersistentIdentifier: HistoryItem] = [:]
  private(set) var fetchAllCalls = 0
  private(set) var modelCalls: [PersistentIdentifier] = []
  private(set) var deletedBatches: [[HistoryItem]] = []

  func model(for id: PersistentIdentifier) -> HistoryItem? {
    modelCalls.append(id)
    return models[id]
  }

  func fetchAll() throws -> [HistoryItem] {
    fetchAllCalls += 1
    if let fetchError { throw fetchError }
    return fetchedItems
  }

  func delete(_ item: HistoryItem) throws {
    deletedBatches.append([item])
  }
  func delete(_ items: [HistoryItem]) throws {
    deletedBatches.append(items)
  }
  func deleteUnpinned() throws {}
  func deleteAll() throws {}
  func save() throws {}
  func countHistoryItems() throws -> Int { 0 }
  func countHistoryItemContents() throws -> Int { 0 }
}
