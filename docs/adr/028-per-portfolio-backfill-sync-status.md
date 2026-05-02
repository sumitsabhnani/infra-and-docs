# ADR-028: Per-Portfolio Backfill Sync Status — Stale-Symbol Window and Banner Precedence

**Status:** Accepted
**Date:** 2026-05-02
**Supersedes:** none
**Related:** ADR-002 (SnapTrade ledger ingestion), ADR-004 (Historical market data), ADR-014 (Read-time stock splits), ADR-022 (CSV import historical-price backfill)

---

## Context

After a SnapTrade broker link or a manual single-ticker add, two async jobs keep running for several minutes: `EodhdHistoricalPriceBackfillJob` (single-threaded, ~5 QPS, ~25 years of bars per new `SecurityListing`) and `CorporateActionSplitBackfillJob` (chained off `HistoricalPriceBackfillCompletedEvent`, recomputes AVCO via `HoldingsRecomputeOnCorporateActionListener`). Until splits land and the replay re-runs, on-screen quantity and cost basis are pre-split-adjusted — wrong-but-confidently-rendered numbers.

ADR-022 already established the stateless backfill-status pattern for CSV imports (`GET /api/v1/csv-import/backfill-status` derived from `market_data_price_daily`). That endpoint is keyed on a frontend-supplied list of listing UUIDs collected at commit time, which works for one-shot CSV imports but does not cover the broker-link path (no commit response to embed listing IDs into) or the post-login resume case (the IDs are gone).

A second problem surfaced once the per-portfolio endpoint shipped: some EODHD-uncovered tickers (delisted, unsupported) never produce a `market_data_price_daily` row and never land a `ticker_resolution_queue` entry either (the queue is keyed on `holding_id`, and a transaction row without a projected holding skips it). The endpoint returned `SYNCING` forever and the banner looped indefinitely.

---

## Decision

### 1. Per-portfolio derived endpoint, parallel to the CSV one

```
GET /api/v1/portfolio-sync-status?portfolioId={uuid}

{
  status: "SYNCING" | "ACTIVE",
  syncPhase: "BACKFILL_PENDING" | "COMPLETED",
  completedCount, totalCount, pendingListingIds
}
```

`PortfolioBackfillStatusService` derives the response without persistence: portfolio-ownership auth → `TransactionRepository.findOwnedListingIdsForPortfolio(userId, portfolioId)` resolves the user's owned set → diff against `MarketDataPriceDailyRepository.findListingIdsWithPriceData`. Cross-user requests silently drop to `ACTIVE/COMPLETED` (matching `CsvImportStatusService`'s no-info-leak pattern, never 403).

Same DTO shape as `CsvBackfillStatusResponse`. Two duplicates, no shared base record — refactor on the third.

### 2. The pending set has two filters beyond "no daily bars"

Listings drop out of `pendingListingIds` (but stay in `totalCount` for stable progress numbers) when **either** condition holds:

- **Failed ticker resolution.** `TickerResolutionQueueRepository.findListingIdsByStatusAmong("FAILED", ...)` joins through `holdings.acquired_listing_id` since the queue is keyed on `holding_id`, not `security_listing_id`. Listings whose holding has not yet been projected fall through this filter — see Decision 3.
- **Stale `MarketDataSymbol`.** `MarketDataSymbolRepository.findRecentlyCreatedListingIds(owned, threshold)` returns the listings whose symbol was created within the last **15 minutes**. Anything not in that set — symbol older than 15 min, or no symbol at all — is treated as "EODHD has had its window" and silently dropped.

### 3. The 15-minute staleness window is load-bearing

The EODHD executor (`eodhdHistoricalBackfillExecutor` in `AsyncConfig`, corePoolSize=1, queue=1000, 200 ms inter-request delay) clears even a ~200-symbol broker account in ~40 s; with bounded retries (3 attempts, 1 s/2 s linear backoff) the worst case is 2–3 min. 15 minutes is the documented generous cutoff after which a symbol still missing daily bars is treated as EODHD-uncovered, not in-flight.

This is a heuristic, not a derived signal. There is no `last_attempted_at` column on `market_data_symbol`; building one would require touching the row even when EODHD returns zero bars, which the job does not currently do. The staleness window is the cheaper surface.

`STALE_SYMBOL_THRESHOLD_MINUTES = 15` is a private constant on `PortfolioBackfillStatusService`. Tuning it is a code change with a unit test, not a configuration knob.

### 4. Frontend banner precedence: SnapTrade > CSV > Prices

`portfolio.component.ts` carries three parallel sync slots: `syncStatus` (SnapTrade), `csvSyncStatus` (CSV), `pricesSyncStatus` (this ADR). At most one banner shows at a time. The prices banner is gated on `pricesSyncStatus === 'SYNCING' && syncStatus !== 'SYNCING' && syncStatus !== 'PENDING' && csvSyncStatus !== 'SYNCING'`.

The SnapTrade "All data synced! Reload to see your portfolio." success message (both the in-flight `syncPhase === 'TRANSACTIONS_SYNCED' | 'COMPLETED'` variant and the post-`status === 'ACTIVE'` variant) is suppressed while `pricesSyncStatus === 'SYNCING'`. `pricesSyncStatus` is set eagerly to `SYNCING` at the start of `startPricesBackfillPolling` (before the first poll response) so there is no flicker between SnapTrade flipping ACTIVE and the prices banner taking over.

