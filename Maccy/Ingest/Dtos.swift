import Foundation
import SwiftData

/// Stable, store-scoped identity of a persisted history item.
///
/// SwiftData exposes this value as `Hashable` and `Sendable`, so it can key the
/// off-main dedup index directly without hashing an undocumented description.
typealias StoredItemID = PersistentIdentifier.ID

/// A single, `Sendable` pasteboard content entry projected from a `HistoryItemContent`.
struct ContentDTO: Equatable, Hashable, Sendable {
  let type: String
  let value: Data?
  let fingerprint: UInt64?
  let size: Int
}

/// A `Sendable` snapshot of one clipboard copy: its content entries plus source metadata.
struct ClipboardItemDTO: Equatable, Sendable {
  let contents: [ContentDTO]
  let application: String?
  let source: CopyOrigin
}

/// Origin of a copy: its pasteboard `changeCount` plus the source app's name, if known.
struct CopyOrigin: Equatable, Hashable, Sendable {
  let changeCount: Int
  let name: String?

  init(changeCount: Int, name: String? = nil) {
    self.changeCount = changeCount
    self.name = name
  }
}

/// A history item's dedup signature: its content entries, sorted for order-independent comparison.
struct SignatureDTO: Equatable, Hashable, Sendable {
  let entries: [ContentSignatureEntry]

  init(entries: [ContentSignatureEntry]) {
    self.entries = entries.sorted()
  }
}

/// One entry of a dedup signature, identifying a single content value by type, size, and (when large enough) fingerprint.
struct ContentSignatureEntry: Comparable, Equatable, Hashable, Sendable {
  let type: String
  let fingerprint: UInt64?
  let size: Int

  static func < (lhs: ContentSignatureEntry, rhs: ContentSignatureEntry) -> Bool {
    if lhs.type != rhs.type {
      return lhs.type < rhs.type
    }

    if lhs.size != rhs.size {
      return lhs.size < rhs.size
    }

    return (lhs.fingerprint ?? 0) < (rhs.fingerprint ?? 0)
  }
}

/// An image fingerprint: its byte size plus the 64-bit content hash.
struct MaccyFingerprint: Equatable, Hashable, Sendable {
  let size: Int
  let hash: UInt64
}

/// A `Sendable` projection of a `@Model HistoryItem`.
///
/// `@Model` instances never cross an actor boundary; this value carries only
/// the identity/title fields the main observer needs and the signature the
/// dedup index needs.
struct ItemSnapshotDTO: Equatable, Sendable {
  let id: StoredItemID

  /// The SwiftData fetchable handle (`ModelContext.model(for:)`). Set by
  /// `snapshot(of:)` from the `@Model`; `nil` in synthetic test snapshots, in
  /// which case the consumer falls back to a full reconcile. `PersistentIdentifier`
  /// is a `Sendable` value handle, not the `@Model` itself, so it crosses the
  /// ingest-to-main actor boundary safely.
  let persistentID: PersistentIdentifier?
  let title: String
  let signature: SignatureDTO
}

/// A `Sendable` change notification emitted by the ingest actor and consumed by the main-observer history.
enum StoreEvent: Equatable, Sendable {
  case added(ItemSnapshotDTO)
  case merged(ItemSnapshotDTO)
  case removed(StoredItemID)
  case cleared
}

/// A single clipboard copy submitted to the ingest actor.
struct IngestRequest: Equatable, Sendable {
  let source: CopyOrigin
  let contents: [ContentDTO]
  let application: String?
  let now: Date
  let policy: IngestPolicy
}

/// The outcome of an ingest: the resulting `StoreEvent` (if any) plus instrumentation metrics.
struct IngestResult: Equatable, Sendable {
  let event: StoreEvent?
  let metrics: IngestMetrics
  /// True only when the actor failed to commit (a persistence error). Lets the
  /// dispatch site tell a real failure (`event == nil` AND `persistenceFailed`)
  /// from a legitimate filter-out (`event == nil`, `persistenceFailed == false`)
  /// so it surfaces failures without false-positiveing on filtered copies.
  /// `var` (not `let`) so the memberwise initializer exposes it as a defaulted
  /// parameter — a `let` with a default is fixed and not settable at init.
  var persistenceFailed: Bool = false
}

/// Instrumentation for one ingest: dedup candidate hits, bytes fingerprinted, and parse wall-time in milliseconds.
struct IngestMetrics: Equatable, Sendable {
  let dedupHits: Int
  let bytesHashed: Int
  let parseMs: Double

  static let zero = IngestMetrics(dedupHits: 0, bytesHashed: 0, parseMs: 0)
}

/// Projects a `@Model HistoryItem` into a `Sendable` `ItemSnapshotDTO`, computing its dedup signature.
func snapshot(of item: HistoryItem) -> ItemSnapshotDTO {
  ItemSnapshotDTO(
    id: storedItemID(for: item),
    persistentID: item.persistentModelID,
    title: item.title,
    signature: signatureDTO(of: item)
  )
}

/// Projects the canonical, transient-filtered dedup signature used by both the
/// authoritative containment check and the candidate index.
func signatureDTO(of item: HistoryItem) -> SignatureDTO {
  item.duplicateSignature.dto
}

/// Projects a `@Model HistoryItem`'s contents and stored fingerprints into
/// `Sendable` `ContentDTO` values at the persistence boundary.
func contentDTOs(of item: HistoryItem) -> [ContentDTO] {
  item.contents.map { content in
    let value = content.value
    return ContentDTO(
      type: content.type,
      value: value,
      fingerprint: content.fingerprint,
      size: value?.count ?? 0
    )
  }
}

/// Returns the stable, store-scoped identity of a persisted history item.
func storedItemID(for item: HistoryItem) -> StoredItemID {
  item.persistentModelID.id
}
