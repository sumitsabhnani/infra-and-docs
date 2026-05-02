# ADR-028: Resilient Broker Linking — Symbol Parity, Null-Exchange Promotion, EODHD JIT Resilience, Sync-Status Truth

**Status:** Accepted
**Date:** 2026-05-02

---

## Context

Re-linking a Trading 212 account end-to-end (full local wipe, fresh SnapTrade `connect/complete`, ~177 securities) surfaced four independent failure modes in the initial-sync chain. They cascaded into a single user-visible symptom — wrong realized P&L on closed AMZN / GOOG positions that straddled their 2022 splits — but the underlying causes touched four different services.

1. **Symbol-extraction asymmetry.** SnapTrade's SDK wraps `Position` two levels deep (`Position → PositionSymbol → UniversalSymbol`) and `Activity` one level deep (`Activity → UniversalSymbol`). `SnapTradeHoldingsReconciler` and `SnapTradeActivityMapper` each hard-coded one shape and silently returned `null` on the other. A holding's `acquired_listing_id` resolved to a fully-populated listing; the corresponding activity's `security_listing_id` resolved to a sibling row with `exchange_id = NULL`. ~20 orphan listings in production with `tx_count > 0 AND holding_count = 0`.

2. **Null-exchange short-circuit creates duplicate masters.** `SecurityListingService.findExistingMasterFor(ticker, exchange=null)` short-circuits and `EodhdSymbolDerivationService` bails when the listing has no exchange — so the activity-side orphan never gets a `MarketDataSymbol`, never gets historical bars, and never gets splits. When the next sync arrives with an exchange, a *new* listing + *new* master are created instead of promoting the existing null-exchange row.

3. **EODHD JIT chain silently breaks on transient failure.** `EodhdHistoricalPriceBackfillJob.onBackfillRequested` ran on the shared `backgroundJobExecutor` (3 core / 5 max). Initial broker linking publishes hundreds of `HistoricalPriceBackfillRequestedEvent`s in a 6-second burst; concurrent TCP connections to `eodhd.com` triggered host-level "Connection refused" on 104 of ~177 calls. The catch block logged ERROR and swallowed the exception — `HistoricalPriceBackfillCompletedEvent` was never published, which is the JIT trigger for `CorporateActionSplitBackfillJob.onHistoricalBackfillCompleted`. `corporate_action_split` stayed empty, AVCO walked the broken qty stream, and AMZN / GOOG closed positions computed against pre-split BUYs and post-split SELLs.

4. **Sync banner lies about progress.** The frontend banner polled a single endpoint that didn't distinguish FAILED ticker-resolution rows from in-flight ones, and treated any listing without bars as "still pending." A SnapTrade portfolio with even one EODHD-uncovered ticker (delisted, untranslatable MIC) kept the banner up indefinitely.

POP-111 closes all four together because they share the same regression surface (initial broker link). This ADR records the shipped architecture.

---

## Decision 1: Single Symbol Extractor Probes Both SnapTrade Wrapping Shapes

`SnapTradeSymbolExtractor` (in `api/service/snaptrade`) is the only path either flow uses to read SnapTrade symbol metadata. Its `resolveUniversalSymbol(payload)` walks one level, then two levels, then a `Map<String,Object>` shape — returning whichever level first exposes a non-null `getRawSymbol()`. The output is a `Symbol` record `(ticker, yahooSymbol, listingFigi, exchangeCode, rawExchangeCode, micCode, currency, name)`.

`SnapTradeHoldingsReconciler` and `SnapTradeActivityMapper` were stripped of their hand-rolled `extract*` methods plus reflection helpers (~178 / ~170 lines deleted respectively) and now call `symbolExtractor.extract(payload)` exactly once per row. Activity-side synthetic external IDs use `symbolExtractor.extract(activity).ticker()` to stay consistent with holding-side hashing.

**Invariant:** for any SnapTrade payload that a holding *and* an activity describe the same underlying security, both flows must produce byte-identical `Symbol` records. Any divergence reintroduces orphan-listing bugs. The unit test `SnapTradeSymbolExtractorTest` pins this with parameterised cases for INFY, BLS, ABB, SCHAEFFLER plus typed-SDK / Map-shape cross-products.

## Decision 2: Promote Null-Exchange Listings; Never Create a Duplicate When Exchange Resolves Late

`SecurityListingService.findOrCreateByTickerOrFigiOrExchange` gains a Step B' between the existing exchange-keyed lookup (Step B) and the create branch:

