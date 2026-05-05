# ADR-026: Heterogeneous Broker CSV Format Support — Composite Type Signal, Skip Rules, Dividend Price Fallback

**Status:** Accepted
**Date:** 2026-05-01
**Extends:** ADR-020 §Decision 3 (AI-Assisted Mapper Pattern)

---

## Context

ADR-020 shipped an AI-mapper schema with one column per canonical concept (`tickerColumn`, `quantityColumn`, `priceColumn`, `typeColumn`, `dateColumn`, ...). It assumed every row in the CSV is a securities transaction and that a single `typeColumn` value resolves to `BUY` / `SELL` / `DIVIDEND` / `TRANSFER`.

Real broker exports (Freetrade, Trading 212, Schwab, Vanguard, Revolut) violate all three assumptions:

1. **Composite type signal.** Freetrade exports an activity *category* in `Type` (`ORDER`, `DIVIDEND`, `INTEREST_FROM_CASH`, `MONTHLY_STATEMENT`, `TOP_UP`, `WITHDRAWAL`, `PROPERTY`, `SPECIAL_DIVIDEND`) and the *direction* (`BUY` / `SELL`) in a separate column populated only for `ORDER` rows. ADR-020's mapper has no slot for "direction".
2. **Non-trade rows interleaved with trades.** A typical Freetrade activity feed of 273 rows had 50 cash-interest, 51 monthly-statement, 22 top-ups, and 2 withdrawals — 125/273 rows that have no ticker, no quantity, no price. Under ADR-020's schema each one fails preview validation with `quantity is required, price is required, ticker is required, unknown transaction type: …`.
3. **Per-row price column varies.** For Freetrade `DIVIDEND` / `SPECIAL_DIVIDEND` / `PROPERTY` (REIT distribution) rows, `Price per Share in Account Currency` is empty; the per-share payout sits in `Dividend Amount Per Share`. Dividends are not a price-less event — they have a price; it's just in a different column.

The fix could not be a per-broker adapter (Freetrade today, Trading 212 next month, Schwab after that — that path leads to a `BrokerPreset` registry and a maintenance tail). It had to be a generic schema extension that the LLM can learn to populate from any header sample.

---

## Decision 1: Four New Optional `ColumnMapping` Fields

| Field | Purpose | Freetrade example |
|---|---|---|
| `directionColumn` | Trade direction (`BUY`/`SELL`) when separate from the activity category | `"Buy / Sell"` |
| `dividendPriceColumn` | Per-share fallback used when a row resolves to `DIVIDEND` and `priceColumn` is blank | `"Dividend Amount Per Share"` |
| `skipTypes` (`List<String>`) | Values in `typeColumn` whose rows are non-trade (cash interest, statements, top-ups, withdrawals) | `["INTEREST_FROM_CASH", "MONTHLY_STATEMENT", "TOP_UP", "WITHDRAWAL"]` |
| `typeAliases` (`Map<String,String>`) | Map raw category → canonical type. Sentinel `"<USE_DIRECTION>"` defers to `directionColumn` for that row | `{"ORDER":"<USE_DIRECTION>", "PROPERTY":"DIVIDEND", "SPECIAL_DIVIDEND":"DIVIDEND"}` |

All four are nullable. A CSV that doesn't need them produces null values and behaves exactly as ADR-020 specified — strict back-compat.

The fields live on `ColumnMapping` (the AI-mapper output), not on a side channel, because they are mapping decisions: the LLM derives them from the same header + 5 sample rows it already reads.

## Decision 2: Per-Row Type Resolution Chain

`CsvImportService.previewAiFlexible` resolves each row's transaction type in this order:

