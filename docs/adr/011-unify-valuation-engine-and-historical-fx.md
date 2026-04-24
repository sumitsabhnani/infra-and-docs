# ADR-011: Unified Valuation Engine & Historical FX Cost Basis

**Status:** Accepted
**Date:** 2026-04-16
**Context:** After ADR-009 introduced the USD-normalized cost basis path, Alcoa Corp (AA) still reported **€25.05** average price in the UI versus Trading212's **€27.22** — an ~8.7% discrepancy on a cross-currency holding. Root cause: the partial-buy rule computed `costBasisReporting = qty × avgUsdPrice × fx(USD→reporting)` using **today's** FX rate rather than the historical rate at each purchase date. Separately, `HoldingController` and `StockGroupService` had drifted into divergent valuation paths, so the same holding could produce different numbers in the holdings table vs. the group summary.

---

## Decision 1: Extract `ValuationEngineService` as Single Source of Truth

**Choice:** All reporting-currency cost basis, gain/loss, and FX impact math lives in `ValuationEngineService`. `HoldingController`, `StockGroupService`, and any future aggregator call into the same engine with the same `HoldingValuationInput` record.

**Rationale:** ADR-009's Accounting Tie-Out Principle requires rows to sum to summary totals. When two call sites independently re-implement the partial-buy rule, they drift — and the drift is invisible until a user notices their holdings subtotal doesn't match the group header. Centralizing the math means a fix in one place corrects every caller, and unit tests cover every consumer at once.

**Enforcement:**
- `StockGroupService.getSummary()` now fetches `findAvgReportingPriceByPortfolio` per portfolio and threads the map through `buildGroupSummaryRows` → `aggregateToSummaryRow` → `sumCostBasisReporting`, calling the same 8-arg `costBasisReporting` overload used by `HoldingController`.
- `HoldingValuationInput` is a record with a fixed 10-field contract; adding a new input requires updating every call site, which flushes drift at compile time.

## Decision 2: Graceful FX Fallback Hierarchy

**Choice:** When converting a purchase from native currency to reporting currency for cost basis, use this priority order:

1. **Broker FX (`broker_fx_rate`)** — the rate the broker actually used for settlement. Captured at sync time from SnapTrade's `UniversalActivity.fx_rate` and stored immutably on the transaction row. Verified against `broker_amount` within 5% tolerance before use.
2. **Local Historical FX (`fx_rate` table)** — EOD close from EODHD, pre-fetched via admin backfill. `HistoricalFxRateService.getHistoricalRate(from, to, date)` does a pure DB lookup (USD-base, cross-routed) and returns `null` if no rate exists on or before the trade date.
3. **Live Current FX (`FxRateSnapshot`)** — today's rate from the in-memory snapshot. The existing ADR-009 fallback, now explicitly the last resort rather than the default.

Each leg is tried in order; on `null` the next leg is used. The reporting normalizer (Step 1 + 2) runs **async** and persists results into `normalized_reporting_price` / `normalized_reporting_amount` / `reporting_currency_at_normalization` on the transaction row. The read hot-path only ever reads those pre-computed columns (Step 1 + 2 never ran synchronously during a holdings fetch).

**Rationale:** Broker FX is ground truth — it's what actually moved money — so it ranks above any external approximation. Local historical FX is the next-best proxy for the trade date but can have gaps (weekends, holidays, currencies we haven't backfilled yet). Live FX is mathematically wrong for historical cost basis but produces a stable, always-available number; preserving it as a fallback means a missing rate never breaks the UI, it just reduces accuracy to the ADR-009 baseline.

**Immutable ledger, cached projection:** The `transactions` table is the ledger — broker facts only (`broker_fx_rate`, `broker_fee`, `broker_amount`) plus the audit trail of what we used for USD normalization (`fx_rate_to_usd`). The reporting-currency columns are a **performance cache** that can be rebuilt from the ledger at any time. Changing a user's reporting currency does not mutate the ledger; it invalidates and rebuilds the cache.

## Decision 3: Event-Driven Chunked Backfill for Reporting Currency

**Choice:** Reporting-currency normalization is never computed on the read path. It is triggered by explicit events and processed asynchronously in chunked batches of 100:

- **`ReportingCurrencyChangedEvent`** — fired from `UserController` after a user changes their reporting currency. Listener runs via `@TransactionalEventListener(AFTER_COMMIT) @Async("backgroundJobExecutor")` and calls `backfillForUser(userId, newCurrency)`.
- **`BrokerSyncCompletedEvent`** — same listener, ensures newly synced transactions are normalized to the user's current reporting currency.
- **Admin endpoints** — `POST /api/v1/admin/fx-rates/backfill-historical?from=...&to=...` pre-populates the local `fx_rate` table from EODHD (bounded to 365 days per call, superuser-gated). `POST /api/v1/admin/transactions/backfill-reporting?currency=...` re-runs normalization for all users. No external API calls happen inside the batch loop — the normalizer is DB-only and fails soft when rates are missing.

Each batch is `saveAllAndFlush`'d independently. No single large `@Transactional` spans the whole population. Un-normalizable batches (missing FX data) break the loop rather than spinning, so a gap in historical FX coverage degrades gracefully into ADR-009's live-FX fallback rather than blocking the queue.

**Rationale:** Synchronous external API calls on the hot path break the SLA when EODHD is slow; a single-transaction backfill across 50k transactions blocks other writes and risks rollback of legitimate work on failure. Event-driven async + chunked flushing isolates failure blast radius to a single batch and lets the UI render immediately from the cached projection. Admin-triggered historical FX backfill keeps EODHD calls out of the request path entirely — they only happen when an operator explicitly decides to widen coverage.

---

## Consequences

- AA and every other cross-currency holding now reflect the **weighted historical FX rate** at each purchase date, matching the broker's own reporting.
- Holdings table and group summary are guaranteed to tie out because they compute through the same engine with the same inputs.
- Adding a new caller (e.g., a future portfolio-analytics endpoint) requires zero math duplication — just call `ValuationEngineService.costBasisReporting(...)`.
- A missing historical FX rate no longer breaks the UI; it falls back to live FX (ADR-009 behavior) and logs a warning, self-healing once the admin backfill covers the gap.
- Reporting-currency changes are instant for the user (UI updates from the cache) and accurate in the background (async re-normalization completes within seconds for typical portfolios).
- The transaction ledger remains immutable with respect to reporting currency — changing reporting preferences only affects the cache columns, never the broker-sourced fields.
- Historical FX coverage is now a first-class operational concern: `fx_rate` table must be backfilled before reporting normalization produces accurate results. The admin endpoints make this a one-time operator action per currency pair.
