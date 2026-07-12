import AppKit.NSEvent
import Defaults
import SwiftData
import XCTest
@testable import Maccy

/// Characterizes History's UI requests as outward values before AppState
/// coupling is inverted.
@MainActor
final class HistoryUIEffectTests: XCTestCase {
  private var history: History!
  private var effects: [HistoryUIEffect] = []

  override func setUp() async throws {
    try await super.setUp()
    History.shared.clearAll()
    history = History(logsPersistenceErrors: false)
    history.configureUIEffectSink { [weak self] effect in
      self?.effects.append(effect)
    }
  }

  override func tearDown() async throws {
    history.clearAll()
    history = nil
    effects = []
    try await super.tearDown()
  }

  func testConsumeRequestsSelectionAndResize() throws {
    let decorator = try HistoryTestDriver.seed(textItem("added"), in: history)

    XCTAssertTrue(effects.contains { effect in
      guard case .select(let selected) = effect else { return false }
      return selected === decorator
    })
    XCTAssertTrue(effects.contains { if case .resizePopup = $0 { true } else { false } })
  }

  func testClearRequestsCloseAndResize() async throws {
    _ = try HistoryTestDriver.seed(textItem("clear"), in: history)
    effects = []

    history.clear()
    await Task.yield()

    XCTAssertTrue(effects.contains { if case .closePopup = $0 { true } else { false } })
    XCTAssertTrue(effects.contains { if case .resizePopup = $0 { true } else { false } })
  }

  func testSearchRequestsHighlightAndResize() async throws {
    _ = try HistoryTestDriver.seed(textItem("needle"), in: history)
    effects = []

    history.searchQuery = "needle"
    try await Task.sleep(for: .milliseconds(250))
    await history.waitForInFlightSearch()

    XCTAssertTrue(effects.contains { if case .highlightFirst = $0 { true } else { false } })
    XCTAssertTrue(effects.contains { if case .resizePopup = $0 { true } else { false } })
  }

  func testUnpinRequestsScrollTarget() throws {
    let decorator = try HistoryTestDriver.seed(textItem("pin"), in: history)
    history.togglePin(decorator)
    effects = []

    history.togglePin(decorator)

    XCTAssertTrue(effects.contains { effect in
      guard case .scrollTo(let id) = effect else { return false }
      return id == decorator.id
    })
  }

  func testFacadeClearUsesInjectedClipboardAndStoreEventServices() async {
    let savedClearSystemClipboard = Defaults[.clearSystemClipboard]
    let savedIngestor = Clipboard.shared.ingestor
    defer {
      Defaults[.clearSystemClipboard] = savedClearSystemClipboard
      Clipboard.shared.ingestor = savedIngestor
    }
    Defaults[.clearSystemClipboard] = false
    Clipboard.shared.ingestor = nil

    let item = textItem("clear-injected")
    let decorator = HistoryItemDecorator(item)
    let listState = HistoryListState(decorators: [decorator])
    let persistence = RuntimeServicesPersistence()
    var clearCalls = 0
    var storeEvents: [StoreEvent] = []
    let history = History(
      persistence: persistence,
      listState: listState,
      runtimeServices: HistoryRuntimeServices(
        clipboard: HistoryClipboardActions(
          clear: { clearCalls += 1 },
          copy: { _, _ in },
          paste: {}
        ),
        modifierFlags: { [] },
        currentEvent: { nil },
        publishStoreEvents: { storeEvents.append(contentsOf: $0) },
        log: { _ in }
      ),
      logsPersistenceErrors: false
    )

    history.clear()
    await Task.yield()

    XCTAssertEqual(clearCalls, 1)
    XCTAssertEqual(storeEvents, [.removed(storedItemID(for: item))])
  }

