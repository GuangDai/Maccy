import SwiftUI

/// Renders a single clipboard history entry, tracking viewport visibility and selection state.
struct HistoryItemView: View {
  @Bindable var item: HistoryItemDecorator
  var previous: HistoryItemDecorator?
  var next: HistoryItemDecorator?
  var index: Int

  /// The connection appearance derived from whether the adjacent rows are also selected.
  private var selectionAppearance: SelectionAppearance {
    let previousSelected = previous?.isSelected ?? false
    let nextSelected = next?.isSelected ?? false
    switch (previousSelected, nextSelected) {
    case (true, false):
      return .topConnection
    case (false, true):
      return .bottomConnection
    case (true, true):
      return .topBottomConnection
    default:
      return .none
    }
  }

  @Environment(AppState.self) private var appState

  var body: some View {
    ListItemView(
      id: item.id,
      selectionId: item.id,
      appIcon: item.applicationImage,
      image: item.thumbnailImage,
      accessoryImage: item.thumbnailImage != nil ? nil : ColorImage.from(item.title),
      attributedTitle: item.attributedTitle,
      shortcuts: item.shortcuts,
      isSelected: item.isSelected,
      selectionIndex: nil,
      selectionAppearance: selectionAppearance
    ) {
      Text(verbatim: item.title)
    }
    .onAppear {
      VisibilityTracker.shared.register(item)
      item.onAppearInViewport()
    }
    .onDisappear {
      item.onDisappearFromViewport()
      VisibilityTracker.shared.unregister(item)
    }
    .onTapGesture {
      appState.history.select(item)
    }
  }
}
