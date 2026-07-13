/// Owns the image resources needed to turn one persisted history model into its
/// main-actor row decorator. Production and tests choose the resource lifetime
/// explicitly; the decorator itself never reaches a process-wide cache.
@MainActor
struct HistoryItemDecoratorFactory {
  let imageProcessor: any ImageProcessing
  private let applicationImage: @MainActor (HistoryItem) -> ApplicationImage
  private let purgeApplicationImagesAction: @MainActor () -> Void

  init(
    imageProcessor: any ImageProcessing,
    applicationImage: @escaping @MainActor (HistoryItem) -> ApplicationImage,
    purgeApplicationImages: @escaping @MainActor () -> Void
  ) {
    self.imageProcessor = imageProcessor
    self.applicationImage = applicationImage
    self.purgeApplicationImagesAction = purgeApplicationImages
  }

  init(
    imageProcessor: any ImageProcessing,
    applicationImages: ApplicationImageCache
  ) {
    self.init(
      imageProcessor: imageProcessor,
      applicationImage: { applicationImages.getImage(item: $0) },
      purgeApplicationImages: { applicationImages.purge() }
    )
  }

  /// Production resources shared by persisted-row decoration and ingestion.
  static func live() -> HistoryItemDecoratorFactory {
    HistoryItemDecoratorFactory(
      imageProcessor: ImageProcessor(cache: ThumbnailCache()),
      applicationImages: ApplicationImageCache()
    )
  }

  /// Per-History resources for tests and non-application compositions.
  static func isolated() -> HistoryItemDecoratorFactory {
    HistoryItemDecoratorFactory(
      imageProcessor: PassthroughImageProcessor(),
      applicationImages: ApplicationImageCache()
    )
  }

  func make(
    _ item: HistoryItem,
    shortcuts: [KeyShortcut] = []
  ) -> HistoryItemDecorator {
    HistoryItemDecorator(
      item,
      shortcuts: shortcuts,
      imageProcessor: imageProcessor,
      applicationImage: applicationImage(item)
    )
  }

  func purgeApplicationImages() {
    purgeApplicationImagesAction()
  }
}
