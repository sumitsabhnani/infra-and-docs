# ADR-038: Latest-Price Read Path — Unified Cache, Symmetric JIT, Market-Hours-Aware Refresh

**Status:** Accepted
**Date:** 2026-05-12
**Related:** ADR-006 (price-sweeper microservice), ADR-022 (backfill progress derived, not persisted), ADR-028 (EODHD JIT backfill is serial, throttled, bounded-retry)

---

## Context

The latest-price read path had grown three independent cache regions and two asymmetric JIT paths that together violated the "no sync external calls on hot path" principle for a non-trivial slice of requests:

- `stockPrices` (5-min Redis cache on `MarketDataService.getCachedCurrentPrice`) served `GET /api/stocks/{id}/current`. On cache miss it made a **synchronous** Zerodha or EODHD HTTP call on the user thread. `POST /api/stocks/refresh/{id}` reached the same `@Cacheable` and **silently served stale-cached data** instead of force-refreshing, contradicting its OpenAPI contract.
- `latestPrices` (20-min Redis cache, `@CachePut`-driven by the 15-min `LatestPriceRefreshJob`) served `GET /api/stocks/{id}/latest` and `POST /api/stocks/batch/current`. This path was correct — DB- and cache-backed, never a synchronous external call.
- Indian listings had async JIT (`MarketDataService.getYahooCachePrice` → sweeper `/force-fetch`); **non-Indian listings had no equivalent** — newly-added US holdings rendered blank until the next 15-min refresh tick.
- `LatestPriceRefreshJob` cron `0 0/15 * * * *` ran 24/7 with no market-hours guard. EODHD and Zerodha received bulk-quote requests every 15 minutes on weekends and overnight; the same requests on closed markets returned identical values cycle after cycle.
- Concurrent reads of an unseen symbol enqueued N redundant `/force-fetch` calls to the sweeper. The sweeper-side 1s lock absorbed the upstream traffic but the Java executor queue piled up.
- `latest_market_price.is_realtime` had zero readers across backend, frontend, jobs, and Python sweeper (verified by grep). The column was written on every upsert and never branched on.

A devils-advocate review of the proposed fix correctly killed a sixth track (ShedLock on scheduled jobs): production runs single-instance Docker Compose on Hetzner, and `portfolio-optimizer-backend/k8s/deployment.yaml` is vestigial — adding distributed locking would impose a migration, dep, and `@CachePut` interaction risk for zero current benefit.

---

## Decision 1: One Cache Region for Latest Prices — `stockPrices` Is Gone

`RedisConfig.cacheConfigurations` no longer defines a `stockPrices` region. All single-listing current-price reads route through `PriceService.getLatestPrice(SecurityListing)` / `PriceService.getLatestPrice(UUID)`, which is `@Cacheable("latestPrices", key=#listing.id)`. `latestPrices` TTL is bumped from 20 minutes to **24 hours** — it is a defence-in-depth backstop, not a freshness mechanism (`@CachePut` from `onLatestPricesRefreshed` keeps it warm; the TTL exists only to bound stuck-key bugs).

`StockPriceController.getCurrentPrice` and `getCurrentPriceByFigi` now read from `priceService.getLatestPrice(...)` and label `StockPriceDto.source = "latest_market_price"`. The OpenAPI description on both endpoints reads "Refreshed every 15 minutes by the background job" — no more "Cached for 5 minutes."

## Decision 2: `POST /refresh/{id}` Actually Refreshes Now

The latent bug — `PriceService.refreshPrice` calling the cached `MarketDataService.getCurrentPrice` and never persisting — is fixed inline. The dependency wiring now includes `ApplicationEventPublisher`; on a successful provider fetch, `refreshPrice` upserts via `LatestMarketPriceRepository.upsertLatestPrice` and emits `LatestPricesRefreshedEvent`, which `PriceService.onLatestPricesRefreshed` translates into `@CachePut` on the `latestPrices` cache. The endpoint's contract — "force refresh from external API, bypass cache" — is now honored end-to-end.

## Decision 3: Async JIT Symmetry — `EodhdJitFetchHandler` for Non-Indian Listings

`PriceService.getCachedLatestPrice(SecurityListing)` on cache+DB miss already enqueued a sweeper `/force-fetch` for Indian listings. The same path now calls `marketDataService.enqueueEodhdJitFetch(listing)` for non-Indian listings.

`EodhdJitFetchHandler.fetchAndPersist` lives in `api/service/marketdata/`, runs on a dedicated single-threaded `eodhdJitExecutor` inside `MarketDataService`, and mirrors the ADR-028 historical-backfill pattern: pre-call rate-limit acquire, `eodhdRealtimeClient.fetchBulkPrices(List.of(providerSymbol))`, three attempts with linear backoff (1s → 2s) on transient `EodhdApiException`, fail-closed on `EodhdRateLimitException` (do not retry the 429 — the scheduled batch will pick up the symbol on the next cycle).

