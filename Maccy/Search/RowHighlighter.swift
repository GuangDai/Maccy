import Logging
import SwiftUI

enum RowHighlightUpdate {
  case unchanged
  case replacement(AttributedString?)
}

struct RowHighlighter {
  private struct TitleMemo {
    let text: String
    let ranges: [Range<String.Index>]
    let style: HighlightMatch
  }

  private struct PreviewMemo {
    let text: String
    let ranges: [Range<Int>]
    let style: HighlightMatch
  }

  private let logger = Logger(label: "org.p0deje.Maccy")
  private var titleMemo: TitleMemo?
  private var previewMemo: PreviewMemo?

  mutating func title(
    query: String,
    text: String,
    ranges: [Range<String.Index>],
    style: HighlightMatch
  ) -> RowHighlightUpdate {
    guard !query.isEmpty, !text.isEmpty else {
      guard titleMemo != nil else { return .unchanged }
      titleMemo = nil
      return .replacement(nil)
    }
    if let memo = titleMemo,
       memo.text == text,
       memo.ranges == ranges,
       memo.style == style {
      return .unchanged
    }

    var attributed = AttributedString(text.shortened(to: TextLimits.highlight))
    for range in ranges {
      guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
            let upper = AttributedString.Index(range.upperBound, within: attributed) else {
        logger.debug("highlight range fell outside the render window; dropped")
        continue
      }
      apply(style, to: &attributed, in: lower..<upper)
    }
    titleMemo = TitleMemo(text: text, ranges: ranges, style: style)
    return .replacement(attributed)
  }

  mutating func preview(
    query: String,
    text: String,
    ranges: [Range<Int>],
    style: HighlightMatch
  ) -> RowHighlightUpdate {
    guard !query.isEmpty, !text.isEmpty else {
      guard previewMemo != nil else { return .unchanged }
      previewMemo = nil
      return .replacement(nil)
    }
    if let memo = previewMemo,
       memo.text == text,
       memo.ranges == ranges,
       memo.style == style {
      return .unchanged
    }

    var attributed = AttributedString(text)
    let count = text.count
    for range in ranges {
      let lowerOffset = range.lowerBound
      let upperOffset = min(range.upperBound, count)
      guard lowerOffset < count, lowerOffset < upperOffset else { continue }
      let lowerString = text.index(text.startIndex, offsetBy: lowerOffset)
      let upperString = text.index(text.startIndex, offsetBy: upperOffset)
      guard let lower = AttributedString.Index(lowerString, within: attributed),
            let upper = AttributedString.Index(upperString, within: attributed) else { continue }
      apply(style, to: &attributed, in: lower..<upper)
    }
    previewMemo = PreviewMemo(text: text, ranges: ranges, style: style)
    return .replacement(attributed)
  }

  private func apply(
    _ style: HighlightMatch,
    to attributed: inout AttributedString,
    in range: Range<AttributedString.Index>
  ) {
    switch style {
    case .bold:
      attributed[range].font = .bold(.body)()
    case .italic:
      attributed[range].font = .italic(.body)()
    case .underline:
      attributed[range].underlineStyle = .single
    case .color:
      attributed[range].backgroundColor = .findHighlightColor
      attributed[range].foregroundColor = .black
    }
  }
}
