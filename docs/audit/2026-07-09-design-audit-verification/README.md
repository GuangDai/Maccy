# 2026-07-09 Design-Structure Audit — Verification & Grilling

| Field | Value |
|-------|-------|
| **Role** | **Verification + recalibration** of [`2026-07-09-design-structure-audit/`](../2026-07-09-design-structure-audit/) against HEAD, produced by a `/grill-with-docs` session (grilling + domain-modeling). |
| **Baseline HEAD** | `6cd37c8` (`6cd37c88be63d29300ebf624eb9c211d1a1ed5c9`) — **confirmed equal to the audited baseline**, so all line numbers are directly checkable. |
| **Method** | (1) A 13-agent verification workflow: 7 parallel clusters re-checked every `DS-xxx` finding against HEAD source, then 6 adversarial "refute" agents re-tried the correctness-critical findings. (2) Firsthand grep/read of the load-bearing findings by the author. One cluster agent (`verify:search`, DS-010) hit a rate limit; DS-010 was verified firsthand instead. |
| **Constraint** | Read-only. No product code changed. Verdicts are evidence, not fixes. |
| **Does not replace** | The design audit. It **sits on top of it**: confirms mechanisms, recalibrates severities, and adds what the audit missed. |

## Headline verdict (one paragraph)

The design audit is **mechanism-accurate** — **27 of 34** findings are confirmed exactly as described, and its measurement precision is exceptional (History.swift = 989 LOC exact, `AppState.shared` = 23 sites exact, shared bus = 171/26 exact, legacy `Search` = 217 LOC exact). Its single systematic weakness is **severity inflation**: **6 findings are overstated** because the audit scores *mechanism presence* rather than *realized impact* — the worst cases self-heal on the next popup open (DS-002), have dormant triggers (DS-025), or describe latent-only risk (DS-019, refuted as a cross-relaunch hazard). The grilling also surfaced **19 issues the audit missed** — one of which, a silent session-wide dedup disable (`NEW-dedup-ids-1`), is arguably more serious than several "High" findings — plus **16 glossary/location corrections**. Net: trust the audit's *what*, re-weight its *how bad*, and patch its blind spots before acting on the playbook.

## How to read

| Goal | Start here |
|------|-----------|
| The recalibrated picture + what to do first | [`00-executive-verdict.md`](00-executive-verdict.md) |
| Per-finding verdict table (all 34) | [`01-verdict-matrix.md`](01-verdict-matrix.md) |
| The 19 issues the audit **missed** (ranked) | [`02-new-findings.md`](02-new-findings.md) |
| Severity recalibration + glossary/location fixes | [`03-severity-and-glossary-corrections.md`](03-severity-and-glossary-corrections.md) |
| **Wave A execution plan (decided by grilling)** | [`04-correctness-wave-plan.md`](04-correctness-wave-plan.md) |
| Domain terms sharpened during grilling | [`glossary-supplement.md`](glossary-supplement.md) |

## Verdict tally

| Verdict | Count | IDs |
|---------|-------|-----|
| CONFIRMED (as-is) | 25 | DS-001,003,004,005,007,011,012,013,014,015,018,020,021,022,023,024,026,027,030,032,034 + DS-002(mechanism),DS-008,DS-010(firsthand) |
| PARTIALLY_CONFIRMED | 5 | DS-009, 016, 025, 031, 033 |
| Severity OVERSTATED | 6 | DS-002 (Crit→High), DS-006 (High→Med), DS-016/017/019/025 (Med→Low) |
| Severity UNDERSTATED | 2 | DS-008 (dead surface larger), DS-028 (gates ~250 LOC dead subtree) |
| REFUTED | 1 | DS-019 (no cross-relaunch break in HEAD; ItemID not persisted) |
| New issues added | 19 | `NEW-*-1..4` per cluster — see `02-new-findings.md` |

## Related authorities

| Doc | Use for |
|-----|---------|
| [`../2026-07-09-design-structure-audit/`](../2026-07-09-design-structure-audit/) | The audited design/structure findings (this doc verifies it) |
| [`../architecture-and-root-causes.md`](../architecture-and-root-causes.md) | Architecture narrative |
| [`../2026-06-28-roadmap-bs5-bs8-gap-audit/`](../2026-06-28-roadmap-bs5-bs8-gap-audit/) | BS-5..8 completion % |

**Note:** The design audit's playbook (`19-master-playbook.md`) remains the execution guide; this verification **re-prioritizes its Wave A** and **adds new items**. The grilling of the roadmap decisions follows in conversation.
