import XCTest
@testable import Maccy

/// Tests for the ingest DTO value types (Sendable conformance and equality semantics).
class DtoTests: XCTestCase {
  /// Every DTO type used across actor boundaries conforms to `Sendable`.
  func testDtoTypesAreSendable() {
    requireSendable(StoredItemID.self)
    requireSendable(ContentDTO.self)
    requireSendable(ClipboardItemDTO.self)
    requireSendable(CopyOrigin.self)
    requireSendable(SignatureDTO.self)
    requireSendable(ContentSignatureEntry.self)
    requireSendable(MaccyFingerprint.self)
    requireSendable(ItemSnapshotDTO.self)
    requireSendable(StoreEvent.self)
    requireSendable(IngestPolicy.self)
    requireSendable(IngestMainActorPlan.self)
    requireSendable(IngestRequest.self)
    requireSendable(IngestResult.self)
    requireSendable(IngestMetrics.self)
  }

  /// `SignatureDTO` equality is driven by content shape (type, fingerprint, size).
  func testSignatureDtoUsesContentShapeForEquality() {
    let entry = ContentSignatureEntry(type: "public.utf8-plain-text", fingerprint: 42, size: 12)
    let signature = SignatureDTO(entries: [entry])

    XCTAssertEqual(signature, SignatureDTO(entries: [entry]))
    XCTAssertNotEqual(
      signature,
      SignatureDTO(entries: [
        ContentSignatureEntry(type: "public.utf8-plain-text", fingerprint: 43, size: 12)
      ])
    )
  }

  /// The standalone signature projection is the exact value carried by a full
  /// item snapshot, including both unhashed small data and fingerprinted large
  /// data. Candidate lookup can therefore reuse it without a parallel mapping.
  @MainActor
  func testSignatureProjectionMatchesSnapshotSignature() {
    let largeValue = Data(repeating: 0x41, count: 16 * 1_024)
    let item = HistoryItem(contents: [
      HistoryItemContent(type: "public.utf8-plain-text", value: Data("small".utf8)),
      HistoryItemContent(type: "public.png", value: largeValue)
    ])

    let signature = signatureDTO(of: item)

    XCTAssertEqual(signature, snapshot(of: item).signature)
    XCTAssertEqual(signature.entries.count, 2)
    XCTAssertEqual(
      signature.entries.first { $0.type == "public.png" }?.fingerprint,
      ClipboardDataProcessor.fingerprintIfLarge(largeValue)
    )
  }

  /// `IngestResult` carries its event and metrics through to the caller.
  @MainActor
  func testIngestResultCarriesEventAndMetrics() {
    let storedItemID = HistoryItem().persistentModelID.id
    let copiedAt = Date(timeIntervalSince1970: 1_717_171_717)
    let signature = SignatureDTO(entries: [
      ContentSignatureEntry(type: "public.utf8-plain-text", fingerprint: 42, size: 10)
    ])
    let snapshot = ItemSnapshotDTO(
      id: storedItemID,
      persistentID: nil,
      title: "Copied text",
      firstCopiedAt: copiedAt,
      lastCopiedAt: copiedAt,
      numberOfCopies: 1,
      pin: nil,
      application: "org.example.App",
      textPreview: "Copied text",
      imageFingerprint: nil,
      signature: signature
    )

    let result = IngestResult(
      event: .added(snapshot),
      metrics: IngestMetrics(dedupHits: 1, bytesHashed: 64, parseMs: 0.25)
    )

    XCTAssertEqual(result.event, .added(snapshot))
    XCTAssertEqual(result.metrics.dedupHits, 1)
    XCTAssertEqual(result.metrics.bytesHashed, 64)
    XCTAssertEqual(result.metrics.parseMs, 0.25)
  }

  /// Asserts the given type conforms to `Sendable` (compile-time check via the generic constraint).
  private func requireSendable<T: Sendable>(_ type: T.Type) {}
}
