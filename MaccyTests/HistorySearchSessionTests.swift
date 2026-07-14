import Foundation
import XCTest
@testable import Maccy

/// Defines the cohesive search session extracted from History: corpus
/// ownership, staleness, result projection, highlighting, and UI requests.
@MainActor
final class HistorySearchSessionTests: XCTestCase {
  func testEmptyQueryPublishesCompleteListSynchronously() {
    let first = decorator(title: "first", body: "first")
    let second = decorator(title: "second", body: "second")
    let state = HistoryListState(decorators: [first, second])
    state.publishVisible([])
    let session = makeSession(state: state, backend: ControlledSearchBackend())
    var effects: [HistoryUIEffect] = []
    session.configureUIEffectSink { effects.append($0) }

    session.refresh(mode: .exact)

    XCTAssertEqual(state.items, [first, second])
    XCTAssertTrue(effects.contains { effect in
      guard case .select(let selected) = effect else { return false }
      return selected === first
    })
    XCTAssertTrue(effects.contains { if case .resizePopup = $0 { true } else { false } })
  }

  func testLateResultCannotOverwriteNewerQuery() async {
    let old = decorator(title: "old", body: "old")
    let new = decorator(title: "new", body: "new")
    let state = HistoryListState(decorators: [old, new])
    let backend = ControlledSearchBackend()
    let session = makeSession(state: state, backend: backend)
    session.replaceCorpus([old, new])

    session.query = "old"
    session.refresh(mode: .exact)
    await backend.waitUntilPending("old")

    session.query = "new"
    session.refresh(mode: .exact)
    await backend.waitUntilPending("new")
    await backend.resolve("new", with: [match(new)])
    await session.wait()

    await backend.resolve("old", with: [match(old)])
    await Task.yield()

    XCTAssertEqual(state.items, [new])
  }

  func testReplaceCorpusInvalidatesCurrentGeneration() {
    let item = decorator(title: "item", body: "body")
    let state = HistoryListState(decorators: [item])
    let session = makeSession(state: state, backend: ControlledSearchBackend())
    let generationBeforeReplacement = session.generation

    session.replaceCorpus([item])

    XCTAssertEqual(session.generation, generationBeforeReplacement + 1)
  }

  func testReplaceCorpusDefersBodyCappingToBackend() async {
    let body = String(repeating: "a", count: TextLimits.searchBodyMin + 1)
    let item = decorator(title: "item", body: body)
    let state = HistoryListState(decorators: [item])
    let backend = CorpusSourceRecorder()
    let session = HistorySearchSession(
      listState: state,
      backend: backend,
      debounce: nil,
      bodyLimitProvider: { TextLimits.searchBodyMin }
    )

    session.replaceCorpus([item])
    let replacement = await backend.waitForReplacement()

    XCTAssertEqual(replacement.sources.map(\.body), [body])
    XCTAssertEqual(replacement.bodyLimit, TextLimits.searchBodyMin)
  }

  func testMissingAndDuplicateResultIDsPublishOneKnownDecorator() async {
    let known = decorator(title: "known", body: "known")
    let state = HistoryListState(decorators: [known])
    let missingID = UUID()
    let backend = ImmediateSearchBackend(results: [
      match(known),
      match(known),
      SearchMatchDTO(id: missingID, title: "missing", score: nil, ranges: [])
    ])
    let session = makeSession(state: state, backend: backend)
    session.replaceCorpus([known])

    session.query = "known"
    session.refresh(mode: .exact)
    await session.wait()

    XCTAssertEqual(state.items, [known])
  }

  func testCorpusInsertAndRemovePreserveListOrder() async {
    let first = decorator(title: "item-a", body: "a")
    let second = decorator(title: "item-b", body: "b")
    let third = decorator(title: "item-c", body: "c")
    let state = HistoryListState(decorators: [first, third])
    let session = makeSession(state: state, backend: SearchActor())
    session.replaceCorpus([first, third])
    state.insert(second, at: 1)
    session.insertCorpus(second, at: 1)
    state.remove(third)
    session.removeCorpus([third.id])

    session.query = "item"
    session.refresh(mode: .exact)
    await session.wait()

    XCTAssertEqual(state.items, [first, second])
  }

