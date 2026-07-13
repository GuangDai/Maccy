import Foundation
import SwiftUI

/// Owns popup selection/scroll/navigation state: the current `selection`, the
/// lead item, hover-vs-keyboard navigation, and the highlight/extend actions
/// bound to arrow-key and shortcut gestures.
@MainActor
@Observable
class NavigationManager {
  private var history: History
  private var footer: Footer
  private let onLeadChange: @MainActor (HistoryItemDecorator?) -> Void

  /// Creates the manager bound to its history, footer, and lead-change output.
  init(
    history: History,
    footer: Footer,
    onLeadChange: @escaping @MainActor (HistoryItemDecorator?) -> Void = { _ in }
  ) {
    self.history = history
    self.footer = footer
    self.onLeadChange = onLeadChange
  }

  /// The current multi-capable selection; `willSet` mirrors membership onto
  /// each decorator.
  var selection: Selection<HistoryItemDecorator> = Selection() {
    willSet {
      selection.forEach { $0.isSelected = false }
      newValue.forEach { $0.isSelected = true }
    }
  }

  /// The decorator (or footer item) the view should scroll to.
  var scrollTarget: UUID?
  /// The id of the current lead (a history item or footer item).
  var leadSelection: UUID? {
    if let item = leadHistoryItem {
      return item.id
    }
    if let footerItem = footer.selectedItem {
      return footerItem.id
    }
    return nil
  }
  private(set) var leadHistoryItem: HistoryItemDecorator? {
    didSet {
      guard oldValue?.id != leadHistoryItem?.id else { return }

      // Cancel the previous lead item's in-flight preview decode so it stops
      // occupying the single serial `ImageProcessor` actor. Previously only
      // `invalidate`/`cleanupImages` cancelled, so navigating off a lead left
      // its preview decoding to completion — a stale-decode pile-up on the
      // actor (worst case under mouse hover). A cached preview survives
      // (`cancelPreviewGeneration` keeps `previewImage`); only an uncached
      // in-flight decode is stopped.
      //
      // Hopped to `@MainActor`: this `didSet` runs in the main-isolated model,
      // but the hop keeps the cancellation decoupled from the selection change.
      let previous = oldValue
      Task { @MainActor in
        previous?.cancelPreviewGeneration()
      }
      onLeadChange(leadHistoryItem)
    }
  }

  /// A hover-pending id to apply once keyboard navigation ends.
  var hoverSelectionWhileKeyboardNavigating: UUID?
  var isKeyboardNavigating: Bool = true {
    didSet {
      if !isKeyboardNavigating,
         let hoverSelection = hoverSelectionWhileKeyboardNavigating {
        hoverSelectionWhileKeyboardNavigating = nil
        // Mouse hover selects an already-visible cell — do NOT programatically
        // scroll to it. Routing hover through `scroll(to:)` set `scrollTarget`
        // on every hover, feeding a LazyVStack anchor invalidation that caused
        // a layout-feedback storm. Hover must update selection without
        // disturbing the scroll position.
        selectWithoutScrolling(id: hoverSelection)
      }
    }
  }

  /// Sets `scrollTarget` to drive the list to `id`.
  private func scroll(to id: UUID?, item: HistoryItemDecorator? = nil) {
    scrollTarget = id
  }

  /// Selects by id, dispatching to a history item or footer item if found.
  func select(id: UUID) {
    if let item = history.items.first(where: { $0.id == id }) {
      select(item: item, footerItem: nil)
    } else if let item = footer.items.first(where: { $0.id == id }) {
      select(item: nil, footerItem: item)
    } else {
      select(item: nil, footerItem: nil)
    }
  }

  /// Selects a history and/or footer item and scrolls to it, in one transaction.
  func select(item: HistoryItemDecorator? = nil, footerItem: FooterItem? = nil) {
    withTransaction(Transaction()) {
      selectWithoutScrolling(item: item, footerItem: footerItem)
      scroll(to: item?.id, item: item)
    }
  }

