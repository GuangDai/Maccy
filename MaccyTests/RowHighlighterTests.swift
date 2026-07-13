import SwiftUI
import XCTest
@testable import Maccy

@MainActor
final class RowHighlighterTests: XCTestCase {
  func testTitleAppliesEveryConfiguredStyle() {
    let text = "foo bar"
    let range = text.range(of: "bar")!

    for style in HighlightMatch.allCases {
      var highlighter = RowHighlighter()
      guard case .replacement(let actual?) = highlighter.title(
        query: "bar",
        text: text,
        ranges: [range],
        style: style
      ) else {
        return XCTFail("first render must return a replacement")
      }

      XCTAssertEqual(actual, expected(text: text, match: "bar", style: style))
    }
  }

  func testSameTitleInputsAreUnchangedUntilStyleChanges() {
    let text = "foo bar"
    let range = text.range(of: "bar")!
    var highlighter = RowHighlighter()

    _ = highlighter.title(query: "bar", text: text, ranges: [range], style: .bold)
    guard case .unchanged = highlighter.title(
      query: "bar", text: text, ranges: [range], style: .bold
    ) else {
      return XCTFail("identical inputs must reuse the memo")
    }
    guard case .replacement = highlighter.title(
      query: "bar", text: text, ranges: [range], style: .underline
    ) else {
      return XCTFail("style changes must rebuild")
    }
  }

  func testEmptyQueryClearsOnceThenRemainsUnchanged() {
    let text = "foo bar"
    let range = text.range(of: "bar")!
    var highlighter = RowHighlighter()
    _ = highlighter.title(query: "bar", text: text, ranges: [range], style: .bold)

    guard case .replacement(nil) = highlighter.title(
      query: "", text: text, ranges: [], style: .bold
    ) else {
      return XCTFail("first clear must remove the attributed value")
    }
    guard case .unchanged = highlighter.title(
      query: "", text: text, ranges: [], style: .bold
    ) else {
      return XCTFail("repeated clear must not retrigger observation")
    }
  }

  func testPreviewClampsPartialRangeAndSkipsDeepRange() {
    var highlighter = RowHighlighter()
    guard case .replacement(let partial?) = highlighter.preview(
      query: "bar", text: "foo bar", ranges: [4..<100], style: .bold
    ) else {
      return XCTFail("partial preview range must build")
    }
    XCTAssertEqual(partial, expected(text: "foo bar", match: "bar", style: .bold))

    var deepHighlighter = RowHighlighter()
    guard case .replacement(let deep?) = deepHighlighter.preview(
      query: "x", text: "foo bar", ranges: [100..<103], style: .bold
    ) else {
      return XCTFail("deep-only preview still returns plain attributed text")
    }
    XCTAssertEqual(deep, AttributedString("foo bar"))
  }

  func testTitleDropsRangesBeyondTheRenderWindow() {
    let text = String(repeating: "a", count: TextLimits.highlight) + "z"
    let deepRange = text.range(of: "z")!
    var highlighter = RowHighlighter()

    guard case .replacement(let actual?) = highlighter.title(
      query: "z", text: text, ranges: [deepRange], style: .bold
    ) else {
      return XCTFail("title render must still return its bounded plain text")
    }
    XCTAssertEqual(
      actual,
      AttributedString(String(repeating: "a", count: TextLimits.highlight))
    )
  }

  private func expected(
    text: String,
    match: String,
    style: HighlightMatch
  ) -> AttributedString {
    var expected = AttributedString(text)
    let range = expected.range(of: match)!
    switch style {
    case .bold:
      expected[range].font = .bold(.body)()
    case .italic:
      expected[range].font = .italic(.body)()
    case .underline:
      expected[range].underlineStyle = .single
    case .color:
      expected[range].backgroundColor = .findHighlightColor
      expected[range].foregroundColor = .black
    }
    return expected
  }
}
