import AppKit.NSWorkspace
import Defaults
import Foundation
import Observation
import Sauce

/// Main-actor view model wrapping a `HistoryItem` `@Model`: projects its title,
/// and holds highlights, keyboard shortcuts, and lazily generated
/// thumbnail/preview images for one row in the history list.
@MainActor
@Observable
class HistoryItemDecorator: Identifiable, Hashable, HasVisibility, VisibilityObserving {
  /// Identity-only equality. `nonisolated` so it satisfies `Equatable`/
  /// `Hashable` from a `@MainActor` type; reads only the `let` UUID `id`
  /// (Sendable). `title` reads main-isolated model state and `attributedTitle`
  /// is main-mutated, so hashing them would cross isolation; `Hashable` need
  /// only reflect identity.
  nonisolated static func == (lhs: HistoryItemDecorator, rhs: HistoryItemDecorator) -> Bool {
    return lhs.id == rhs.id
  }

  /// Preview decode/placeholder target size. The longest side is capped at
  /// `Defaults[.imageMaxPreviewPixels]` (default 800) to bound the off-main
  /// decode + on-main composite cost; 0 = no artificial cap (decodes at screen
  /// resolution — visually identical to "original" in the slideout pane, without
  /// the 256 MB+ bitmap a true native decode of a huge image would cost).
  /// Configurable in Appearance settings.
  static var previewImageSize: NSSize {
    ImageGenerationCoordinator.previewImageSize
  }
  static var thumbnailImageSize: NSSize {
    ImageGenerationCoordinator.thumbnailImageSize
  }

  let id = UUID()

  /// Direct projection of the SwiftData source of truth. Reading the model here
  /// lets Swift Observation track the real dependency and makes a model update
  /// visible in the same main-actor turn, without a duplicate stored mirror.
  var title: String { item.title }
  var attributedTitle: AttributedString?
  /// Preview-pane highlight over the item's body text (``text``), built when a
  /// search match lands in the body. `nil` when there is no body match — the
  /// preview then shows plain ``text``. Ranges past the preview window are deep
  /// matches, left for the scrollable text view.
  var previewAttributedText: AttributedString?
  /// The query and full body-relative ranges behind `previewAttributedText`,
  /// retained so the scrollable preview (`PreviewTextRep`) can show the full
  /// body and deep matches the capped `Text` window cannot.
  private(set) var previewBodyQuery: String = ""
  private(set) var previewBodyRanges: [Range<Int>] = []

  var isVisible: Bool = true
  /// Whether this row is part of the current selection.
  var isSelected = false
  var shortcuts: [KeyShortcut] = []

  /// Display name of the source app (or `"iCloud"` for Universal Clipboard).
  var application: String? {
    if item.universalClipboard {
      return "iCloud"
    }

    guard let bundle = item.application,
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
    else {
      return nil
    }

    return url.deletingPathExtension().lastPathComponent
  }

  /// Whether the item carries image data.
  var hasImage: Bool { imageGeneration.hasImage }

  var previewImageGenerationTask: Task<Void, Never>? {
    imageGeneration.previewImageGenerationTask
  }
  var thumbnailImageGenerationTask: Task<Void, Never>? {
    imageGeneration.thumbnailImageGenerationTask
  }
  var previewImage: NSImage? {
    get { imageGeneration.previewImage }
    set { imageGeneration.previewImage = newValue }
  }
  var thumbnailImage: NSImage? {
    get { imageGeneration.thumbnailImage }
    set { imageGeneration.thumbnailImage = newValue }
  }
  var applicationImage: ApplicationImage
  @ObservationIgnored private let imageGeneration: ImageGenerationCoordinator
  @ObservationIgnored private var textPreviewCache: String?
  @ObservationIgnored private var textPreviewCacheLimit: Int = -1

  // Bounded by HistoryItem.textPreviewLimit (configurable; 0 = full text). The
  // cache auto-invalidates when the limit changes so the next read picks up the
  // new value without a relaunch.
  var text: String {
    let limit = HistoryItem.textPreviewLimit
    if let textPreviewCache, textPreviewCacheLimit == limit {
      return textPreviewCache
    }

    let preview = item.previewableTextPrefix(maxLength: limit)
    textPreviewCache = preview
    textPreviewCacheLimit = limit
    return preview
  }

  /// True when the preview should use the scrollable `NSTextView` rather than
  /// the capped SwiftUI `Text`: either the body is longer than the text-preview
  /// window, or a match lands past it (a deep match that needs scrolling to).
  /// `NSTextView`'s lazy layout keeps live memory bounded where `Text` would
  /// eagerly lay out the whole string.
  var needsScrollablePreview: Bool {
    let limit = HistoryItem.textPreviewLimit
    guard limit > 0 else { return false }
    let body = item.searchText ?? ""
    if body.count > limit {
      return true
    }
    if !previewBodyQuery.isEmpty {
      return previewBodyRanges.contains { $0.lowerBound >= limit }
    }
    return false
  }

  var isPinned: Bool { item.pin != nil }
  var isUnpinned: Bool { item.pin == nil }

  /// Identity-only hash (mirrors `==`).
  nonisolated func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  private(set) var item: HistoryItem

  @ObservationIgnored private var rowHighlighter = RowHighlighter()