  func testFacadeSelectUsesInjectedClipboardAndModifierServices() async {
    let savedPasteByDefault = Defaults[.pasteByDefault]
    let savedRemoveFormatting = Defaults[.removeFormattingByDefault]
    let savedIgnoreEvents = Defaults[.ignoreEvents]
    let savedIgnoreOnlyNextEvent = Defaults[.ignoreOnlyNextEvent]
    let savedIngestor = Clipboard.shared.ingestor
    defer {
      Defaults[.pasteByDefault] = savedPasteByDefault
      Defaults[.removeFormattingByDefault] = savedRemoveFormatting
      Defaults[.ignoreEvents] = savedIgnoreEvents
      Defaults[.ignoreOnlyNextEvent] = savedIgnoreOnlyNextEvent
      Clipboard.shared.ingestor = savedIngestor
    }
    Defaults[.pasteByDefault] = false
    Defaults[.removeFormattingByDefault] = false
    Defaults[.ignoreEvents] = true
    Defaults[.ignoreOnlyNextEvent] = false
    Clipboard.shared.ingestor = nil
    let item = textItem("select-injected")
    let decorator = HistoryItemDecorator(item)
    let listState = HistoryListState(decorators: [decorator])
    var copiedItem: HistoryItem?
    var copiedWithoutFormatting = true
    var pasteCalls = 0
    let history = History(
      persistence: RuntimeServicesPersistence(),
      listState: listState,
      runtimeServices: HistoryRuntimeServices(
        clipboard: HistoryClipboardActions(
          clear: {},
          copy: {
            copiedItem = $0
            copiedWithoutFormatting = $1
          },
          paste: { pasteCalls += 1 }
        ),
        modifierFlags: { .option },
        currentEvent: { nil },
        publishStoreEvents: { _ in },
        log: { _ in }
      ),
      logsPersistenceErrors: false
    )

    history.select(decorator)
    await Task.yield()

    XCTAssertTrue(copiedItem === item)
    XCTAssertFalse(copiedWithoutFormatting)
    XCTAssertEqual(pasteCalls, 1)
  }

  private func textItem(_ text: String) -> HistoryItem {
    HistoryBuilder()
      .withContent(type: "public.utf8-plain-text", value: Data(text.utf8))
      .build()
  }
}

@MainActor
final class AppStateRuntimeServicesTests: XCTestCase {
  func testEmptySelectionCopiesSearchThroughInjectedRuntimeService() async {
    let savedIgnoreEvents = Defaults[.ignoreEvents]
    let savedIgnoreOnlyNextEvent = Defaults[.ignoreOnlyNextEvent]
    let savedIngestor = Clipboard.shared.ingestor
    defer {
      Defaults[.ignoreEvents] = savedIgnoreEvents
      Defaults[.ignoreOnlyNextEvent] = savedIgnoreOnlyNextEvent
      Clipboard.shared.ingestor = savedIngestor
    }
    Defaults[.ignoreEvents] = true
    Defaults[.ignoreOnlyNextEvent] = false
    Clipboard.shared.ingestor = nil

    let history = History(
      persistence: RuntimeServicesPersistence(),
      logsPersistenceErrors: false
    )
    var copiedText: [String] = []
    let appState = AppState(
      history: history,
      footer: Footer(),
      runtimeServices: AppStateRuntimeServices(
        copyText: { copiedText.append($0) },
        readStorageSize: { "" }
      )
    )
    history.searchQuery = "copy injected query"

    appState.select()
    await Task.yield()

    XCTAssertEqual(copiedText, ["copy injected query"])
    XCTAssertEqual(history.searchQuery, "")
  }

  func testPrewarmUsesTheAppStatesInjectedHistory() async {
    let persistence = RuntimeServicesPersistence()
    let history = History(
      persistence: persistence,
      logsPersistenceErrors: false
    )
    let appState = AppState(history: history, footer: Footer())

    appState.prewarmVisibleWindow()
    for _ in 0..<100 where persistence.fetchAllCalls == 0 {
      await Task.yield()
    }

    XCTAssertEqual(persistence.fetchAllCalls, 1)
  }
}

@MainActor
private final class RuntimeServicesPersistence: HistoryPersistence {
  func delete(_ item: HistoryItem) throws {}
  func delete(_ items: [HistoryItem]) throws {}
  func deleteUnpinned() throws {}
  func deleteAll() throws {}
  func save() throws {}
  private(set) var fetchAllCalls = 0

  func fetchAll() throws -> [HistoryItem] {
    fetchAllCalls += 1
    return []
  }
  func model(for id: PersistentIdentifier) -> HistoryItem? { nil }
  func countHistoryItems() throws -> Int { 0 }
  func countHistoryItemContents() throws -> Int { 0 }
}
