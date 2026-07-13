import XCTest
@testable import Maccy

/// Locks memory-pressure cleanup to the resources owned by the attached
/// History composition, rather than a process-wide cache singleton.
@MainActor
final class MemoryGovernanceTests: XCTestCase {
  func testMemoryWarningPurgesImagesOwnedByAttachedHistory() {
    let history = RecordingHistoryRef()
    let governor = MemoryGovernor()
    governor.attach(history: history)

    governor.handleMemoryWarning()

    XCTAssertEqual(history.applicationImagePurgeCount, 1)
  }
}

@MainActor
private final class RecordingHistoryRef: HistoryRef {
  private(set) var applicationImagePurgeCount = 0

  func decorators() -> [HistoryItemDecorator] { [] }

  func purgeApplicationImages() {
    applicationImagePurgeCount += 1
  }
}
