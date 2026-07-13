import XCTest
@testable import Maccy

final class HistoryRowLayoutTests: XCTestCase {
  func testTextRowsScaleByClampedLineCount() {
    XCTAssertEqual(HistoryRowLayout.textHeight(lines: 1), HistoryRowLayout.baseHeight)
    XCTAssertEqual(
      HistoryRowLayout.textHeight(lines: 3),
      HistoryRowLayout.baseHeight + 2 * HistoryRowLayout.textLineIncrement
    )
    XCTAssertEqual(HistoryRowLayout.textHeight(lines: 0), HistoryRowLayout.textHeight(lines: 1))
    XCTAssertEqual(HistoryRowLayout.textHeight(lines: 9), HistoryRowLayout.textHeight(lines: 4))
  }

  func testImageRowsHonorConfiguredContentHeightAndFloor() {
    XCTAssertEqual(
      HistoryRowLayout.imageHeight(maxImageHeight: 40),
      max(HistoryRowLayout.baseHeight, 50)
    )
    XCTAssertEqual(
      HistoryRowLayout.imageHeight(maxImageHeight: -1),
      HistoryRowLayout.baseHeight
    )
    XCTAssertNotEqual(
      HistoryRowLayout.rowHeight(isImage: true, maxImageHeight: 40, textLines: 1),
      HistoryRowLayout.rowHeight(isImage: false, maxImageHeight: 40, textLines: 1)
    )
  }
}
