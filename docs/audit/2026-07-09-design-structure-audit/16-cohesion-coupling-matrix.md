# 16 — Cohesion & Coupling Matrix

**Baseline:** HEAD `6cd37c8`

---

## 1. Cohesion scores

| Module | Cohesion | Rationale |
|--------|----------|-----------|
| IngestFilter / SignatureIndex | Very high | Single concept, pure |
| SearchActor | High | Corpus + match |
| ImageProcessor stack | High | Decode pipeline |
| HistoryItemEngine | High | Rule set (type coupling exception) |
| HistoryItemDecorator | Medium–high | Row presentation |
| Clipboard | Medium–low | In + out + paste + dead helpers |
| AppDelegate | Low | Launch + test + UI |
| **History** | **Very low** | See `04` |
| AppState | Medium | Acceptable bus but thick |
| Storage | Medium–high | Container + recovery; loader side-car |

---

## 2. Coupling matrix (simplified)

Legend: **P** = common/singleton, **D** = data, **C** = control, **F** = framework, **T** = temporal/order, **H** = hidden

| From \\ To | History | AppState | Storage | Clipboard | Ingestor | SearchActor | Defaults |
|------------|---------|----------|---------|-----------|----------|-------------|---------|
| Views | D | P | — | — | — | — | D |
| Intents | P | P | — | — | — | — | — |
| History | — | **P+C (23)** | P+F | P | — | D | D |
| Clipboard | P+C | P | — | — | D | — | D |
| Ingestor | H(onEvent) | — | F | — | — | — | D via MainActor |
| Decorator | — | — | F(model) | — | — | — | D |
| AppDelegate | P | P | P | P | C | — | D |

---

## 3. High-coupling relationships

| Pair | Type | Evidence | Reduce? | How | Cost |
|------|------|----------|---------|-----|------|
| History ↔ AppState | P+C bidirectional | 23 sites in History.swift | Yes | UIEffectPort | Medium |
| * ↔ *.shared | P | 171 hits / 26 files | Progressive | ctor injection | Medium |
| HistoryItem → Storage | F | availablePins | Yes | move query | Low |
| Clipboard ↔ IngestFilter rules | Duplication | dual UTI sets | Yes | single source | Low–med |
| UI delete ↛ SignatureIndex | Missing | DS-009 | Yes | events/rebuild | Medium |
| Decorator → @Model | D/F | holds item | Limited | invalidate discipline | — |
| Search dual engine | Duplication | DS-010 | Yes | merge | Medium |
| Intent → AppState | P | Intents/* | Medium | port | Low |

---

## 4. Couplings to **keep**

- SearchActor ↔ Fuse (internal)  
- @ModelActor ↔ ModelContext  
- Views ↔ Observable state  
- ImageProcessor ↔ ImageIO  
- Containment supersedes after index candidates  

---

## 5. History split axes (change reasons)

1. Projection changes (StoreEvent)  
2. Search UX  
3. User mutations (delete/pin)  
4. Legacy test writes  
5. Shortcut display  
6. Chrome side effects  

Avoid microservice explosion: 5–7 application types max to start; shared `HistoryListState`.

---

## 6. Coupling type glossary (for reviews)

| Type | Example in Maccy |
|------|------------------|
| Content | Reading private fields across modules |
| Common | `*.shared` |
| Control | flags / needsResize driving behavior |
| Stamp | fat context objects |
| Data | DTO parameters |
| Temporal | copy then checkForChanges |
| Sequential | commit then onEvent then syncAll |
| Framework | SwiftData `@Model`, AppKit |
| Deployment | Intents in same binary touching UI session |
