# Feature Spec: Bulk CSV Import System

## Context

A bulk CSV import feature that accepts transaction history in two ways: a strict template format or any broker's export via the AI mapper. Holdings-snapshot upload was considered and removed — the system enforces a pure transaction ledger and does not accept "current positions" as a source of truth.

**Design decisions:**
1. Two import modes — Strict Template (TRANSACTIONS) and AI Mapper (AI_FLEXIBLE)
2. AI is opt-in ("Any broker format") — strict template is the default
3. Reuse existing `LlmService` — no new SDK dependency
4. **AI-Assisted Mapper Pattern:** the LLM infers column mappings from header + 5 sample rows only. Java parses the full file deterministically via Apache Commons CSV. Numeric values never pass through the LLM. One LLM call per import regardless of file size.

---

## Architecture

Two import modes. Both converge on the **same commit path**: persist `Transaction` rows, then trigger `HoldingService.updateHoldingsForPortfolio()`. Holdings are derived — never directly written by the import pipeline.

```
┌─────────────────────────────────────────────────────────────┐
│  Frontend: bulk-changes-tab wizard                           │
│  ┌──────────────────────┬──────────────────────────────┐    │
│  │ Strict Template      │ AI Mapper                    │    │
│  │ (TRANSACTIONS)       │ (AI_FLEXIBLE)                │    │
│  └──────────┬───────────┴──────────────┬───────────────┘    │
└─────────────┼──────────────────────────┼────────────────────┘
              │                          │
              │                          ▼
              │              POST /api/v1/csv-import/infer-mapping
              │              (header + first 5 rows → LlmService)
              │                          │
              │                          ▼
              │              MappingProposal → user confirms in UI
              │                          │
              ▼                          ▼
  POST /api/v1/csv-import/preview
  (strict: built-in mapping; AI: user-confirmed mapping)
  Deterministic parse of FULL file via Apache Commons CSV
              │
              ▼
  Preview JSON: {rows, warnings, parseErrors, totalRows, validRows, duplicateRows}
              │
              ▼ (user reviews & confirms)
  POST /api/v1/csv-import/commit
    → dedup by externalId (SHA-256 hash)
    → insert Transactions (FX-normalised, BigDecimal)
    → updateHoldingsForPortfolio()
```

**Critical principle:** the LLM is **never** in the data-extraction path. It is called exactly once per AI-mode import, only to infer column mappings. All numeric parsing happens deterministically in Java.

### Endpoints

| Endpoint | Purpose |
|---|---|
| `POST /api/v1/csv-import/infer-mapping` | AI mode only: header + first 5 rows → `LlmService` → `MappingProposal`. No data beyond the sample leaves this path. |
| `POST /api/v1/csv-import/preview` | Parse the full file deterministically. Return preview rows. **No writes.** |
| `POST /api/v1/csv-import/commit` | Take reviewed rows from preview; insert transactions; trigger holdings refresh. |

---

## Data Model

### TransactionType
`BUY | SELL | DIVIDEND | TRANSFER` — no OPENING_BALANCE. All imports produce real transaction types.

### Row-hash dedup
- `rowHash = SHA-256(portfolioId|ticker|iso_date|type|qty|price)[0..16 hex]`
- Stored as `externalId = "csv:v1:" + rowHash`
- Pre-insert check via `TransactionRepository.findByExternalIdAndPortfolioId()` (already indexed)
- Re-uploading the same CSV returns `skippedDuplicates`, never duplicates

---

## Backend Implementation

### Files

| File | Purpose |
|---|---|
| `controller/CsvImportController.java` | Three endpoints (preview, commit, infer-mapping) + JWT auth |
| `service/csvimport/CsvImportService.java` | Orchestrates preview + commit; TRANSACTIONS and AI_FLEXIBLE modes; dedup; post-commit holdings refresh |
| `service/csvimport/CsvContentParser.java` | Wraps Apache Commons CSV; BOM strip, CRLF, quoted fields; 100k row cap |
| `service/csvimport/AiCsvMapper.java` | LLM call for mapping inference only; validates all returned column names against real header |
| `dto/csvimport/ImportMode.java` | Enum: `TRANSACTIONS, AI_FLEXIBLE` |
| `dto/csvimport/DedupStatus.java` | Enum: `NEW, DUPLICATE` |
| `dto/csvimport/ColumnMapping.java` | Record: 9 nullable column name fields (includes isinColumn) |
| `dto/csvimport/MappingProposal.java` | Record: mapping + typeValueMap + dateFormat + confidence + warnings |
| `dto/csvimport/InferMappingRequest.java` | Record: portfolioId + targetMode + csvContent |
| `dto/csvimport/PreviewRow.java` | Record: all parsed row fields + valid flag + errors + isin |
| `dto/csvimport/RowError.java` | Record: rowNumber + ticker + messages |
| `dto/csvimport/CsvPreviewRequest.java` | Record: all preview params; AI fields nullable for strict mode |
| `dto/csvimport/CsvPreviewResponse.java` | Record: rows + parseErrors + warnings + stats |
| `dto/csvimport/CsvCommitRequest.java` | Record: portfolioId + mode + rows |
| `dto/csvimport/CsvCommitResponse.java` | Record: committed + skippedDuplicates + failed + errors |

