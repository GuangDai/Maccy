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

  private func textItem(_ text: String) -> HistoryItem {
    HistoryBuilder()
      .withContent(type: "public.utf8-plain-text", value: Data(text.utf8))
      .build()
  }
}
