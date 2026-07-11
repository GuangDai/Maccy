import XCTest
@testable import Maccy

/// Tests for `SignatureIndex`, the in-memory dedup index mapping content
/// signatures to item ids. Covers exact-signature lookup, per-entry containment
/// lookup (so re-copying plain text after a rich copy merges rather than
/// duplicates), and incremental register/remove behavior.
class SignatureIndexTests: XCTestCase {
  /// A registered signature resolves back to its item id.
  func testLookupReturnsRegisteredID() {
    let itemID = UUID()
    var index = SignatureIndex<UUID>()

    index.register(textSignature, id: itemID)

    XCTAssertEqual(index.lookup(textSignature), itemID)
  }

  /// Signature entry order within a signature does not affect lookup.
  func testSignatureEntriesAreOrderIndependent() {
    let itemID = UUID()
    var index = SignatureIndex<UUID>()

    index.register(mixedSignature, id: itemID)

    XCTAssertEqual(index.lookup(reorderedMixedSignature), itemID)
  }

  /// Removing an item id drops every signature registered against it.
  func testRemoveDeletesAllSignaturesForID() {
    let itemID = UUID()
    var index = SignatureIndex<UUID>()
    index.bulkRegister([
      (textSignature, itemID),
      (imageSignature, itemID)
    ])

    index.remove(id: itemID)

    XCTAssertNil(index.lookup(textSignature))
    XCTAssertNil(index.lookup(imageSignature))
  }

  /// The initializer builds the index from a batch of (signature, id) pairs.
  func testBulkRegisterBuildsIndex() {
    let textID = UUID()
    let imageID = UUID()

    let index = SignatureIndex([
      (textSignature, textID),
      (imageSignature, imageID)
    ])

    XCTAssertEqual(index.lookup(textSignature), textID)
    XCTAssertEqual(index.lookup(imageSignature), imageID)
  }

  /// Re-registering a signature under a new id, then removing the old id,
  /// leaves the signature pointing at the new id.
  func testRegisterMovesSignatureToNewID() {
    let oldID = UUID()
    let newID = UUID()
    var index = SignatureIndex<UUID>()

    index.register(textSignature, id: oldID)
    index.register(textSignature, id: newID)
    index.remove(id: oldID)

    XCTAssertEqual(index.lookup(textSignature), newID)
  }

  /// An ingest request whose content exactly matches a registered signature
  /// surfaces that item id as a candidate.
  func testCandidatesReturnsIDForExactMatch() {
    let itemID = UUID()
    var index = SignatureIndex<UUID>()
    index.register(textSignature, id: itemID)

    let request = IngestRequest(
      source: CopyOrigin(changeCount: 1),
      contents: [
        ContentDTO(
          type: "public.utf8-plain-text",
          value: nil,
          fingerprint: 100,
          size: 12
        )
      ],
      application: nil,
      now: Date(timeIntervalSince1970: 0),
      policy: .standard
    )

    XCTAssertEqual(index.candidates(for: request), [itemID])
  }

  /// An ingest request sharing no signature yields no candidates.
  func testCandidatesReturnsEmptyForNoMatch() {
    var index = SignatureIndex<UUID>()
    index.register(textSignature, id: UUID())

    let request = IngestRequest(
      source: CopyOrigin(changeCount: 1),
      contents: [
        ContentDTO(
          type: "public.png",
          value: nil,
          fingerprint: 999,
          size: 64
        )
      ],
      application: nil,
      now: Date(timeIntervalSince1970: 0),
      policy: .standard
    )

    XCTAssertEqual(index.candidates(for: request), [])
  }

  // MARK: - Per-entry containment candidates

  private var textEntry: ContentSignatureEntry {
    ContentSignatureEntry(type: "public.utf8-plain-text", fingerprint: 100, size: 12)
  }

  private var imageEntry: ContentSignatureEntry {
    ContentSignatureEntry(type: "public.png", fingerprint: 200, size: 64)
  }

