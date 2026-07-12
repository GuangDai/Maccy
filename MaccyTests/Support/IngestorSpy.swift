import Foundation
@testable import Maccy

actor IngestorSpy: ClipboardIngestor {
  private(set) var requests: [IngestRequest] = []
  private(set) var storeEvents: [StoreEvent] = []
  private(set) var storeEventBatches: [[StoreEvent]] = []
  var result = IngestResult(event: nil, metrics: .zero)

  func ingest(_ request: IngestRequest) async -> IngestResult {
    requests.append(request)
    return result
  }

  func synchronizeStoreEvents(_ events: [StoreEvent]) async {
    storeEventBatches.append(events)
    storeEvents.append(contentsOf: events)
  }
}
