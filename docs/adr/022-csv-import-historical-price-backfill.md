# ADR-022: CSV Import Historical Price Backfill — JIT Trigger and Stateless Sync Status

**Status:** Accepted
**Date:** 2026-04-26
**Supersedes:** none
**Related:** ADR-003 (Async Ticker Resolution), ADR-004 (Historical Market Data), ADR-020 (CSV Import), ADR-021 (Strict CSV Dedup)

---

## Context

When a CSV import created a brand-new `SecurityListing` for a ticker the system had never seen before, the listing was persisted but **no historical price backfill ever fired**. Charts and history pages for the new ticker stayed empty until the next scheduled sweep — or forever, if no sweep covered it.

The pipeline already exists for SnapTrade: `JitSecuritySetupService.onNewListingCreated` creates a `MarketDataSymbol`, publishes `HistoricalPriceBackfillRequestedEvent`, and `EodhdHistoricalPriceBackfillJob.onBackfillRequested` (`@TransactionalEventListener(AFTER_COMMIT) @Async`) does the EODHD/Bhavkosh fetch. SnapTrade calls into this from `SnapTradeService` after each new listing is reconciled. The CSV import path simply never called it.

**Root cause** (verified, not a missing feature): `CsvImportService.resolveListing()` returned a bare `SecurityListing` and used the 1-arg `findOrCreateByTicker(ticker)` overload as its ticker-only fallback — an overload that does not expose the `wasCreated` flag. The information needed to detect "this is a new listing, fire JIT" was being thrown away one method call before it could be acted on.

A secondary question: how should the frontend show progress while backfill runs? SnapTrade has a `SnaptradeConnection` entity that persists across the sync, so a polling endpoint reads from it directly. CSV imports have no equivalent long-lived domain object — the import is a one-shot fan-out.

---

## Decision

### 1. Wire CSV-created listings into the existing JIT pipeline

`CsvImportService.resolveListing()` now returns `ListingResolutionResult` (which carries `wasCreated`) instead of bare `SecurityListing`. Every resolution path — ISIN-found, exchange-known, ticker-only fallback — produces a `ListingResolutionResult`. The ticker-only fallback was changed from `findOrCreateByTicker(ticker)` to `findOrCreateByTickerOrFigiOrExchange(ticker, null, null, null, currency, null)`, which routes through the same Step C path SnapTrade uses.

In `commit()`, after `transactionRepository.save(txn)` succeeds for each row:

```
if (resolution.wasCreated() && newListingIds.add(listing.getId())) {
    // first time we've seen this brand-new listing in this commit batch
    try { jitSecuritySetupService.onNewListingCreated(listing); } catch (...) { log.warn(...) }
    try { enqueueFigiResolution(listing); }                        catch (...) { log.warn(...) }
}
```

`newListingIds` is a `LinkedHashSet<UUID>` initialised at the top of `commit()`. It serves three purposes:
- **Dedup within batch:** a CSV with 50 BUY rows for the same brand-new ticker fires JIT exactly once, not 50 times.
- **Insertion order preserved:** for diagnostics + the response.
- **Source of truth for the response payload** (see §3).

JIT and FIGI calls are wrapped in **separate try/catch blocks** so that a JIT failure cannot prevent FIGI enqueue, and neither can roll back the already-saved transaction. This mirrors the existing per-row error isolation comment in `commit()`.

### 2. No `csv_import_job` table — stateless status query

Considered: a `csv_import_job` entity, repository, listener, and migrations to mirror the `SnaptradeConnection` shape exactly.

**Rejected.** SnapTrade has the connection entity because the connection is a long-lived domain object — credentials, last-sync timestamps, account IDs all persist beyond the sync itself. A CSV import is a one-shot event with no other reason to exist past commit. Adding a job table just to mirror the polling shape introduces persistence surface area, retention concerns, and a listener for an `HistoricalPriceBackfillCompletedEvent` consumer that does nothing but flip a flag — for no domain benefit.

Instead: the commit response returns the `newListingIds` it triggered backfill for, and the frontend polls a stateless endpoint that reads `market_data_price_daily` directly to compute `{ completedCount, totalCount, syncPhase }`. From the frontend's perspective the polling lifecycle, intervals, message rotation, and visual banner are byte-identical to SnapTrade.

```
GET /api/v1/csv-import/backfill-status?listingIds={uuid1},{uuid2},...

{
  status: "SYNCING" | "ACTIVE",
  syncPhase: "BACKFILL_PENDING" | "COMPLETED",
  completedCount, totalCount, pendingListingIds
}
```

A listing is "complete" iff at least one row exists in `market_data_price_daily` for it. Implemented via a single `SELECT DISTINCT mds.security_listing_id FROM market_data_price_daily p JOIN market_data_symbol mds … WHERE security_listing_id IN (:ids)` — bounded query, no N+1.

### 3. Auth on the status endpoint — transaction-ownership gate

The status endpoint accepts arbitrary listing UUIDs from the client. Without an auth check, any user could probe arbitrary listing IDs and learn whether they have price data — a soft information leak.

**Auth filter:** the service calls `TransactionRepository.findOwnedListingIdsForUser(userId, requestedListingIds)` and **silently drops** any listing not in that set (never echoed back in `pendingListingIds`). The query is `SELECT DISTINCT t.securityListing.id FROM Transaction t WHERE t.portfolio.user.id = :userId AND t.securityListing.id IN :listingIds` — bounded, indexed, single round-trip.