```
Step B': promote a null-exchange sibling
  candidates = findAllByTickerIgnoreCaseAndExchangeIsNull(ticker)
  filter currency match (case-insensitive, both sides non-null)
  filter transactionRepository.countBySecurityListingId(c.id) == 0
  if exactly one candidate:
    set exchange + listing_figi (if absent) + currency on that row, save, return
```

The filters are deliberately strict:
- **Currency match** prevents a USD activity from adopting a EUR null-exchange listing (or vice versa) when two unrelated brokers happen to share a ticker symbol.
- **Zero transactions on the candidate** keeps promotion side-effect-free. A listing with even one transaction has user-visible P&L history attached; we don't mutate its identity, we create a new row and let the dedup canonicalizer (ADR-019) link masters at the security_master layer.
- **Exactly one match** — multiple null-exchange siblings collapse to "create new" rather than guessing.

Promotion re-fires `JitSecuritySetupService.onNewListingCreated(saved)` and enqueues a fresh FIGI resolution because the original Phase α JIT call for the null-exchange row bailed at `EodhdSymbolDerivationService:253-255` (no exchange → no `MarketDataSymbol`). Without the re-fire, the promoted listing has no provider symbol and no path to historical prices.

A partial index supports the lookup at scale:

```sql
CREATE INDEX IF NOT EXISTS idx_security_listing_ticker_null_exchange
    ON security_listing (LOWER(ticker))
    WHERE exchange_id IS NULL;
```

(Migration `V20260502140000`. Filtered to keep the index small — null-exchange rows are a transient population.)

**Relationship to ADR-019:** ADR-019 is read-time canonicalization for *masters* — duplicates exist, are linked via `canonical_master_id`, and the read path heals. ADR-028 §Decision 2 is write-time promotion for *listings* — we prefer to never produce the duplicate in the first place when the natural key (ticker + currency, exchange-late-arriving) gives us a deterministic match. They compose: promotion eliminates the listing-level duplicate; canonicalization is the safety net at the master level when promotion's gates don't fire.

## Decision 3: EODHD JIT Backfill Runs Serial, Throttled, Bounded-Retry

A new bean `eodhdHistoricalBackfillExecutor` (in `AsyncConfig`) is single-threaded (`corePoolSize=1`, `maxPoolSize=1`, `queueCapacity=1000`, `CallerRunsPolicy`). `EodhdHistoricalPriceBackfillJob.onBackfillRequested` is annotated `@Async("eodhdHistoricalBackfillExecutor")`, replacing the previous `backgroundJobExecutor` wiring.

Each call:
1. Sleeps `INTER_REQUEST_DELAY_MS = 200` before any HTTP — caps sustained EODHD QPS at ~5 even on a fast network.
2. Runs the backfill inside a retry loop: `MAX_BACKFILL_ATTEMPTS = 3`, linear backoff `RETRY_BACKOFF_BASE_MS = 1000` (1s → 2s).
3. Retries only `EodhdHistoricalClient.EodhdApiException` (network I/O, 5xx, transient rate-limit). Programming/state errors fail fast — they do not burn the retry budget.
4. Publishes `HistoricalPriceBackfillCompletedEvent` only on success. After exhausting attempts, logs ERROR with the last transient cause attached (`log.error(..., lastTransient)` so the stack trace is visible).

Worst-case math: 177 symbols × (200 ms + ~300 ms HTTP) ≈ 90 s in the success path; × (200 ms + 3 s retry budget) ≈ 9.5 min if every symbol exhausts retries. Acceptable for an async post-link backfill that the frontend already polls against.

**Invariant:** `HistoricalPriceBackfillCompletedEvent` is the load-bearing trigger for `CorporateActionSplitBackfillJob.onHistoricalBackfillCompleted`. Any future change that affects when this event fires must preserve the property "transient upstream failure must not silently break the splits cascade." The weekly `scheduledWeeklySweep` (Sundays 04:00 UTC) is the safety net for symbols that exhaust retries — it will re-discover splits on the next pass — but the JIT chain is still the primary path.

**The pattern generalises.** Future external-API JIT consumers should consider a per-provider serial executor when (a) the provider rate-limits or refuses concurrent connections under burst, and (b) the JIT trigger is a fan-out event (broker link, bulk import). The shared `backgroundJobExecutor` is the right home for everything else.

## Decision 4: Per-Portfolio Backfill-Status Endpoint Is Authoritative About "Done"

`GET /api/v1/portfolio-sync-status?portfolioId={id}` returns `BackfillStatusResponse(status, syncPhase, completedCount, totalCount, pendingListingIds[])`. Backed by `PortfolioBackfillStatusService` in `api/service/portfolio`.

