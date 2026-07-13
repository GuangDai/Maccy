import AppKit
import Foundation
import Logging
import SwiftData

/// Off-main clipboard ingest contract.
protocol ClipboardIngestor: Sendable {
  func ingest(_ request: IngestRequest) async -> IngestResult
  func synchronizeStoreEvents(_ events: [StoreEvent]) async
}

/// Off-main clipboard ingest actor: the sole production history-write path.
///
/// The pipeline runs on the ingest actor: filter the request contents, dedup
/// against existing items, write a single SwiftData transaction, then emit a
/// `Sendable` `StoreEvent` back to the main observer. Only selected small
/// RTF/HTML parsing hops to `MainActor`; file/plain/image copies stay entirely
/// on the actor after `Clipboard` dispatches their value snapshots.
///
/// ## Concurrency model
/// - `modelContext` is the actor's isolated `ModelContext` (provided by the
///   `@ModelActor` macro, run through a `DefaultSerialModelExecutor` so each
///   access is mutually exclusive). `ModelContext` is not `Sendable`, but it lives
///   entirely inside this actor's isolation: every fetch, mutation,
///   `transaction`, `processPendingChanges`, and `save` happens on the actor.
///   The `@Model HistoryItem` / `HistoryItemContent` instances therefore never
///   cross isolation — only `ItemSnapshotDTO` / `StoreEvent` (both `Sendable`)
///   leave the actor.
/// - `now` is an injected clock. `ingest(_:)` calls it once at the top to fix a
///   single `timestamp`, then reuses `timestamp` for `firstCopiedAt` /
///   `lastCopiedAt` so one ingest is internally consistent. `Date()` is never
///   called from inside the actor.
/// - `image` is the `ImageProcessing` strategy (used later for thumbnails and
///   previews); this actor calls `HistoryItem.generateTitle()` for text titles.
///   Image items get an empty title (the OCR feature was removed).
///
/// ## Single-transaction invariant
/// One `modelContext.transaction { ... }` followed by one
/// `modelContext.save()` per ingest. The trim, the duplicate delete, and the
/// new-item insert all land in the same transaction. Errors are logged via
/// `logger.error` (never silently `try?`-swallowed) and surface as a no-event
/// `IngestResult`.
@ModelActor
actor BackgroundClipboardIngestor: ClipboardIngestor {
  /// Title and full search body projected from one filtered content batch.
  private struct TextProjection: Sendable {
    let title: String
    let searchText: String
  }

  /// Actor-internal duplicate-search result. Candidate models stay on this
  /// actor and are mutated only later inside the matching ingest transaction.
  private struct DuplicateSearchResult {
    let duplicate: HistoryItem?
    let backfillCandidates: [HistoryItem]
  }

  /// The deletions one `commit` applied, for two consumers: the dedup-index keys
  /// (`StoredItemID`, for `maintainDedupIndex`) and the fetchable persistent IDs the
  /// main-thread observer needs to drop the corresponding decorators in O(deleted)
  /// without re-fetching every row on each copy (D4 / `NEW-history-spine-2`).
  /// Both are captured from the `@Model` refs before `context.delete`.
  private struct CommitDeletes: Sendable {
    let dedupIDs: [StoredItemID]
    let persistentIDs: [PersistentIdentifier]
  }

  // `var` with defaults so the `@ModelActor` macro's generated
  // `init(modelContainer:)` satisfies "all stored properties initialized"; the
  // real values are set in the custom init below.
  private var image: ImageProcessing = PassthroughImageProcessor()
  private var now: @Sendable () -> Date = { Date() }
  /// Delivers the committed `StoreEvent` plus the `PersistentIdentifier`s of the
  /// items this ingest deleted (the duplicate plus size-trim evictions) back to
  /// the main observer. The consumer drops exactly those decorators from `all`
  /// in O(deleted) instead of re-fetching every row identifier on each copy (D4 /
  /// `NEW-history-spine-2`). `[PersistentIdentifier]` is `Sendable` (it already
  /// rides `ItemSnapshotDTO.persistentID`), so it crosses this actor→main hop.
  private var onEvent: @Sendable (StoreEvent, [PersistentIdentifier]) async -> Void = { _, _ in }
  private let logger = Logger(label: "org.p0deje.Maccy")

  /// In-memory dedup index over every committed item's content entries,
  /// replacing the per-copy full-table fetch plus O(n) `supersedes` scan with an
  /// O(hits) candidate lookup.
  ///
  /// `persistentIDByStoredID` bridges the index's stable keys to the
  /// `PersistentIdentifier` that `model(for:)` needs to fetch each candidate for
  /// authoritative `supersedes` confirm. `StoredItemID` is not itself a fetch
  /// handle, so the full `PersistentIdentifier` remains in this bridge. The
  /// index is built lazily on the first ingest, then maintained incrementally per
  /// commit (register the inserted item, unregister the duplicate plus the
  /// size-trim evictions).
  private var signatureIndex = SignatureIndex<StoredItemID>()
  private var persistentIDByStoredID: [StoredItemID: PersistentIdentifier] = [:]
  private var dedupIndexInitialized = false

  /// Consecutive failures of the dedup-index init fetch, used to space retries
  /// so a persistently-unreadable store does not add a full-table fetch to every
  /// copy. Reset to zero once an init fetch succeeds.
  private var dedupInitConsecutiveFailures = 0
  /// 1-based number of the next `ensureDedupIndexInitialized` call allowed to
  /// attempt an init fetch. Stays at 1 until a failure, then advances by the
  /// current backoff spacing.
  private var dedupInitNextAttemptCall = 1
  /// Monotonic count of `ensureDedupIndexInitialized` invocations, for spacing.
  private var dedupInitCallNumber = 0

  #if DEBUG
  /// Error injected by `forceInitFetchFailure` to exercise the init retry path.
  private enum ForcedDedupInitFailure: Error {
    case forced
  }

  /// Error injected immediately before save to verify failed transactions do
  /// not leak pending changes into the next ingest.
  private enum ForcedCommitFailure: Error, CustomStringConvertible {
    case forced

    var description: String {
      "ForcedCommitFailure.forced"
    }
  }

  /// Test-only: when set, the dedup-index init fetch fails until cleared,
  /// simulating a transient store error so the retry path is exercisable.
  /// Compiled out of Release; production is always false.
  private var forceInitFetchFailure = false

  /// Test-only: fail `commit` after pending changes are processed but before
  /// save, reproducing the cross-ingest pending-change leak deterministically.
  private var forceCommitFailure = false

  /// Test-only setter for `forceInitFetchFailure`.
  func setDedupInitFetchFailureForTesting(_ enabled: Bool) {
    forceInitFetchFailure = enabled
  }

  /// Test-only setter for `forceCommitFailure`.
  func setCommitFailureForTesting(_ enabled: Bool) {
    forceCommitFailure = enabled
  }
  #endif

  init(
    modelContainer: ModelContainer,
    image: ImageProcessing,
    now: @escaping @Sendable () -> Date,
    onEvent: @escaping @Sendable (StoreEvent, [PersistentIdentifier]) async -> Void
  ) {
    self.modelContainer = modelContainer
    self.image = image
    self.now = now
    self.onEvent = onEvent
    modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(modelContainer))
  }

  /// Applies committed main-actor store events to the actor-owned dedup index.
  ///
  /// `History` sends one batch after a successful UI delete/clear operation, so
  /// stale candidate and persistent-ID bridge entries do not accumulate. A full
  /// clear leaves the index uninitialized: if an actor ingest raced the clear,
  /// the next ingest rebuilds from the committed store instead of assuming it is
  /// still empty.
  func synchronizeStoreEvents(_ events: [StoreEvent]) async {
    for event in events {
      switch event {
      case .added(let item), .merged(let item):
        signatureIndex.register(item.signature, id: item.id)
        if let persistentID = item.persistentID {
          persistentIDByStoredID[item.id] = persistentID
        }
      case .removed(let itemID):
        unregisterFromDedupIndex(itemID: itemID)
      case .cleared:
        signatureIndex = SignatureIndex<StoredItemID>()
        persistentIDByStoredID.removeAll()
        dedupIndexInitialized = false
        dedupInitConsecutiveFailures = 0
        dedupInitNextAttemptCall = 1
        dedupInitCallNumber = 0
      }
    }
  }

  /// Ingests one clipboard copy off the main thread.
  ///
  /// Steps (one actor-owned transaction):
  /// 1. Consume the `IngestPolicy` value captured by `Clipboard` while it was
  ///    already on the main actor.
  /// 2. Filter the request contents on this actor. Only the whitespace-string
  ///    rich-text fallback enters the AppKit parser on `MainActor`.
  /// 3. Project title/search text here for file/plain/image content, or on
  ///    `MainActor` when small RTF/HTML parsing is actually selected.
  /// 4. Build the new `HistoryItem` on the actor's isolated `modelContext`.
  /// 5. Dedup against existing items via the per-entry `SignatureIndex`
  ///    (O(hits) candidate lookup plus authoritative `supersedes` confirm),
  ///    replacing the removed main-thread full-table duplicate scan.
  /// 6. Merge fields from the duplicate if found (mirroring
  ///    the old main-thread merge path).
  /// 7. Single-transaction commit: trim unpinned items beyond the request's
  ///    history-size snapshot (oldest first), delete the duplicate, insert
  ///    the new item, then one save.
  /// 8. Emit `.added` (no duplicate) or `.merged` (duplicate found) with the
  ///    item's `ItemSnapshotDTO`.
  /// 9. Report `IngestMetrics`.
  ///
  /// - Returns: The `StoreEvent` (if any) plus metrics. On a persistence error
  ///   the event is `nil`, the error is logged, and the metrics reflect the
  ///   pre-commit state (dedup decision plus parse timing).
  func ingest(_ request: IngestRequest) async -> IngestResult {
    let filterStart = now()
    let config = request.policy.filter
    let rawPlan = IngestMainActorPlan(contents: request.contents, config: config)
    let richTextPresent: Bool
    if rawPlan.contains(.richTextPresence) {
      richTextPresent = await MainActor.run {
        parseRichTextPresence(in: request.contents, config: config)
      }
    } else {
      richTextPresent = oversizedRichTextPresent(in: request.contents, config: config)
    }

    let filtered = filterContents(
      request.contents,
      application: request.application,
      config: config,
      richTextPresent: richTextPresent
    )
    let parseMs = now().timeIntervalSince(filterStart) * 1000

    guard !filtered.isEmpty else {
      return IngestResult(
        event: nil,
        metrics: IngestMetrics(dedupHits: 0, bytesHashed: 0, parseMs: parseMs)
      )
    }

    let projectionPlan = IngestMainActorPlan(contents: filtered, config: config)
    let projection: TextProjection
    if projectionPlan.contains(.textProjection) {
      projection = await MainActor.run {
        Self.textProjection(
          for: filtered,
          showSpecialSymbols: request.policy.showSpecialSymbols
        )
      }
    } else {
      projection = Self.textProjection(
        for: filtered,
        showSpecialSymbols: request.policy.showSpecialSymbols
      )
    }

    let timestamp = now()
    let item = makeHistoryItem(
      filtered, application: request.application, timestamp: timestamp,
      title: projection.title, searchText: projection.searchText
    )
    ensureDedupIndexInitialized()
    let duplicateSearch = findDuplicate(of: item)
    let dup = duplicateSearch.duplicate
    if let dup {
      mergeFields(from: dup, into: item, timestamp: timestamp)
    }

    let dedupHits = dup != nil ? 1 : 0
    let bytesHashed = Self.bytesHashed(for: item)

    let commitResult: CommitDeletes
    do {
      commitResult = try commit(
        item,
        deleting: dup,
        backfilling: duplicateSearch.backfillCandidates,
        limit: request.policy.historyLimit
      )
    } catch {
      modelContext.rollback()
      logger.error("Failed to commit ingest: \(String(describing: error))")
      return IngestResult(
        event: nil,
        metrics: IngestMetrics(dedupHits: dedupHits, bytesHashed: bytesHashed, parseMs: parseMs),
        persistenceFailed: true
      )
    }

    // Keep the dedup index in sync with the committed transaction.
    maintainDedupIndex(inserted: item, deleted: commitResult.dedupIDs)

    let event: StoreEvent = dup == nil
      ? .added(snapshot(of: item))
      : .merged(snapshot(of: item))
    await onEvent(event, commitResult.persistentIDs)

    return IngestResult(
      event: event,
      metrics: IngestMetrics(dedupHits: dedupHits, bytesHashed: bytesHashed, parseMs: parseMs)
    )
  }

  // MARK: - Ingest steps

  /// Builds the new `HistoryItem` from the filtered contents.
  ///
  /// The title/search projection is computed before model construction. Plain,
  /// file, and image paths run on this actor; selected rich text is projected on
  /// the main actor because `NSAttributedString` parsing cannot run off-main.
  private func makeHistoryItem(
    _ contents: [ContentDTO],
    application: String?,
    timestamp: Date,
    title: String,
    searchText: String
  ) -> HistoryItem {
    let item = HistoryItem(
      contents: contents.map { HistoryItemContent(type: $0.type, value: $0.value) }
    )
    item.application = application
    item.firstCopiedAt = timestamp
    item.lastCopiedAt = timestamp
    item.title = title
    item.searchText = searchText
    return item
  }

  /// Projects both persisted text fields using `HistoryItemEngine`'s canonical
  /// priority and formatting rules. The routing plan guarantees this executes
  /// on `MainActor` whenever either engine call can reach RTF/HTML parsing.
  private static func textProjection(
    for contents: [ContentDTO],
    showSpecialSymbols: Bool
  ) -> TextProjection {
    return TextProjection(
      title: HistoryItemEngine.generateTitle(
        contents: contents,
        fallbackTitle: "",
        maxLength: HistoryItem.titlePreviewLimit,
        richTextParsingLimit: 512 * 1_024,
        showSpecialSymbols: showSpecialSymbols
      ),
      searchText: HistoryItemEngine.searchableBody(
        contents: contents,
        richTextParsingLimit: 512 * 1_024
      )
    )
  }

  /// Finds an existing item that supersedes the new one via the per-entry index,
  /// replacing the legacy per-copy full-table fetch plus O(n) `supersedes` scan.
  ///
  /// The index returns candidate ids whose signature shares at least one content
  /// entry with the new item; each is fetched by `PersistentIdentifier` and
  /// confirmed with the authoritative `supersedes` (which rules out same-size and
  /// fingerprint collisions), so dedup correctness is identical to the legacy
  /// O(n) scan. Genuinely-new content shares no entry and yields no candidates —
  /// the O(1) fast path. `model(for:)` returning an un-faulted shell for an id it
  /// no longer knows (a stale index entry) is harmless: such a shell has no
  /// contents, so `supersedes` returns false and it is skipped.
  private func findDuplicate(of item: HistoryItem) -> DuplicateSearchResult {
    let signature = item.duplicateSignature
    let indexSignature = signature.dto
    var backfillCandidates: [HistoryItem] = []
    for candidateID in signatureIndex.candidates(forEntries: indexSignature.entries) {
      guard let candidatePID = persistentIDByStoredID[candidateID],
            let candidate = modelContext.model(for: candidatePID) as? HistoryItem,
            candidate != item else {
        continue
      }
      backfillCandidates.append(candidate)
      guard candidate.supersedes(signature) else {
        continue
      }
      return DuplicateSearchResult(
        duplicate: candidate,
        backfillCandidates: backfillCandidates
      )
    }
    return DuplicateSearchResult(
      duplicate: nil,
      backfillCandidates: backfillCandidates
    )
  }

  /// Persists the fingerprint column for any of `item`'s large content entries
  /// whose column is still nil.
  ///
  /// Rows that existed before the fingerprint column was added migrate in with
  /// a nil column, so the dedup containment check falls back to a full byte
  /// comparison on every ingest that touches them. Computing and storing the
  /// fingerprint once — inside the ingest transaction, after duplicate search
  /// has returned its candidates — lets later ingests read the column. The write
  /// is idempotent (entries that already have a fingerprint, or fall below the
  /// threshold, are skipped) and adds no transaction. A candidate that is about
  /// to be deleted as the duplicate is skipped by `commit`; surviving candidates
  /// persist their backfill atomically with the new item.
  private func backfillMissingFingerprints(in item: HistoryItem) {
    for content in item.contents {
      guard content.fingerprint == nil,
            let value = content.value,
            let fingerprint = ClipboardDataProcessor.fingerprintIfLarge(value) else {
        continue
      }
      content.fingerprint = fingerprint
    }
  }

  /// Lazily builds the dedup index from the committed store on the first
  /// successful ingest: one O(n) pass, then skipped on subsequent ingests. A
  /// transient fetch failure does NOT permanently disable dedup — the index is
  /// left un-initialized and the fetch is retried on later ingests, with
  /// exponential backoff so a persistently-unreadable store bounds the per-copy
  /// cost rather than turning every copy into a full-table fetch. Each failed
  /// attempt is logged so the regression is diagnosable. Runs on the actor's
  /// isolated context.
  private func ensureDedupIndexInitialized() {
    guard !dedupIndexInitialized else { return }
    dedupInitCallNumber += 1
    guard dedupInitCallNumber >= dedupInitNextAttemptCall else { return }
    let existing: [HistoryItem]
    do {
      #if DEBUG
      if forceInitFetchFailure {
        throw ForcedDedupInitFailure.forced
      }
      #endif
      existing = try modelContext.fetch(FetchDescriptor<HistoryItem>())
    } catch {
      dedupInitConsecutiveFailures += 1
      let spacing = 1 << min(dedupInitConsecutiveFailures - 1, 5)
      dedupInitNextAttemptCall = dedupInitCallNumber + spacing
      logger.error(
        "Dedup index init failed; retry #\(dedupInitConsecutiveFailures): \(String(describing: error))"
      )
      return
    }
    for item in existing {
      registerInDedupIndex(item)
    }
    dedupIndexInitialized = true
    dedupInitConsecutiveFailures = 0
  }

  /// Registers one item's signature plus its id-to-`PersistentIdentifier` bridge entry.
  private func registerInDedupIndex(_ item: HistoryItem) {
    let snap = snapshot(of: item)
    signatureIndex.register(snap.signature, id: snap.id)
    if let pid = snap.persistentID {
      persistentIDByStoredID[snap.id] = pid
    }
  }

  /// Removes one item's signature plus bridge entry (used for the duplicate and
  /// the size-trim-evicted items that `commit` deletes).
  private func unregisterFromDedupIndex(itemID: StoredItemID) {
    signatureIndex.remove(id: itemID)
    persistentIDByStoredID.removeValue(forKey: itemID)
  }

  /// Keeps the dedup index in sync with one committed transaction: drops the
  /// duplicate plus size-trim evictions, then registers the inserted item after
  /// the save so its `persistentModelID` / `StoredItemID` are finalized.
  private func maintainDedupIndex(inserted item: HistoryItem, deleted: [StoredItemID]) {
    for deletedID in deleted {
      unregisterFromDedupIndex(itemID: deletedID)
    }
    registerInDedupIndex(item)
  }

  /// Copies the duplicate's fields into the new item.
  private func mergeFields(from dup: HistoryItem, into item: HistoryItem, timestamp: Date) {
    item.contents = dup.contents.map { HistoryItemContent(type: $0.type, value: $0.value) }
    item.firstCopiedAt = dup.firstCopiedAt
    item.numberOfCopies += dup.numberOfCopies
    item.pin = dup.pin
    item.title = dup.title
    item.searchText = dup.searchText
    if !item.fromMaccy {
      item.application = dup.application
    }
    item.lastCopiedAt = timestamp
  }

  /// Single-transaction commit: delete the duplicate, trim unpinned items beyond
  /// the request's history-size snapshot (oldest first), insert the new
  /// item, then one `processPendingChanges` plus `save`.
  ///
  /// D5 (`NEW-ingest-dualpath-1`): instead of faulting every unpinned `@Model`
  /// each copy (measured ~52 ms at n=1000), this counts unpinned with a no-fault
  /// `fetchCount` and fetches only the oldest `toEvict` rows via a bounded
  /// `fetchLimit`. The duplicate is deleted (pending) before the fetches so both
  /// honor the live `pin == nil` predicate and exclude it — no in-memory dup
  /// flag, no arithmetic subtraction, no cached-fault divergence from a
  /// concurrent main-side pin change. The predicate is fresh per copy, so a
  /// just-pinned item is excluded by construction (no in-memory pin cache to go
  /// stale → cannot evict a pinned item).
  ///
  /// Returns the deletions (dedup-index `StoredItemID`s plus the fetchable persistent
  /// IDs) so the caller can keep the dedup index in sync and hand the main
  /// observer the exact set of decorators to drop — captured from each item
  /// before it is deleted, since a post-save snapshot of a deleted `@Model`
  /// would fault a torn row.
  private func commit(
    _ item: HistoryItem,
    deleting dup: HistoryItem?,
    backfilling candidates: [HistoryItem],
    limit: Int
  ) throws -> CommitDeletes {
    var deletedItemIDs: [StoredItemID] = []
    var deletedPersistentIDs: [PersistentIdentifier] = []
    try modelContext.transaction {
      for candidate in candidates where candidate != dup {
        backfillMissingFingerprints(in: candidate)
      }

      // Delete the duplicate first (pending) so the count and tail fetches below
      // exclude it via the live `pin == nil` predicate — no dup-membership flag
      // and no arithmetic subtraction (which would read `dup.pin` from the
      // actor's cached fault and could diverge from the store under a concurrent
      // main-side pin change on the dup).
      if let dup {
        deletedItemIDs.append(snapshot(of: dup).id)
        deletedPersistentIDs.append(dup.persistentModelID)
        modelContext.delete(dup)
      }

      // Count unpinned WITHOUT faulting any @Model (SELECT COUNT(*) WHERE
      // pin IS NULL). Honors the pending dup delete above, so it excludes the
      // dup. An unpinned insert reserves one slot; a pinned merge does not
      // consume the unpinned retention budget.
      let unpinnedCount = try modelContext.fetchCount(
        FetchDescriptor<HistoryItem>(predicate: #Predicate { $0.pin == nil })
      )
      let retainedBeforeInsert = max(0, item.pin == nil ? limit - 1 : limit)
      let toEvict = max(0, unpinnedCount - retainedBeforeInsert)

      // Fetch only the oldest `toEvict` unpinned rows (ascending sort, bounded),
      // not all of them — the steady-state copy evicts ~1, so this faults ~1 row
      // instead of ~1000. Excludes the pending dup.
      if toEvict > 0 {
        var tailDescriptor = FetchDescriptor<HistoryItem>(
          predicate: #Predicate { $0.pin == nil },
          sortBy: [SortDescriptor(\.lastCopiedAt, order: .forward)]
        )
        tailDescriptor.fetchLimit = toEvict
        let tail = try modelContext.fetch(tailDescriptor)
        for excess in tail {
          deletedItemIDs.append(snapshot(of: excess).id)
          deletedPersistentIDs.append(excess.persistentModelID)
          modelContext.delete(excess)
        }
      }

      modelContext.insert(item)
      #if DEBUG
      if forceCommitFailure {
        throw ForcedCommitFailure.forced
      }
      #endif
    }
    modelContext.processPendingChanges()
    try modelContext.save()
    return CommitDeletes(dedupIDs: deletedItemIDs, persistentIDs: deletedPersistentIDs)
  }

  /// Approximates the byte volume that would be fingerprinted during this ingest:
  /// the sum of `value.count` over contents whose size clears
  /// `ClipboardDataProcessor.fingerprintIfLarge`'s 16 KiB threshold.
  ///
  /// Used only for `IngestMetrics.bytesHashed` reporting; it does not influence
  /// dedup correctness (the actual fingerprints are computed lazily inside
  /// `HistoryItemEngine`).
  private static func bytesHashed(for item: HistoryItem) -> Int {
    item.contents.reduce(0) { total, content in
      guard let data = content.value,
            data.count >= 16 * 1024 else {
        return total
      }
      return total + data.count
    }
  }
}