  /// Creates a decorator for `item`, seeding shortcuts and the app icon.
  /// Persisted projections supply both image dependencies through
  /// `HistoryItemDecoratorFactory`; the fallbacks keep standalone test
  /// construction isolated from process-wide resources.
  init(
    _ item: HistoryItem,
    shortcuts: [KeyShortcut] = [],
    imageProcessor: ImageProcessing = PassthroughImageProcessor(),
    applicationImage: ApplicationImage? = nil
  ) {
    self.item = item
    self.shortcuts = shortcuts
    self.imageGeneration = ImageGenerationCoordinator(
      imageProcessor: imageProcessor,
      imageData: { item.imageData }
    )
    self.applicationImage = applicationImage ?? ApplicationImage(bundleIdentifier: nil)
  }

  /// Derives the pinned keyboard shortcut from the persisted pin after a
  /// successful mutation. Unpinned numeric slots remain owned by
  /// `HistoryMutations.updateUnpinnedShortcuts()`.
  func updatePinnedShortcut() {
    guard let pin = item.pin else { return }
    shortcuts = KeyShortcut.create(character: pin)
  }

  /// Kicks off thumbnail generation (off-main) if not already cached or in flight.
  func ensureThumbnailImage() {
    imageGeneration.ensureThumbnailImage()
  }

  /// Kicks off preview generation (off-main) if not already cached or in flight.
  func ensurePreviewImage() {
    imageGeneration.ensurePreviewImage()
  }

  /// Awaits the preview image, generating it if needed. `nil` after completion
  /// means the data was invalid or the generation was cancelled; cancellation
  /// is expected when the decorator is invalidated/superseded, so only genuine
  /// decode failures are logged (they would otherwise look like an empty clipboard).
  func asyncGetPreviewImage() async -> NSImage? {
    await imageGeneration.asyncGetPreviewImage()
  }

  /// Marks the decorator invalidated and drops all transient images.
  func invalidate() {
    imageGeneration.invalidate()
    textPreviewCache = nil
  }

  /// Drops all transient images (preview, thumbnail, decoded cache, text/blob).
  func cleanupImages() {
    releaseTransientImages(.invalidate)
  }

  /// Drops transient images per `reason`. `.scrollOut` keeps the cheap thumbnail
  /// (list scroll reuses it fast) and frees only the preview bitmap; the heavier
  /// reasons also clear thumbnail/text/blob state.
  func releaseTransientImages(_ reason: ReleaseReason) {
    imageGeneration.release(reason)
    switch reason {
    case .scrollOut:
      break
    case .settingChange, .memoryWarning, .invalidate:
      textPreviewCache = nil
    }
  }

  // MARK: - Viewport visibility

  func onAppearInViewport() {
    ensureThumbnailImage()
  }

  func onDisappearFromViewport() {
    releaseTransientImages(.scrollOut)
  }

  /// Cancels an in-flight preview decode and drops the task handle, WITHOUT
  /// clearing a cached `previewImage` (unlike `cleanupImages`). Called when the
  /// lead selection moves off this item (`NavigationManager.leadHistoryItem`
  /// `didSet`) so a stale decode doesn't keep occupying the single serial
  /// `ImageProcessor` actor — previously only `invalidate`/`cleanupImages`
  /// cancelled, so navigating away left the old preview decoding to completion,
  /// piling up behind the actor queue. A re-select of an already-decoded item
  /// stays instant (cache hit in `asyncGetPreviewImage`); a re-select of a
  /// cancelled-uncached item re-kicks via `ensurePreviewImage` (the nil'd handle
  /// lets it through).
  func cancelPreviewGeneration() {
    imageGeneration.cancelPreviewGeneration()
  }

  /// Kicks off (preview, thumbnail) generation. Used by `sizeImages()` for the
  /// benchmark/tests that want both rendered; production paths call the
  /// individual `ensure*` accessors as the view appears.
  func sizeImages() {
    imageGeneration.sizeImages()
  }

  /// Builds `attributedTitle` with `query`'s `ranges` styled per the highlight
  /// preference; clears highlighting when `query` or `title` is empty. A repeat
  /// call whose title, ranges, and highlight style all match the previous build
  /// returns without rebuilding or reassigning — skipping both the
  /// `AttributedString` construction and the `@Observable` trigger that would
  /// re-rasterize the row.
  func highlight(_ query: String, _ ranges: [Range<String.Index>]) {
    switch rowHighlighter.title(
      query: query,
      text: title,
      ranges: ranges,
      style: Defaults[.highlightMatch]
    ) {
    case .unchanged:
      return
    case .replacement(let attributed):
      attributedTitle = attributed
    }
  }

  /// Builds `previewAttributedText` over the body text with the given
  /// body-relative grapheme `ranges` highlighted, clamped to the preview window:
  /// ranges past `text.count` are deep matches, left for the scrollable text
  /// view. Clears when `query` or `text` is empty. A repeat call whose text,
  /// ranges, and highlight style all match the previous build returns without
  /// rebuilding or reassigning.
  func setPreviewHighlight(_ query: String, _ ranges: [Range<Int>]) {
    previewBodyQuery = query
    previewBodyRanges = ranges
    switch rowHighlighter.preview(
      query: query,
      text: text,
      ranges: ranges,
      style: Defaults[.highlightMatch]
    ) {
    case .unchanged:
      return
    case .replacement(let attributed):
      previewAttributedText = attributed
    }
  }
}