1. Read `rawCategory = typeColumn` cell.
2. **Skip check.** If `rawCategory ∈ skipTypes` → mark `RowStatus.SKIPPED`, set `skipReason`, halt remaining checks. The row appears in the preview for visibility but never reaches commit.
3. **Alias resolution.** Look up `typeAliases[rawCategory]`. If the alias is the sentinel `"<USE_DIRECTION>"`, read `directionColumn` for this row and use that as the raw type instead. Otherwise, the alias replaces `rawCategory`.
4. **Canonicalisation via `typeValueMap`** (existing ADR-020 mechanism) → `BUY` / `SELL` / `DIVIDEND` / `TRANSFER`.
5. **Price fallback.** If the resolved type is `DIVIDEND` and the `priceColumn` cell is blank, fall back to `dividendPriceColumn`. Keep BUY/SELL strict on `priceColumn` — those rows always have a price.

This single chain handles every Freetrade row pattern (and the analogous patterns in other brokers) without per-broker code paths.

## Decision 3: `RowStatus` Enum — `NEW | DUPLICATE | SKIPPED | INVALID | CASH_FLOW | CORPORATE_ACTION_DROPPED`

`PreviewRow` gains `rowStatus` (the source of truth) and `skipReason` (human-readable, e.g. `"skipped: INTEREST_FROM_CASH"`). Semantics:

- `NEW` — passed validation, not a duplicate, eligible for commit as a `Transaction`.
- `DUPLICATE` — hash matches an existing transaction or cash flow; skipped on commit.
- `SKIPPED` — `skipTypes` rule matched and the row is not a recognised cash event; preview-only, never persisted; `validationErrors` is empty.
- `INVALID` — at least one entry in `validationErrors`.
- `CASH_FLOW` — row resolved to a non-trade cash event (`DEPOSIT/WITHDRAWAL/INTEREST/FEE/TAX/FX_CONVERSION/ADJUSTMENT`) and will be persisted to the `cash_flows` table at commit (ADR-028 routing extended to CSV).
- `CORPORATE_ACTION_DROPPED` — row resolved to a broker corp-action type (`BONUS/SPLIT/MERGER_*/SPINOFF_IN/RIGHTS_IN`); recorded for audit visibility but never persisted, since EODHD/BhavKosh `corporate_action_*` is the canonical source (ADR-029).

Legacy `dedupStatus: NEW | DUPLICATE` is preserved on `PreviewRow` for one release for client back-compat — `SKIPPED` rows emit `dedupStatus = NEW`. The frontend filters `validNewRows` by `rowStatus === 'NEW'` (not by `dedupStatus`) so SKIPPED rows are never sent to commit. `CsvPreviewResponse` gains `skippedRows` alongside `validRows` / `duplicateRows`.

Defence-in-depth: `CsvImportService.commit` re-checks `rowStatus == SKIPPED` and silently drops such rows even if a misbehaving client posts them.

## Decision 4: `parseFlexibleDateTime` — Returns `OffsetDateTime` (UTC) Always

ADR-020's `previewAiFlexible` parsed dates with `LocalDate.parse(raw, dateFmt)` then fell back to a naive `LocalDateTime.parse` via `ISO_LOCAL_DATE_TIME` — neither accepts the `Z` suffix in Freetrade's `2026-04-17T00:00:00.000Z`.

`parseFlexibleDateTime(raw, dateFmt)` cascades through `OffsetDateTime → LocalDateTime → LocalDate → Instant.parse` and **always returns `OffsetDateTime` in UTC**. Any `LocalDate` / `LocalDateTime` parsed mid-cascade is converted via `.atStartOfDay(ZoneOffset.UTC)` / `.atOffset(ZoneOffset.UTC)` before escaping the helper — they are transient extraction steps, never stored. The displayed `isoDate` string in `PreviewRow` is derived via `result.toLocalDate().toString()`.

This aligns the preview path with the existing `parseTimestamp` in commit, which already handled offset datetimes — closing a discrepancy where commit could persist a row whose preview had failed validation.

## Decision 5: Ghost-State UX — `skipTypes` and `typeAliases` Never Reach the User

`directionColumn` and `dividendPriceColumn` appear in the mapping editor as ordinary optional dropdowns labelled "Trade Direction (Optional)" and "Dividend Fallback Price (Optional)" — they map to one CSV column each, and the user can correct the AI's pick.