  func testBodyMatchPublishesPreviewHighlightWithoutTitleHighlight() async {
    let item = decorator(title: "display", body: "prefix needle suffix")
    let state = HistoryListState(decorators: [item])
    let session = makeSession(state: state, backend: SearchActor())
    session.replaceCorpus([item])

    session.query = "needle"
    session.refresh(mode: .exact)
    await session.wait()

    XCTAssertEqual(state.items, [item])
    XCTAssertNil(item.attributedTitle)
    XCTAssertNotNil(item.previewAttributedText)
  }

  func testModeRefreshReusesCorpusWithNewMode() async {
    let item = decorator(title: "abc", body: "abc")
    let state = HistoryListState(decorators: [item])
    let session = makeSession(state: state, backend: SearchActor())
    session.replaceCorpus([item])
    session.query = "a.c"

    session.refresh(mode: .exact)
    await session.wait()
    XCTAssertTrue(state.items.isEmpty)

    session.refresh(mode: .regexp)
    await session.wait()
    XCTAssertEqual(state.items, [item])
  }

  private func makeSession(
    state: HistoryListState,
    backend: any HistorySearchBackend
  ) -> HistorySearchSession {
    HistorySearchSession(
      listState: state,
      backend: backend,
      debounce: nil,
      modeProvider: { .exact }
    )
  }

  private func decorator(title: String, body: String) -> HistoryItemDecorator {
    let item = HistoryBuilder()
      .withContent(type: "public.utf8-plain-text", value: Data(body.utf8))
      .withTitle(title)
      .build()
    item.searchText = body
    return HistoryItemDecorator(item)
  }

  private func match(_ decorator: HistoryItemDecorator) -> SearchMatchDTO {
    SearchMatchDTO(id: decorator.id, title: decorator.title, score: nil, ranges: [])
  }
}

private struct RecordedCorpusReplacement: Sendable {
  let sources: [SearchCorpusSource]
  let bodyLimit: Int
}

private actor CorpusSourceRecorder: HistorySearchBackend {
  private var replacement: RecordedCorpusReplacement?

  func waitForReplacement() async -> RecordedCorpusReplacement {
    while true {
      if let replacement {
        return replacement
      }
      await Task.yield()
    }
  }

  func search(query: String, mode: Search.Mode) -> [SearchMatchDTO] { [] }

  func replaceCorpus(_ sources: [SearchCorpusSource], bodyLimit: Int) {
    replacement = RecordedCorpusReplacement(sources: sources, bodyLimit: bodyLimit)
  }

  func insert(_ source: SearchCorpusSource, bodyLimit: Int, at position: Int) {}
  func remove(_ ids: [UUID]) {}
  func clearCorpus() {}
}

private actor ImmediateSearchBackend: HistorySearchBackend {
  let results: [SearchMatchDTO]

  init(results: [SearchMatchDTO]) {
    self.results = results
  }

  func search(query: String, mode: Search.Mode) -> [SearchMatchDTO] { results }
  func replaceCorpus(_ sources: [SearchCorpusSource], bodyLimit: Int) {}
  func insert(_ source: SearchCorpusSource, bodyLimit: Int, at position: Int) {}
  func remove(_ ids: [UUID]) {}
  func clearCorpus() {}
}

private actor ControlledSearchBackend: HistorySearchBackend {
  private var pending: [String: CheckedContinuation<[SearchMatchDTO], Never>] = [:]

  func search(query: String, mode: Search.Mode) async -> [SearchMatchDTO] {
    await withCheckedContinuation { continuation in
      pending[query] = continuation
    }
  }

  func waitUntilPending(_ query: String) async {
    while pending[query] == nil {
      await Task.yield()
    }
  }

  func resolve(_ query: String, with results: [SearchMatchDTO]) {
    pending.removeValue(forKey: query)?.resume(returning: results)
  }

  func replaceCorpus(_ sources: [SearchCorpusSource], bodyLimit: Int) {}
  func insert(_ source: SearchCorpusSource, bodyLimit: Int, at position: Int) {}
  func remove(_ ids: [UUID]) {}
  func clearCorpus() {}
}
