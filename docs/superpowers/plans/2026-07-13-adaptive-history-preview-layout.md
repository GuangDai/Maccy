# Adaptive History Rows and Preview Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the Popup runtime boundary while making image height effective, adding stable multi-line text rows, scaling preview height with the main popup, and pinning text-preview scrolling to the preview viewport.

**Architecture:** `Popup` remains the pure owner of height policy and talks outward only through `PopupRuntimeServices`; `AppState` composes the live closures. A small `HistoryRowLayout` policy resolves text/image geometry before asynchronous thumbnail publication, while views receive explicit sizes. `PreviewTextRep` owns an AppKit scroll-view factory whose viewport constraints can be tested without rendering the full SwiftUI tree.

**Tech Stack:** Swift 6.0 complete strict concurrency, AppKit, SwiftUI Observation, Defaults, XCTest, GitHub Actions macOS 26 arm64.

## Global Constraints

- Work in `/tmp/Maccy-pending-delete` on `quality-popup-runtime-services`; do not touch the user's dirty primary worktree.
- There is no local Xcode/macOS toolchain: do not run local builds, tests, SwiftLint, or xcodegen.
- Use TDD for behavior: establish a compiling additive/extractive seam, commit the RED tests, then make the minimum GREEN changes.
- Never allow an asynchronously arriving thumbnail to change a row's height.
- Never derive a main-list image row's height from source image dimensions;
  every image row uses the configured, clamped image-content height.
- Do not eagerly classify or decode the complete history collection; image-kind resolution is limited to realized row decorators.
- Keep text-row lines clamped to `1...4`, image content height clamped to `1...200`, and preview minimum height percent clamped to `25...100` with defaults `1`, `40`, and `60`.
- Keep thumbnails aspect-fit and keep footer/header rows at the platform base height.
- `maxVisibleItems` is a compact-text-row viewport cap; larger image rows may reduce the number of simultaneously visible items.
- Only Sendable DTOs cross actors; no `@Model` crosses an actor boundary.
- Do not add new singleton reach; `Popup.swift` must contain no `AppState.shared` or `History.shared` after GREEN.
- Update only the English source-locale strings for new setting keys; leave translated locale files Weblate-owned.
- Use only one active `macOS 26 ARM CI` workflow run. Poll at least 90 seconds apart and inspect failed jobs before logs.
- Commit every task separately and keep commits reviewable; push batches so CI covers as many commits as possible.

## Existing prerequisites

- `7d1a2b25 refactor(quality): define popup runtime port` is independently reviewed PASS.
- `af80c425 test(quality): define popup runtime boundary` plus
  `92623190 test(quality): make popup commit timing deterministic` are independently reviewed PASS.
- Workflow `29236917253` established the first RED boundary: project generation and lint/build succeeded, and the unit shard failed before live Popup routing was implemented.
- The frozen design is
  `docs/superpowers/specs/2026-07-13-adaptive-history-preview-layout-design.md`.

---

### Task 1: Add compiling layout test seams without changing behavior

**Files:**
- Create: `Maccy/Views/HistoryRowLayout.swift`
- Modify: `Maccy/Extensions/Defaults.Keys+Names.swift`
- Modify: `Maccy/Observables/Popup.swift`
- Modify: `Maccy/Views/PreviewItemView.swift`

**Interfaces:**
- Produces: `HistoryRowLayout.baseHeight`, `textHeight(lines:)`, `imageHeight(maxImageHeight:)`, and `rowHeight(isImage:maxImageHeight:textLines:)`.
- Produces: `Popup.previewMinimumHeight(maximumHeight:percent:)` while shipped behavior still uses the old 150 pt floor.
- Produces: `PreviewTextRep.makeScrollView()` as an extraction of the current factory.
- Produces: Defaults keys `.textRowLines` and `.previewMinimumHeightPercent`, not yet consumed by production views.

- [ ] **Step 1: Add inert Defaults keys**

Add next to the existing preview/list keys in `Defaults.Keys+Names.swift`:

```swift
  /// Number of lines reserved for text-only history rows.
  static let textRowLines = Key<Int>("textRowLines", default: 1)
  /// Minimum open-preview height as a percentage of the configured popup height.
  static let previewMinimumHeightPercent = Key<Int>(
    "previewMinimumHeightPercent",
    default: 60
  )
```

No production code reads these keys in this task.

- [ ] **Step 2: Add a legacy-behavior row-layout seam**

