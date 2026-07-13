import AppKit
import Defaults
import XCTest
@testable import Maccy

/// Defaults changes apply to the complete decorator corpus, including rows
/// hidden by the current search projection.
@MainActor
final class HistoryDefaultsWatcherTests: XCTestCase {
  func testShowSpecialSymbolsRefreshesHiddenDecoratorTitle() async throws {
    let savedValue = Defaults[.showSpecialSymbols]
    defer { Defaults[.showSpecialSymbols] = savedValue }
    Defaults[.showSpecialSymbols] = false

    let visible = decorator(" visible ")
    let hidden = decorator(" hidden ")
    let listState = HistoryListState(decorators: [visible, hidden])
    listState.publishVisible([visible])
    _ = History(
      persistence: SwiftDataHistoryPersistence(context: Storage.shared.context),
      listState: listState,
      logsPersistenceErrors: false
    )
    await Task.yield()

    Defaults[.showSpecialSymbols] = true
    try await Task.sleep(for: .milliseconds(100))

    XCTAssertEqual(visible.title, "·visible·")
    XCTAssertEqual(hidden.title, "·hidden·")
  }

  func testImageSizingChangesReleaseHiddenDecoratorImages() async throws {
    let savedHeight = Defaults[.imageMaxHeight]
    let savedPreviewPixels = Defaults[.imageMaxPreviewPixels]
    defer {
      Defaults[.imageMaxHeight] = savedHeight
      Defaults[.imageMaxPreviewPixels] = savedPreviewPixels
    }

    let visible = decorator("visible")
    let hidden = decorator("hidden")
    let listState = HistoryListState(decorators: [visible, hidden])
    listState.publishVisible([visible])
    _ = History(
      persistence: SwiftDataHistoryPersistence(context: Storage.shared.context),
      listState: listState,
      logsPersistenceErrors: false
    )
    await Task.yield()

    visible.thumbnailImage = NSImage(size: NSSize(width: 10, height: 10))
    hidden.thumbnailImage = NSImage(size: NSSize(width: 10, height: 10))
    Defaults[.imageMaxHeight] = savedHeight + 1
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertNil(visible.thumbnailImage)
    XCTAssertNil(hidden.thumbnailImage)

    visible.previewImage = NSImage(size: NSSize(width: 10, height: 10))
    hidden.previewImage = NSImage(size: NSSize(width: 10, height: 10))
    Defaults[.imageMaxPreviewPixels] = savedPreviewPixels + 1
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertNil(visible.previewImage)
    XCTAssertNil(hidden.previewImage)
  }

  func testAdaptiveRowSizingChangesRequestPopupRemeasurement() async {
    let savedImageHeight = Defaults[.imageMaxHeight]
    let savedTextLines = Defaults[.textRowLines]
    defer {
      Defaults[.imageMaxHeight] = savedImageHeight
      Defaults[.textRowLines] = savedTextLines
    }
    Defaults[.imageMaxHeight] = 40
    Defaults[.textRowLines] = 1

    let imageResize = expectation(description: "image row resize requested")
    let textResize = expectation(description: "text row resize requested")
    var resizeRequests = 0
    let history = History(
      persistence: SwiftDataHistoryPersistence(context: Storage.shared.context),
      logsPersistenceErrors: false
    )
    history.configureUIEffectSink { effect in
      if case .resizePopup = effect {
        resizeRequests += 1
        if resizeRequests == 1 {
          imageResize.fulfill()
        } else if resizeRequests == 2 {
          textResize.fulfill()
        }
      }
    }
    await Task.yield()

    Defaults[.imageMaxHeight] = 41
    await fulfillment(of: [imageResize], timeout: 1)
    XCTAssertEqual(resizeRequests, 1)

    Defaults[.textRowLines] = 2
    await fulfillment(of: [textResize], timeout: 1)
    XCTAssertEqual(resizeRequests, 2)
  }

  private func decorator(_ text: String) -> HistoryItemDecorator {
    HistoryItemDecorator(
      HistoryBuilder()
        .withContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data(text.utf8))
        .build()
    )
  }
}
