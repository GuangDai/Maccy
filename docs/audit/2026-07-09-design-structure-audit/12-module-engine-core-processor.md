# 12 — Module: Engine / Core / C++ Processor

**Files:** `Engine/HistoryItemEngine.swift`, `Core/ClipboardDataProcessor.swift`, `Processor/*`  
**Baseline:** HEAD `6cd37c8`

---

## 1. HistoryItemEngine

### Responsibilities (no SwiftData writes)

- Containment `Signature`  
- `contains` / supersedes support  
- `generateTitle` / `previewableTextPrefix` / `searchableBody`  

### Coupling debt (DS-030)

APIs take `[HistoryItemContent]` (`@Model` class). Ingest builds **throwaway** uninserted models to call Engine — works but couples “pure” domain to persistence types.

**Ideal:** `ContentDTO` or small protocol.

### Title priority

file URLs → string → small RTF → small HTML → fallback; then special-symbol transform.

---

## 2. ClipboardDataProcessor

```text
stringPrefix → MaccyTextProcessor.validUTF8PrefixLength
dataLikelyEqual(lhs, lhsFp, rhs, rhsFp)
fingerprintIfLarge (≥ 16 KiB → xxh3)
```

### Correctness contract (**red line**)

| Case | Result |
|------|--------|
| sizes differ | false |
| both large, fingerprints present and differ | false |
| both large, fingerprints equal | **still `lhs == rhs`** |
| missing fingerprint | full `==` |

**Do not remove post-hash compare.**

---

## 3. Processor C++/ObjC++

| Piece | Role |
|-------|------|
| ClipboardByteProcessor | UTF-8 prefix length validation |
| MaccyTextProcessor | bridge fingerprint / validUTF8 |
| xxHash third_party | xxh3 |

Bridging header: `Maccy-Bridging-Header.h`.

Evolution (BS-8 gaps may still apply): streaming enumerateByteRanges, etc. — design audit defers to gap suite for completion %.

---

## 4. Two signatures relationship

Index signature (DTO) vs containment signature (Engine) — both needed; name them in code comments using glossary terms.

---

## 5. Recommendations

1. Engine on DTO.  
2. Keep C++ tests (MaccyTextProcessorTests, Fingerprint*, DataLikelyEqual*).  
3. Single constant for 16 KiB threshold.  

**Confidence:** High. **Touch risk:** Critical if contracts change.
