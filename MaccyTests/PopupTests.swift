import Defaults
import XCTest
@testable import Maccy

/// Tests for the popup window: open-time selection and the list-height cap.
@MainActor
final class PopupTests: XCTestCase {
  private let history = History.shared
  private let savedSize = Defaults[.size]
  private let savedSortBy = Defaults[.sortBy]
  private let savedShowSearch = Defaults[.showSearch]
  private let savedSearchVisibility = Defaults[.searchVisibility]

  override func setUp() async throws {
    try await super.setUp()
    history.clearAll()
    AppState.shared.navigator.selectWithoutScrolling(item: nil)
    Defaults[.size] = 10
    Defaults[.sortBy] = .firstCopiedAt
  }

  override func tearDown() async throws {
    history.searchQuery = ""
    Defaults[.showSearch] = savedShowSearch
    Defaults[.searchVisibility] = savedSearchVisibility
    Defaults[.size] = savedSize
    Defaults[.sortBy] = savedSortBy
    try await super.tearDown()
  }

  func testSearchVisibleTracksPreferenceAndQuery() {
    Defaults[.showSearch] = false
    Defaults[.searchVisibility] = .always
    XCTAssertFalse(AppState.shared.searchVisible)

    Defaults[.showSearch] = true
    XCTAssertTrue(AppState.shared.searchVisible)

    Defaults[.searchVisibility] = .duringSearch
    history.searchQuery = ""
    XCTAssertFalse(AppState.shared.searchVisible)

    history.searchQuery = "needle"
    XCTAssertTrue(AppState.shared.searchVisible)
  }

  func testHeaderLayoutCollapsesOnlyWhenSearchIsNotVisible() {
    XCTAssertEqual(HeaderView.maximumLayoutHeight(isVisible: false), 0)
    XCTAssertNil(HeaderView.maximumLayoutHeight(isVisible: true))
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

  func testInjectedRuntimeOwnsWindowAndSizingEffects() {
    let recorder = PopupRuntimeRecorder()
    let popup = Popup(runtimeServices: recorder.services, installsEventHandlers: false)
    let savedWindowSize = Defaults[.windowSize]
    let savedPreviewMinimumHeightPercent = Defaults[.previewMinimumHeightPercent]
    defer {
      Defaults[.windowSize] = savedWindowSize
      Defaults[.previewMinimumHeightPercent] = savedPreviewMinimumHeightPercent
    }
    Defaults[.windowSize] = NSSize(width: 450, height: 800)
    Defaults[.previewMinimumHeightPercent] = 60

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

    // The minimum-height floor applies unconditionally (always-on), so a tiny
    // requested height is raised to previewMinimumHeightPercent of the window
    // with no preview-open precondition.
    XCTAssertEqual(popup.preferredHeight(for: 10), 480)
    popup.resize(height: 120)
    popup.resize(height: 650)
    popup.resize(height: 900)
    XCTAssertEqual(recorder.resizedHeights, [480, 650, 800])
  }

  func testPreviewMinimumHeightScalesWithWindowAndClampsPercent() {
    XCTAssertEqual(Popup.previewMinimumHeight(maximumHeight: 800, percent: 60), 480)
    XCTAssertEqual(Popup.previewMinimumHeight(maximumHeight: 800, percent: 0), 200)
    XCTAssertEqual(Popup.previewMinimumHeight(maximumHeight: 800, percent: 200), 800)
  }

  /// The minimum-height floor applies unconditionally — a popup shorter than the
  /// configured floor is raised to it even when no slideout preview is open.
  ///
  /// Stability invariant for candidate ①: search drives filtering only, never
  /// window geometry, so the floor cannot switch on/off with preview state.
  func testPreferredHeightAppliesMinimumFloorWithoutPreviewOpen() {
    let recorder = PopupRuntimeRecorder()
    let popup = Popup(runtimeServices: recorder.services, installsEventHandlers: false)
    let savedWindowSize = Defaults[.windowSize]
    let savedPercent = Defaults[.previewMinimumHeightPercent]
    defer {
      Defaults[.windowSize] = savedWindowSize
      Defaults[.previewMinimumHeightPercent] = savedPercent
    }
    Defaults[.windowSize] = NSSize(width: 450, height: 800)
    Defaults[.previewMinimumHeightPercent] = 60
    // No preview-open precondition is set: the floor must apply unconditionally.
    XCTAssertEqual(popup.preferredHeight(for: 10), 480, accuracy: 0.001)
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
