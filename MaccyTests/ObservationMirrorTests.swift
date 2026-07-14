import Foundation
import SwiftData
import XCTest
@testable import Maccy

/// Locks explicit one-way observation projections that must not lose a rapid
/// final update after the recursive `withObservationTracking` relays are gone.
@MainActor
final class ObservationMirrorTests: XCTestCase {
  func testMenuIconProjectionPublishesFinalValueAfterRapidListChanges() {
    let listState = HistoryListState()
    let history = History(
      persistence: ObservationPersistence(),
      listState: listState,
      logsPersistenceErrors: false
    )
    let appState = AppState(history: history, footer: Footer())
    var projected: [String] = []
    appState.configureMenuIconTextSink { projected.append($0) }

    for index in 0..<100 {
      let item = HistoryBuilder()
        .withContent(
          type: "public.utf8-plain-text",
          value: Data("copy-\(index)".utf8)
        )
        .build()
      listState.replaceAll([HistoryItemDecorator(item)])
    }

    XCTAssertEqual(appState.menuIconText, "copy-99")
    XCTAssertEqual(projected.last, "copy-99")
    XCTAssertEqual(projected.count, 101)
  }
}

@MainActor
private final class ObservationPersistence: HistoryPersistence {
  func delete(_ item: HistoryItem) throws {}
  func delete(_ items: [HistoryItem]) throws {}
  func deleteUnpinned() throws {}
  func deleteAll() throws {}
  func save() throws {}
  func fetchAll() throws -> [HistoryItem] { [] }
  func model(for id: PersistentIdentifier) -> HistoryItem? { nil }
  func countHistoryItems() throws -> Int { 0 }
  func countHistoryItemContents() throws -> Int { 0 }
}