Create `Maccy/Views/HistoryRowLayout.swift`:

```swift
import AppKit

/// Pure geometry policy for history content rows.
enum HistoryRowLayout {
  static var baseHeight: CGFloat {
    if #available(macOS 26.0, *) { return 24 }
    return 22
  }

  static var textLineIncrement: CGFloat {
    ceil(NSFont.systemFont(ofSize: NSFont.systemFontSize).boundingRectForFont.height)
  }

  static func textHeight(lines: Int) -> CGFloat {
    baseHeight
  }

  static func imageHeight(maxImageHeight: Int) -> CGFloat {
    baseHeight
  }

  static func rowHeight(
    isImage: Bool,
    maxImageHeight: Int,
    textLines: Int
  ) -> CGFloat {
    isImage ? imageHeight(maxImageHeight: maxImageHeight) : textHeight(lines: textLines)
  }
}
```

The intentionally legacy-returning methods are an additive seam for compiling
behavioral RED tests; views do not call them in this task.

- [ ] **Step 3: Extract preview helpers without routing behavior**

In `Popup.swift`, retain `minimumPreviewHeight = 150` and add:

```swift
  static func previewMinimumHeight(maximumHeight: CGFloat, percent: Int) -> CGFloat {
    minimumPreviewHeight
  }
```

In `PreviewTextRep`, extract the current constructor exactly:

```swift
  static func makeScrollView() -> NSScrollView {
    NSTextView.scrollableTextView()
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = Self.makeScrollView()
    if let textView = scrollView.documentView as? NSTextView {
      configure(textView)
    }
    return scrollView
  }
```

Do not change scroll-view or text-container flags yet.

- [ ] **Step 4: Run static gates and commit**

Run:

```bash
git diff --check
rg -n "textRowLines|previewMinimumHeightPercent" Maccy/Extensions/Defaults.Keys+Names.swift
rg -n "HistoryRowLayout|previewMinimumHeight\(|makeScrollView" Maccy
```

Expected: no whitespace errors; both Defaults keys and all three seams are present.

Commit:

```bash
git add Maccy/Views/HistoryRowLayout.swift \
  Maccy/Extensions/Defaults.Keys+Names.swift \
  Maccy/Observables/Popup.swift \
  Maccy/Views/PreviewItemView.swift
git commit -m "refactor(quality): add adaptive layout test seams"
```

---

### Task 2: Commit one compiling RED batch for every new policy

**Files:**
- Create: `MaccyTests/HistoryRowLayoutTests.swift`
- Modify: `MaccyTests/PopupTests.swift`
- Modify: `MaccyTests/HistoryDecoratorTests.swift`

**Interfaces:**
- Consumes: all additive/extractive seams from Task 1.
- Produces: failing behavioral contracts for adaptive row geometry, percentage preview height, and viewport-bound AppKit text scrolling.

- [ ] **Step 1: Add RED row-layout tests**

Create `MaccyTests/HistoryRowLayoutTests.swift`:

```swift
import XCTest
@testable import Maccy

final class HistoryRowLayoutTests: XCTestCase {
  func testTextRowsScaleByClampedLineCount() {
    XCTAssertEqual(HistoryRowLayout.textHeight(lines: 1), HistoryRowLayout.baseHeight)
    XCTAssertEqual(
      HistoryRowLayout.textHeight(lines: 3),
      HistoryRowLayout.baseHeight + 2 * HistoryRowLayout.textLineIncrement
    )
    XCTAssertEqual(HistoryRowLayout.textHeight(lines: 0), HistoryRowLayout.textHeight(lines: 1))
    XCTAssertEqual(HistoryRowLayout.textHeight(lines: 9), HistoryRowLayout.textHeight(lines: 4))
  }

  func testImageRowsHonorConfiguredContentHeightAndFloor() {
    XCTAssertEqual(
      HistoryRowLayout.imageHeight(maxImageHeight: 40),
      max(HistoryRowLayout.baseHeight, 50)
    )
    XCTAssertEqual(
      HistoryRowLayout.imageHeight(maxImageHeight: -1),
      HistoryRowLayout.baseHeight
    )
    XCTAssertEqual(
      HistoryRowLayout.imageHeight(maxImageHeight: 999),
      max(HistoryRowLayout.baseHeight, 210)
    )
    XCTAssertNotEqual(
      HistoryRowLayout.rowHeight(isImage: true, maxImageHeight: 40, textLines: 1),
      HistoryRowLayout.rowHeight(isImage: false, maxImageHeight: 40, textLines: 1)
    )
  }
}
```

