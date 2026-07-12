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
    let history = History(persistence: persistence, logsPersistenceErrors: false)
    let existing = decorator(item(title: "existing"))
    history.all = [existing]

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
    let history = History(persistence: persistence, logsPersistenceErrors: false)
    history.all = [decorator(duplicate)]

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
    let history = History(persistence: persistence, logsPersistenceErrors: false)
    history.all = [existing]

    history.consume(.cleared)

    XCTAssertEqual(persistence.fetchAllCalls, 1)
    XCTAssertTrue(history.all.first === existing)
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
    let history = History(persistence: persistence, logsPersistenceErrors: false)
    let ingestor = IngestorSpy()
    let savedIngestor = Clipboard.shared.ingestor
    Clipboard.shared.ingestor = ingestor
    defer { Clipboard.shared.ingestor = savedIngestor }

    try await history.load()
    let eventBatches = await waitForStoreEvents(in: ingestor, count: 2)

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

  private func waitForStoreEvents(
    in ingestor: IngestorSpy,
    count: Int
  ) async -> [[StoreEvent]] {
    for _ in 0..<100 {
      if await ingestor.storeEvents.count >= count {
        return await ingestor.storeEventBatches
      }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return await ingestor.storeEventBatches
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
