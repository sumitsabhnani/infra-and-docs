# ADR-021: Strict CSV Deduplication and Partial-Fill Disambiguation

**Status:** Accepted  
**Date:** 2026-04-26  
**Supersedes:** the dedup section of ADR-020 (replaces `csv:v1:` with `csv:v2:`)

---

## Context

ADR-020 introduced `csv:v1:` row-hash dedup keyed on `(portfolioId, ticker, isoDate, type, qty, price, currency)`. Date was collapsed to `yyyy-MM-dd` (start-of-day UTC); no broker trade ID was included.

Indian (and other) exchange tradebooks emit **one row per execution leg** (partial fill), not one row per order. A single market order split across fourteen exchange fills produces fourteen CSV rows with identical date/symbol/qty/price but distinct broker `trade_id`s. Under `csv:v1:` all fourteen collapsed into one committed row — silently dropping thirteen fills and miscounting the position by ≈92 %.

Empirical verification: uploading `Tradebook_GMD201_EQ_merged.csv` (Zerodha, 1 168 rows) into a brand-new portfolio reported **1 035 committed / 133 duplicates skipped**. Replaying the `csv:v1:` key against the file confirmed the maths exactly — confirming the 133 were intra-file false-duplicates, not real duplicates.

---

## Decision

### 1. Hash schema bumped to `csv:v2:` — new canonical input

```
portfolioId | ticker(upper) | isoTimestamp(UTC) | type(upper) | qty.plainString | price.plainString | currency(upper) | externalTradeId(or "")
```

`isoTimestamp` replaces the date-only string: it is the full `OffsetDateTime.toString()` in UTC. For date-only sources (`yyyy-MM-dd`) it becomes `…T00:00:00Z` — semantically equivalent to the old date string, so non-Zerodha imports with date-only columns keep deduping correctly across re-uploads. `externalTradeId` is appended last; when blank it contributes an empty segment.

### 2. Strict deduplication — no ordinal fallback

If two rows produce the same `csv:v2:` hash they are treated as duplicates and the second is skipped. We do **not** append a row-ordinal (e.g. `#2`, `#3`) to invent uniqueness for colliding partial fills.

**Why not ordinal fallback?**

| Concern | Ordinal approach | Strict approach |
|---|---|---|
| Idempotency on re-upload | Fails if the broker re-exports rows in a different order — re-upload silently re-imports "new" rows | Re-upload always produces the same hash; dedup is deterministic |
| Silent data multiplication | Ordinals treat every intra-file collision as a new transaction even when they are genuine duplicates | Explicit intent required; user maps Trade ID or accepts collapse |
| Mathematical correctness | Intra-file dedup silently inflates position sizes | Position size is only correct when the user has explicitly disambiguated |

For a platform where Accuracy is the top priority, inventing uniqueness from row position is incompatible with the "Correctness > Convenience" principle. Partial fills require explicit disambiguation by the user mapping a Trade ID column — this is an intentional opt-in, not a silent fix.

### 3. Optional `externalTradeId` canonical field — strongly recommended when present

`AiCsvMapper` system prompt lists `externalTradeIdColumn` as **optional but strongly recommended when present**, with examples: `trade_id`, `Trade No.`, `Execution ID`, `Fill ID`. When the AI maps it (or the user corrects the mapping), each broker fill carries its unique exchange-assigned ID in the hash, making every row distinct while preserving idempotency across re-uploads of the same file.

`ColumnMapping` gains `externalTradeIdColumn` (10th field). `PreviewRow` gains `externalTradeId` (the resolved cell value) and `transactionTimestamp` (the full timestamp string when the date column carries time-of-day; null otherwise). Both are passed through to commit and threaded into `computeRowHash`.

### 4. Timestamp parsing — UTC verbatim, no zone shift

When a date column contains a full datetime string (e.g. Zerodha's `order_execution_time`: `"2024-09-27T13:36:15"`), `CsvImportService.parseTimestamp` parses it as a naive `LocalDateTime` and attaches `ZoneOffset.UTC` **without converting from any regional timezone**. This preserves the source date under all market schedules and prevents the midnight-boundary shift that would break daily FX/pricing lookups:

```
naive "2024-09-27T13:36:15" → 2024-09-27T13:36:15Z   ✓  date preserved
IST→UTC "2024-09-27T23:59:00" → 2024-09-27T18:29:00Z  ✓  date preserved (markets closed by then anyway)
```

Sources that carry an explicit UTC offset (`Z` or `+HH:mm`) are converted correctly via `OffsetDateTime.parse`. Date-only sources fall back to start-of-day UTC, matching the old behaviour.

`Transaction.transactionDate` is now stored as the full `OffsetDateTime` when the source provides time-of-day, rather than `LocalDate.atStartOfDay().atOffset(UTC)`. Pricing and FX lookups derive `LocalDate.from(transactionDate)` — unchanged.

### 5. Strict-mode column detection

`CsvImportService` adds `EXTERNAL_TRADE_ID_ALIASES` (`external_trade_id`, `trade_id`, `execution_id`, `fill_id`, etc.) for auto-detection in `TRANSACTIONS` mode, consistent with the existing alias lists for `isin`, `currency`, and `exchange`.

### 6. UI warning

The Bulk Changes Done step renders a `@if (skippedDuplicates > 0)` warning explaining that skipped rows may be partial fills and directing the user to map the Trade ID column on the next import.

---

## Residual limitation (acknowledged)

Brokers that emit neither a per-fill trade ID **nor** distinct per-second exec timestamps (date-only legacy statements, some US broker exports) will still collapse legitimate same-day same-price partial fills under strict hashing. This is intentional: silent uniqueness-invention is worse than a visible warning. The UI message is the escape hatch.

---

## Consequences

- All future CSV imports use `csv:v2:` hashes. Existing `csv:v1:` hashes in `externalId` are not touched — they live alongside the new scheme without collision (prefix-gated). Any re-upload of a previously-imported file against a portfolio that already has `csv:v1:` rows will commit those rows again (from the `csv:v2:` perspective they are new). Affected users should wipe and re-import if they want `csv:v2:` dedup applied retroactively.
- `computeRowHash` is package-private; no external callers exist. The signature change is non-breaking at the API level.
- `PreviewRow` is a JSON DTO crossing HTTP. The two new fields (`externalTradeId`, `transactionTimestamp`) are nullable; existing clients that omit them receive `null` — no deserialization error.
- The AI system prompt instructs the LLM to map `externalTradeIdColumn` whenever present. Mapping accuracy depends on LLM capability but the server-side `validateColumn` guard (ADR-020, §3) still rejects any column name not in the real header.