Expected under Task 1: the 3-line, 40-point image, and unequal-kind assertions fail.

Also add to `HistoryDecoratorTests` so semantic row kind cannot change when
transient image state is released:

```swift
  func testImageRowKindSurvivesTransientInvalidation() {
    let itemDecorator = historyItemDecorator(largeImageData(), .png)

    XCTAssertTrue(itemDecorator.hasImage)
    itemDecorator.invalidate()
    XCTAssertTrue(itemDecorator.hasImage)
  }
```

Expected before Task 4: the final assertion fails because the current
`invalidate()` clears the blob cache and the invalidated decorator refuses to
fault the model again.

- [ ] **Step 2: Replace the fixed preview-floor assertion with percentage contracts**

In `PopupTests.testInjectedRuntimeOwnsWindowAndSizingEffects`, save/restore
`.previewMinimumHeightPercent`, set it to 60, and replace the old 150 pt
expectations:

```swift
  let savedPreviewMinimumHeightPercent = Defaults[.previewMinimumHeightPercent]
  defer {
    Defaults[.previewMinimumHeightPercent] = savedPreviewMinimumHeightPercent
  }
  Defaults[.previewMinimumHeightPercent] = 60

  recorder.previewMinimumRequired = true
  XCTAssertEqual(popup.preferredHeight(for: 10), 480)
  popup.resize(height: 120)
  XCTAssertEqual(recorder.resizedHeights, [480])
```

Add a pure clamp test:

```swift
  func testPreviewMinimumHeightScalesWithWindowAndClampsPercent() {
    XCTAssertEqual(Popup.previewMinimumHeight(maximumHeight: 800, percent: 60), 480)
    XCTAssertEqual(Popup.previewMinimumHeight(maximumHeight: 800, percent: 0), 200)
    XCTAssertEqual(Popup.previewMinimumHeight(maximumHeight: 800, percent: 200), 800)
  }
```

Expected under Task 1: all three pure values and the injected preferred-height
assertions fail against the legacy 150 pt implementation.

- [ ] **Step 3: Add RED AppKit scroll-layout test**

Add to `HistoryDecoratorTests`:

```swift
  func testPreviewTextScrollViewTracksViewportWidth() throws {
    let scrollView = PreviewTextRep.makeScrollView()
    let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)

    XCTAssertTrue(scrollView.hasVerticalScroller)
    XCTAssertFalse(scrollView.hasHorizontalScroller)
    XCTAssertTrue(scrollView.autohidesScrollers)
    XCTAssertTrue(textView.isVerticallyResizable)
    XCTAssertFalse(textView.isHorizontallyResizable)
    XCTAssertTrue(textView.autoresizingMask.contains(.width))
    XCTAssertTrue(try XCTUnwrap(textView.textContainer).widthTracksTextView)
    XCTAssertEqual(textView.textContainer?.lineBreakMode, .byWordWrapping)
  }
```

Expected under Task 1: the width-tracking/horizontal-resizing/layout assertions
fail while construction still succeeds.

- [ ] **Step 4: Commit, push, and dispatch one RED workflow**

Run static checks only:

```bash
git diff --check
git status --short
```

Commit:

```bash
git add MaccyTests/HistoryRowLayoutTests.swift \
  MaccyTests/PopupTests.swift \
  MaccyTests/HistoryDecoratorTests.swift
git commit -m "test(quality): define adaptive row and preview layout"
```

Before triggering, confirm no queued/in-progress run:

```bash
gh run list --workflow "macOS 26 ARM CI" --limit 5
```

If workflow `29236917253` is still active, do not trigger another run; continue
reviewing Task 2 and preparing Task 3 until it finishes. Otherwise:

```bash
git push origin quality-popup-runtime-services
gh workflow run "macOS 26 ARM CI" --ref quality-popup-runtime-services
```

Expected: project generation, lint, and build succeed; the unit shard fails only
in the new layout tests plus the already-known runtime-routing tests. Record the
run id, inspect job conclusions first, then inspect the failed unit artifact/log
tail. Do not poll sooner than 90 seconds.

---

### Task 3: GREEN the Popup runtime boundary and percentage height policy

**Files:**
- Modify: `Maccy/Observables/Popup.swift`
- Modify: `Maccy/Observables/AppState.swift`