The HTTP fetch + retry loop runs **outside** any `@Transactional` boundary. The DB write + event publish are scoped to a tiny `persistAndPublish` helper that relies on the `@Modifying @Transactional` annotation on the repository method, opening a HikariCP connection only for the write. The synchronous HTTP call and `Thread.sleep` backoff between attempts no longer hold a database connection.

## Decision 4: Concurrent-Read Deduplication

`MarketDataService.inFlightFetches` is a `ConcurrentHashMap<String, CompletableFuture<Void>>` keyed by namespaced symbol (`"yahoo:RELIANCE.NS"`, `"eodhd:AAPL.US"`). N concurrent reads of a cold-miss symbol enqueue exactly one task; the entry is removed in the task's `whenComplete` callback, so success or failure both release the marker immediately. No TTL — JVM crash resets the map; a hung task would also hang its executor, where retries wouldn't help.

The dedup applies to both the Yahoo sweeper path and the new EODHD JIT path.

## Decision 5: Scheduled Refresh Skips Per-Provider on Closed Markets

`core/util/MarketHours.java` is a stateless helper with `isUsMarketOpen(Instant)` and `isIndianMarketOpen(Instant)`. Windows: US 09:30–16:30 ET (regular + 30 min post-close), Indian 09:15–15:30 IST. DST is handled by `ZoneId` — no UTC arithmetic.

`LatestPriceRefreshJob.refreshLatestPrices`:

- **EODHD branch** runs only when `MarketHours.isUsMarketOpen(cycleAt)` is true. Closed → log `Skipping EODHD partition ({n} symbols): US market closed` once per cycle and skip the bulk fetch.
- **Zerodha branch** runs only when `MarketHours.isIndianMarketOpen(cycleAt)` is true. Same skip pattern.
- **BHAVKOSH branch** keeps running every cycle. It reads sweeper-Redis (sub-ms) — the sweeper itself is already gated on `_is_within_market_window()` in `price-sweeper/app/scheduler.py:30-47`, so no outbound Fyers call fires off-hours. Running this branch off-hours is essentially free.

Holiday calendars are explicitly out of scope. Republic Day, Independence Day, July 4, etc. still fire EODHD/Zerodha requests. Documented gap; revisit if it becomes a measurable cost.

## Decision 6: Shared EODHD Rate Budget — `EodhdRateLimiter`

`jobs/service/EodhdRateLimiter.java` is a fair FIFO 200ms-spaced reservation gate (`ReentrantLock(fair=true)` + monotonic `nextAllowedNanos`). Both `LatestPriceRefreshJob` (EODHD branch) and `EodhdJitFetchHandler` call `acquire()` before any `EodhdRealtimeClient.fetchBulkPrices` invocation.