`skipTypes` and `typeAliases` are different: they are *behaviour rules* (which categories to filter, how to combine columns) that an end user has no domain context to author or audit. Surfacing them as a multi-input chip widget (an earlier iteration of this work) bloated the mapping step and exposed a backend abstraction the user shouldn't reason about. **The values are AI-inferred, held as ghost state in the frontend (`editedSkipTypes` / `editedTypeAliases` signals), and forwarded verbatim to `/preview` via `buildColumnMapping`.** The user sees the *outcome* (rows tagged `SKIPPED` in the preview, with a grey badge and `skipReason` tooltip) but never the rule.

If the AI proposes a wrong skip rule the visible failure mode is benign — the user sees more skipped rows than expected and re-uploads with manual mapping if needed. The contrary failure (user authors a wrong rule and silently loses transactions) is the one we ship away from.

## Bounds and Validation Guardrails

Extending the mapping schema widens the LLM's attack surface. Three guardrails:

- **Header-existence check** for `directionColumn` and `dividendPriceColumn` via the existing `AiCsvMapper.validateColumn`. Hallucinated columns are silently nulled — same pattern as the original 10 columns from ADR-020.
- **Bounded list / map sizes.** `skipTypes` and `typeAliases` are truncated to `MAX_LIST_OR_MAP_ENTRIES = 20` with a debug log if the LLM exceeds it. Real broker exports have fewer than 10 distinct activity types; 20 is generous. Truncate-not-reject preserves the "graceful degradation" pattern.
- **`<USE_DIRECTION>` sentinel is exact-match.** `CATEGORY_USE_DIRECTION` is a constant on `ColumnMapping`; `resolveRawType` compares case-insensitively but otherwise demands the exact literal — no near-matches, no AI-paraphrased "USE_DIRECTION" / "use_direction".

The deterministic-Java-parses-data principle from ADR-020 holds: the LLM still never extracts a numeric value or a date.

---

## Consequences

- **Freetrade and similar broker exports import end-to-end** without a per-broker adapter or a manual mapping correction step. Validated against a 273-row Freetrade activity feed: 148 valid trades + 125 skipped cash events + 0 errors.
- **`PreviewRow` carries two new fields** (`rowStatus`, `skipReason`). Existing JSON clients that ignore unknown fields are unaffected. The legacy `dedupStatus` field stays one release for client back-compat; remove in a follow-up once the frontend has cut over.
- **`CsvPreviewResponse` carries `skippedRows`** — additive, non-breaking.
- **The mapping editor is unchanged for users who don't need the new behaviour.** The two visible additions (Trade Direction, Dividend Fallback Price) are ordinary optional dropdowns alongside the existing ten.
- **Cash transaction types now route to `cash_flows`.** ADR-028 introduced the table; CSV import joined the routing in 2026-05 — broker labels for `CONTRIBUTION/DEPOSIT/WITHDRAWAL/INTEREST/FEE/MANAGEMENT_FEE/TAX/WITHHOLDING/FX/CONVERSION/ADJUSTMENT` resolve to `RowStatus.CASH_FLOW` (not `SKIPPED`) and persist to `cash_flows` at commit. `SKIPPED` is now reserved for genuinely-unrecognised categories the AI flagged as non-trade. The `skipTypes` channel still exists as the audit-trail bucket for everything that doesn't route to `cash_flows`, `transactions`, or `CORPORATE_ACTION_DROPPED`.
- **Strict-template (`TRANSACTIONS`) mode is unchanged.** The four new fields apply only to `AI_FLEXIBLE`. Template users keep the controlled column set.
- **No broker-named code paths exist.** The ADR's title says "broker CSV"; the implementation says "any CSV with a composite type signal or non-trade rows". This is the only shape that scales — every Freetrade-specific branch we don't write is a Trading-212-specific branch we don't have to write later.
