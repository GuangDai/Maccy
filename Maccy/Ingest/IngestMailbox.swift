import Foundation

/// Lossless FIFO backpressure between pasteboard polling and the ingest actor.
///
/// A burst creates one drain task. Requests captured while an ingest is in
/// flight remain queued, so only one actor call is outstanding at a time and
/// every observed clipboard snapshot is delivered in submission order.
@MainActor
final class IngestMailbox {
  private enum Operation {
    case ingest(
      request: IngestRequest,
      ingestor: any ClipboardIngestor,
      completion: @MainActor (IngestResult) -> Void
    )
    case synchronize(events: [StoreEvent], ingestor: any ClipboardIngestor)
  }

  private var operations: [Operation] = []
  private var nextIndex = 0
  private var drainTask: Task<Void, Never>?

  /// Enqueues one observed copy and starts the shared drain when idle.
  func submit(
    _ request: IngestRequest,
    to ingestor: any ClipboardIngestor,
    completion: @escaping @MainActor (IngestResult) -> Void
  ) {
    operations.append(.ingest(request: request, ingestor: ingestor, completion: completion))
    startDrainIfNeeded()
  }

  /// Enqueues committed store events behind any already-observed copies.
  func submit(storeEvents: [StoreEvent], to ingestor: any ClipboardIngestor) {
    guard !storeEvents.isEmpty else { return }
    operations.append(.synchronize(events: storeEvents, ingestor: ingestor))
    startDrainIfNeeded()
  }

  /// Starts the single shared drain task when the mailbox transitions from idle.
  private func startDrainIfNeeded() {
    guard drainTask == nil else { return }

    drainTask = Task { @MainActor [weak self] in
      await self?.drain()
    }
  }

  /// Drains by index instead of `removeFirst()` so a burst stays O(requests).
  private func drain() async {
    while nextIndex < operations.count {
      let operation = operations[nextIndex]
      nextIndex += 1
      switch operation {
      case .ingest(let request, let ingestor, let completion):
        let result = await ingestor.ingest(request)
        completion(result)
      case .synchronize(let events, let ingestor):
        await ingestor.synchronizeStoreEvents(events)
      }
    }

    operations.removeAll(keepingCapacity: true)
    nextIndex = 0
    drainTask = nil
  }
}
