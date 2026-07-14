import AsyncAlgorithms
import Defaults
import Foundation
import Observation

/// Actor backend hidden behind the main-actor search session.
protocol HistorySearchBackend: Sendable {
  func search(query: String, mode: Search.Mode) async -> [SearchMatchDTO]
  func replaceCorpus(_ sources: [SearchCorpusSource], bodyLimit: Int) async
  func insert(_ source: SearchCorpusSource, bodyLimit: Int, at position: Int) async
  func remove(_ ids: [UUID]) async
  func clearCorpus() async
}

extension SearchActor: HistorySearchBackend {}

/// Owns query debouncing, corpus projection, staleness, result lookup, and
/// visible-result publication for clipboard history search.
@MainActor
@Observable
final class HistorySearchSession {
  var query = "" {
    didSet {
      queryContinuation.yield(query)
    }
  }

  @ObservationIgnored private(set) var generation = 0
  @ObservationIgnored private let listState: HistoryListState
  @ObservationIgnored private let backend: any HistorySearchBackend
  @ObservationIgnored private let modeProvider: @MainActor () -> Search.Mode
  @ObservationIgnored private let bodyLimitProvider: @MainActor () -> Int
  @ObservationIgnored private let queryStream: AsyncStream<String>
  @ObservationIgnored private let queryContinuation: AsyncStream<String>.Continuation
  @ObservationIgnored private var consumer: Task<Void, Never>?
  @ObservationIgnored private var searchTask: Task<Void, Never>?
  @ObservationIgnored private var corpusUpdateTask: Task<Void, Never>?
  @ObservationIgnored private var decoratorsByID: [UUID: HistoryItemDecorator] = [:]
  @ObservationIgnored private var uiEffectSink: HistoryUIEffectSink = { _ in }
  @ObservationIgnored private var didPublishVisible: @MainActor () -> Void = {}

  init(
    listState: HistoryListState,
    backend: any HistorySearchBackend = SearchActor(),
    debounce: Duration? = .milliseconds(200),
    modeProvider: @escaping @MainActor () -> Search.Mode = { Defaults[.searchMode] },
    bodyLimitProvider: @escaping @MainActor () -> Int = { Defaults[.searchBodyLimit] }
  ) {
    self.listState = listState
    self.backend = backend
    self.modeProvider = modeProvider
    self.bodyLimitProvider = bodyLimitProvider

    var continuation: AsyncStream<String>.Continuation!
    let stream = AsyncStream<String> { continuation = $0 }
    queryStream = stream
    queryContinuation = continuation

    if let debounce {
      startConsumer(debounce: debounce)
    }
  }

  /// Installs the composition-owned interpreter for outward UI requests.
  func configureUIEffectSink(_ sink: @escaping HistoryUIEffectSink) {
    uiEffectSink = sink
  }

  /// Installs list-display work that follows every visible publication.
  func configureDidPublishVisible(_ action: @escaping @MainActor () -> Void) {
    didPublishVisible = action
  }

  /// Awaits the latest in-flight search, if any.
  func wait() async {
    await searchTask?.value
  }

  /// Invalidates the current search so a late actor result cannot publish.
  func invalidate() {
    generation &+= 1
    searchTask?.cancel()
    searchTask = nil
  }

  /// Runs the current query immediately under `mode`, bypassing debounce.
  func refresh(mode: Search.Mode) {
    if query.isEmpty {
      publishCompleteList()
      return
    }

    generation &+= 1
    let requestedGeneration = generation
    let requestedQuery = query
    let backend = backend
    let pendingCorpusUpdate = corpusUpdateTask
    searchTask?.cancel()
    searchTask = Task { [weak self] in
      await pendingCorpusUpdate?.value
      let matches = await backend.search(query: requestedQuery, mode: mode)
      guard !Task.isCancelled, let self else { return }
      self.apply(matches, query: requestedQuery, generation: requestedGeneration)
    }
  }

  /// Publishes the complete list when no query is active; otherwise re-runs
  /// the actor search. This is the single visible-projection refresh policy
  /// shared by the History facade and persistence projector.
  func refreshVisibleItems(mode: Search.Mode) {
    if query.isEmpty {
      listState.publishVisible(listState.all)
      didPublishVisible()
    } else {
      refresh(mode: mode)
    }
  }

