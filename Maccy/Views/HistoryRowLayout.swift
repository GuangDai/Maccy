import AppKit

/// Pure geometry policy for history content rows.
enum HistoryRowLayout {
  static var baseHeight: CGFloat {
    if #available(macOS 26.0, *) { return 24 }
    return 22
  }

  static var textLineIncrement: CGFloat {
    ceil(NSFont.systemFont(ofSize: NSFont.systemFontSize).boundingRectForFont.height)
  }

  static func textHeight(lines: Int) -> CGFloat {
    let clampedLines = min(max(lines, 1), 4)
    return baseHeight + CGFloat(clampedLines - 1) * textLineIncrement
  }

  static func effectiveImageContentHeight(_ requestedHeight: Int) -> CGFloat {
    CGFloat(min(max(requestedHeight, 1), 200))
  }

  static func imageHeight(maxImageHeight: Int) -> CGFloat {
    max(baseHeight, effectiveImageContentHeight(maxImageHeight) + 10)
  }

  static func rowHeight(
    isImage: Bool,
    maxImageHeight: Int,
    textLines: Int
  ) -> CGFloat {
    isImage ? imageHeight(maxImageHeight: maxImageHeight) : textHeight(lines: textLines)
  }
}
