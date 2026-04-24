# ADR-007: Redis-First Market Indices — Background-Warmed Cache for Top-Bar Data

**Status:** Accepted  
**Date:** 2026-04-12  
**Context:** The top-bar market indices (S&P 500, Dow Jones, Nasdaq, NIFTY 50, MSCI ACWI) were fetched synchronously from the EODHD real-time API on every cache miss. With a 5-minute TTL and 5 sequential API calls (200ms inter-call sleep), the first user request after expiry blocked for ~1s+. This degraded TTFB unpredictably and consumed EODHD rate-limit budget on the hot path. A secondary issue: `CacheConfig.java` in the `api` module declared a `RedisCacheManagerBuilderCustomizer` for the `marketIndexes` cache, but `RedisConfig.java` in `core` created an explicit `@Bean CacheManager`, causing Spring Boot autoconfiguration to back off — the customizer never fired, and the cache silently used the default 1-hour TTL.

---

## Decision

### Background Cache-Warming Job

A new `MarketIndexRefreshJob` in the `jobs` module runs on a `@Scheduled(cron = "0 0/5 * * * *")` schedule (every 5 minutes). It fetches all configured indices from the EODHD real-time API and writes the result to Redis via `CacheManager.getCache("marketIndexes").put("all", ...)`.

```
┌─────────────────────────────────────────────────┐
│  Every 5 min (background)                       │
│                                                 │
│  MarketIndexRefreshJob                          │
│    │                                            │
│    ├─ GET eodhd.com/api/real-time/GSPC.INDX     │
│    ├─ GET eodhd.com/api/real-time/DJI.INDX      │
│    ├─ GET eodhd.com/api/real-time/IXIC.INDX     │
│    ├─ GET eodhd.com/api/real-time/NSEI.INDX     │
│    └─ GET eodhd.com/api/real-time/ACWI.US       │
│         │                                       │
│         ▼                                       │
│    CacheManager.put("marketIndexes", "all")     │
│         │                                       │
│         ▼                                       │
│    ┌──────────┐                                 │
│    │  Redis   │  TTL: 10 min                    │
│    └──────────┘                                 │
└─────────────────────────────────────────────────┘
```

### Read Path (O(1) Cache Hit)

`MarketIndexService.getAll()` retains its `@Cacheable(value = "marketIndexes", key = "'all'")` annotation. Because the background job keeps the cache warm, the `@Cacheable` annotation almost never triggers a cache miss — it serves purely as the read-through fallback if the job is temporarily down or delayed.

```
GET /api/market-indexes
  └─ MarketIndexService.getAll()
       └─ @Cacheable("marketIndexes", key="all")
            └─ Redis HIT (99.9% of requests)
                 └─ 0ms network cost (local Redis)
```

### TTL Strategy

The `marketIndexes` cache TTL is **10 minutes**, configured in `RedisConfig.cacheManager()` (the single source of truth for all cache TTLs). The background job refreshes every 5 minutes. This means:

- **Normal operation:** Cache is always warm; users never hit EODHD.
- **Single missed cycle:** Cache remains valid for another 5 minutes (10-min TTL minus 5-min refresh interval).
- **Two consecutive missed cycles:** Cache expires; `@Cacheable` fallback fetches from EODHD synchronously (same behavior as before, but now only under double-failure conditions).

The dead `CacheConfig.java` customizer in the `api` module was removed.

### Startup Behavior

`StartupJobTrigger` performs two actions on `ApplicationReadyEvent`:

1. **Explicit cache eviction** — `cacheManager.getCache("marketIndexes").clear()` removes any stale entries that may contain old `@class` metadata (e.g., after a `MarketIndexDto` package move). This provides zero-downtime deployment safety without requiring manual Redis flushing.

2. **Non-blocking async refresh** — `CompletableFuture.runAsync(() -> marketIndexRefreshJob.refresh())` with a 300-second `.orTimeout()`. If the EODHD API is hanging, the Spring Boot application still starts successfully and serves requests (the first user request will trigger the `@Cacheable` fallback).

### Shared Index Definitions

`MarketIndexDefinitions` in `core` is the single source of truth for the index list (symbol, EODHD symbol, display name, currency). Both `MarketIndexRefreshJob` (jobs module) and `MarketIndexService` (api module) reference it, eliminating definition drift.

### Module Boundaries

- `MarketIndexDefinitions` and `MarketIndexDto` live in `core` (shared by both `api` and `jobs`).
- `MarketIndexRefreshJob` lives in `jobs` (depends on `core` only — no `api` dependency).
- `MarketIndexService` and `MarketIndexController` remain in `api`.

---

## Frontend Changes

### Currency Display

The `IndexCardComponent` now renders the `currency` field alongside the index name: `S&P 500 USD`, `NIFTY 50 INR`. The currency label uses a nested `<span class="index-card__currency">` with smaller, muted styling to remain visually subordinate.

### Modern Angular Control Flow

Both `MarketIndexesComponent` and `IndexCardComponent` templates were migrated from legacy `*ngIf`/`*ngFor` structural directives to Angular 17's built-in `@if`/`@for`/`@else` control flow blocks. `CommonModule` was removed from `MarketIndexesComponent` imports; `IndexCardComponent` imports only `DecimalPipe`.

---

## Consequences

### Positive

- **TTFB protected:** Market index reads are O(1) Redis hits under normal operation.
- **Rate-limit budget preserved:** EODHD calls happen in the background, not on the user hot path.
- **Deployment-safe:** Explicit cache eviction on startup prevents deserialization errors from DTO refactors.
- **Non-blocking startup:** Application serves traffic immediately; cache warms asynchronously.
- **Graceful degradation:** Individual index fetch failures produce partial results; the cache is only updated if at least one index succeeds.

### Trade-offs

- **Index list duplication eliminated:** The shared `MarketIndexDefinitions` class in `core` is the single source; changes propagate to both modules automatically.
- **Stale data window:** In the worst case (job fails twice), users see data up to 10 minutes old before the `@Cacheable` fallback kicks in. Acceptable for display-only market indices.