  /// Selects by id without disturbing the scroll position (for hover).
  func selectWithoutScrolling(id: UUID) {
    if let item = history.items.first(where: { $0.id == id }) {
      selectWithoutScrolling(item: item, footerItem: nil)
    } else if let item = footer.items.first(where: { $0.id == id }) {
      selectWithoutScrolling(item: nil, footerItem: item)
    } else {
      selectWithoutScrolling(item: nil, footerItem: nil)
    }
  }

  /// Selects a history and/or footer item without scrolling.
  func selectWithoutScrolling(
    item: HistoryItemDecorator? = nil,
    footerItem: FooterItem? = nil
  ) {
    if let item = item {
      selectInHistory(item)
    } else if let footerItem = footerItem {
      selectInFooter(footerItem)
    } else {
      leadHistoryItem = nil
      selection = .init()
      footer.selectedItem = nil
    }
  }

  /// Sets a single history item as the lead selection, clearing the footer.
  private func selectInHistory(_ item: HistoryItemDecorator) {
    leadHistoryItem = item
    selection = .init(items: [item])
    footer.selectedItem = nil
  }

  /// Sets a footer item as selected, clearing the history lead.
  private func selectInFooter(_ item: FooterItem) {
    leadHistoryItem = nil
    selection = .init()
    footer.selectedItem = item
  }

  /// Marks keyboard navigation active and selects the given item/footer item.
  private func selectFromKeyboardNavigation(
    item: HistoryItemDecorator? = nil,
    footerItem: FooterItem? = nil
  ) {
    isKeyboardNavigating = true
    select(item: item, footerItem: footerItem)
  }

  /// Highlights the first visible history item (or clears if none).
  func highlightFirst() {
    if let item = history.firstVisibleItem {
      selectFromKeyboardNavigation(item: item)
    } else {
      selectFromKeyboardNavigation(item: nil)
    }
  }

  /// Moves the highlight one step backward (up), crossing into the footer at the top.
  func highlightPrevious() {
    guard let lead = leadSelection else { return }

    if let historyItem = history.firstVisibleItem(where: { $0.id == lead }) {
      if let nextItem = history.visibleItem(before: historyItem) {
        selectFromKeyboardNavigation(item: nextItem)
      } else {
        highlightFirst()
      }
    } else if let footerItem = footer.firstVisibleItem(where: { $0.id == lead }) {
      if let nextItem = footer.visibleItem(before: footerItem) {
        selectFromKeyboardNavigation(footerItem: nextItem)
      } else if let nextItem = history.lastVisibleItem {
        selectFromKeyboardNavigation(item: nextItem)
      }
    }
  }

  /// Moves the highlight one step forward (down), crossing into the footer at the bottom.
  func highlightNext(allowCycle: Bool = false) {
    guard let lead = leadSelection else { return }

    if let historyItem = history.firstVisibleItem(where: { $0.id == lead }) {
      if let nextItem = history.visibleItem(after: historyItem) {
        selectFromKeyboardNavigation(item: nextItem)
      } else if let nextItem = footer.firstVisibleItem {
        selectFromKeyboardNavigation(footerItem: nextItem)
      } else if allowCycle {
        highlightFirst()
      }
    } else if let footerItem = footer.firstVisibleItem(where: { $0.id == lead }) {
      if let nextItem = footer.visibleItem(after: footerItem) {
        selectFromKeyboardNavigation(footerItem: nextItem)
      } else if let nextItem = footer.firstVisibleItem {
        selectFromKeyboardNavigation(footerItem: nextItem)
      } else if allowCycle {
        // End of footer; cycle to the beginning
        highlightFirst()
      }
    }
  }

  /// Moves the highlight to the last item (footer, or the last history row).
  func highlightLast() {
    guard let lead = leadSelection else { return }

    if let historyItem = history.firstVisibleItem(where: { $0.id == lead }) {
      if historyItem == history.lastVisibleItem,
         let nextItem = footer.firstVisibleItem {
        selectFromKeyboardNavigation(footerItem: nextItem)
      } else {
        selectFromKeyboardNavigation(item: history.lastVisibleItem)
      }
    } else if footer.selectedItem != nil {
      selectFromKeyboardNavigation(footerItem: footer.lastVisibleItem)
    } else {
      selectFromKeyboardNavigation(footerItem: footer.firstVisibleItem)
    }
  }

}
