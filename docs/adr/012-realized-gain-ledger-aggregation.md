# ADR-012: Transaction-Ledger-Derived Realized Gain Aggregation

**Status:** Accepted
**Date:** 2026-04-19
**Context:** The Holdings overview page displayed a "Total Gain" card whose secondary line (`Realised: $0`) was hardcoded. Per-stock realized gain was already computed correctly inside `TickerDetailService` via AVCO, but no aggregate existed for the overview. Three data paths could have supplied it: (a) extend `/api/holdings` with per-holding realized totals, (b) read `PortfolioSnapshot.realizedPnl`, (c) derive fresh from the transaction ledger on demand. Path (a) silently drops fully liquidated tickers because `findActiveWithSecurity...` filters to `quantity > 0`. Path (b) is unsafe — `PortfolioCalculationService.updatePortfolioSnapshot` sums SELL proceeds rather than `proceeds − costBasis`, so the stored field is not realized gain at all. Only path (c) captures liquidated positions and is mathematically tied to a single AVCO implementation.

---

## Decision 1: Extract `RealizedGainCalculator` as the Single AVCO Source of Truth

**Choice:** All AVCO realized-gain math lives in `core/src/main/java/com/portfolio/tracker/core/service/RealizedGainCalculator.java`. The class exposes a reusable `AvcoState` step-machine plus two entry points — `computeTxnCurrency(List<Transaction>)` for the detail view (native currency) and `computeReportingCurrency(List<Transaction>, String, FxRateSnapshot)` for reporting-currency rollups. `TickerDetailService.toTickerTransactionDtos` now delegates its per-transaction output to the same `AvcoState`.

**Rationale:** ADR-011 established `ValuationEngineService` as the single source of truth for reporting-currency valuation math; this ADR applies the same principle to AVCO. A divergent implementation in the summary service would be invisible until a user noticed the overview card's total didn't match the sum of per-stock realized gains shown in the detail view. One state-machine shared by both call sites means a fix in one place corrects every caller and tests cover every consumer. The `AvcoState` interface is deliberately narrow (`step(Transaction)` returns the per-txn realized amount or `null`) so callers that need per-txn granularity (detail view) and callers that need only the sum (summary) reuse identical logic without a double loop.

**Enforcement:** `TickerDetailServiceTransactionsTest` remains green byte-identically, proving the refactor preserves legacy per-txn output. `RealizedGainCalculatorTest` covers the state machine directly as a pure unit test (no Spring context). `PortfolioSnapshot.realizedPnl` is explicitly **not** read anywhere — the field is flagged as tech debt rather than consumed.

## Decision 2: Derive Summary Realized Gain from the Transaction Ledger, Not Holdings

**Choice:** `StockGroupService.computeTotalRealizedGain` iterates `transactionRepository.findByPortfolioId(pid)` for each `effectivePortfolioId`, groups transactions by `(portfolioId, effectiveMasterId)` where `effectiveMasterId = COALESCE(canonicalMasterId, securityId)`, and runs one `AvcoState` per group. The result is summed into `GroupSummaryRowDto.allTotals.realizedGain`. Per-group rows receive `BigDecimal.ZERO` for now — user requirement is the overall summary card only.

**Rationale:** Deriving from holdings would silently lose realized PnL the moment a position fully liquidates, because the holdings query filters `quantity > 0`. A user who closed a winning position last month would see their realized gain evaporate from the card as soon as the final SELL zeroed the holding row — the worst possible UX for a "realized" metric. Deriving from the transaction ledger matches the immutable-ledger principle from ADR-011: holdings are a projection; the ledger is truth. The cross-exchange rollup key (`effectiveMasterId`) matches the existing convention in `TransactionRepository.findAvgReportingPriceByPortfolio`, so a security held across BSE and NSE shares one AVCO state.

**Exclusion rule (explicit):** Transactions for `(portfolio, effectiveMasterId)` pairs whose active holding has `excludedFromCalculations=true` are skipped. Liquidated tickers (no active holding exists) are included by default — consistent with the principle that realized PnL from a fully sold position should still count toward portfolio totals. This asymmetry is deliberate and documented on `computeTotalRealizedGain`.

## Decision 3: Reuse the ADR-011 FX Fallback Hierarchy

**Choice:** `RealizedGainCalculator.computeReportingCurrency` reads `normalizedReportingAmount` / `reportingCurrencyAtNormalization` from each transaction row when the stored reporting currency matches. This means realized gain automatically inherits the broker-FX → local-historical-FX → live-FX priority from ADR-011. When normalization is missing (e.g., user changed reporting currency and the async backfill hasn't completed), the calculator falls back to `FxRateSnapshot.getRate(txCurrency, reportingCurrency)` — live FX, ADR-011's final-leg baseline. No synchronous external calls occur.

**Rationale:** SELLs that happened months or years ago must be priced at the FX rate of their trade date, not today's rate — otherwise a USD-denominated profit can spuriously appear as an EUR loss (or vice versa) when FX moves. Reading the pre-computed `normalizedReportingAmount` column lets the summary request stay on the read hot path without touching external APIs, while the event-driven backfill (ADR-011 Decision 3) keeps the cache current. `PortfolioSnapshot.realizedPnl` is not used because its existing calculation is incorrect and rebuilding it would duplicate this work.

---

## Consequences

- Fully liquidated positions contribute correctly to overview realized gain — the metric is stable across a position's full lifecycle, not just while shares are held.
- Per-stock realized gain (detail view, native currency) and aggregate realized gain (overview card, reporting currency) are guaranteed to tie out because both flow through `AvcoState`. Discrepancies between the two views can only be caused by FX conversion, not by algorithm drift.
- Multi-portfolio aggregation (via `portfolioIds` query param) works with no new endpoint — the same summary call already scopes by portfolio set.
- Changing reporting currency automatically rescales realized gain via the ADR-011 async normalizer; no bespoke rebuild for the new field.
- Per-group realized-gain attribution is deferred: `GroupSummaryRowDto.realizedGain` is populated only on `allTotals`, zero on group rows. Populating per-group is a later, additive change that doesn't bump the DTO shape.
- Computation cost is O(transactions) per summary request. For typical portfolios this is negligible; if a user crosses tens of thousands of transactions we can cache into a corrected `PortfolioSnapshot.realizedPnl` without changing the API contract.
- `PortfolioSnapshot.realizedPnl` and the surrounding `PortfolioCalculationService.updatePortfolioSnapshot` logic are now formally known to be incorrect. Removing or fixing them is tech debt; out of scope here because nothing reads them.
