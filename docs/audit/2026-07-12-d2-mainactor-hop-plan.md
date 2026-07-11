# D2 — Shrink the ingest MainActor hop

Date: 2026-07-12

## Goal

Remove the unconditional `MainActor.run` block from every background ingest
without moving AppKit's RTF/HTML parsing off the main thread.

## Locked constraints

- `NSAttributedString(rtf:)` and `NSAttributedString(html:)` remain main-actor
  work. Commit `0a3374c` established that either parser can trap off-main.
- Filtering, dedup, SwiftData mutation, trimming, and saving remain on the ingest
  actor.
- Live `Defaults` semantics remain per-copy: `Clipboard`, which already runs on
  `MainActor`, attaches a Sendable policy snapshot to each request.
- Title and full search-text behavior must remain byte-for-byte compatible with
  `HistoryItemEngine`.

## TDD slices

1. Add fixture-backed planning tests proving a large plain-text copy needs no
   rich-text main-actor work, an RTF-only copy needs projection, and a
   whitespace-plus-RTF copy needs only the preservation check (the surviving
   plain representation wins title/body priority).
2. Add a request-shape test proving `Clipboard` captures the live policy values.
3. Introduce the Sendable policy and a pure rich-text work planner. Split the
   filter so its ordinary rules can execute without AppKit parsing.
4. Run title/search projection on the ingest actor for file/plain/image paths;
   hop to `MainActor` only when the planner identifies small RTF/HTML parsing.
5. Keep the existing end-to-end RTF no-trap regression and run the generated
   project full matrix before closing D2.

## Non-goals

- No background `NSAttributedString` experiment in production: the prior crash
  is stronger evidence than a runner timing experiment.
- No cached global settings object or observer graph; a per-request value
  snapshot cannot go stale and keeps the actor free of UI/global reads.
- No parser protocol with a single production adapter. The planning seam is a
  pure value decision and is sufficient to test routing.
