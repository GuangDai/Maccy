# 06 — Module: Models (HistoryItem / HistoryItemContent)

**Files:** `Maccy/Models/HistoryItem.swift` (338), `HistoryItemContent.swift` (43)  
**Baseline:** HEAD `6cd37c8`

---

## 1. HistoryItem

### 1.1 Business concept

One clipboard history record: multi-type payloads, source app, copy timestamps/counts, pin, list title, searchable body.

### 1.2 Fields

| Field | Semantics | Issue |
|-------|-----------|-------|
| application | Bundle id | optional |
| firstCopiedAt / lastCopiedAt | Dates | clear |
| numberOfCopies | Merge accumulation | clear |
| pin | Hotkey char? | optional String, not value type |
| title | Precomputed label | dual with generateTitle |
| searchText | Full-text body | nil = pre-migration row |
| contents | cascade relationship | correct rule |

### 1.3 Method groups

| Group | Methods | Should live |
|-------|---------|-------------|
| Dedup | supersedes, duplicateSignature | Domain — OK via Engine |
| Title/body | generateTitle, previewableTextPrefix, searchableBody | Domain — **should not read Defaults inside entity** |
| Content access | fileURLs, imageData, html/rtf/text, flags | Read model — OK |
| Static pins | Historical: supportedPins, **availablePins**, randomAvailablePin | **Resolved (`76a2a53`): moved to context-injected `PinService` (DS-015)** |
| File | dataFromFileIfAllowed | Infrastructure policy |

### 1.4 Anemic vs rich

Partially rich (supersedes/title). Orchestration still in History/Ingestor. It remains persistence-bound through `@Model`, but the former pin fetch no longer couples the entity to `Storage.shared`.

### 1.5 `imageData` / file read

```text
contentData tiff/png/jpeg/heic
else Handoff jpeg fileURL → dataFromFileIfAllowed
```

HEAD `dataFromFileIfAllowed`: size read failure → **nil** (not OOM path). Size > max → nil. Data(contentsOf) failure → nil.

### 1.6 Recommendations

| Keep | Move out | Value objects | Constraints |
|------|----------|---------------|-------------|
| Persisted fields + relationship | availablePins query | PinKey, CopyCount | pin ∈ supported set |
| supersedes delegation | Defaults reads | SearchText optional semantics | document nil searchText |

---

## 2. HistoryItemContent

| Field | Role |
|-------|------|
| type | UTI string |
| value | Data? |
| fingerprint | xxh3 if large at init; nil if small or old row |

`maxValueSize` reads `Defaults` — model static depends on user settings (timing windows vs IngestConfig snapshot).

Backfill: actor candidate path only (not full table).

---

## 3. Cross-model mapping

| Persist | DTO | Search |
|---------|-----|--------|
| HistoryItem | ItemSnapshotDTO | SearchCorpusItem (**decorator id!**) |
| HistoryItemContent | ContentDTO | folded into body string |

**Easiest identity bug:** treating SearchCorpusItem.id as ItemID.

---

## 4. Schema evolution

Lightweight columns: fingerprint, searchText. No heavy VersionedSchema. Backfill policy must be productized (measure nil rates).

---

## 5. Risks

| Risk | Note |
|------|------|
| Dual title source | ingest writes title; showSpecialSymbols regenerates via History loop |
| nil searchText | title-only search until filled |
| content copy on merge | new rows; cascade delete matters |
| pin as free string | convention-enforced |

**Confidence:** High on structure; Medium on nil column population rates in user DBs.
