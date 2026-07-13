import Foundation
import Observation
import SwiftData
import XCTest
@testable import Maccy

/// Defines the structural-mutation boundary that replaces History's direct
/// writes to its `all` and `items` arrays.
@MainActor
final class HistoryListStateTests: XCTestCase {
  func testStructuralMutationsInvokeHookExactlyOnce() {
    var mutationCount = 0
    let state = HistoryListState(willMutate: { mutationCount += 1 })
    let first = decorator("first")
    let second = decorator("second")

    state.replaceAll([first])
    XCTAssertEqual(mutationCount, 1)

    state.insert(second, at: 1)
    XCTAssertEqual(mutationCount, 2)

    XCTAssertTrue(state.remove(second))
    XCTAssertEqual(mutationCount, 3)

    XCTAssertEqual(state.removeStoredIDs([first.item.persistentModelID]), [first])
    XCTAssertEqual(mutationCount, 4)
  }

  func testPublishingVisibleItemsDoesNotInvokeStructuralHook() {
    var mutationCount = 0
    let state = HistoryListState(willMutate: { mutationCount += 1 })
    let visible = decorator("visible")

    state.publishVisible([visible])

    XCTAssertEqual(state.items, [visible])
    XCTAssertTrue(state.all.isEmpty)
    XCTAssertEqual(mutationCount, 0)
  }

  func testStoredIDRemovalReturnsOnlyRemovedDecorators() {
    let first = decorator("first")
    let second = decorator("second")
    let survivor = decorator("survivor")
    let state = HistoryListState(willMutate: {})
    state.replaceAll([first, survivor, second])

    let removed = state.removeStoredIDs([
      first.item.persistentModelID,
      second.item.persistentModelID
    ])

    XCTAssertEqual(removed, [first, second])
    XCTAssertEqual(state.all, [survivor])
    XCTAssertEqual(state.items, [survivor])
  }

  func testHistoryObservationTracksNestedVisiblePublication() async {
    let state = HistoryListState(willMutate: {})
    let history = History(
      persistence: SwiftDataHistoryPersistence(context: Storage.shared.context),
      listState: state,
      logsPersistenceErrors: false
    )
    let probe = ObservationChangeProbe()

    withObservationTracking {
      _ = history.items
    } onChange: {
      Task { @MainActor in
        probe.markChanged()
      }
    }

    state.publishVisible([decorator("observed")])
    await Task.yield()

    XCTAssertTrue(probe.didChange)
  }

  private func decorator(_ text: String) -> HistoryItemDecorator {
    HistoryItemDecorator(
      HistoryBuilder()
        .withContent(type: "public.utf8-plain-text", value: Data(text.utf8))
        .build()
    )
  }
}

@MainActor
private final class ObservationChangeProbe {
  private(set) var didChange = false

  func markChanged() {
    didChange = true
  }
}
