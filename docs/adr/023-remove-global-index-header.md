# ADR-023: Remove Global Market Index Header

**Status:** Accepted  
**Date:** 2026-04-28  
**Supersedes:** ADR-007 (Redis-First Market Indices), ADR-015 (3-Minute Polling + Flash Highlights)

---

## Context

ADR-007 introduced a fixed dark top-bar showing live quotes for five global indices (S&P 500, Dow Jones, Nasdaq, NIFTY 50, MSCI ACWI). ADR-015 added a 3-minute client-side polling loop and per-value flash highlights when prices changed. The feature required:

- A 5-minute `@Scheduled` cron job (`MarketIndexRefreshJob`) making sequential EODHD calls.
- A startup `ApplicationReadyEvent` listener (`StartupJobTrigger`) for cache eviction and warm-up.
- A dedicated cache-only REST endpoint (`GET /api/markets/indices/live`) and a second endpoint (`GET /api/market-indexes`) serving the same data via `@Cacheable`.
- A `marketIndexes` Redis cache entry with a 10-minute TTL.
- An Angular component tree (`MarketIndexesComponent` + `IndexCardComponent`) polling every 180 s with flash-highlight diffing.
- A `MarketIndexDefinitions` config class and `MarketIndexDto` in `core`.

The bar was display-only — no trading decisions were made against its numbers. The product direction has shifted toward a denser portfolio analytics workspace where the fixed 36 px bar traded vertical space for information that users were not acting on. Removing it eliminates infra maintenance, external API consumption (EODHD real-time calls every 5 minutes regardless of active sessions), and SCSS layout coupling across the app shell.

---

## Decision

Remove the global market index header in full.

### What was deleted

**Backend (10 files)**

| Module | File | Role |
|--------|------|------|
| `api` | `MarketIndicesLiveController.java` | `GET /api/markets/indices/live` (cache-only read) |
| `api` | `MarketIndexController.java` | `GET /api/market-indexes` (`@Cacheable` read-through) |
| `api` | `MarketIndexService.java` | Fan-out EODHD fetcher with `@Cacheable` |
| `api` | `MarketIndexClient.java` | Thin EODHD `real-time/{symbol}` HTTP client |
| `api` (test) | `MarketIndicesLiveControllerTest.java` | MockMvc tests for the live endpoint |
| `core` | `MarketIndexDto.java` | DTO (`symbol, name, currentValue, changeAmount, changePercent, currency`) |
| `core` | `MarketIndexDefinitions.java` | Hardcoded ticker list (the 5 indices) |
| `jobs` | `MarketIndexRefreshJob.java` | `@Scheduled` 5-minute EODHD refresh |
| `jobs` | `StartupJobTrigger.java` | `ApplicationReadyEvent` cache eviction + async warm-up |
| `jobs` (test) | `MarketIndexRefreshJobTest.java` | Mockito unit tests for the refresh job |

**Backend (1 line edited)**

- `core/RedisConfig.java` — removed the `marketIndexes` cache TTL entry (`Duration.ofMinutes(10)`).

**Frontend (1 directory deleted)**

- `src/app/shared/market-indexes/` — `MarketIndexesComponent`, `IndexCardComponent`, `market-indexes.models.ts`, and all associated specs (9 files total).

**Frontend (5 files edited)**

- `app.component.ts` — removed `MarketIndexesComponent` import and `imports[]` entry.
- `app.component.html` — removed the `<nav class="app-indexes-bar">` block.
- `app.component.scss` — removed `$bar-h`, `$stack-h`, and the `.app-indexes-bar` rule.
- `app-header.component.scss` — removed `$bar-h: 36px;`; changed `top: $bar-h` → `top: 0` so the header sits flush at the top of the viewport.
- `api.service.ts` — removed `getMarketIndexes()`, `getLiveMarketIndices()`, and the `MarketIndex` import.

### What was kept

- `eodhd.api.key` in all three `application*.properties` files — used by other EODHD market-data workflows.
- All Flyway migrations — none were index-specific.
- The rest of `api/.../service/marketdata/` — only `MarketIndexService` and `MarketIndexClient` were index-specific.
- All other `RedisConfig` cache entries (`stockPrices`, `latestPrices`, `historicalPrices`, `portfolioValuations`, `userTickers`, `supportedCurrencies`, `allLatestRates`).

### No database changes

Indices were never persisted in Postgres. The `marketIndexes::all` Redis key will expire naturally and never be repopulated. No Flyway migration is needed.

---

## Consequences

**Positive**
- Eliminates 5-minute EODHD polling regardless of active sessions — reduces external API consumption.
- Removes `StartupJobTrigger` startup latency and cache-eviction/warm-up risk at deploy time.
- Frees 36 px of vertical space in the app shell (header now sits at `top: 0`).
- Removes SCSS layout coupling (`$bar-h`) that threaded through two components.
- ~19 files removed; no orphaned types or dangling references remain.

**Trade-offs**
- Users no longer see global index prices in the app. If a market-data widget is reintroduced, it should be designed as an optional, in-page panel rather than a fixed shell element, and it must not poll an external API on the hot path (same principle as ADR-007).