**Interfaces:**
- Consumes: the ten `PopupRuntimeServices` operations and Task 2 Popup tests.
- Produces: Popup with zero global reach and a clamped percentage preview floor.

- [ ] **Step 1: Implement the pure preview floor**

Replace the legacy helper and remove `minimumPreviewHeight`:

```swift
  static func previewMinimumHeight(maximumHeight: CGFloat, percent: Int) -> CGFloat {
    let clampedPercent = min(max(percent, 25), 100)
    return maximumHeight * CGFloat(clampedPercent) / 100
  }
```

In `preferredHeight(for:)`, use one maximum and the runtime predicate:

```swift
  func preferredHeight(for newHeight: CGFloat) -> CGFloat {
    let maximumHeight = Defaults[.windowSize].height
    var minimumHeight = headerHeight + Self.verticalPadding
    if runtimeServices.requiresPreviewMinimumHeight() {
      minimumHeight = max(
        minimumHeight,
        Self.previewMinimumHeight(
          maximumHeight: maximumHeight,
          percent: Defaults[.previewMinimumHeightPercent]
        )
      )
    }
    return min(max(newHeight, minimumHeight), maximumHeight)
  }
```

- [ ] **Step 2: Route every Popup effect through the port**

Use these bodies:

```swift
  func open(height: CGFloat, at popupPosition: PopupPosition = Defaults[.popupPosition]) {
    runtimeServices.selectInitialItem()
    runtimeServices.openPanel(height, popupPosition)
  }

  func close() { runtimeServices.closePanel() }
  func isClosed() -> Bool { !runtimeServices.isPanelPresented() }
```

In `resize`, call:

```swift
    runtimeServices.resizePanel(preferredHeight(for: self.height))
```

In the closed hotkey path call `runtimeServices.prewarmVisibleWindow()`.
Replace the repeated-hotkey body with the port equivalents:

```swift
    if runtimeServices.selectPressedShortcut() { return nil }
    if state == .opening { state = .cycle }
    if state == .cycle {
      runtimeServices.highlightNext()
      return nil
    }
    if state == .toggle {
      close()
      return nil
    }
    return event
```

Keep commit deferred:

```swift
    if state == .cycle {
      Task { @MainActor [runtimeServices] in
        runtimeServices.commitSelection()
      }
      return nil
    }
```

- [ ] **Step 3: Make event handling instance-owned**

Capture `[weak self]` in the local event-monitor closure and route flags through:

```swift
        let consume = MainActor.assumeIsolated {
          self?.shouldConsumeFlagsChanged(allReleased: allReleased) ?? false
        }
```

Remove the deinit comment's claim that Popup is necessarily the process-lifetime
`AppState.shared.popup`.

- [ ] **Step 4: Compose live services in AppState**

At the end of `AppState.init`, after `history.configureUIEffectSink`, add:

```swift
    popup.configureRuntimeServices(PopupRuntimeServices(
      selectInitialItem: { [weak self] in
        guard let self else { return }
        self.navigator.select(
          item: self.history.unpinnedItems.first ?? self.history.pinnedItems.first
        )
      },
      openPanel: { [weak self] height, position in
        self?.appDelegate?.panel.open(height: height, at: position)
      },
      closePanel: { [weak self] in self?.appDelegate?.panel.close() },
      isPanelPresented: { [weak self] in self?.appDelegate?.panel.isPresented == true },
      requiresPreviewMinimumHeight: { [weak self] in
        guard let self else { return false }
        return self.preview.state.isOpen && self.navigator.leadSelection != nil
      },
      resizePanel: { [weak self] height in
        self?.appDelegate?.panel.verticallyResize(to: height)
      },
      prewarmVisibleWindow: { [weak self] in self?.prewarmVisibleWindow() },
      selectPressedShortcut: { [weak self] in
        guard let self, let item = self.history.pressedShortcutItem else { return false }
        self.navigator.select(item: item)
        Task { @MainActor [weak self] in self?.history.select(item) }
        return true
      },
      highlightNext: { [weak self] in self?.navigator.highlightNext(allowCycle: true) },
      commitSelection: { [weak self] in self?.select() }
    ))
```

- [ ] **Step 5: Run structural gates and commit**