The aligned 200ms throttle (matching ADR-028's `INTER_REQUEST_DELAY_MS`) caps sustained QPS at ~5 — well under EODHD's documented limits. The shared budget means a user-thread JIT burst cannot burn the budget right before a scheduled cycle and trigger a 429 that aborts the entire batch.

## Decision 7: `latest_market_price.is_realtime` Is Dropped

Flyway migration `V20260510120000__Drop_Latest_Market_Price_Is_Realtime.sql` drops the column. Verified zero readers via grep across `portfolio-optimizer-backend/`, `price-sweeper/`, `portfolio-optimizer-frontend/src/`, and `infra-and-docs/docs/`. Removed from `LatestMarketPriceRepository`'s SQL/view/upsert signature, `CachedLatestPrice` record, `LatestPriceDto`, `PriceService`, both `LatestPriceRefreshJob` and `EodhdHistoricalPriceBackfillJob`'s upsert call sites, and `price-sweeper/app/db.py`'s `UPSERT_LATEST_PRICE_SQL`. ADR-006 amended in place to point at this migration; freshness, where it matters, is now derivable from `as_of`. No cache-name bump — `RedisConfig.createJsonSerializer` has `FAIL_ON_UNKNOWN_PROPERTIES = false`, so pre-migration entries deserialise cleanly into the new 3-field `CachedLatestPrice` record.

---

## Consequences

**Positive**

- `GET /api/stocks/{id}/current` and `/figi/{listingFigi}/current` no longer make synchronous external HTTP calls. The "no sync external calls on hot path" principle is now uniformly enforced across all single-symbol read endpoints.
- `POST /api/stocks/refresh/{id}` actually persists. The latent bug — endpoint advertised as force-refresh, served stale-cached value — is gone.
- Newly-added non-Indian holdings populate within seconds of the first read instead of waiting up to 15 minutes for the next scheduled tick.
- EODHD and Zerodha API consumption drops by ~71% (US: 5/7 days × 6.5h / 24h ≈ 19% of the week; Indian: 5/7 × 6.25h / 24h ≈ 19% of the week — the rest is skipped). Off-hours JIT remains permitted; only the scheduled batch is gated.
- A user-thread JIT call can no longer break the next 15-min scheduled refresh by burning the EODHD rate budget.

**Negative**

- The `eodhdJitExecutor` is a single thread, so a stuck JIT task (e.g., EODHD hangs the connection) blocks subsequent JIT fetches until the per-attempt RestTemplate timeout fires. Acceptable: scheduled refresh still runs on its own thread, so the user-thread JIT being temporarily slow does not impair the population path.
- Sweeper-side `/force-fetch` is **not** market-window-gated. After this ADR, EODHD JIT skips outside US hours but Fyers/BHAVKOSH JIT does not. Asymmetry is documented; revisit if cold-miss off-hours JIT generates Fyers token errors at a meaningful rate.
- `MarketHours` does not understand holiday calendars. Off-hours refresh on a US/Indian bank holiday still fires the scheduled bulk-quote request. Tracking the EODHD quota burn from this is the deferred trigger for a holiday-aware extension.
- `inFlightFetches` markers are cleared on `Future.whenComplete`; an `Error` that escapes the executor's task scope without firing `whenComplete` would leave a permanent marker. The JVM restart is the recovery path. No safety TTL — a hung task would also hang its executor, making retries pointless.

**Neutral**

- The `latestPrices` cache region's TTL is 24h, but the cache is event-driven (`@CachePut` on `LatestPricesRefreshedEvent`). The TTL is unobservable in steady state.
- `EodhdRateLimiter` is a single bean in the `jobs` module; the `api` module depends on `jobs` already, so the JIT path can inject it without circular-dependency gymnastics.

---

## Alternatives Considered

- **ShedLock on every `@Scheduled` annotation.** Rejected. Production is single-instance Docker Compose (ADR-001); `k8s/deployment.yaml` is vestigial. Adding `shedlock-spring` + a Flyway migration + ~14 annotations for a problem that does not exist would cost a real `@CachePut`-interaction analysis for zero benefit. If the deployment ever moves to multi-replica, ShedLock + Postgres `JdbcTemplate` lock provider is the right primitive — re-scope at that point.
- **Extend the sweeper-Redis Yahoo TTL to 12h.** Rejected. The Yahoo Redis cache (`market_data:yahoo:*`) is never read on the hot path — the Spring `latestPrices` cache and the `latest_market_price` DB row are always above it. Extending its TTL changes nothing in steady state. (The TTL was independently removed on positive keys by the price-sweeper repo's orphan-prune sibling change, so the Yahoo Redis cache is now permanent until an orphan sweep evicts it — a separate decision orthogonal to this ADR.)
- **Drop DB writes from the price-sweeper, make Redis the source of truth.** Rejected. Would break four production paths: `preloadPricesIntoCache` on startup, the bulk `getLatestPricesByListingIds` endpoint which bypasses cache by design, the 15-min job's BHAVKOSH DB fallback, and the `currency` + `as_of` metadata that the sweeper-Redis JSON does not carry. Postgres also has the stronger backup story than Redis AOF + RDB.
- **Load EOD prices into Redis on application startup.** Already implemented as `PriceService.preloadPricesIntoCache` on `ApplicationReadyEvent`; proposal was a no-op.
- **Cache-name bump from `latestPrices` → `latestPrices_v2` to invalidate pre-migration `CachedLatestPrice` entries.** Rejected. `RedisConfig.createJsonSerializer` has `FAIL_ON_UNKNOWN_PROPERTIES = false` and the record's canonical constructor accepts the remaining 3 fields by name; pre-migration entries with the dropped `isRealtime` field deserialise cleanly. The cache-name bump would leak a `_v2` suffix into ops vocabulary and require a follow-up rename to retire.

---

## Verification

- **Migration:** `V20260510120000__Drop_Latest_Market_Price_Is_Realtime.sql` runs idempotently (`DROP COLUMN IF EXISTS`). Re-applying is a no-op.
- **Cache region:** `RedisConfig.cacheConfigurations` no longer contains `"stockPrices"`. After deploy: `redis-cli KEYS 'stockPrices::*'` returns empty once the prior region expires. Spring instantiates only the regions in the map.
- **Market-hours skip:** `LatestPriceRefreshJobTest` carries `skipsEodhdWhenUsClosed` and `skipsZerodhaWhenIndianClosed`, both using `Mockito.mockStatic(MarketHours.class)` to drive the time check. Both verify `never()` on the respective provider client.
- **Dedup:** `MarketDataServiceForceFetchDedupTest` runs 50 concurrent `getYahooCachePrice` calls for an unseen symbol; `priceSweeperClient.forceFetch` is invoked exactly once. Failure-clearing and completion-clearing each verified by a separate test.
- **JIT contract:** EODHD `429` from the user thread does not block the next scheduled cycle — `EodhdJitFetchHandler` swallows `EodhdRateLimitException` without retry, and the scheduled batch acquires the same `EodhdRateLimiter` after the JIT slot completes.
- **Refresh-endpoint contract:** `POST /api/stocks/refresh/{id}` against a clean DB issues a real EODHD/Zerodha HTTP call (verifiable in WireMock), upserts `latest_market_price`, and a subsequent `GET /api/stocks/{id}/current` returns the fresh value from cache without an external call.
