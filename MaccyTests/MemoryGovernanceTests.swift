import XCTest
@testable import Maccy

/// Locks memory-pressure cleanup to the resources owned by the attached
/// History composition, rather than a process-wide cache singleton.
@MainActor
final class MemoryGovernanceTests: XCTestCase {
  func testMemoryWarningPurgesImagesOwnedByAttachedHistory() {
    var applicationImagePurgeCount = 0
    let factory = HistoryItemDecoratorFactory(
      imageProcessor: PassthroughImageProcessor(),
      applicationImage: { _ in ApplicationImage(bundleIdentifier: nil) },
      purgeApplicationImages: { applicationImagePurgeCount += 1 }
    )
    let storage = Storage(storedInMemoryForTesting: true)
    let history = History(
      persistence: SwiftDataHistoryPersistence(context: storage.context),
      decoratorFactory: factory,
      logsPersistenceErrors: false
    )
    let governor = MemoryGovernor()
    governor.attach(history: history)

    governor.handleMemoryWarning()

    XCTAssertEqual(applicationImagePurgeCount, 1)
  }
}