```bash
git diff --check
test -z "$(rg -n 'AppState\.shared|History\.shared' Maccy/Observables/Popup.swift)"
rg -n "runtimeServices\." Maccy/Observables/Popup.swift
git add Maccy/Observables/Popup.swift Maccy/Observables/AppState.swift
git commit -m "refactor(quality): inject popup runtime services"
```

Expected: no global reach in Popup and all outward effects use the port.

---

### Task 4: GREEN stable adaptive rows and compact-row capping

**Files:**
- Modify: `Maccy/Views/HistoryRowLayout.swift`
- Modify: `Maccy/Observables/Popup.swift`
- Modify: `Maccy/Observables/HistoryItemDecorator.swift`
- Modify: `Maccy/Views/HistoryItemView.swift`
- Modify: `Maccy/Views/ListItemView.swift`
- Modify: `Maccy/Views/ListItemTitleView.swift`
- Modify: `Maccy/Settings/AppearanceSettingsPane.swift`
- Modify: `Maccy/Settings/en.lproj/AppearanceSettings.strings`

**Interfaces:**
- Consumes: Task 2 row-policy tests and Defaults keys.
- Produces: stable explicit row geometry, cached semantic image kind, configurable 1...4 text lines, effective thumbnail height, and compact-row viewport capping.

- [ ] **Step 1: Implement row geometry**

Replace the two legacy-returning methods:

```swift
  static func textHeight(lines: Int) -> CGFloat {
    let clampedLines = min(max(lines, 1), 4)
    return baseHeight + CGFloat(clampedLines - 1) * textLineIncrement
  }

  static func effectiveImageContentHeight(_ requestedHeight: Int) -> CGFloat {
    CGFloat(min(max(requestedHeight, 1), 200))
  }

  static func imageHeight(maxImageHeight: Int) -> CGFloat {
    max(baseHeight, effectiveImageContentHeight(maxImageHeight) + 10)
  }
```

- [ ] **Step 2: Cache semantic image presence separately from image bytes**

In `HistoryItemDecorator`, add:

```swift
  @ObservationIgnored private var hasImageContentCache: Bool?
```

Replace `hasImage` with:

```swift
  var hasImage: Bool {
    if let hasImageContentCache { return hasImageContentCache }
    let hasImage = imageData != nil
    hasImageContentCache = hasImage
    return hasImage
  }
```

Do not clear `hasImageContentCache` in `releaseTransientImages`; semantic row
kind is immutable even when transient bytes/decoded images are released.

- [ ] **Step 3: Give ListItemView explicit stable geometry**

Add parameters with footer-compatible defaults:

```swift
  var rowHeight: CGFloat = HistoryRowLayout.baseHeight
  var imageContentHeight: CGFloat = max(1, HistoryRowLayout.baseHeight - 10)
  var titleLineLimit: Int = 1
```

Replace the thumbnail frame and row frame:

```swift
          .frame(height: imageContentHeight)
```

```swift
        ListItemTitleView(
          attributedTitle: attributedTitle,
          lineLimit: titleLineLimit,
          title: title
        )
```

```swift
    .frame(height: rowHeight)
```

Update `ListItemTitleView`:

```swift
  var lineLimit: Int
```

Use `.lineLimit(lineLimit)` in both attributed and plain branches; keep middle
truncation and the macOS 26 drawing-group workaround.

- [ ] **Step 4: Resolve row geometry only for realized history rows**

In `HistoryItemView`, import Defaults and add:

```swift
  @Default(.imageMaxHeight) private var imageMaxHeight
  @Default(.textRowLines) private var textRowLines
```

At the start of `body`, resolve once:

```swift
    let isImage = item.hasImage
    let rowHeight = HistoryRowLayout.rowHeight(
      isImage: isImage,
      maxImageHeight: imageMaxHeight,
      textLines: textRowLines
    )
```

Pass:

```swift
      rowHeight: rowHeight,
      imageContentHeight: HistoryRowLayout.effectiveImageContentHeight(imageMaxHeight),
      titleLineLimit: min(max(textRowLines, 1), 4),
```

Because `HistoryItemView` is created by `LazyVStack`, this resolves/caches image
presence for realized rows only and before thumbnail publication.

- [ ] **Step 5: Cap the scroll viewport in configured text-row units**

Replace `Popup.itemHeight` with:

```swift
  static var itemHeight: CGFloat { HistoryRowLayout.baseHeight }
```

In `Popup.resize`, pass:

```swift
      itemHeight: HistoryRowLayout.textHeight(lines: Defaults[.textRowLines])
```

