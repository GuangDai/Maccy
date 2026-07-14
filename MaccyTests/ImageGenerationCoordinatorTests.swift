import AppKit
import XCTest
@testable import Maccy

@MainActor
final class ImageGenerationCoordinatorTests: XCTestCase {
  func testLoadsBytesLazilyAndReloadsAfterMemoryRelease() async throws {
    var loads = 0
    let data = try XCTUnwrap(NSImage(named: "StatusBarMenuImage")?.tiffRepresentation)
    let coordinator = ImageGenerationCoordinator(
      imageProcessor: PassthroughImageProcessor(),
      imageData: {
        loads += 1
        return data
      }
    )

    XCTAssertEqual(loads, 0)
    coordinator.ensureThumbnailImage()
    _ = await coordinator.thumbnailImageGenerationTask?.value
    XCTAssertEqual(loads, 1)
    XCTAssertNotNil(coordinator.thumbnailImage)

    coordinator.release(.memoryWarning)
    coordinator.ensureThumbnailImage()
    _ = await coordinator.thumbnailImageGenerationTask?.value
    XCTAssertEqual(loads, 2)
    XCTAssertNotNil(coordinator.thumbnailImage)
  }

  func testScrollOutKeepsThumbnailAndDropsPreview() async throws {
    let data = try XCTUnwrap(NSImage(named: "StatusBarMenuImage")?.tiffRepresentation)
    let coordinator = ImageGenerationCoordinator(
      imageProcessor: PassthroughImageProcessor(),
      imageData: { data }
    )
    coordinator.sizeImages()
    _ = await coordinator.thumbnailImageGenerationTask?.value
    _ = await coordinator.previewImageGenerationTask?.value

    coordinator.release(.scrollOut)

    XCTAssertNotNil(coordinator.thumbnailImage)
    XCTAssertNil(coordinator.previewImage)
    XCTAssertNil(coordinator.previewImageGenerationTask)
  }

  func testInvalidationPreventsImageDataLoad() {
    var loads = 0
    let coordinator = ImageGenerationCoordinator(
      imageProcessor: PassthroughImageProcessor(),
      imageData: {
        loads += 1
        return Data([0])
      }
    )

    coordinator.invalidate()
    coordinator.ensurePreviewImage()

    XCTAssertEqual(loads, 0)
    XCTAssertNil(coordinator.previewImageGenerationTask)
  }

  func testRepeatedEnsureKeepsOneThumbnailInFlight() async {
    let processor = CountingSuspendingImageProcessor()
    let coordinator = ImageGenerationCoordinator(
      imageProcessor: processor,
      imageData: { Data([1]) }
    )

    coordinator.ensureThumbnailImage()
    let task = coordinator.thumbnailImageGenerationTask
    coordinator.ensureThumbnailImage()
    await processor.waitForThumbnail()
    let calls = await processor.thumbnailCallCount()

    XCTAssertEqual(calls, 1)
    coordinator.release(.invalidate)
    _ = await task?.value
  }

  func testInvalidationPreventsLatePreviewPublication() async {
    let processor = GatedPreviewProcessor()
    let coordinator = ImageGenerationCoordinator(
      imageProcessor: processor,
      imageData: { Data([1]) }
    )
    coordinator.ensurePreviewImage()
    let task = coordinator.previewImageGenerationTask
    await processor.waitUntilStarted()

    coordinator.invalidate()
    await processor.finish()
    _ = await task?.value

    XCTAssertNil(coordinator.previewImage)
  }
}

private actor CountingSuspendingImageProcessor: ImageProcessing {
  private var thumbnailCalls = 0
  private var thumbnailWaiters: [CheckedContinuation<Void, Never>] = []

  func thumbnail(for data: Data, max: CGSize) async -> NSImage? {
    thumbnailCalls += 1
    for waiter in thumbnailWaiters {
      waiter.resume()
    }
    thumbnailWaiters.removeAll()
    while !Task.isCancelled {
      await Task.yield()
    }
    return nil
  }

  func preview(for data: Data, max: CGSize) async -> NSImage? { nil }

  func waitForThumbnail() async {
    if thumbnailCalls > 0 { return }
    await withCheckedContinuation { thumbnailWaiters.append($0) }
  }

  func thumbnailCallCount() -> Int { thumbnailCalls }
}

private actor GatedPreviewProcessor: ImageProcessing {
  private var previewStarted = false
  private var previewContinuation: CheckedContinuation<Void, Never>?
  private var startWaiters: [CheckedContinuation<Void, Never>] = []

  func thumbnail(for data: Data, max: CGSize) async -> NSImage? { nil }

  func preview(for data: Data, max: CGSize) async -> NSImage? {
    await withCheckedContinuation { continuation in
      previewContinuation = continuation
      previewStarted = true
      for waiter in startWaiters {
        waiter.resume()
      }
      startWaiters.removeAll()
    }
    return NSImage(size: NSSize(width: 1, height: 1))
  }

  func waitUntilStarted() async {
    if previewStarted { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func finish() {
    previewContinuation?.resume()
    previewContinuation = nil
  }
}
