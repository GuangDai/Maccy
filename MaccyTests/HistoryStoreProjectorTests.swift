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

  private func item(title: String) -> HistoryItem {
    HistoryBuilder()
      .withContent(type: "public.utf8-plain-text", value: Data(title.utf8))
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

  func model(for id: PersistentIdentifier) -> HistoryItem? {
    modelCalls.append(id)
    return models[id]
  }

  func fetchAll() throws -> [HistoryItem] {
    fetchAllCalls += 1
    if let fetchError { throw fetchError }
    return fetchedItems
  }

  func delete(_ item: HistoryItem) throws {}
  func deleteUnpinned() throws {}
  func deleteAll() throws {}
  func save() throws {}
  func countHistoryItems() throws -> Int { 0 }
  func countHistoryItemContents() throws -> Int { 0 }
}
