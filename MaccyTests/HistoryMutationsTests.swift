import AppKit.NSEvent
import Defaults
import Foundation
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
    XCTAssertEqual(harness.errors.first?.0, "Failed to clear history")
  }

  func testClearKeepsPinsAndPublishesExactRemoval() async {
    let pinned = decorator(item(title: "pinned", pin: "p"))
    let unpinned = decorator(item(title: "unpinned"))
    let removedID = storedItemID(for: unpinned.item)
    let harness = makeHarness([pinned, unpinned])

    harness.subject.clear()
    let removedCorpusIDs = await waitForRemovedCorpus(in: harness.backend)
    let effects = await waitForEffects(in: harness, count: 2)

    XCTAssertEqual(harness.persistence.deleteUnpinnedCalls, 1)
    XCTAssertEqual(harness.listState.all, [pinned])
    XCTAssertEqual(removedCorpusIDs, [unpinned.id])
    XCTAssertEqual(harness.storeEvents, [.removed(removedID)])
    XCTAssertEqual(harness.clipboard.clearCalls, 1)
    XCTAssertEqual(effectNames(effects), ["closePopup", "resizePopup"])
  }

  func testClearAllDrainsProjectionCorpusAndIndex() async {
    let first = decorator(item(title: "first"))
    let second = decorator(item(title: "second", pin: "p"))
    let harness = makeHarness([first, second])

    harness.subject.clearAll()
    let clearCorpusCalls = await waitForClearCorpus(in: harness.backend)
    let effects = await waitForEffects(in: harness, count: 2)

    XCTAssertEqual(harness.persistence.deleteAllCalls, 1)
    XCTAssertEqual(harness.listState.all, [])
    XCTAssertEqual(clearCorpusCalls, 1)
    XCTAssertEqual(harness.storeEvents, [.cleared])
    XCTAssertEqual(harness.clipboard.clearCalls, 1)
    XCTAssertEqual(effectNames(effects), ["closePopup", "resizePopup"])
  }

  func testDeleteFailurePreservesProjectionAndEmitsNoEffects() async {
    let target = decorator(item(title: "target"))
    let harness = makeHarness([target])
    harness.persistence.deleteError = MutationTestError.expected

    harness.subject.delete(target)
    try? await Task.sleep(for: .milliseconds(20))
    let removedCorpusIDs = await harness.backend.removedIDs

    XCTAssertEqual(harness.persistence.deletedItems.count, 1)
    XCTAssertTrue(harness.persistence.deletedItems.first === target.item)
    XCTAssertEqual(harness.listState.all, [target])
    XCTAssertEqual(removedCorpusIDs, [])
    XCTAssertEqual(harness.storeEvents, [])
    XCTAssertTrue(harness.effects.isEmpty)
    XCTAssertEqual(harness.errors.first?.0, "Failed to delete history item")
  }

  func testDeleteRemovesProjectionCorpusAndIndexAfterCommit() async {
    let survivor = decorator(item(title: "survivor"))
    let target = decorator(item(title: "target"))
    let removedStoreID = storedItemID(for: target.item)
    let harness = makeHarness([survivor, target])

    harness.subject.delete(target)
    let removedCorpusIDs = await waitForRemovedCorpus(in: harness.backend)
    let effects = await waitForEffects(in: harness, count: 1)

    XCTAssertEqual(harness.persistence.deletedItems.count, 1)
    XCTAssertTrue(harness.persistence.deletedItems.first === target.item)
    XCTAssertEqual(harness.listState.all, [survivor])
    XCTAssertEqual(removedCorpusIDs, [target.id])
    XCTAssertEqual(harness.storeEvents, [.removed(removedStoreID)])
    XCTAssertEqual(harness.clipboard.clearCalls, 0)
    XCTAssertEqual(effectNames(effects), ["resizePopup"])
    XCTAssertTrue(harness.errors.isEmpty)
  }

  func testSelectWithoutModifiersUsesDefaultCopyAndPastePolicy() async {
    let savedPasteByDefault = Defaults[.pasteByDefault]
    let savedRemoveFormatting = Defaults[.removeFormattingByDefault]
    defer {
      Defaults[.pasteByDefault] = savedPasteByDefault
      Defaults[.removeFormattingByDefault] = savedRemoveFormatting
    }
    Defaults[.pasteByDefault] = true
    Defaults[.removeFormattingByDefault] = true
    let selected = decorator(item(title: "selected"))
    let harness = makeHarness([selected])
    harness.searchSession.query = "needle"

    harness.subject.select(selected)
    await waitForEmptyQuery(in: harness.searchSession)

    assertSingleCopy(in: harness, item: selected.item, removeFormatting: true)
    XCTAssertEqual(harness.clipboard.pasteCalls, 1)
    XCTAssertEqual(effectNames(harness.effects), ["closePopup"])
    XCTAssertEqual(harness.searchSession.query, "")
  }

  func testSelectMapsModifierActionsToClipboardCommands() async {
    let savedPasteByDefault = Defaults[.pasteByDefault]
    let savedRemoveFormatting = Defaults[.removeFormattingByDefault]
    defer {
      Defaults[.pasteByDefault] = savedPasteByDefault
      Defaults[.removeFormattingByDefault] = savedRemoveFormatting
    }
    Defaults[.pasteByDefault] = false
    Defaults[.removeFormattingByDefault] = false
    let scenarios = [
      MutationSelectScenario(flags: .command, removeFormatting: false, pasteCalls: 0),
      MutationSelectScenario(flags: .option, removeFormatting: false, pasteCalls: 1),
      MutationSelectScenario(flags: [.option, .shift], removeFormatting: true, pasteCalls: 1)
    ]

    for scenario in scenarios {
      let selected = decorator(item(title: "selected"))
      let harness = makeHarness([selected], modifierFlags: scenario.flags)
      harness.searchSession.query = "needle"

      harness.subject.select(selected)
      await waitForEmptyQuery(in: harness.searchSession)

      assertSingleCopy(in: harness, item: selected.item, removeFormatting: scenario.removeFormatting)
      XCTAssertEqual(harness.clipboard.pasteCalls, scenario.pasteCalls)
      XCTAssertEqual(effectNames(harness.effects), ["closePopup"])
      XCTAssertEqual(harness.searchSession.query, "")
    }
  }

  func testSelectWithUnknownModifiersHasNoSideEffects() async {
    let selected = decorator(item(title: "selected"))
    let harness = makeHarness([selected], modifierFlags: .control)
    harness.searchSession.query = "needle"

    harness.subject.select(selected)
    try? await Task.sleep(for: .milliseconds(20))

    XCTAssertTrue(harness.clipboard.copies.isEmpty)
    XCTAssertEqual(harness.clipboard.pasteCalls, 0)
    XCTAssertTrue(harness.effects.isEmpty)
    XCTAssertEqual(harness.searchSession.query, "needle")
  }

  func testTogglePinFailureRestoresOldPinWithoutProjectionEffects() async {
    let target = decorator(item(title: "target", pin: "p"))
    let harness = makeHarness([target])
    harness.persistence.saveError = MutationTestError.expected
    harness.searchSession.query = "needle"

    harness.subject.togglePin(target)
    try? await Task.sleep(for: .milliseconds(20))
    let removedCorpusIDs = await harness.backend.removedIDs

    XCTAssertEqual(harness.persistence.saveCalls, 1)
    XCTAssertEqual(target.item.pin, "p")
    XCTAssertEqual(harness.listState.all, [target])
    XCTAssertEqual(removedCorpusIDs, [])
    XCTAssertTrue(harness.effects.isEmpty)
    XCTAssertEqual(harness.searchSession.query, "needle")
    XCTAssertEqual(harness.errors.first?.0, "Failed to save pinned history item")
  }

  func testTogglePinSuccessMovesCorpusClearsQueryAndScrollsToUnpinnedItem() async {
    let target = decorator(item(title: "target", pin: "p"))
    let harness = makeHarness([target])
    harness.searchSession.query = "needle"

    harness.subject.togglePin(target)
    let corpusMove = await waitForCorpusMove(in: harness.backend)

    XCTAssertEqual(harness.persistence.saveCalls, 1)
    XCTAssertNil(target.item.pin)
    XCTAssertEqual(harness.listState.all, [target])
    XCTAssertEqual(corpusMove.removed, [target.id])
    XCTAssertEqual(corpusMove.inserted.map(\.id), [target.id])
    XCTAssertEqual(corpusMove.inserted.map(\.position), [0])
    XCTAssertEqual(harness.searchSession.query, "")
    XCTAssertEqual(scrollTargets(harness.effects), [target.id])
    XCTAssertTrue(harness.errors.isEmpty)
  }

  private func makeHarness(
    _ decorators: [HistoryItemDecorator],
    modifierFlags: NSEvent.ModifierFlags = []
  ) -> MutationHarness {
    MutationHarness(decorators: decorators, modifierFlags: modifierFlags)
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

  private func waitForEffects(
    in harness: MutationHarness,
    count: Int
  ) async -> [HistoryUIEffect] {
    for _ in 0..<100 {
      if harness.effects.count >= count { return harness.effects }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return harness.effects
  }

  private func waitForEmptyQuery(in searchSession: HistorySearchSession) async {
    for _ in 0..<100 {
      if searchSession.query.isEmpty { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  private func assertSingleCopy(
    in harness: MutationHarness,
    item: HistoryItem,
    removeFormatting: Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(harness.clipboard.copies.count, 1, file: file, line: line)
    XCTAssertTrue(harness.clipboard.copies.first?.0 === item, file: file, line: line)
    XCTAssertEqual(harness.clipboard.copies.first?.1, removeFormatting, file: file, line: line)
  }

  private func waitForCorpusMove(
    in backend: MutationSearchBackend
  ) async -> (removed: [UUID], inserted: [MutationCorpusInsert]) {
    for _ in 0..<100 {
      let removed = await backend.removedIDs
      let inserted = await backend.inserted
      if !removed.isEmpty, !inserted.isEmpty { return (removed, inserted) }
      try? await Task.sleep(for: .milliseconds(5))
    }
    let removed = await backend.removedIDs
    let inserted = await backend.inserted
    return (removed, inserted)
  }

  private func scrollTargets(_ effects: [HistoryUIEffect]) -> [UUID] {
    effects.compactMap { effect in
      guard case .scrollTo(let id) = effect else { return nil }
      return id
    }
  }
}

private enum MutationTestError: Error {
  case expected
}

private struct MutationSelectScenario {
  let flags: NSEvent.ModifierFlags
  let removeFormatting: Bool
  let pasteCalls: Int
}

@MainActor
private final class MutationHarness {
  let persistence: MutationPersistence
  let listState: HistoryListState
  let backend: MutationSearchBackend
  let clipboard: MutationClipboardRecorder
  let searchSession: HistorySearchSession
  let subject: HistoryMutations
  var effects: [HistoryUIEffect] = []
  var storeEvents: [StoreEvent] = []
  var errors: [(String, Error)] = []

  init(
    decorators: [HistoryItemDecorator],
    modifierFlags: NSEvent.ModifierFlags
  ) {
    let persistence = MutationPersistence()
    let listState = HistoryListState(decorators: decorators)
    let backend = MutationSearchBackend()
    let clipboard = MutationClipboardRecorder()
    self.persistence = persistence
    self.listState = listState
    self.backend = backend
    self.clipboard = clipboard
    let searchSession = HistorySearchSession(
      listState: listState,
      backend: backend,
      debounce: nil
    )
    self.searchSession = searchSession
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
      modifierFlags: { modifierFlags },
      log: { _ in }
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
  var deleteError: Error?
  var deleteUnpinnedError: Error?
  var saveError: Error?
  private(set) var deletedItems: [HistoryItem] = []
  private(set) var deleteUnpinnedCalls = 0
  private(set) var deleteAllCalls = 0
  private(set) var saveCalls = 0

  func delete(_ item: HistoryItem) throws {
    deletedItems.append(item)
    if let deleteError { throw deleteError }
  }
  func delete(_ items: [HistoryItem]) throws {}

  func deleteUnpinned() throws {
    deleteUnpinnedCalls += 1
    if let deleteUnpinnedError { throw deleteUnpinnedError }
  }

  func deleteAll() throws {
    deleteAllCalls += 1
  }

  func save() throws {
    saveCalls += 1
    if let saveError { throw saveError }
  }
  func fetchAll() throws -> [HistoryItem] { [] }
  func model(for id: PersistentIdentifier) -> HistoryItem? { nil }
  func countHistoryItems() throws -> Int { 0 }
  func countHistoryItemContents() throws -> Int { 0 }
}

private struct MutationCorpusInsert: Sendable {
  let id: UUID
  let position: Int
}

private actor MutationSearchBackend: HistorySearchBackend {
  private(set) var removedIDs: [UUID] = []
  private(set) var inserted: [MutationCorpusInsert] = []
  private(set) var clearCorpusCalls = 0

  func search(query: String, mode: Search.Mode) async -> [SearchMatchDTO] { [] }
  func replaceCorpus(_ entries: [SearchCorpusItem]) async {}
  func insert(_ entry: SearchCorpusItem, at position: Int) async {
    inserted.append(MutationCorpusInsert(id: entry.id, position: position))
  }
  func remove(_ ids: [UUID]) async { removedIDs.append(contentsOf: ids) }
  func clearCorpus() async { clearCorpusCalls += 1 }
}
