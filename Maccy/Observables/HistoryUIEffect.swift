import Foundation

/// A UI request emitted by `History` and interpreted by the composition root.
/// Keeping these requests as values prevents the history domain from reaching
/// back into the global `AppState` object graph.
@MainActor
enum HistoryUIEffect {
  case closePopup
  case resizePopup
  case select(HistoryItemDecorator?)
  case highlightFirst
  case scrollTo(UUID)
}

/// Composition-owned output port for `History` UI requests.
typealias HistoryUIEffectSink = @MainActor (HistoryUIEffect) -> Void