This pattern (filter rather than 403) is appropriate because the frontend may legitimately hand the endpoint a stale or partially-stale list across sessions, and a 403 would force the user to refresh.

### 4. DoS guard

Maximum 200 listing IDs per request. A real interactive CSV import that creates >200 brand-new tickers in one go is unrealistic; the cap exists to bound the IN-clause and the per-poll CPU.

### 5. Frontend reuses SnapTrade banner UX exactly

The CSV polling lifecycle uses the same `.sync-banner--syncing` / `.sync-banner--success` / `.sync-banner--error` SCSS classes and the same 2500 ms message rotation. **The fixed 5 s interval / 120-attempt cap was replaced (2026-05) with a growing schedule** — `5 s × 6 → 30 s × 10 → 60 s indefinitely` until the user dismisses or status flips to `ACTIVE`. The hard 10-minute cliff that previously flipped the banner to `FAILED` while the backfill was genuinely still running is gone; only `4xx` responses now end the loop in error. The frontend also chunks `listingIds` into batches of ≤ 200 via `forkJoin` and aggregates worst-case `status`/`syncPhase`, so an import that creates more than 200 brand-new listings no longer 400s on the controller's `@Size(max = 200)` guard. **Parallel state**, not shared — `csvSyncStatus` lives alongside (not replacing) the SnapTrade `syncStatus` so a user with both flows running concurrently does not see banners collide.

### 6. Pre-fix data is not retroactively backfilled

Listings created by CSV imports **before this fix landed** are not retroactively repaired. Re-running the CSV (idempotent under ADR-021's `csv:v2:` dedup) is a no-op for transactions but a JIT-trigger for any listings that are still in the `wasCreated=true` state — but pre-fix listings were created with `wasCreated=true` and then ignored, so the re-run path won't re-trigger them. The admin `HistoricalPricePrefillJob` endpoint covers any cleanup; no automatic backfill path is provided.

---

## Why this is safe

- **Idempotent JIT:** `JitSecuritySetupService.createEodhdSymbolIfAble` short-circuits when the `MarketDataSymbol` already exists. The `LinkedHashSet<UUID>` dedup is purely an I/O optimisation, not a correctness requirement.
- **No HTTP latency hit:** The event listener is `@TransactionalEventListener(AFTER_COMMIT) @Async("backgroundJobExecutor")` — the same pool SnapTrade uses (core=3, max=5, queue=500). Commit response time is unchanged.
- **Module boundaries respected:** All wiring stays in `api`, which already depends on `core`.
- **No new tables / migrations:** state lives in existing `market_data_price_daily`, `figi_resolution_queue`, `market_data_symbol`.
- **Multi-listing CSV semantics:** A user uploading 50 brand-new tickers fires 50 events into `backgroundJobExecutor` — well within the queue capacity of 500.

---

## What we are deliberately not doing

- **A `csv_import_job` persistence model.** The stateless status query gives identical UX parity at a fraction of the surface area.
- **Synchronous price fetching during commit.** Project rule: no sync external calls on hot path (see SYSTEM_SNAPSHOT §4).
- **Backfilling listings created by CSV imports prior to this fix.** Admin endpoints exist for that; auto-repair is out of scope.
- **A 403 on the status endpoint for unowned listings.** Silent filter is the correct UX.

---

## Consequences

- `CsvCommitResponse` gains a 5th positional field `List<UUID> newListingIds`. The record's previous callers (one frontend client, one IT test) accept the additional field at construction; no API URL change.
- `MarketDataPriceDailyRepository` gains `findListingIdsWithPriceData(List<UUID>)` (bulk distinct-listing query).
- `TransactionRepository` gains `findOwnedListingIdsForUser(UUID userId, List<UUID> listingIds)` for the auth filter.
- New: `CsvImportStatusController` endpoint, `CsvImportStatusService`, `CsvBackfillStatusResponse` DTO. ~80 LOC backend.
- Frontend: parallel `csvSyncStatus` / `csvSyncPhase` / `csvBackfillListingIds` state on `portfolio.component`, new `csvBackfillStarted` event chain through `bulk-changes-tab → add-transaction-modal → portfolio.component`. No new SCSS — reuses existing `.sync-banner*` classes.
- The `enqueueFigiResolution` helper is duplicated between `CsvImportService` and `SnapTradeService` (5 lines). DRY refactor into a shared service is out of scope; flagged as a candidate for ADR-003 follow-up if a third caller appears.

---

## Key Files

| File | Role |
|------|------|
| `api/.../csvimport/CsvImportService.java` | Wires JIT + FIGI; collects `newListingIds`; refactored `resolveListing` |
| `api/.../csvimport/CsvImportStatusService.java` | Stateless aggregator; auth filter; 200-ID DoS cap |
| `api/.../controller/CsvImportController.java` | New `GET /backfill-status` endpoint |
| `api/.../dto/csvimport/CsvBackfillStatusResponse.java` | DTO mirroring SnapTrade sync field shape |
| `api/.../dto/csvimport/CsvCommitResponse.java` | `newListingIds` field added |
| `core/.../MarketDataPriceDailyRepository.java` | `findListingIdsWithPriceData` |
| `core/.../TransactionRepository.java` | `findOwnedListingIdsForUser` |
| `frontend/.../portfolio.component.ts` | Parallel CSV polling state, `startCsvBackfillPolling` |
| `frontend/.../bulk-changes-tab.component.ts` | `@Output() csvBackfillStarted` |
