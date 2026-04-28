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
| `POST /api/v1/csv-import/commit` | Take reviewed rows from preview; insert transactions; trigger holdings refresh; trigger JIT historical-price backfill for any newly-created listings. |
| `GET  /api/v1/csv-import/backfill-status?listingIds=...` | Stateless poll endpoint for the post-commit sync banner. Reads `market_data_price_daily` directly (no job table) and returns SnapTrade-shaped `{ status, syncPhase, completedCount, totalCount, pendingListingIds }`. Auth-filtered to the caller's owned listings; capped at 200 IDs per request. See ADR-022. |

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
| `dto/csvimport/CsvCommitResponse.java` | Record: committed + skippedDuplicates + failed + errors + `newListingIds` (UUIDs of brand-new listings whose backfill was triggered) |
| `dto/csvimport/CsvBackfillStatusResponse.java` | Record: status + syncPhase + completedCount + totalCount + pendingListingIds (mirrors SnapTrade sync DTO so frontend polling code is parallel) |
| `service/csvimport/CsvImportStatusService.java` | Stateless aggregator: auth-filters listing IDs to the caller's owned set, then asks `MarketDataPriceDailyRepository.findListingIdsWithPriceData` which have ≥1 bar |

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

### Historical price backfill (post-commit)

Any listing created during commit gets the same JIT treatment SnapTrade applies after a broker sync:

```
CsvImportService.commit() — per row
  ↓ resolveListing() → ListingResolutionResult { listing, wasCreated }
  ↓ transactionRepository.save(txn)
  ↓ if (wasCreated && newListingIds.add(listing.id)):
     → JitSecuritySetupService.onNewListingCreated(listing)
        → creates MarketDataSymbol if missing
        → publishes HistoricalPriceBackfillRequestedEvent (AFTER_COMMIT, async)
     → enqueueFigiResolution(listing)        // figi_resolution_queue
  ↓ commit response: newListingIds = LinkedHashSet of brand-new listings
```

JIT and FIGI calls are wrapped in **independent try/catch blocks** so a JIT failure cannot block FIGI enqueue and neither can roll back the saved transaction (mirrors the existing per-row error-isolation contract). The `LinkedHashSet` dedups the firing within a single commit — a CSV with 50 BUY rows for the same brand-new ticker triggers JIT exactly once.

### Backfill-status sync banner (frontend)

The frontend reuses the SnapTrade sync banner exactly — same `.sync-banner--syncing` / `.sync-banner--success` / `.sync-banner--error` SCSS, same 5000 ms poll interval, same 2500 ms message-rotation, same 120-attempt cap (~10 minutes). Only the message strings and the polled endpoint differ.

```
bulk-changes-tab → @Output csvBackfillStarted({ listingIds })
   → add-transaction-modal forwards
   → portfolio.component.onCsvBackfillStarted()
       → startCsvBackfillPolling(listingIds)         // 5s interval
       → startCsvSyncMessageCycle()                  // 2.5s rotation
       → on status === 'ACTIVE' → loadHoldings() + auto-dismiss after 3s
       → on FAILED or 120 attempts exhausted → error variant
```

Banner state (`csvSyncStatus`, `csvSyncPhase`, `csvBackfillListingIds`) is **parallel** to the SnapTrade equivalent rather than shared, so a user with a SnapTrade sync running concurrently does not see banners collide.

See ADR-022 for the architectural rationale (why no `csv_import_job` table) and the auth/DoS guards on the status endpoint.

### Heterogeneous broker formats (AI_FLEXIBLE only)

Real-world broker exports (Freetrade, Trading 212, Schwab, Vanguard, Revolut) often diverge from the
strict template in three ways:

1. **Composite type signal** — the activity category (`ORDER`, `DIVIDEND`, `INTEREST_FROM_CASH`,
   `MONTHLY_STATEMENT`, ...) is in one column, the trade direction (`BUY`/`SELL`) in another.
2. **Non-trade rows interleaved** — cash interest, monthly statements, top-ups, withdrawals, fee
   accruals appear inline with trades and have no ticker / quantity / price.
3. **Per-row price column varies** — `DIVIDEND` rows often have an empty primary price column and a
   per-share dividend column instead.

`ColumnMapping` carries four optional fields to express these patterns generically (no per-broker
adapters):

| Field | Purpose | Freetrade example |
|---|---|---|
| `directionColumn` | Trade direction column when separate from category | `"Buy / Sell"` |
| `dividendPriceColumn` | Per-share fallback used when row resolves to `DIVIDEND` and the primary `priceColumn` is blank | `"Dividend Amount Per Share"` |
| `skipTypes` (max 20) | Values in `typeColumn` whose rows are marked `SKIPPED` (surfaced in preview, never persisted) | `["INTEREST_FROM_CASH", "MONTHLY_STATEMENT", "TOP_UP", "WITHDRAWAL"]` |
| `typeAliases` (max 20) | Map from raw category to canonical type. Sentinel `"<USE_DIRECTION>"` defers to `directionColumn` | `{"ORDER":"<USE_DIRECTION>", "PROPERTY":"DIVIDEND", "SPECIAL_DIVIDEND":"DIVIDEND"}` |

**Per-row resolution order** in `CsvImportService.previewAiFlexible`:

1. If `rawCategory ∈ skipTypes` → mark `RowStatus.SKIPPED`, skip remaining checks, exclude from
   commit.
2. Resolve `rawType = typeAliases[rawCategory]` if set; sentinel `"<USE_DIRECTION>"` reads
   `directionColumn` for that row.
3. Canonicalise via `typeValueMap` → `BUY` / `SELL` / `DIVIDEND` / `TRANSFER`.
4. For `DIVIDEND` rows with blank `priceColumn`, fall back to `dividendPriceColumn`.

**Row status model**: `PreviewRow.rowStatus` is `NEW | DUPLICATE | SKIPPED | INVALID`. The legacy
`dedupStatus: NEW | DUPLICATE` is preserved for one release for client back-compat. `SKIPPED` rows
appear in the preview with a grey badge and `skipReason` tooltip; `validationErrors` is empty;
they're excluded from `validRows` and counted in the new `skippedRows` field on `CsvPreviewResponse`.

**Date robustness**: `parseFlexibleDateTime` (returns `OffsetDateTime` in UTC) cascades through
`OffsetDateTime → LocalDateTime → LocalDate → Instant.parse`, so ISO-8601 timestamps with offsets
(`2026-04-17T00:00:00.000Z`) parse cleanly even when the configured `dateFormat` is too restrictive.
`LocalDate` / `LocalDateTime` are transient extraction steps only — never escape the helper.

**Bounds**: `AiCsvMapper.MAX_LIST_OR_MAP_ENTRIES = 20`. Excess `skipTypes` / `typeAliases` entries
in the LLM response are truncated silently with a debug log (matches the existing
`validateColumn` hallucination-guard pattern). `directionColumn` and `dividendPriceColumn` go
through the same `validateColumn` header-existence check as the original 10 columns.

**Out of scope for this iteration** — proper cash transaction types (`DEPOSIT` / `WITHDRAWAL` /
`INTEREST` / `FEE`) with nullable `security_listing_id`. Today those rows show as `SKIPPED`. Adding
them later is forward-compatible: the same `skipTypes` entries become alias targets to the new
cash types instead.

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
