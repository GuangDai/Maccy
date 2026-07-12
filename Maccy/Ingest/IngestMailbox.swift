import Foundation

/// Lossless FIFO backpressure between pasteboard polling and the ingest actor.
///
/// A burst creates one drain task. Requests captured while an ingest is in
/// flight remain queued, so only one actor call is outstanding at a time and
/// every observed clipboard snapshot is delivered in submission order.
@MainActor
final class IngestMailbox {
  private struct Entry {
    let request: IngestRequest
    let ingestor: any ClipboardIngestor
    let completion: @MainActor (IngestResult) -> Void
  }

  private var entries: [Entry] = []
  private var nextIndex = 0
  private var drainTask: Task<Void, Never>?

  /// Enqueues one observed copy and starts the shared drain when idle.
  func submit(
    _ request: IngestRequest,
    to ingestor: any ClipboardIngestor,
    completion: @escaping @MainActor (IngestResult) -> Void
  ) {
    entries.append(Entry(request: request, ingestor: ingestor, completion: completion))
    guard drainTask == nil else { return }

    drainTask = Task { @MainActor [weak self] in
      await self?.drain()
    }
  }

  /// Drains by index instead of `removeFirst()` so a burst stays O(requests).
  private func drain() async {
    while nextIndex < entries.count {
      let entry = entries[nextIndex]
      nextIndex += 1
      let result = await entry.ingestor.ingest(entry.request)
      entry.completion(result)
    }

    entries.removeAll(keepingCapacity: true)
    nextIndex = 0
    drainTask = nil
  }
}
