import Defaults
import XCTest
@testable import Maccy

/// Tests for the popup window: open-time selection and the list-height cap.
@MainActor
final class PopupTests: XCTestCase {
  private let history = History.shared
  private let savedSize = Defaults[.size]
  private let savedSortBy = Defaults[.sortBy]

  override func setUp() async throws {
    try await super.setUp()
    history.clearAll()
    AppState.shared.navigator.selectWithoutScrolling(item: nil)
    Defaults[.size] = 10
    Defaults[.sortBy] = .firstCopiedAt
  }

  override func tearDown() async throws {
    history.searchQuery = ""
    Defaults[.size] = savedSize
    Defaults[.sortBy] = savedSortBy
    try await super.tearDown()
  }

  /// Opening the popup re-selects the newest history item, regardless of the
  /// navigator's prior selection.
  func testOpenSelectsNewestHistoryItem() throws {
    let older = try HistoryTestDriver.seed(historyItem("bar"), in: history)
    let newest = try HistoryTestDriver.seed(historyItem("foo"), in: history)
    AppState.shared.navigator.select(item: older)

    AppState.shared.popup.open(height: 0)

    XCTAssertEqual(AppState.shared.navigator.selection.first, newest)
  }

  /// `cappedListHeight` clamps the list to `maxVisibleItems` rows but leaves
  /// shorter content unchanged, honors the row height, and is uncapped when the
  /// visible-item limit is non-positive.
  func testCappedListHeightLimitsRowsToMaxVisibleItems() {
    // Cap binds when content exceeds maxVisibleItems rows (10 rows × 22pt).
    XCTAssertEqual(
      Popup.cappedListHeight(contentHeight: 4_400, maxVisibleItems: 10, itemHeight: 22),
      220,
      accuracy: 0.001
    )
    // No cap when content already fits within the limit.
    XCTAssertEqual(
      Popup.cappedListHeight(contentHeight: 150, maxVisibleItems: 10, itemHeight: 22),
      150,
      accuracy: 0.001
    )
    // maxVisibleItems <= 0 means uncapped (defensive; not exposed in Settings).
    XCTAssertEqual(
      Popup.cappedListHeight(contentHeight: 4_400, maxVisibleItems: 0, itemHeight: 22),
      4_400,
      accuracy: 0.001
    )
    // Respects itemHeight (macOS 26+ uses 24pt per row).
    XCTAssertEqual(
      Popup.cappedListHeight(contentHeight: 4_400, maxVisibleItems: 10, itemHeight: 24),
      240,
      accuracy: 0.001
    )
  }

  func testInjectedRuntimeOwnsWindowAndSizingEffects() {
    let recorder = PopupRuntimeRecorder()
    let popup = Popup(runtimeServices: recorder.services, installsEventHandlers: false)
    let savedWindowSize = Defaults[.windowSize]
    let savedMaxVisibleItems = Defaults[.maxVisibleItems]
    defer {
      Defaults[.windowSize] = savedWindowSize
      Defaults[.maxVisibleItems] = savedMaxVisibleItems
    }
    Defaults[.windowSize] = NSSize(width: 450, height: 800)
    Defaults[.maxVisibleItems] = 100

    popup.open(height: 120, at: .cursor)
    XCTAssertEqual(recorder.initialSelectionCalls, 1)
    XCTAssertEqual(recorder.openedPanels.count, 1)
    XCTAssertEqual(recorder.openedPanels.first?.0, 120)
    XCTAssertEqual(recorder.openedPanels.first?.1, .cursor)

    XCTAssertTrue(popup.isClosed())
    recorder.panelPresented = true
    XCTAssertFalse(popup.isClosed())
    popup.close()
    XCTAssertEqual(recorder.closePanelCalls, 1)

    recorder.previewMinimumRequired = true
    XCTAssertEqual(popup.preferredHeight(for: 10), Popup.minimumPreviewHeight)
    popup.resize(height: 120)
    XCTAssertEqual(recorder.resizedHeights, [Popup.minimumPreviewHeight])
  }

  func testInjectedRuntimeOwnsOpenCycleAndCommitEffects() async {
    let recorder = PopupRuntimeRecorder()
    let commitExpectation = expectation(description: "selection commits after modifier handling")
    recorder.onCommitSelection = { commitExpectation.fulfill() }
    let popup = Popup(runtimeServices: recorder.services, installsEventHandlers: false)

    popup.handleTestingHotKeyDown()
    XCTAssertEqual(recorder.prewarmCalls, 1)
    XCTAssertEqual(recorder.initialSelectionCalls, 1)
    XCTAssertEqual(recorder.openedPanels.count, 1)

    recorder.panelPresented = true
    popup.handleTestingHotKeyDown()
    XCTAssertEqual(recorder.highlightNextCalls, 1)
    popup.handleTestingModifiersReleased()
    XCTAssertEqual(recorder.commitSelectionCalls, 0)
    await fulfillment(of: [commitExpectation], timeout: 1)
    XCTAssertEqual(recorder.commitSelectionCalls, 1)
  }

  func testHandledShortcutStopsCycleAndClosePaths() {
    let recorder = PopupRuntimeRecorder()
    recorder.panelPresented = true
    recorder.shortcutHandled = true
    let popup = Popup(runtimeServices: recorder.services, installsEventHandlers: false)

    popup.handleTestingHotKeyDown()

    XCTAssertEqual(recorder.shortcutCalls, 1)
    XCTAssertEqual(recorder.highlightNextCalls, 0)
    XCTAssertEqual(recorder.closePanelCalls, 0)
  }

  /// Builds a `HistoryItem` carrying a single string content entry, inserted
  /// into the shared context, with its title derived from the value.
  private func historyItem(_ value: String) -> HistoryItem {
    let item = HistoryItem()
    item.contents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: value.data(using: .utf8)
      )
    ]
    item.numberOfCopies = 1
    item.title = item.generateTitle()
    return item
  }
}

@MainActor
private final class PopupRuntimeRecorder {
  var initialSelectionCalls = 0
  var openedPanels: [(CGFloat, PopupPosition)] = []
  var closePanelCalls = 0
  var panelPresented = false
  var previewMinimumRequired = false
  var resizedHeights: [CGFloat] = []
  var prewarmCalls = 0
  var shortcutHandled = false
  var shortcutCalls = 0
  var highlightNextCalls = 0
  var commitSelectionCalls = 0
  var onCommitSelection: (() -> Void)?

  var services: PopupRuntimeServices {
    PopupRuntimeServices(
      selectInitialItem: { [weak self] in self?.initialSelectionCalls += 1 },
      openPanel: { [weak self] height, position in
        self?.openedPanels.append((height, position))
      },
      closePanel: { [weak self] in self?.closePanelCalls += 1 },
      isPanelPresented: { [weak self] in self?.panelPresented == true },
      requiresPreviewMinimumHeight: { [weak self] in self?.previewMinimumRequired == true },
      resizePanel: { [weak self] in self?.resizedHeights.append($0) },
      prewarmVisibleWindow: { [weak self] in self?.prewarmCalls += 1 },
      selectPressedShortcut: { [weak self] in
        self?.shortcutCalls += 1
        return self?.shortcutHandled == true
      },
      highlightNext: { [weak self] in self?.highlightNextCalls += 1 },
      commitSelection: { [weak self] in
        self?.commitSelectionCalls += 1
        self?.onCommitSelection?()
      }
    )
  }
}
