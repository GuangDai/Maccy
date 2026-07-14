import XCTest

@testable import Maccy

/// Tests the search actor's owned corpus: that `replaceCorpus`/`insert`/`remove`
/// /`clearCorpus` keep the corpus and its `all`-order in sync, and that the
/// stateful ``SearchActor/search(query:mode:)`` over the owned corpus agrees with
/// the pure ``SearchActor/search(query:within:mode:)`` over the same entries.
final class SearchCorpusOwnershipTests: XCTestCase {
  private let searchActor = SearchActor()

  /// Builds a corpus item whose id encodes `number`, so `ids(_:)` can recover it.
  private func item(_ number: Int, _ title: String, body: String = "") -> SearchCorpusItem {
    let suffix = String(format: "%012d", number)
    return SearchCorpusItem(
      id: UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!,
      title: title,
      body: body
    )
  }

  /// Builds an uncapped source whose id encodes `number`.
  private func source(_ number: Int, _ title: String, body: String = "") -> SearchCorpusSource {
    let suffix = String(format: "%012d", number)
    return SearchCorpusSource(
      id: UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!,
      title: title,
      body: body
    )
  }

  /// Extracts the trailing integer each result id encodes, in match order.
  private func ids(_ results: [SearchMatchDTO]) -> [Int] {
    results.compactMap { Int($0.id.uuidString.suffix(12)) }
  }

  /// `replaceCorpus` seeds the full corpus; an empty query returns every entry
  /// in the order given.
  func testReplaceCorpusSeedsCorpusInOrder() async {
    await searchActor.replaceCorpus(
      [source(1, "foo"), source(2, "bar"), source(3, "baz")],
      bodyLimit: TextLimits.searchBodyMax
    )

    let results = await searchActor.search(query: "", mode: .exact)
    XCTAssertEqual(ids(results), [1, 2, 3])
  }

  func testOwnedCorpusCapsSourceBodyAtActorBoundary() async {
    let body = "inside-marker" + String(repeating: "x", count: TextLimits.searchBodyMin)
      + "outside-marker"
    await searchActor.replaceCorpus(
      [source(1, "title", body: body)],
      bodyLimit: TextLimits.searchBodyMin
    )

    let inside = await searchActor.search(query: "inside-marker", mode: .exact)
    let outside = await searchActor.search(query: "outside-marker", mode: .exact)

    XCTAssertEqual(ids(inside), [1])
    XCTAssertTrue(outside.isEmpty)
  }

  /// `insert(at:)` places the entry at the given index, shifting the tail.
  func testInsertAtPositionMaintainsOrder() async {
    await searchActor.replaceCorpus(
      [source(1, "a"), source(2, "c")],
      bodyLimit: TextLimits.searchBodyMax
    )
    await searchActor.insert(
      source(3, "b"),
      bodyLimit: TextLimits.searchBodyMax,
      at: 1
    )

    let results = await searchActor.search(query: "", mode: .exact)
    XCTAssertEqual(ids(results), [1, 3, 2])
  }

  /// Inserting an entry whose id is already present moves it (re-insert), so a
  /// `.merged` re-insert at a new position doesn't leave a stale duplicate.
  func testInsertWithExistingIdMovesIt() async {
    await searchActor.replaceCorpus(
      [source(1, "a"), source(2, "b"), source(3, "c")],
      bodyLimit: TextLimits.searchBodyMax
    )
    await searchActor.insert(
      source(2, "b-moved"),
      bodyLimit: TextLimits.searchBodyMax,
      at: 0
    )

    let results = await searchActor.search(query: "", mode: .exact)
    XCTAssertEqual(ids(results), [2, 1, 3])
    XCTAssertEqual(results.map(\.title), ["b-moved", "a", "c"])
  }

  /// `remove` drops the named entries and preserves the order of the survivors.
  func testRemoveDropsItems() async {
    await searchActor.replaceCorpus(
      [source(1, "a"), source(2, "b"), source(3, "c")],
      bodyLimit: TextLimits.searchBodyMax
    )
    await searchActor.remove([source(2, "b").id])

    let results = await searchActor.search(query: "", mode: .exact)
    XCTAssertEqual(ids(results), [1, 3])
  }

  /// `clearCorpus` empties the corpus, so a query that previously matched now
  /// matches nothing.
  func testClearCorpusEmpties() async {
    await searchActor.replaceCorpus(
      [source(1, "foo"), source(2, "bar")],
      bodyLimit: TextLimits.searchBodyMax
    )
    await searchActor.clearCorpus()

    let results = await searchActor.search(query: "foo", mode: .exact)
    XCTAssertTrue(results.isEmpty)
  }

  /// The stateful search over the owned corpus agrees with the pure search over
  /// the same entries, for every mode — the ownership layer only relocates the
  /// corpus, it does not change match semantics.
  func testOwnedSearchMatchesPureOverCorpus() async {
    let corpus = [item(1, "foo bar"), item(2, "baz qux"), item(3, "xyz")]
    let sources = [source(1, "foo bar"), source(2, "baz qux"), source(3, "xyz")]
    await searchActor.replaceCorpus(sources, bodyLimit: TextLimits.searchBodyMax)

    for mode in Search.Mode.allCases {
      let owned = await searchActor.search(query: "ba", mode: mode)
      let pure = await searchActor.search(query: "ba", within: corpus, mode: mode)
      XCTAssertEqual(ids(owned), ids(pure), "mode \(mode)")
    }
  }
}
