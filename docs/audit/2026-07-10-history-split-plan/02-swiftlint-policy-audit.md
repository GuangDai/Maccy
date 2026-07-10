# 02 — SwiftLint Policy Audit (custom thresholds vs stock)

**Baseline:** HEAD `.swiftlint.yml` · commit `a8365fa` · official SwiftLint rule defaults · CI workflow `macos26-arm-ci.yml` · **Process finding** (not a product defect)

---

## 1. Current project configuration

```yaml
# .swiftlint.yml (HEAD)
disabled_rules:
  - multiple_closures_with_trailing_closure
  - non_optional_string_data_conversion
  - todo
line_length:
  ignores_comments: true
file_length:
  warning: 1000
  error: 1000
type_body_length:
  warning: 1000
  error: 1000
function_body_length:
  warning: 1000
  error: 1000
```

**CI invocation** (from project docs / workflow):

```text
swiftlint lint --quiet --strict --no-cache
```

Then a self-scan fails the job if the log contains `warning:` or `error:`.

With `--strict`, **any warning is already a failure**. Setting `warning == error == 1000` therefore:

- Collapses the two-tier severity ladder into a **single cliff**.
- Removes any “you are getting large” signal before hard fail.

---

## 2. Stock SwiftLint defaults (official rule docs)