  /// Replaces the owned corpus and O(1) result lookup in complete-list order.
  func replaceCorpus(_ decorators: [HistoryItemDecorator]) {
    invalidate()
    decoratorsByID = Dictionary(
      uniqueKeysWithValues: decorators.map { ($0.id, $0) }
    )
    let sources = decorators.map { corpusSource(for: $0) }
    let bodyLimit = bodyLimitProvider()
    enqueueCorpusUpdate { backend in
      await backend.replaceCorpus(sources, bodyLimit: bodyLimit)
    }
  }

  /// Inserts one decorator into both corpus owners at the same list position.
  func insertCorpus(_ decorator: HistoryItemDecorator, at position: Int) {
    decoratorsByID[decorator.id] = decorator
    let source = corpusSource(for: decorator)
    let bodyLimit = bodyLimitProvider()
    enqueueCorpusUpdate { backend in
      await backend.insert(source, bodyLimit: bodyLimit, at: position)
    }
  }

  /// Removes decorators from both corpus owners by stable decorator id.
  func removeCorpus(_ ids: [UUID]) {
    for id in ids {
      decoratorsByID.removeValue(forKey: id)
    }
    enqueueCorpusUpdate { backend in
      await backend.remove(ids)
    }
  }

  /// Clears both corpus owners.
  func clearCorpus() {
    decoratorsByID.removeAll()
    enqueueCorpusUpdate { backend in
      await backend.clearCorpus()
    }
  }

  private func enqueueCorpusUpdate(
    _ operation: @escaping @Sendable (any HistorySearchBackend) async -> Void
  ) {
    let previous = corpusUpdateTask
    let backend = backend
    corpusUpdateTask = Task {
      await previous?.value
      await operation(backend)
    }
  }

  private func startConsumer(debounce: Duration) {
    let stream = queryStream
    consumer = Task { @MainActor [weak self] in
      for await _ in stream.removeDuplicates().debounce(for: debounce) {
        guard let self else { return }
        self.refresh(mode: self.modeProvider())
      }
    }
  }

  private func publishCompleteList() {
    invalidate()
    for decorator in listState.all {
      decorator.highlight("", [])
      decorator.setPreviewHighlight("", [])
    }
    listState.publishVisible(listState.all)
    didPublishVisible()
    let firstUnpinned = listState.items.first(where: \.isUnpinned)
    uiEffectSink(.select(firstUnpinned))
    uiEffectSink(.resizePopup)
  }

  private func apply(_ matches: [SearchMatchDTO], query: String, generation: Int) {
    guard self.generation == generation else { return }

    var seen: Set<UUID> = []
    var visible: [HistoryItemDecorator] = []
    for match in matches where seen.insert(match.id).inserted {
      guard let decorator = decoratorsByID[match.id] else { continue }
      applyHighlight(match, query: query, to: decorator)
      visible.append(decorator)
    }
    listState.publishVisible(visible)
    didPublishVisible()
    uiEffectSink(.highlightFirst)
    uiEffectSink(.resizePopup)
  }

  private func applyHighlight(
    _ match: SearchMatchDTO,
    query: String,
    to decorator: HistoryItemDecorator
  ) {
    if match.inBody {
      decorator.highlight("", [])
      decorator.setPreviewHighlight(query, match.ranges)
    } else if decorator.title == match.title {
      let ranges = match.ranges.map { indexRange($0, in: decorator.title) }
      decorator.highlight(query, ranges)
      decorator.setPreviewHighlight("", [])
    } else {
      decorator.highlight("", [])
      decorator.setPreviewHighlight("", [])
    }
  }

  private func corpusSource(for decorator: HistoryItemDecorator) -> SearchCorpusSource {
    SearchCorpusSource(
      id: decorator.id,
      title: decorator.title,
      body: decorator.item.searchText ?? ""
    )
  }

  private func indexRange(_ range: Range<Int>, in title: String) -> Range<String.Index> {
    let count = title.count
    let lower = max(0, min(range.lowerBound, count))
    let upper = max(lower, min(range.upperBound, count))
    let start = title.startIndex
    return title.index(start, offsetBy: lower)..<title.index(start, offsetBy: upper)
  }
}