The service computes `pending` as listings owned by the portfolio that meet **all three** of:
1. No row in `market_data_price_daily` (no historical bars yet).
2. No row in `ticker_resolution_queue` with `status = FAILED` (FAILED listings are dropped — they will never resolve).
3. The `MarketDataSymbol` was created within the last `STALE_SYMBOL_THRESHOLD_MINUTES = 15` (older symbols are treated as EODHD-uncovered and dropped).

`totalCount` keeps FAILED + stale listings — the user sees stable "X of Y completed" numbers. `pendingListingIds` is the live set the frontend polls against. `done = pending.isEmpty()`; `status = ACTIVE` and `syncPhase = COMPLETED` once `done` is true.

Cross-user portfolio access returns the empty-progress shape silently (matches `CsvImportStatusService`'s pattern — no leak of cross-user portfolio existence).

**Why this matters.** The 15-minute stale window exists because EODHD-uncovered tickers (delisted, untranslatable MIC, custom-formatted broker-side symbols) leave a `MarketDataSymbol` row but never produce price data. The previous endpoint counted them as pending forever. With the serial executor at ~5 QPS plus retries, even ~200-symbol broker accounts clear in well under 15 minutes — anything older with no bars is structurally not coming through the JIT path, and the banner should reflect that truth.

---

## Consequences

- **Initial broker linking is now resilient to upstream blips.** The 104-of-177 burst-failure scenario is closed: serial execution prevents the connection refusal, and bounded retry absorbs single-symbol transients. The splits cascade stays intact.
- **`SecurityListingService` carries three new dependencies** (`TransactionRepository`, `JitSecuritySetupService`, `FigiResolutionQueueRepository`) and a new partial index. The promotion path is exercised on every exchange-resolved sync (SnapTrade activities, CSV imports, manual transaction adds), not just SnapTrade — the bug existed structurally but only SnapTrade's wrapping asymmetry triggered it loudly.
- **The shared `backgroundJobExecutor` is no longer the home for EODHD JIT backfill.** Any future code change that re-routes `onBackfillRequested` back to the shared pool reintroduces the burst failure mode. Tests on `OnBackfillRequested` (retry-success, retry-exhaustion, non-retryable-fast-fail) pin the contract.
- **The frontend banner has a single source of truth.** `PortfolioBackfillStatusService` is the only computation; the frontend renders against `BackfillStatusResponse.status` / `syncPhase` and never derives "done" from listing arrays.
- **No ledger touch.** `transactions` rows are byte-identical to what they were before the fix. The corruption symptom (wrong realized P&L) heals on the next dashboard fetch once `corporate_action_split` populates via the now-resilient JIT chain or the weekly sweep.
- **One failed-state surface remains.** `MarketDataSymbol` rows for EODHD-uncovered tickers persist with `is_active = true` and zero bars indefinitely. Decision 4 hides them from the banner; it does not delete them. Cleanup is admin work and out of scope here.

## Alternatives Considered

- **Decouple splits from price-backfill success entirely** — listen on `HistoricalPriceBackfillRequestedEvent` instead of `…CompletedEvent`. Rejected: split data only needs `providerSymbol`, but firing the splits trigger before the price backfill verifies the symbol resolves means we burn EODHD `/api/splits` calls on tickers that EODHD doesn't cover at all. Coupling the splits trigger to "we have proven we can talk to EODHD about this symbol" is the right gate; resilience belongs in the price-backfill chain, not in re-routing the trigger.
- **Re-publish the request event on transient failure** instead of inline retry. Rejected: queueing back into the same single-threaded executor preserves order but doubles the bookkeeping (the queue can grow unbounded if EODHD is down for a sustained window). Inline retry with a small bounded budget plus the weekly sweep covers both transient (retry succeeds) and sustained (sweep catches up) failures with simpler invariants.
- **Persist a `listing_promotion_log` audit row for Decision 2's promotions.** Rejected for now — the promotion is non-destructive (no transaction or holding row touched), idempotent on the natural key, and traceable from `security_listing.updated_at` plus the pre-existing FIGI queue row that re-arms after promotion. Adding a log table without an operational consumer is dead weight.
- **Deduplicate listings via DB unique constraint on `(LOWER(ticker), currency, exchange_id IS NULL)`.** Rejected for the same reason ADR-019 §Decision 1 rejected unique constraints on master rows: a constraint violation from inside an ingestion `@Transactional` rolls back the caller and silently drops broker-reported data. Best-effort promotion plus the dedup canonicalizer respects Never-Drop-Data.