| Rule | Default warning | Default error | Other defaults |
|------|-----------------|---------------|----------------|
| [`file_length`](https://realm.github.io/SwiftLint/file_length.html) | **400** | **1000** | `ignore_comment_only_lines: false` |
| [`type_body_length`](https://realm.github.io/SwiftLint/type_body_length.html) | **250** | **350** | **`excluded_types: [extension, protocol]`** |
| [`function_body_length`](https://realm.github.io/SwiftLint/function_body_length.html) | **50** | **100** | comments/blank lines ignored in body count |

### Critical fact about extensions

Under **stock** `type_body_length`:

- **Extensions are excluded** (`excluded_types: [extension, protocol]`).
- Moving methods from `class History { ... }` into `extension History { ... }` **shrinks the measured class body** and is the standard way to pass a 350-line type cap **without** introducing new types.
- Extensions are **not** “measured as separate types with their own 350 budget” by default — they are **not measured at all**.

When the project overrides only `warning` / `error` on `type_body_length`, SwiftLint typically **keeps** `excluded_types` defaults unless explicitly cleared. So:

| World | Effect of pure extension-split |
|-------|--------------------------------|
| Stock defaults | Shrinks **class** body (helps type_body); shrinks **file** only if moved to **another file** |
| Project 1000/1000 | Class body already “legal” up to 1000; same-file extensions do almost nothing; **other-file** extensions only help `file_length` |

**Claim correction:** docs that say “SwiftLint measures each extension separately, so extension-split clears type_body” are **misleading under stock defaults** (extensions excluded) and **irrelevant under project 1000** (class already allowed to ~958). The binding cliff today is **`file_length` 978/1000**, not type_body.

---

## 3. What `a8365fa` changed (2026-06-24)

**Commit message (summary):** raise `file_length` / `type_body_length` / `function_body_length` to 1000; remove per-file disables that would trip `superfluous_disable_command` / fight `blanket_disable_command`. At that moment max file was History at **796**.

### Before (stock defaults + explicit disables)

Known god-files carried **named debt markers**, e.g.:

- `History.swift`: `// swiftlint:disable file_length` + `type_body_length` on the class  
- `HistoryItemDecorator.swift`, `ClipboardIngestor.swift`, large tests, `AppDelegate`, `NavigationManager`, …  
- `KeyChord`: cyclomatic + function_body  
- UITests file_length / type_body  

That pattern was noisy but **honest**: the debt was **labeled**.

### After

| Dimension | Effect |
|-----------|--------|
| `file_length` **error** | **Unchanged at 1000** (stock error was already 1000) |
| `file_length` **warning** | **400 → 1000** — soft band **removed** |
| `type_body_length` | **250/350 → 1000/1000** — **primary architectural neutering** |
| `function_body_length` | **50/100 → 1000/1000** — large methods free |
| Disables | Removed as “superfluous” — **debt markers deleted** |

**Intent (charitable):** stop disable thrash under strict CI.  
**Side effect (realized):** length rules stop acting as **structure pressure** until a **file** hits 1000 lines.

---

## 4. Empirical consequences for History

```text
a8365fa: 796  (thresholds raised)
   …
d933dff: 1000 (at wall)
040fbfa: 1060 → CI file_length FAIL
b4667d8: extract History+PasteStack → 964  (lint surgery)
   …
HEAD:    978  (22 lines headroom)
```

Documented in BS-5 redesign progress log: first CI failure on History growth was fixed by **moving paste-stack out**, not by changing dependencies. That is the **incentive shape** of cliff-only lint:

1. Feature work lands in the god file.  
2. CI fails at 1000+.  
3. Emergency extract of whatever is easiest to move.  
4. Green CI; coupling unchanged.

**History+PasteStack** is coherent *as a feature module*, but the extract was **timed by lint**, and the feature is **dead** (`multiSelectionEnabled = false` → E4 / `NEW-singletons-intents-misc-1`). So the extract is double-awkward: lint theater + dead code.

---

## 5. Problems introduced (catalog)

### P-LINT-1 — Cliff-only failure mode

No progressive warning between 400 and 999. Engineers discover size only when CI is red.

### P-LINT-2 — Wrong incentive (file surgery over dependency change)

“Split for headroom” looks productive. DS-022, AppState×23, dual write path stay put.

### P-LINT-3 — `type_body_length` no longer describes types

A **958-line class** is legal. Stock would hard-fail at **350**. The rule no longer encodes “types should be deep modules with small surfaces.”

### P-LINT-4 — `function_body_length` no longer bounds methods

Stock error 100 would push decomposition of large `init` / mutation methods. At 1000, effectively off.

### P-LINT-5 — Roadmap language overweights `file_length`

Master roadmap: *don’t add to History without checking file_length headroom; split is the real cure.*  
That equates **architecture progress** with **line count**. After this audit, the cure is **narrower surfaces and single chokepoints**, not “978 → N files of the same class.”

### P-LINT-6 — Restoring stock defaults is not free

See `01` §9: many types/tests would fail stock `type_body_length` 350. A big-bang restore is a **repo-wide red wave**, not a History PR.

### P-LINT-7 — `warning: 1000` + `error: 1000` + `--strict`

Redundant configuration; confuses readers into thinking 1000 is “generous room” rather than “only remaining signal.”

### What the lint change did **not** do

- Did **not** invent the god object (History already had disables).  
- Did **not** change the stock `file_length` **error** ceiling (always 1000).  
- Did **not** force real type extraction (and neither does the wall today).

---

## 6. Interaction with the History split plan

| Proposal | Under project lint | Verdict |
|----------|--------------------|---------|
| Extension-split only to gain headroom | Clears `file_length`; type still god | **Hollow** (lint theater) |
| “We must split because 22 lines left” | True as **risk of CI flake on next feature**, false as **architecture mandate** | Prefer **delete dead `add` (~80 LOC)** or D4 shrink before split |
| “type_body forces 5–7 types” | False at 1000 | Don’t invent pressure that isn’t there |
| Restore stock type_body 350 now | Breaks History + Decorator + Ingestor + tests | **Not** Step 1 of History plan |

---

## 7. Recommended lint policy (optional separate track)

**Do not** couple this to D4 or a History file split.

### Option A — Soft band only (minimal)

```yaml
file_length:
  warning: 500
  error: 1000
type_body_length:
  warning: 400
  error: 800   # still loose vs stock 350; not a free pass to 1000
function_body_length:
  warning: 60
  error: 120
```

Gives progressive signal under `--strict` once warning < error.  
**Care:** warning 500 on file_length makes current History (978) an **immediate CI fail** — so either:

- phase warnings upward slowly, or  
- keep high errors and use Option B for known gods.

### Option B — Keep high errors; restore **named debt** (honest)

Re-add **scoped** disables with a one-line reason pointing at finding IDs:

```swift
// swiftlint:disable:this type_body_length — DS-001; tracked 2026-07-10-history-split-plan
class History: ItemsContainer {
```

Pros: visibility without fake discipline.  
Cons: reintroduces disable noise (the original reason for `a8365fa`).

### Option C — Stock defaults + multi-sprint extract plan

Only if the project explicitly wants length rules as architecture enforcement. Requires a sequenced extract program across History, Decorator, Ingestor, tests — **not** this suite’s near-term path.

### Explicit non-recommendation

**Do not** “fix” P-LINT-* by multi-file `extension History` moves alone. That encodes the wrong lesson and conflicts with B0.

---

## 8. Verification checklist (for a future lint PR)

- [ ] Diff `.swiftlint.yml` with intentional warning **band** (warning < error) or document why not  
- [ ] `rg 'swiftlint:disable' --type swift` — every disable cites a finding id or issue  
- [ ] Dry-run count of new violations before merging (CI job or temporary workflow)  
- [ ] No same-PR History behavior change  

---

## 9. One-line finding

**`a8365fa` traded labeled debt + soft pressure for a silent 1000-line file cliff; under that regime, History splits for lint are hollow, and architecture work must be justified by D4/D0/B3–B4/D1 — not by headroom math.**
