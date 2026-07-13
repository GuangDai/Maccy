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
    baseHeight
  }

  static func imageHeight(maxImageHeight: Int) -> CGFloat {
    baseHeight
  }

  static func rowHeight(
    isImage: Bool,
    maxImageHeight: Int,
    textLines: Int
  ) -> CGFloat {
    isImage ? imageHeight(maxImageHeight: maxImageHeight) : textHeight(lines: textLines)
  }
}
