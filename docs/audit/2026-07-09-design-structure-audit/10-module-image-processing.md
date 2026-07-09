# 10 — Module: Image Processing

**Directory:** `Maccy/ImageProcessing/` + `ApplicationImage*`, `ColorImage`  
**Baseline:** HEAD `6cd37c8` · Flow G

---

## 1. Components

| Symbol | Role |
|--------|------|
| `ImageProcessing` protocol | thumbnail/preview Sendable |
| `ImageProcessor` actor | prod; thumb via cache; preview direct |
| `PassthroughImageProcessor` | sync fallback/tests |
| `ImageDownsampler` | ImageIO thumbnail |
| `ThumbnailCache` | memory + disk LRU |
| `ApplicationImage` / Cache | source app icons + file watch |
| `ColorImage` | color swatches |

---

## 2. Data flow

```text
Data (blob)
  → ImageProcessor.thumbnail
       fingerprint (count, xxh3 via MaccyTextProcessor)
       ThumbnailCache
       ImageDownsampler
       NSImage
  → decorator.thumbnailImage

  → ImageProcessor.preview (no cache, cancel checkpoints)
  → decorator.previewImage
```

---

## 3. Cache key

`MaccyFingerprint(size, hash)` + maxPixel — xxh3 family (not legacy FNV for this path on HEAD).

---

## 4. Sharing

`HistoryItemDecorator.defaultImageProcessor` singleton; AppDelegate injects same into ingestor. Ingest does not currently use it for titles.

---

## 5. Memory seam

Row-level `releaseTransientImages`; process-level MemoryGovernor + ApplicationImageCache.purge.  
**No DecodedImageCache type** on HEAD (older gap text outdated).

---

## 6. Risks

| Issue | Note |
|-------|------|
| Full `Data` before ImageIO | Peak memory |
| ApplicationImage DispatchSource | Historical SIGTRAP; fixed queue.main (see 2026-07-05 doc) |
| Disk cache lifecycle | Ops awareness |

---

## 7. Recommendations

Keep actor boundary. Align docs. Long-term streaming large images only with measurement.

**Confidence:** High.