Do not inspect item kinds in Popup or HistoryListView.

- [ ] **Step 6: Add the two compact Appearance controls**

In `AppearanceSettingsPane`, add Defaults bindings and clamped formatters:

```swift
  @Default(.textRowLines) private var textRowLines
  @Default(.previewMinimumHeightPercent) private var previewMinimumHeightPercent
```

```swift
  private let textRowLinesFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.minimum = 1
    formatter.maximum = 4
    return formatter
  }()

  private let previewMinimumHeightPercentFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.minimum = 25
    formatter.maximum = 100
    return formatter
  }()
```

Place the text-row control after image height and the preview-height control
after preview delay:

```swift
      Settings.Section(label: { Text("TextRowLines", tableName: "AppearanceSettings") }) {
        HStack {
          TextField("", value: $textRowLines, formatter: textRowLinesFormatter)
            .frame(width: 120)
            .help(Text("TextRowLinesTooltip", tableName: "AppearanceSettings"))
          Stepper("", value: $textRowLines, in: 1...4)
            .labelsHidden()
        }
      }
```

```swift
      Settings.Section(
        label: { Text("PreviewMinimumHeightPercent", tableName: "AppearanceSettings") }
      ) {
        HStack {
          TextField(
            "",
            value: $previewMinimumHeightPercent,
            formatter: previewMinimumHeightPercentFormatter
          )
          .frame(width: 120)
          .help(Text("PreviewMinimumHeightPercentTooltip", tableName: "AppearanceSettings"))
          Stepper("", value: $previewMinimumHeightPercent, in: 25...100)
            .labelsHidden()
        }
      }
```

Add only these English source strings:

```text
"TextRowLines" = "Text row lines:";
"TextRowLinesTooltip" = "Number of lines shown for text history items. Image rows use the separate image height.\nDefault: 1.";
"PreviewMinimumHeightPercent" = "Preview minimum height:";
"PreviewMinimumHeightPercentTooltip" = "Minimum preview height as a percentage of the configured popup height.\nDefault: 60%.";
```

- [ ] **Step 7: Run static gates and commit**

```bash
git diff --check
test -z "$(rg -n 'frame\(height: Popup\.itemHeight|Popup\.itemHeight - 10' Maccy/Views)"
rg -n "textRowLines|previewMinimumHeightPercent" Maccy/Settings/AppearanceSettingsPane.swift
git add Maccy/Views/HistoryRowLayout.swift \
  Maccy/Observables/Popup.swift \
  Maccy/Observables/HistoryItemDecorator.swift \
  Maccy/Views/HistoryItemView.swift \
  Maccy/Views/ListItemView.swift \
  Maccy/Views/ListItemTitleView.swift \
  Maccy/Settings/AppearanceSettingsPane.swift \
  Maccy/Settings/en.lproj/AppearanceSettings.strings
git commit -m "feat(quality): add stable adaptive history rows"
```

---

### Task 5: GREEN viewport-bound text preview layout

**Files:**
- Modify: `Maccy/Views/PreviewItemView.swift`

**Interfaces:**
- Consumes: Task 2 AppKit scroll-layout test.
- Produces: full-width vertical-only scrolling for both AppKit and SwiftUI text previews, with preview-body layout priority above fixed metadata.

- [ ] **Step 1: Configure the AppKit viewport**

Replace `PreviewTextRep.makeScrollView()`:

```swift
  static func makeScrollView() -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true

    if let textView = scrollView.documentView as? NSTextView {
      textView.minSize = .zero
      textView.maxSize = NSSize(
        width: .greatestFiniteMagnitude,
        height: .greatestFiniteMagnitude
      )
      textView.isVerticallyResizable = true
      textView.isHorizontallyResizable = false
      textView.autoresizingMask = [.width]
      textView.textContainer?.containerSize = NSSize(
        width: scrollView.contentSize.width,
        height: .greatestFiniteMagnitude
      )
      textView.textContainer?.widthTracksTextView = true
      textView.textContainer?.heightTracksTextView = false
      textView.textContainer?.lineBreakMode = .byWordWrapping
    }
    return scrollView
  }
```

- [ ] **Step 2: Give the body the preview column's remaining rectangle**

Extract the image/text switch into:

```swift
  @ViewBuilder
  private var previewBody: some View {
    if item.hasImage {
      AsyncView<NSImage?, _, _> {
        return await item.asyncGetPreviewImage()
      } content: { image in
        if let image {
          previewImage {
            Image(nsImage: image)
              .resizable()
          }
        } else {
          previewImage {
            ZStack {
              Color.gray.opacity(0.3)
                .frame(
                  idealWidth: HistoryItemDecorator.previewImageSize.width,
                  idealHeight: HistoryItemDecorator.previewImageSize.height
                )
              Image(systemName: "photo.badge.exclamationmark")
                .symbolRenderingMode(.multicolor)
                .frame(alignment: .center)
            }
          }
        }
      } placeholder: {
        previewImage {
          ZStack {
            Color.gray.opacity(0.3)
              .frame(
                idealWidth: HistoryItemDecorator.previewImageSize.width,
                idealHeight: HistoryItemDecorator.previewImageSize.height
              )
            ProgressView()
              .frame(alignment: .center)
          }
        }
      }
    } else if item.needsScrollablePreview {
      PreviewTextRep(
        text: item.item.searchText ?? item.text,
        query: item.previewBodyQuery,
        ranges: item.previewBodyRanges
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else {
      ScrollView(.vertical) {
        Group {
          if let preview = item.previewAttributedText {
            Text(preview).font(.body)
          } else {
            Text(item.text).font(.body)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }
```

At the top of `VStack`, render:

```swift
      previewBody
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .layoutPriority(1)
```

Remove the old `Spacer(minLength: 0)` between preview content and the divider.
Keep the divider and metadata branches unchanged.

- [ ] **Step 3: Run static gates and commit**

```bash
git diff --check
rg -n "hasHorizontalScroller = false|widthTracksTextView = true|byWordWrapping|layoutPriority\(1\)" Maccy/Views/PreviewItemView.swift
git add Maccy/Views/PreviewItemView.swift
git commit -m "fix(quality): bind text preview to viewport"
```

---

### Task 6: Full workflow gate, branch review, and master integration

**Files:**
- Review all commits after `61bf8ece`.

**Interfaces:**
- Consumes: completed Tasks 1–5.
- Produces: one fully verified branch and a fast-forwarded `master`.

- [ ] **Step 1: Push the complete GREEN batch**

```bash
git status --short --branch
git diff --check origin/master...HEAD
git push origin quality-popup-runtime-services
```

- [ ] **Step 2: Trigger exactly one full branch workflow**

First confirm no workflow is active, then:

```bash
gh workflow run "macOS 26 ARM CI" --ref quality-popup-runtime-services
gh run list --workflow "macOS 26 ARM CI" --limit 5
```

Record the run id. Poll no more often than every 90 seconds. Between polls,
review the next audit item (`VF-10-history-clipboard-cycle`) without editing this
branch's files.

- [ ] **Step 3: Diagnose any failure in repository order**

```bash
run_id=$(gh run list --workflow "macOS 26 ARM CI" --branch quality-popup-runtime-services --limit 1 --json databaseId -q '.[0].databaseId')
gh run view "$run_id" --json jobs -q '.jobs[] | "\(.name): \(.conclusion)"'
failed_job_id=$(gh run view "$run_id" --json jobs -q '.jobs[] | select(.conclusion == "failure") | .databaseId' | head -n 1)
gh run view "$run_id" --job="$failed_job_id" --log | tail -n 80
```

Treat lint/build errors and concrete assertions as real. Do not loop reruns for
the documented UI 3-second contention or micro-benchmark RSD flakes.

- [ ] **Step 4: Run whole-branch code review**

Review `61bf8ece..HEAD` for:

- spec coverage against both Popup runtime and adaptive-layout design docs;
- zero global reach in `Popup.swift`;
- no strong `AppState -> PopupRuntimeServices -> AppState` cycle;
- stable row geometry independent of `thumbnailImage` publication;
- no eager all-history image classification;
- scroll-view width tracking and absence of horizontal scrolling;
- Defaults clamps and source-string scope.

Resolve every blocker with a separate commit and another full workflow only if
source changed after the green run.

- [ ] **Step 5: Fast-forward master and verify automatic master CI**

After the branch workflow is green and review is clean:

```bash
git -C /lzcapp/document/Projects/Maccy merge --ff-only quality-popup-runtime-services
git -C /lzcapp/document/Projects/Maccy push origin master
```

Do not stage, overwrite, or delete the user's primary-worktree files. Monitor the
single automatic master run with the same 90-second cadence and failure triage.