  /// A superset item (string + image) must surface when only its string entry is
  /// queried — this is the containment case the old exact-match index missed and the
  /// reason a per-entry index is required (otherwise re-copying plain text after a
  /// rich copy of the same text would create a duplicate instead of merging).
  func testCandidatesForEntriesReturnsSupersetItem() {
    let itemID = UUID()
    var index = SignatureIndex<UUID>()
    index.register(mixedSignature, id: itemID)

    XCTAssertEqual(index.candidates(forEntries: [textEntry]), [itemID])
  }

  /// Querying the exact entry of a single-entry item returns that item.
  func testCandidatesForEntriesReturnsExactItem() {
    let itemID = UUID()
    var index = SignatureIndex<UUID>()
    index.register(textSignature, id: itemID)

    XCTAssertEqual(index.candidates(forEntries: [textEntry]), [itemID])
  }

  /// Genuinely-new content (no shared entry) yields no candidates — the O(1) fast
  /// path that lets the actor skip the full-table scan for the common case.
  func testCandidatesForEntriesEmptyForNovelContent() {
    let itemID = UUID()
    var index = SignatureIndex<UUID>()
    index.register(imageSignature, id: itemID)

    XCTAssertEqual(index.candidates(forEntries: [textEntry]), [])
  }

  /// An item matching on several entries is returned once, not once per entry.
  func testCandidatesForEntriesDedupesOverlap() {
    let itemID = UUID()
    var index = SignatureIndex<UUID>()
    index.register(mixedSignature, id: itemID)

    XCTAssertEqual(index.candidates(forEntries: [textEntry, imageEntry]), [itemID])
  }

  /// Multiple items sharing an entry all surface as candidates (confirm narrows them).
  func testCandidatesForEntriesReturnsAllSharingItems() {
    let idA = UUID()
    let idB = UUID()
    var index = SignatureIndex<UUID>()
    index.register(textSignature, id: idA)
    index.register(textSignature, id: idB)

    XCTAssertEqual(Set(index.candidates(forEntries: [textEntry])), Set([idA, idB]))
  }

  /// Removing an item id clears its per-entry candidate membership.
  func testRemoveClearsEntryCandidates() {
    let itemID = UUID()
    var index = SignatureIndex<UUID>()
    index.register(textSignature, id: itemID)
    index.remove(id: itemID)

    XCTAssertEqual(index.candidates(forEntries: [textEntry]), [])
  }

  /// After a full signature moves to a new id, the old id's per-entry membership is
  /// gone too (no stale candidates).
  func testRegisterMoveThenRemoveOldIDClearsEntryCandidates() {
    let oldID = UUID()
    let newID = UUID()
    var index = SignatureIndex<UUID>()
    index.register(textSignature, id: oldID)
    index.register(textSignature, id: newID)
    index.remove(id: oldID)

    XCTAssertEqual(index.candidates(forEntries: [textEntry]), [newID])
  }

  /// A single plain-text-content signature.
  private var textSignature: SignatureDTO {
    SignatureDTO(entries: [
      ContentSignatureEntry(type: "public.utf8-plain-text", fingerprint: 100, size: 12)
    ])
  }

  /// A single image-content signature.
  private var imageSignature: SignatureDTO {
    SignatureDTO(entries: [
      ContentSignatureEntry(type: "public.png", fingerprint: 200, size: 64)
    ])
  }

  /// A multi-entry signature carrying both image and text content.
  private var mixedSignature: SignatureDTO {
    SignatureDTO(entries: [
      ContentSignatureEntry(type: "public.png", fingerprint: 200, size: 64),
      ContentSignatureEntry(type: "public.utf8-plain-text", fingerprint: 100, size: 12)
    ])
  }

  /// The same entries as `mixedSignature` in reversed order.
  private var reorderedMixedSignature: SignatureDTO {
    SignatureDTO(entries: [
      ContentSignatureEntry(type: "public.utf8-plain-text", fingerprint: 100, size: 12),
      ContentSignatureEntry(type: "public.png", fingerprint: 200, size: 64)
    ])
  }

}
