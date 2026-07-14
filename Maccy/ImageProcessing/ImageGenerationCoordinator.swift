import AppKit
import Defaults
import Logging
import Observation

/// Owns the lazy bytes, in-flight work, decoded images, and release policy for
/// one history row. The decorator exposes a compatibility facade; views never
/// depend on this coordinator directly.
@MainActor
@Observable
final class ImageGenerationCoordinator {
  private enum Kind {
    case thumbnail
    case preview
  }

  /// Preview decode/placeholder target size. The longest side is capped at the
  /// configured preview-pixel limit; zero keeps the popup screen size.
  static var previewImageSize: NSSize {
    let raw = NSScreen.forPopup?.visibleFrame.size ?? NSSize(width: 2048, height: 1536)
    let cap = Defaults[.imageMaxPreviewPixels]
    return cap > 0 ? capped(raw, max: CGFloat(cap)) : raw
  }

  /// Stable main-window image target. Source-image dimensions never determine
  /// the row height.
  static var thumbnailImageSize: NSSize {
    NSSize(
      width: 340,
      height: HistoryRowLayout.effectiveImageContentHeight(Defaults[.imageMaxHeight])
    )
  }

  @ObservationIgnored private let imageProcessor: any ImageProcessing
  @ObservationIgnored private let imageDataLoader: @MainActor () -> Data?
  @ObservationIgnored private let logger = Logger(label: "org.p0deje.Maccy")
  @ObservationIgnored private var imageDataCache: Data?
  @ObservationIgnored private var imageDataCacheLoaded = false
  @ObservationIgnored private var hasImageContentCache: Bool?
  @ObservationIgnored private var isInvalidated = false
  @ObservationIgnored private(set) var previewImageGenerationTask: Task<Void, Never>?
  @ObservationIgnored private(set) var thumbnailImageGenerationTask: Task<Void, Never>?

  var previewImage: NSImage?
  var thumbnailImage: NSImage?

  var hasImage: Bool {
    if let hasImageContentCache { return hasImageContentCache }
    let hasImage = imageData != nil
    hasImageContentCache = hasImage
    return hasImage
  }

  private var imageData: Data? {
    if !imageDataCacheLoaded {
      imageDataCache = isInvalidated ? nil : imageDataLoader()
      imageDataCacheLoaded = true
    }
    return imageDataCache
  }

  init(
    imageProcessor: any ImageProcessing,
    imageData: @escaping @MainActor () -> Data?
  ) {
    self.imageProcessor = imageProcessor
    self.imageDataLoader = imageData
  }

  func ensureThumbnailImage() {
    guard imageData != nil, thumbnailImage == nil, thumbnailImageGenerationTask == nil else {
      return
    }
    thumbnailImageGenerationTask = startGeneration(.thumbnail)
  }

  func ensurePreviewImage() {
    guard imageData != nil, previewImage == nil, previewImageGenerationTask == nil else {
      return
    }
    previewImageGenerationTask = startGeneration(.preview)
  }

  func asyncGetPreviewImage() async -> NSImage? {
    if let previewImage {
      return previewImage
    }
    ensurePreviewImage()
    _ = await previewImageGenerationTask?.result
    if previewImage == nil, !isInvalidated {
      logger.error("preview image generation produced no image (corrupt data)")
    }
    return previewImage
  }

  func cancelPreviewGeneration() {
    previewImageGenerationTask?.cancel()
    previewImageGenerationTask = nil
  }

  func sizeImages() {
    ensurePreviewImage()
    ensureThumbnailImage()
  }

  func release(_ reason: ReleaseReason) {
    switch reason {
    case .scrollOut:
      previewImageGenerationTask?.cancel()
      previewImageGenerationTask = nil
      previewImage = nil
    case .settingChange, .memoryWarning, .invalidate:
      thumbnailImageGenerationTask?.cancel()
      previewImageGenerationTask?.cancel()
      thumbnailImageGenerationTask = nil
      previewImageGenerationTask = nil
      thumbnailImage = nil
      previewImage = nil
      imageDataCache = nil
      imageDataCacheLoaded = false
    }
  }

  func invalidate() {
    isInvalidated = true
    release(.invalidate)
  }

  private func startGeneration(_ kind: Kind) -> Task<Void, Never>? {
    guard let imageData else { return nil }
    let processor = imageProcessor
    let target = targetSize(for: kind)

    return Task { @MainActor [weak self] in
      #if DEBUG
      let timing: (
        clock: ContinuousClock,
        totalStart: ContinuousClock.Instant,
        decodeStart: ContinuousClock.Instant
      )? = {
        guard PerfRecorder.enabled else { return nil }
        let clock = ContinuousClock()
        return (clock, clock.now, clock.now)
      }()
      #endif

      let image: NSImage?
      switch kind {
      case .thumbnail:
        image = await processor.thumbnail(for: imageData, max: target)
      case .preview:
        image = await processor.preview(for: imageData, max: target)
      }

      #if DEBUG
      let decodeEnd = timing?.clock.now
      #endif

      guard let self, !self.isInvalidated else { return }
      self.publish(image, for: kind)

      #if DEBUG
      if let timing, let decodeEnd {
        let total = timing.totalStart.duration(to: timing.clock.now)
        let decode = timing.decodeStart.duration(to: decodeEnd)
        self.record(
          kind,
          latency: total,
          mainBlock: max(Duration.zero, total - decode)
        )
      }
      #endif
    }
  }

  private func targetSize(for kind: Kind) -> NSSize {
    switch kind {
    case .thumbnail:
      Self.thumbnailImageSize
    case .preview:
      Self.previewImageSize
    }
  }

  private func publish(_ image: NSImage?, for kind: Kind) {
    switch kind {
    case .thumbnail:
      thumbnailImage = image
    case .preview:
      previewImage = image
    }
  }

  #if DEBUG
  private func record(_ kind: Kind, latency: Duration, mainBlock: Duration) {
    switch kind {
    case .thumbnail:
      PerfRecorder.shared.recordThumbnail(latency: latency, mainBlock: mainBlock)
    case .preview:
      PerfRecorder.shared.recordPreview(latency: latency, mainBlock: mainBlock)
    }
  }
  #endif

  private static func capped(_ size: NSSize, max maxPixels: CGFloat) -> NSSize {
    let longest = max(size.width, size.height)
    guard longest > maxPixels, longest > 0 else { return size }
    let scale = maxPixels / longest
    return NSSize(width: size.width * scale, height: size.height * scale)
  }
}
