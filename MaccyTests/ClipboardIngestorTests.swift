import XCTest
@testable import Maccy

/// Tests for the clipboard ingest protocol.
@MainActor
class ClipboardIngestorTests: XCTestCase {
  /// The ingest protocol accepts any `Sendable` implementation and returns its result.
  func testIngestorProtocolAcceptsSendableImplementations() async {
    let ingestor: any ClipboardIngestor = StubIngestor()
    let result = await ingestor.ingest(
      IngestRequest(
        source: CopyOrigin(changeCount: 1),
        contents: [],
        application: nil,
        now: Date(timeIntervalSince1970: 0),
        policy: .standard
      )
    )

    XCTAssertEqual(result, IngestResult(event: nil, metrics: .zero))
  }
}

/// Minimal `ClipboardIngestor` stub returning an empty result.
private struct StubIngestor: ClipboardIngestor {
  func ingest(_ request: IngestRequest) async -> IngestResult {
    IngestResult(event: nil, metrics: .zero)
  }

  func synchronizeStoreEvents(_ events: [StoreEvent]) async {}
}
