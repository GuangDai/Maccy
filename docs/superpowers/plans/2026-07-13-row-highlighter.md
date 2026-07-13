# Row Highlighter Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract title and preview AttributedString construction from `HistoryItemDecorator` into one cohesive, memoizing `RowHighlighter` module without changing search, layout, or rendering behavior.

**Architecture:** `RowHighlighter` is an in-process value module with two mutating interface methods: one accepts title-relative `String.Index` ranges and one accepts body-relative grapheme offsets. It hides memo keys, truncation/clamping, AttributedString index conversion, and the shared highlight-style switch; callers only handle `.unchanged` versus `.replacement`. `HistoryItemDecorator` remains the Observable owner and assigns returned values only when the module reports a change, preserving the existing render-suppression behavior.

**Tech Stack:** Swift 6.0 complete strict concurrency, SwiftUI `AttributedString`, swift-log, XCTest, XcodeGen, GitHub Actions macOS 26 ARM runner.

## Global Constraints

- Target macOS Sonoma 14+ and preserve Swift 6 complete strict-concurrency compliance.
- Do not build, test, or lint locally; this machine has no Xcode/macOS toolchain.
- Do not change user-visible highlight styles, range semantics, truncation limits, preview layout, image behavior, or startup work.
- Keep `HistoryItemDecorator` as the Observable UI projection; `RowHighlighter` must not depend on `HistoryItem`, SwiftData, image processing, `AppState`, or process-wide `.shared` state.
- Do not introduce a protocol or adapter: this is pure in-process computation with a single implementation.
- Commit each coherent step. Push only after project generation is synchronized and the full CI matrix passes.
- Poll CI no more frequently than every 90 seconds.
- Do not edit the primary worktree's dirty `docs/audit/INDEX.md` or other user-owned files.
- Subagent execution treats Tasks 1 and 2 as one implementation/review gate: the test contract and its module implementation must be committed and reviewed together, never as a knowingly uncompilable intermediate task.

---

### Task 1: Define the deep module interface with direct behavior tests

**Files:**
- Create: `MaccyTests/RowHighlighterTests.swift`
- Modify: `MaccyTests/HistoryDecoratorTests.swift:259-345`

**Interfaces:**
- Consumes: existing `HighlightMatch`, `TextLimits.highlight`, and `AttributedString` styling semantics.
- Produces: tests for `RowHighlighter.title(query:text:ranges:style:)`, `RowHighlighter.preview(query:text:ranges:style:)`, and `RowHighlightUpdate`.

- [ ] **Step 1: Add direct module tests for style, memo, clearing, truncation, and preview clamping**

Create `MaccyTests/RowHighlighterTests.swift` with focused tests shaped like:

```swift
import SwiftUI
import XCTest
@testable import Maccy

@MainActor
final class RowHighlighterTests: XCTestCase {
  func testTitleAppliesEveryConfiguredStyle() {
    let text = "foo bar"
    let range = text.range(of: "bar")!

    for style in HighlightMatch.allCases {
      var highlighter = RowHighlighter()
      guard case .replacement(let actual?) = highlighter.title(
        query: "bar",
        text: text,
        ranges: [range],
        style: style
      ) else {
        return XCTFail("first render must return a replacement")
      }

      XCTAssertEqual(actual, expected(text: text, match: "bar", style: style))
    }
  }

  func testSameTitleInputsAreUnchangedUntilStyleChanges() {
    let text = "foo bar"
    let range = text.range(of: "bar")!
    var highlighter = RowHighlighter()

    _ = highlighter.title(query: "bar", text: text, ranges: [range], style: .bold)
    guard case .unchanged = highlighter.title(
      query: "bar", text: text, ranges: [range], style: .bold
    ) else {
      return XCTFail("identical inputs must reuse the memo")
    }
    guard case .replacement = highlighter.title(
      query: "bar", text: text, ranges: [range], style: .underline
    ) else {
      return XCTFail("style changes must rebuild")
    }
  }

  func testEmptyQueryClearsOnceThenRemainsUnchanged() {
    let text = "foo bar"
    let range = text.range(of: "bar")!
    var highlighter = RowHighlighter()
    _ = highlighter.title(query: "bar", text: text, ranges: [range], style: .bold)

    guard case .replacement(nil) = highlighter.title(
      query: "", text: text, ranges: [], style: .bold
    ) else {
      return XCTFail("first clear must remove the attributed value")
    }
    guard case .unchanged = highlighter.title(
      query: "", text: text, ranges: [], style: .bold
    ) else {
      return XCTFail("repeated clear must not retrigger observation")
    }
  }

  func testPreviewClampsPartialRangeAndSkipsDeepRange() {
    var highlighter = RowHighlighter()
    guard case .replacement(let partial?) = highlighter.preview(
      query: "bar", text: "foo bar", ranges: [4..<100], style: .bold
    ) else {
      return XCTFail("partial preview range must build")
    }
    XCTAssertEqual(partial, expected(text: "foo bar", match: "bar", style: .bold))

    var deepHighlighter = RowHighlighter()
    guard case .replacement(let deep?) = deepHighlighter.preview(
      query: "x", text: "foo bar", ranges: [100..<103], style: .bold
    ) else {
      return XCTFail("deep-only preview still returns plain attributed text")
    }
    XCTAssertEqual(deep, AttributedString("foo bar"))
  }

  func testTitleDropsRangesBeyondTheRenderWindow() {
    let text = String(repeating: "a", count: TextLimits.highlight) + "z"
    let deepRange = text.range(of: "z")!
    var highlighter = RowHighlighter()

    guard case .replacement(let actual?) = highlighter.title(
      query: "z", text: text, ranges: [deepRange], style: .bold
    ) else {
      return XCTFail("title render must still return its bounded plain text")
    }
    XCTAssertEqual(
      actual,
      AttributedString(String(repeating: "a", count: TextLimits.highlight))
    )
  }

  private func expected(
    text: String,
    match: String,
    style: HighlightMatch
  ) -> AttributedString {
    var expected = AttributedString(text)
    let range = expected.range(of: match)!
    switch style {
    case .bold:
      expected[range].font = .bold(.body)()
    case .italic:
      expected[range].font = .italic(.body)()
    case .underline:
      expected[range].underlineStyle = .single
    case .color:
      expected[range].backgroundColor = .findHighlightColor
      expected[range].foregroundColor = .black
    }
    return expected
  }
}
```

- [ ] **Step 2: Keep only thin decorator integration assertions**

Retain `HistoryItemDecoratorTests.testHighlight` and `testPreviewHighlight` to prove decorator assignment. Move deep-range and render-window behavior to `RowHighlighterTests`; do not duplicate those assertions in both test classes.

- [ ] **Step 3: Continue directly to the implementation before committing**

Stage no commit at this point. The new tests and Task 2 implementation form one independently reviewable deliverable; committing a missing `RowHighlighter` type would violate the task gate even though Swift compile boundaries permit temporary worktree breakage.

---

### Task 2: Complete the same implementation gate by extracting and wiring highlighting

**Files:**
- Create: `Maccy/Search/RowHighlighter.swift`
- Modify: `Maccy/Observables/HistoryItemDecorator.swift:395-507`

**Interfaces:**
- Consumes: the tests from Task 1.
- Produces:
  - `enum RowHighlightUpdate { case unchanged; case replacement(AttributedString?) }`
  - `struct RowHighlighter`
  - `mutating func title(query:text:ranges:style:) -> RowHighlightUpdate`
  - `mutating func preview(query:text:ranges:style:) -> RowHighlightUpdate`

- [ ] **Step 1: Implement the value module**

Create `Maccy/Search/RowHighlighter.swift`:

```swift
import Logging
import SwiftUI

enum RowHighlightUpdate {
  case unchanged
  case replacement(AttributedString?)
}

struct RowHighlighter {
  private struct TitleMemo {
    let text: String
    let ranges: [Range<String.Index>]
    let style: HighlightMatch
  }

  private struct PreviewMemo {
    let text: String
    let ranges: [Range<Int>]
    let style: HighlightMatch
  }

  private let logger = Logger(label: "org.p0deje.Maccy")
  private var titleMemo: TitleMemo?
  private var previewMemo: PreviewMemo?

  mutating func title(
    query: String,
    text: String,
    ranges: [Range<String.Index>],
    style: HighlightMatch
  ) -> RowHighlightUpdate {
    guard !query.isEmpty, !text.isEmpty else {
      guard titleMemo != nil else { return .unchanged }
      titleMemo = nil
      return .replacement(nil)
    }
    if let memo = titleMemo,
       memo.text == text,
       memo.ranges == ranges,
       memo.style == style {
      return .unchanged
    }

    var attributed = AttributedString(text.shortened(to: TextLimits.highlight))
    for range in ranges {
      guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
            let upper = AttributedString.Index(range.upperBound, within: attributed) else {
        logger.debug("highlight range fell outside the render window; dropped")
        continue
      }
      apply(style, to: &attributed, in: lower..<upper)
    }
    titleMemo = TitleMemo(text: text, ranges: ranges, style: style)
    return .replacement(attributed)
  }

  mutating func preview(
    query: String,
    text: String,
    ranges: [Range<Int>],
    style: HighlightMatch
  ) -> RowHighlightUpdate {
    guard !query.isEmpty, !text.isEmpty else {
      guard previewMemo != nil else { return .unchanged }
      previewMemo = nil
      return .replacement(nil)
    }
    if let memo = previewMemo,
       memo.text == text,
       memo.ranges == ranges,
       memo.style == style {
      return .unchanged
    }

    var attributed = AttributedString(text)
    let count = text.count
    for range in ranges {
      let lowerOffset = range.lowerBound
      let upperOffset = min(range.upperBound, count)
      guard lowerOffset < count, lowerOffset < upperOffset else { continue }
      let lowerString = text.index(text.startIndex, offsetBy: lowerOffset)
      let upperString = text.index(text.startIndex, offsetBy: upperOffset)
      guard let lower = AttributedString.Index(lowerString, within: attributed),
            let upper = AttributedString.Index(upperString, within: attributed) else { continue }
      apply(style, to: &attributed, in: lower..<upper)
    }
    previewMemo = PreviewMemo(text: text, ranges: ranges, style: style)
    return .replacement(attributed)
  }

  private func apply(
    _ style: HighlightMatch,
    to attributed: inout AttributedString,
    in range: Range<AttributedString.Index>
  ) {
    switch style {
    case .bold:
      attributed[range].font = .bold(.body)()
    case .italic:
      attributed[range].font = .italic(.body)()
    case .underline:
      attributed[range].underlineStyle = .single
    case .color:
      attributed[range].backgroundColor = .findHighlightColor
      attributed[range].foregroundColor = .black
    }
  }
}
```

- [ ] **Step 2: Replace decorator implementation with adapters to the module**

In `HistoryItemDecorator`, add:

```swift
@ObservationIgnored private var rowHighlighter = RowHighlighter()
```

Replace both memo structs, memo properties, and style switches. Keep public method names unchanged:

```swift
func highlight(_ query: String, _ ranges: [Range<String.Index>]) {
  switch rowHighlighter.title(
    query: query,
    text: title,
    ranges: ranges,
    style: Defaults[.highlightMatch]
  ) {
  case .unchanged:
    return
  case .replacement(let attributed):
    attributedTitle = attributed
  }
}

func setPreviewHighlight(_ query: String, _ ranges: [Range<Int>]) {
  previewBodyQuery = query
  previewBodyRanges = ranges
  switch rowHighlighter.preview(
    query: query,
    text: text,
    ranges: ranges,
    style: Defaults[.highlightMatch]
  ) {
  case .unchanged:
    return
  case .replacement(let attributed):
    previewAttributedText = attributed
  }
}
```

The decorator's existing image logger remains because it still reports preview-decode failures; only the dropped-title-range log moves into `RowHighlighter`.

- [ ] **Step 3: Perform static verification**

Run:

