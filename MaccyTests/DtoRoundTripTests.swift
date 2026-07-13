import XCTest
@testable import Maccy

/// Tests that DTO projection functions faithfully round-trip `HistoryItem` fields.
@MainActor
class DtoRoundTripTests: XCTestCase {
  /// `snapshot(of:)` projects only the fields consumed across the actor boundary.
  func testSnapshotProjectsBoundaryFields() {
    let item = HistoryBuilder()
      .withContent(type: "public.utf8-plain-text", value: Data("hello".utf8))
      .withTitle("hello")
      .build()

    let dto = snapshot(of: item)

    XCTAssertEqual(dto.title, "hello")
    XCTAssertEqual(dto.signature, signatureDTO(of: item))
  }

  /// `contentDTOs(of:)` preserves each content entry's type, value, and size.
  func testContentProjectionPreservesContentShape() {
    let text = Data("hello".utf8)
    let item = HistoryBuilder()
      .withContent(type: "public.utf8-plain-text", value: text)
      .withContent(type: "public.png", value: nil)
      .build()

    let dtos = contentDTOs(of: item)

    XCTAssertEqual(dtos, [
      ContentDTO(type: "public.utf8-plain-text", value: text, fingerprint: nil, size: 5),
      ContentDTO(type: "public.png", value: nil, fingerprint: nil, size: 0)
    ])
  }

  /// A committed snapshot carries the model's exact stable store identity.
  func testSnapshotUsesStoredItemIdentity() throws {
    let item = HistoryBuilder()
      .withContent(type: "public.utf8-plain-text", value: Data("hello".utf8))
      .build()
    let context = Storage.shared.context
    context.insert(item)
    try context.save()
    defer {
      context.delete(item)
      try? context.save()
    }

    XCTAssertEqual(snapshot(of: item).id, item.persistentModelID.id)
  }
}
