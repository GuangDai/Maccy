import AppKit
import XCTest
@testable import Maccy

@MainActor
final class MemoryGovernanceTests: XCTestCase {
  func testCompositionRootMemoryWarningKeepsVisibleImagesAndReleasesHiddenImages() {
    let visible = decorator("visible")
    let hidden = decorator("hidden")
    visible.previewImage = NSImage(size: NSSize(width: 2, height: 2))
    visible.thumbnailImage = NSImage(size: NSSize(width: 2, height: 2))
    hidden.previewImage = NSImage(size: NSSize(width: 2, height: 2))
    hidden.thumbnailImage = NSImage(size: NSSize(width: 2, height: 2))
    let tracker = VisibilityTracker()
    tracker.register(visible)
    let appState = appState(visibilityTracker: tracker)
    let root = CompositionRoot(appState: appState)
    let history = MemoryHistorySpy(decorators: [visible, hidden])
    root.memoryGovernor.attach(history: history)

    root.memoryGovernor.handleMemoryWarning()

    XCTAssertNotNil(visible.previewImage)
    XCTAssertNotNil(visible.thumbnailImage)
    XCTAssertNil(hidden.previewImage)
    XCTAssertNil(hidden.thumbnailImage)
    XCTAssertEqual(history.purgeApplicationImagesCalls, 1)
  }

  func testAppStatesUseTheirInjectedVisibilityTracker() {
    let firstTracker = VisibilityTracker()
    let secondTracker = VisibilityTracker()
    let observer = decorator("observer")
    let first = appState(visibilityTracker: firstTracker)
    let second = appState(visibilityTracker: secondTracker)

    first.visibilityTracker.register(observer)

    XCTAssertTrue(first.visibilityTracker === firstTracker)
    XCTAssertTrue(second.visibilityTracker === secondTracker)
    XCTAssertTrue(first.visibilityTracker.isVisible(observer.id))
    XCTAssertFalse(second.visibilityTracker.isVisible(observer.id))
  }

  private func decorator(_ title: String) -> HistoryItemDecorator {
    HistoryItemDecorator(HistoryBuilder().withTitle(title).build())
  }

  private func appState(visibilityTracker: VisibilityTracker) -> AppState {
    let storage = Storage(storedInMemoryForTesting: true)
    let history = History(
      persistence: SwiftDataHistoryPersistence(context: storage.context),
      logsPersistenceErrors: false
    )
    return AppState(
      history: history,
      footer: Footer(),
      visibilityTracker: visibilityTracker
    )
  }
}

@MainActor
private final class MemoryHistorySpy: MemoryGovernanceHistory {
  private let values: [HistoryItemDecorator]
  private(set) var purgeApplicationImagesCalls = 0

  init(decorators: [HistoryItemDecorator]) {
    values = decorators
  }

  func decorators() -> [HistoryItemDecorator] { values }

  func purgeApplicationImages() {
    purgeApplicationImagesCalls += 1
  }
}