```bash
git diff --check
rg -n "HighlightMemo|PreviewHighlightMemo|switch style" Maccy/Observables/HistoryItemDecorator.swift
rg -n "struct RowHighlighter|func title|func preview|func apply" Maccy/Search/RowHighlighter.swift
```

Expected: `git diff --check` exits 0; no memo/style implementation remains in the decorator; the module owns both render paths and the single style switch.

- [ ] **Step 4: Commit the extraction**

```bash
git add Maccy/Search/RowHighlighter.swift Maccy/Observables/HistoryItemDecorator.swift \
  MaccyTests/RowHighlighterTests.swift MaccyTests/HistoryDecoratorTests.swift
git commit -m "refactor(quality): extract row text highlighting"
```

---

### Task 3: Record architecture state and synchronize the generated project

**Files:**
- Modify: `docs/audit/architecture-and-root-causes.md`
- Modify (generated artifact only): `Maccy.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: completed module/test files from Tasks 1–2.
- Produces: current audit status and an Xcode project that contains both new files.

- [ ] **Step 1: Update the authoritative architecture audit**

Add a concise E5/decorator cohesion entry stating that `RowHighlighter` owns both memoized AttributedString render paths and the unified style application, while `HistoryItemDecorator` remains the Observable adapter and image lifecycle owner. Mark full-matrix verification pending.

- [ ] **Step 2: Commit the audit update with code, not as a standalone CI batch**

```bash
git add docs/audit/architecture-and-root-causes.md
git commit -m "docs(quality): record row highlighter extraction"
```

- [ ] **Step 3: Push and run the project-generation workflow once**

```bash
git push -u origin quality-row-highlighter
gh workflow run "Regenerate and Validate Xcode Project" --ref quality-row-highlighter
```

Poll at 90-second intervals. Download the generated artifact, verify only the two expected file references changed, and copy only `Maccy.xcodeproj/project.pbxproj`; do not copy runner `xcuserdata`, `Package.resolved`, or test-plan files.

- [ ] **Step 4: Commit generated output**

```bash
git add Maccy.xcodeproj/project.pbxproj
git commit -m "chore(project): regenerate for row highlighter files"
git push
```

---

### Task 4: Review, full CI, evidence, and integration

**Files:**
- Modify after green evidence: `docs/audit/architecture-and-root-causes.md`

**Interfaces:**
- Consumes: the complete branch from Tasks 1–3.
- Produces: reviewed, runner-verified master history.

- [ ] **Step 1: Request a read-only review of `master..HEAD`**

Require the reviewer to check interface depth, range correctness, memo semantics, Observable assignment suppression, strict concurrency, test replacement versus duplication, and generated-project parity. Fix all Critical/Important findings before CI.

- [ ] **Step 2: Run the full macOS CI matrix once no other workflow is active**

```bash
gh workflow run "macOS 26 ARM CI" --ref quality-row-highlighter
```

Poll every 90 seconds. Required success jobs: Generated Xcode project, Lint + diagnostics, unit, ui-1, ui-2, perf-text, perf-image.

- [ ] **Step 3: Record exact CI evidence**

After green, replace the pending audit marker with the full run ID. This is a pure documentation evidence update and does not require a separate manual CI run.

- [ ] **Step 4: Fast-forward master while preserving the primary dirty state**

Capture `git status --short` before/after, require an identical dirty-file list, fast-forward `master`, and push. Do not delete or modify the user's uncommitted primary files.

## Self-Review

- Spec coverage: the plan extracts only title/preview highlighting and explicitly excludes images, layout, Defaults ownership, startup, and search matching.
- Placeholder scan: every code-producing step contains concrete types, files, commands, and expected outcomes.
- Type consistency: both tests and production use `RowHighlightUpdate`, `RowHighlighter.title(query:text:ranges:style:)`, and `RowHighlighter.preview(query:text:ranges:style:)` with matching range types.
- Deletion test: deleting `RowHighlighter` forces memo keys, truncation/clamping, index conversion, logging, and four-style application back into `HistoryItemDecorator`, so the module earns its seam.
