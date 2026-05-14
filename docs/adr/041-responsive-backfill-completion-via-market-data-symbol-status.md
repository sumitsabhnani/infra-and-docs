# ADR-041: Responsive Backfill Completion via `market_data_symbol.backfill_status`

**Status:** Accepted
**Date:** 2026-05-14
**Related:** ADR-022 (CSV import historical price backfill), ADR-028 (per-portfolio backfill sync status), ADR-039 (master-scoped holdings recompute)

---

## Context

ADR-022 / ADR-028 derived per-portfolio backfill progress purely from `market_data_price_daily` over the user's owned listings, with two pending-set filters: FAILED `ticker_resolution_queue` entries (joined via `holdings.acquired_listing_id`) and a 15-minute staleness window on `MarketDataSymbol.created_at`. The window was sized to the worst-case retry budget of the single-threaded EODHD JIT executor (5 QPS × ~200 symbols × 3-attempt linear-backoff).

In practice that window is the primary clearing mechanism for listings the provider doesn't cover (delisted, foreign exchanges outside EODHD's footprint, fundamentally un-resolvable tickers). User-visible consequences:

- **15-minute latency** on the "Loading historical prices…" banner for any listing the provider can't satisfy. The job knows after one attempt; the platform waits.
- **Mixed-currency aggregation while waiting.** Holdings with un-resolved prices contribute zero to `currentValue`. The "We've identified missing data for …" warning is suppressed during sync by ADR-039's `isAnySyncInProgress` gate. Summary cards show quietly under-counted totals until the staleness fallback releases them.

Empirically, this combined with skeleton-holding creation (ADR-039) on a single Zerodha link produced summary cards showing `Invested ₹31,769` instead of the correct `₹3,020,695` for ~15 minutes after every sync.

The chosen alternative is hybrid: keep derivation for the in-progress signal, but persist *terminal* outcomes so the status service can short-circuit without waiting on the clock.

---

## Decision

Add three columns to `market_data_symbol`:

```
backfill_status        VARCHAR(16)    -- NULL | PENDING | SUCCEEDED | FAILED | NO_DATA
backfill_attempted_at  TIMESTAMPTZ
backfill_notes         TEXT
```

Values are validated in Java via `MarketDataSymbolBackfillStatus` constants (mirrors the `TickerResolutionQueue.resolutionStatus` pattern — no SQL enum). A partial index `idx_market_data_symbol_backfill_status` on `(security_listing_id, backfill_status) WHERE backfill_status IN ('FAILED', 'NO_DATA')` keeps the new query cost flat as the table grows.

`EodhdHistoricalPriceBackfillJob.onBackfillRequested` writes the terminal value before exiting every branch:

- **Method entry:** `PENDING` — clears any prior terminal value so a re-fired event isn't stuck reading the previous attempt's result.
- **Successful bars persisted:** `SUCCEEDED` — only when `hasTerminalStatus` doesn't already see a `NO_DATA` written by the empty-bars branch in the same call.
- **Retry exhaustion on `EodhdApiException`:** `FAILED` with `"retry exhausted: <lastTransient.message>"` in `backfill_notes`.
- **Non-retryable exception (any non-`EodhdApiException`):** `FAILED` with `"non-retryable: <e.message>"`.
- **Empty bars + no prior data** (both `backfillSymbol` for EODHD and `backfillSymbolFromBhavKosh` for BhavKosh): `NO_DATA` with `"empty bars, no prior data"`. The existing `publishTickerResolutionIfNeeded` call remains — ticker re-resolution may still find a better symbol mapping. The two signals are orthogonal: `NO_DATA` releases the status service, the resolution event repairs the listing if possible.

`PortfolioBackfillStatusService.getStatus` reads a third pending-set filter alongside `withData` and `failed`:

```java
Set<UUID> backfillTerminated = new HashSet<>(
    marketDataSymbolRepository.findListingIdsWithTerminalBackfillStatus(owned));

List<UUID> pending = owned.stream()
    .filter(id -> !withData.contains(id)
               && !failed.contains(id)
               && !backfillTerminated.contains(id)
               && fresh.contains(id))
    .toList();
```

The `fresh` 15-minute staleness window stays, but reduces from primary clearing mechanism to safety net — it now catches only the path where the job dies before writing terminal status (process crash mid-call, executor queue overflow). Normal terminal outcomes clear within one frontend poll interval (5–30 s).

The column is not a UI surface. No endpoint serves the raw value; consumers read the derived `BackfillStatusResponse` (`{status, syncPhase, completedCount, totalCount, pendingListingIds}`). Future tooling that needs per-symbol provider verdicts (admin coverage-gap views, sweeper diagnostics) can query the column directly, but the public contract stays the derived DTO.

---

## Consequences

- **Banner clearing drops from ~15 min worst case to one poll interval** for listings the provider can't satisfy. The user sees the real numbers — and the missing-data warning — within seconds of the provider's verdict.
- **The "Backfill Progress is Derived, Not Persisted" rule (SYSTEM_SNAPSHOT §4) is now hybrid.** Derivation owns "is this listing in progress" (from `withData`). Persistence owns "did the provider give up." The earlier blanket claim is updated in the snapshot.
- **BhavKosh empty-bars now mirrors EODHD.** Previously only EODHD's empty-bars-no-prior-data path published `TickerResolutionNeededEvent`; BhavKosh was a silent no-op that let the staleness window do the clearing. Indian-market listings the provider doesn't cover now exit `pending` symmetrically and trigger ticker re-resolution the same way EODHD listings do.
- **Existing rows untouched by migration.** Symbols with price rows are already excluded from pending via `withData`; symbols older than 15 minutes without data are still caught by the (preserved) `fresh` filter. New symbols flow through the column from first attempt.
- **`PENDING` writes are observable diagnostic state.** A `PENDING` row with an old `backfill_attempted_at` and no terminal transition is a signal that the job started but did not finish — exactly the case the staleness window now backstops. Useful for triage without adding a separate audit log.
- **No corresponding column on `market_data_price_daily`.** The terminal status is per-symbol (per-provider-per-listing), not per-bar. Mixing them would conflate "provider doesn't cover this listing at all" with "we already have bars but the latest run failed transiently," which the existing `withData` filter already distinguishes correctly.