### 5. Adaptive polling, persisted timer, three thresholds

- **Cadence:** 5 s × 12 → 30 s × 20 → 60 s steady-state. Once stuck (≥ 10 min) the cadence drops to 60 s and **stays polling** so the banner self-clears once the backend's stale-symbol filter trips.
- **5-min long-running** → subtitle swaps to "Still working — large portfolios can take a few minutes."
- **10-min stuck** → copy swaps to the user-facing report-this-ticker message; polling slows to 60 s but does not stop. Without continued polling the banner could not self-clear once the 15-min server-side filter trips.
- **30-min hard cap** → polling finally stops. Banner stays visible with stuck copy until the user dismisses manually.

`pricesSyncPollStartedAt` is persisted to `sessionStorage` under `syncing_prices_started_at` alongside the existing `syncing_prices_portfolio_id`. On resume after refresh the original start timestamp is restored, so the 10-min and 30-min thresholds cannot be reset by reloading the page.

### 6. Trigger sources funnel into one polling lifecycle

`startPricesBackfillPolling(portfolioId)` is invoked from four places: SnapTrade banner flipping to `ACTIVE` (line 1730), CSV banner dismiss path, post-`createHolding` (manual single-ticker add), and `checkForActiveSyncs()` on portfolio mount / login resume. The same method is idempotent on `(pricesSyncPollingInterval, pricesSyncPortfolioId)` — re-entry on the same portfolio is a no-op.

---

## What we are deliberately not doing

- **Extending `SnaptradeConnection.SyncPhase` with a `BACKFILLING_PRICES` value.** Couples a broker-entity lifecycle to market-data backfill state and breaks for CSV / manual-add flows that have no `SnaptradeConnection`.
- **A `*_backfill_status` table or any new persistence.** ADR-022 already established the stateless-derivation pattern; doing a third copy of the same DTO for a third path is the trigger to extract a shared record, not to introduce schema.
- **SSE / WebSocket push.** Polling at this cadence costs two indexed Postgres queries per request; SSE adds transport, auth, Caddy passthrough, and reconnect concerns for no domain win. The repo's convention is polling (broker sync, CSV backfill).
- **Modifying the backfill jobs themselves.** Coupling job code to UX state defeats the derived-state pattern. The jobs stay event-driven; the status endpoint observes outcomes.
- **A FAILED state on this endpoint.** Listings genuinely uncovered by EODHD live in the ticker-resolution path; this banner only knows "data exists or not yet." The 30-min hard cap is the user-visible surface for "we have given up auto-clearing."
- **A banner in `app-header`.** Per-portfolio state belongs in the portfolio shell.
- **Backfilling progress for FX, dividends, mergers, or spin-offs.** Pricing + splits is the user-facing pain (qty and cost basis change visibly); the others either trail too quickly to matter or are manual-entry only post-ADR-027.

---

## Consequences

- **New surface:** `PortfolioSyncStatusController`, `PortfolioBackfillStatusService`, `BackfillStatusResponse` DTO (~140 LOC backend incl. tests).
- **Repo additions:** `TransactionRepository.findOwnedListingIdsForPortfolio`, `TickerResolutionQueueRepository.findListingIdsByStatusAmong`, `MarketDataSymbolRepository.findRecentlyCreatedListingIds`. All read-only.
- **Frontend:** third `pricesSyncStatus` slot on `portfolio.component`, parallel polling lifecycle, two new SCSS-free template branches, `ApiService.getPortfolioSyncStatus`. Reuses existing `.sync-banner` / `.sync-loader` styles. The `--syncing` variant text color was retoned from `#5eead4` to `var(--text-primary)` for readability.
- **No schema change.** No Flyway migration. No new event.
- **The 15-min staleness window is a known-imperfect heuristic.** A genuinely slow EODHD backfill (e.g. retry storm) on a symbol older than 15 min would be silently dropped from pending — the banner clears even though data is still landing. Acceptable: the next user-driven action that calls `loadHoldings()` picks up the eventual write.
- **Banner precedence is enforced in the template, not the state machine.** All three sync flags can be `SYNCING` simultaneously; the template gates rendering. Future state additions must update both.

---

## Key Files

| File | Role |
|------|------|
| `api/.../controller/PortfolioSyncStatusController.java` | `GET /api/v1/portfolio-sync-status` |
| `api/.../service/portfolio/PortfolioBackfillStatusService.java` | Derived aggregator; auth filter; `STALE_SYMBOL_THRESHOLD_MINUTES = 15` |
| `api/.../dto/portfolio/BackfillStatusResponse.java` | DTO; same shape as `CsvBackfillStatusResponse` |
| `core/.../repository/TransactionRepository.java` | `findOwnedListingIdsForPortfolio` |
| `core/.../repository/TickerResolutionQueueRepository.java` | `findListingIdsByStatusAmong` (joins via `holdings.acquired_listing_id`) |
| `core/.../repository/MarketDataSymbolRepository.java` | `findRecentlyCreatedListingIds` (15-min freshness filter) |
| `frontend/.../portfolio/portfolio.component.ts` | Third polling slot; precedence; persisted start timestamp |
| `frontend/.../portfolio/portfolio.component.html` | Banner template + precedence guards |
| `frontend/.../services/api.service.ts` | `getPortfolioSyncStatus` |
