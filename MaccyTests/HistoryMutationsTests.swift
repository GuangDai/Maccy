import Foundation
import Logging
import SwiftData
import XCTest
@testable import Maccy

@MainActor
final class HistoryMutationsTests: XCTestCase {
  func testClearFailurePreservesProjectionAndEmitsNoEffects() {
    let pinned = decorator(item(title: "pinned", pin: "p"))
    let unpinned = decorator(item(title: "unpinned"))
    let harness = makeHarness([pinned, unpinned])
    harness.persistence.deleteUnpinnedError = MutationTestError.expected

    harness.subject.clear()

    XCTAssertEqual(harness.listState.all, [pinned, unpinned])
    XCTAssertEqual(harness.clipboard.clearCalls, 0)
    XCTAssertTrue(harness.effects.isEmpty)
    XCTAssertEqual(harness.storeEvents, [])
    XCTAssertEqual(harness.errors.count, 1)
  }

  func testClearKeepsPinsAndPublishesExactRemoval() async {
    let pinned = decorator(item(title: "pinned", pin: "p"))
    let unpinned = decorator(item(title: "unpinned"))
    let removedID = storedItemID(for: unpinned.item)
    let harness = makeHarness([pinned, unpinned])

    harness.subject.clear()
    let removedCorpusIDs = await waitForRemovedCorpus(in: harness.backend)

    XCTAssertEqual(harness.persistence.deleteUnpinnedCalls, 1)
    XCTAssertEqual(harness.listState.all, [pinned])
    XCTAssertEqual(removedCorpusIDs, [unpinned.id])
    XCTAssertEqual(harness.storeEvents, [.removed(removedID)])
    XCTAssertEqual(harness.clipboard.clearCalls, 1)
    XCTAssertEqual(effectNames(harness.effects), ["closePopup", "resizePopup"])
  }

  func testClearAllDrainsProjectionCorpusAndIndex() async {
    let first = decorator(item(title: "first"))
    let second = decorator(item(title: "second", pin: "p"))
    let harness = makeHarness([first, second])

    harness.subject.clearAll()
    let clearCorpusCalls = await waitForClearCorpus(in: harness.backend)

    XCTAssertEqual(harness.persistence.deleteAllCalls, 1)
    XCTAssertEqual(harness.listState.all, [])
    XCTAssertEqual(clearCorpusCalls, 1)
    XCTAssertEqual(harness.storeEvents, [.cleared])
    XCTAssertEqual(harness.clipboard.clearCalls, 1)
    XCTAssertEqual(effectNames(harness.effects), ["closePopup", "resizePopup"])
  }

  private func makeHarness(_ decorators: [HistoryItemDecorator]) -> MutationHarness {
    MutationHarness(decorators: decorators)
  }

  private func item(title: String, pin: String? = nil) -> HistoryItem {
    HistoryBuilder()
      .withContent(type: "public.utf8-plain-text", value: Data(title.utf8))
      .withPin(pin)
      .withTitle(title)
      .build()
  }

  private func decorator(_ item: HistoryItem) -> HistoryItemDecorator {
    HistoryItemDecorator(item)
  }

  private func waitForRemovedCorpus(in backend: MutationSearchBackend) async -> [UUID] {
    for _ in 0..<100 {
      let ids = await backend.removedIDs
      if !ids.isEmpty { return ids }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return await backend.removedIDs
  }

  private func waitForClearCorpus(in backend: MutationSearchBackend) async -> Int {
    for _ in 0..<100 {
      let calls = await backend.clearCorpusCalls
      if calls > 0 { return calls }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return await backend.clearCorpusCalls
  }

  private func effectNames(_ effects: [HistoryUIEffect]) -> [String] {
    effects.map { effect in
      switch effect {
      case .closePopup: "closePopup"
      case .resizePopup: "resizePopup"
      case .select: "select"
      case .highlightFirst: "highlightFirst"
      case .scrollTo: "scrollTo"
      }
    }
  }
}

private enum MutationTestError: Error {
  case expected
}

@MainActor
private final class MutationHarness {
  let persistence = MutationPersistence()
  let listState: HistoryListState
  let backend = MutationSearchBackend()
  let clipboard = MutationClipboardRecorder()
  let subject: HistoryMutations
  var effects: [HistoryUIEffect] = []
  var storeEvents: [StoreEvent] = []
  var errors: [(String, Error)] = []

  init(decorators: [HistoryItemDecorator]) {
    let listState = HistoryListState(decorators: decorators)
    self.listState = listState
    let searchSession = HistorySearchSession(
      listState: listState,
      backend: backend,
      debounce: nil
    )
    searchSession.replaceCorpus(decorators)
    subject = HistoryMutations(
      persistence: persistence,
      listState: listState,
      searchSession: searchSession,
      sorter: Sorter(),
      clipboard: HistoryClipboardActions(
        clear: { [clipboard] in clipboard.clearCalls += 1 },
        copy: { [clipboard] item, removeFormatting in
          clipboard.copies.append((item, removeFormatting))
        },
        paste: { [clipboard] in clipboard.pasteCalls += 1 }
      ),
      modifierFlags: { [] },
      logger: Logger(label: "HistoryMutationsTests")
    )
    subject.configureUIEffectSink { [weak self] in self?.effects.append($0) }
    subject.configureStoreEventSink { [weak self] in self?.storeEvents.append(contentsOf: $0) }
    subject.configureErrorSink { [weak self] in self?.errors.append(($0, $1)) }
  }
}

@MainActor
private final class MutationClipboardRecorder {
  var clearCalls = 0
  var copies: [(HistoryItem, Bool)] = []
  var pasteCalls = 0
}

@MainActor
private final class MutationPersistence: HistoryPersistence {
  var deleteUnpinnedError: Error?
  private(set) var deleteUnpinnedCalls = 0
  private(set) var deleteAllCalls = 0

  func delete(_ item: HistoryItem) throws {}
  func delete(_ items: [HistoryItem]) throws {}

  func deleteUnpinned() throws {
    deleteUnpinnedCalls += 1
    if let deleteUnpinnedError { throw deleteUnpinnedError }
  }

  func deleteAll() throws {
    deleteAllCalls += 1
  }

  func save() throws {}
  func fetchAll() throws -> [HistoryItem] { [] }
  func model(for id: PersistentIdentifier) -> HistoryItem? { nil }
  func countHistoryItems() throws -> Int { 0 }
  func countHistoryItemContents() throws -> Int { 0 }
}

private actor MutationSearchBackend: HistorySearchBackend {
  private(set) var removedIDs: [UUID] = []
  private(set) var clearCorpusCalls = 0

  func search(query: String, mode: Search.Mode) async -> [SearchMatchDTO] { [] }
  func replaceCorpus(_ entries: [SearchCorpusItem]) async {}
  func insert(_ entry: SearchCorpusItem, at position: Int) async {}
  func remove(_ ids: [UUID]) async { removedIDs.append(contentsOf: ids) }
  func clearCorpus() async { clearCorpusCalls += 1 }
}