### Validation rules
- `quantity > 0`, `price >= 0`
- Date must parse with the configured pattern (ISO date for strict; user-confirmed format for AI)
- Ticker non-empty; `SecurityListingService` resolves/creates the listing
- ISIN-first resolution: if ISIN is present in the CSV, it is used to look up the listing before falling back to ticker + exchange + currency
- `BigDecimal` throughout — never `double`
- File size cap: 100,000 rows enforced in `CsvContentParser` before any parsing

### ISIN disambiguation
ISIN is mapped as an optional column in both strict and AI modes. When present at commit time:
1. `findByIsin(isin)` is tried first — globally unique, resolves cross-exchange ambiguity
2. Falls back to exchange + ticker + currency
3. Falls back to ticker-only

---

## AI Mapper: AI-Assisted Mapper Pattern

The LLM's only job is **schema inference**. It looks at the header row and a handful of sample rows, then outputs a mapping from canonical fields to source column names.

### Flow
1. User uploads any broker CSV.
2. Frontend `POST /api/v1/csv-import/infer-mapping` with `{portfolioId, targetMode, csvContent}`.
3. Backend extracts header + first 5 data rows. Full file never sent to LLM.
4. `AiCsvMapper` calls `LlmService.generateResponse(systemPrompt, userPrompt)`.
5. Backend returns `MappingProposal` with confidence score and warnings.
6. Frontend shows mapping editor: one dropdown per canonical field (options = actual CSV headers), editable type synonyms, editable date format, confidence bar. Nothing is parsed yet.
7. User confirms → `POST /api/v1/csv-import/preview` with full CSV + confirmed mapping.
8. `CsvImportService` streams the entire file through Apache Commons CSV using the mapping. All numeric parsing via `new BigDecimal(String)`.
9. Returns `CsvPreviewResponse`.
10. User confirms → `POST /api/v1/csv-import/commit`.

### Guardrails
- **Server-side column validation:** every non-null `ColumnMapping` field must exist in the actual header row — enforced in `AiCsvMapper.validateColumn()`. Hallucinated columns are silently nulled.
- **JSON extraction:** `extractJsonBlock()` finds the first balanced `{...}` in the LLM response, tolerating prose wrapping.
- **Low-confidence threshold:** frontend shows the mapping editor for any import; if `confidence < 0.7` the confidence bar is highlighted amber.
- **No auto-commit:** AI mode still requires the preview → commit steps same as strict mode.

---

## Frontend Implementation

The "Bulk Changes" tab in `add-transaction-modal` hosts the full wizard:

| File | Purpose |
|---|---|
| `bulk-changes-tab/bulk-changes-tab.component.ts` | Multi-step wizard: Upload → [Mapping] → Preview → Result |
| `bulk-changes-tab/bulk-changes-tab.component.html` | Angular 17 control flow (`@if`/`@for`) |
| `bulk-changes-tab/bulk-changes-tab.component.scss` | Wizard step indicator, mode cards, upload zone, mapping grid, preview table, result summary |
| `services/csv-import.models.ts` | TypeScript interfaces: `ImportMode`, `WizardStep`, `ColumnMapping`, `MappingProposal`, `PreviewRow`, `CsvPreviewRequest/Response`, `CsvCommitRequest/Response` |
| `services/api.service.ts` | `inferCsvMapping()`, `previewCsv()`, `commitCsv()` |

### Wizard steps
1. **Upload** — mode selector (Strict Template / AI Mapper), portfolio picker, default currency (auto-set from portfolio), drag-and-drop file zone, template download
2. **Mapping** (AI Mapper only) — confidence bar, warnings, field dropdown grid (options = actual CSV headers), BUY/SELL/DIVIDEND synonym inputs, date format input
3. **Preview** — stats bar (total/valid/dup/errors), parse error accordion, scrollable row table (first 100 shown), dedup badges
4. **Result** — committed / skipped / failed counts, row errors accordion, "Import More" reset

---

## Security & Financial Correctness

- **Auth:** all `/api/v1/csv-import/*` endpoints require JWT
- **File size cap:** 100,000 rows enforced in `CsvContentParser` before parsing
- **BigDecimal everywhere** for quantity, price, fees — never `double`
- **UTC dates** — parsed as `LocalDate` → `atStartOfDay().atOffset(ZoneOffset.UTC)`
- **`@Transactional` small:** commit is transactional; the LLM call in `AiCsvMapper.inferMapping()` happens outside any transaction
- **Idempotency:** `externalId = "csv:v1:<hash>"` — re-running returns `skippedDuplicates`, never duplicates
- **Preview ≠ trust:** `commit` re-validates every row server-side
- **No direct holdings writes:** all imports go through the transaction ledger; `updateHoldingsForPortfolio` derives holdings

---

## Testing

### Backend
- `CsvContentParserTest` — quoted fields, embedded commas, BOM, CRLF, empty rows, 100k row cap
- `CsvImportControllerIT` (`@SpringBootTest` + Testcontainers):
  - Happy path: transactions CSV → preview → commit → Transaction rows + Holdings refreshed
  - Dedup: upload same CSV twice → second returns `skippedDuplicates=N, committed=0`
  - Malformed row: reported as parse error, valid rows unaffected
  - AI mode: mock `LlmService`; assert LLM called exactly once; verify deterministic parse
  - `AiCsvMapperTest` — injection fixture, hallucinated-column fixture, low-confidence fixture

### Frontend
- `bulk-changes-tab.component.spec.ts` — step navigation, mode switching, file load

> **Testcontainers note:** `~/.testcontainers.properties` may have a stale `docker.raw.sock` path. Fix to `/var/run/docker.sock` before running integration tests locally.
