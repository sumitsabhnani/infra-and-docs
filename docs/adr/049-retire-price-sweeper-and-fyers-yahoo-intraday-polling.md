# ADR-049: Retire `price-sweeper` & Fyers V3; Consolidate Delayed Intraday Quotes on Yahoo Finance + Monotonic `latest_market_price`

**Status:** Accepted
**Date:** 2026-11-15
**Supersedes:** [ADR-006](006-price-sweeper-microservice.md) (Python `price-sweeper` sidecar), [ADR-042](042-fyers-quotes-tri-state-outcomes-and-negative-cache.md) (Fyers `/quotes` runtime failure classification)
**Amends:** [ADR-036](036-system-wide-vendor-tokens-encrypted-singleton.md) (retires the `fyers_token` instance while keeping the singleton-token pattern), [ADR-038](038-latest-price-read-path.md) (replaces sweeper/EODHD/Zerodha intraday polling with unified Yahoo `/v8/finance/spark`), [ADR-040](040-fyers-symbol-master-and-symbol-kind-classification.md) (retires Fyers public-CDN symbol resolution and `SecurityListingRenameDetectionJob` while retaining `symbol_kind` and `IndianTickerNormalizer`)

---

## Context

Running a standalone Python `price-sweeper` FastAPI sidecar backed by Fyers V3 `/quotes` introduced recurring operational and correctness friction:

1. **Daily manual operator OAuth capture:** Fyers V3 tokens expire every ~24 hours without headless refresh, requiring daily superuser sign-in via `/admin/settings` and cross-language AES-256-GCM decryption (`fyers_token`).
2. **Split intraday paths & EODHD real-time dependency:** Indian listings polled via Python `price-sweeper` + Redis (`SweeperPriceCacheReader`), while US/global listings polled EODHD real-time bulk quotes (`EodhdRealtimeClient`) — blocking the Phase 4 exit from paid EODHD subscriptions.
3. **Non-monotonic & nondeterministic `latest_market_price`:**
   - `latest_market_price` PK is `(security_listing_id, provider_id)`, so multi-provider listings had multiple rows while `findBySecurityListingIds` / `findAllLatestPrices` lacked `DISTINCT ON (security_listing_id) ... ORDER BY as_of DESC`.
   - `upsertLatestPrice` lacked a monotonic `as_of` guard, and callers stamped EOD bars at `00:00Z` (`atStartOfDay`) or `OffsetDateTime.now()` instead of exchange close or upstream quote timestamps — allowing stale backfills or late jobs to overwrite fresher intraday quotes and blindly publish `LatestPricesRefreshedEvent` into the 24h `latestPrices` Redis cache.

---

## Decisions

### Decision 1: Unified Cross-Provider Monotonic `latest_market_price` Contract

- **Deterministic reads:** `LatestMarketPriceRepository.findBySecurityListingIds` and `findAllLatestPrices` use `SELECT DISTINCT ON (security_listing_id) ... ORDER BY security_listing_id, as_of DESC NULLS LAST, provider_id ASC`.
- **Monotonic writes (`int upsertLatestPrice`):**
  - Cross-provider guard: `INSERT ... SELECT ... WHERE NOT EXISTS (SELECT 1 FROM latest_market_price existing WHERE existing.security_listing_id = :listingId AND existing.as_of IS NOT NULL AND existing.as_of > CAST(:asOf AS timestamptz))`.
  - Same-provider guard: `ON CONFLICT (security_listing_id, provider_id) DO UPDATE ... WHERE latest_market_price.as_of IS NULL OR EXCLUDED.as_of >= latest_market_price.as_of`.
  - Returns affected row count (`0` or `1`); callers emit `LatestPricesRefreshedEvent` **only** when `rows > 0`.
- **Canonical timestamp semantics (`MarketHours`):**
  - EOD daily bars (`BhavKoshDailyPriceRefreshJob`, `EodhdHistoricalPriceBackfillJob`, `HistoricalPricePrefillJob`) stamp `latest_market_price.as_of` via `MarketHours.eodAsOf(barDate, timezone, closeTime, exchangeCode)` (exchange local close converted to UTC — e.g. NSE `15:30 IST = 10:00Z`, NYSE `16:00 ET = 20:00Z/21:00Z`, LSE `16:30 London`) while keeping `market_data_price_daily.as_of_date` anchored at `00:00:00 UTC`.
  - AMFI NAVs (`AmfiNavRefreshJob`, `MutualFundService`) stamp `latest_market_price.as_of` via `MarketHours.navAsOf(navDate)` (`23:00 IST = 17:30Z`) while keeping `market_data_price_daily.as_of_date` at `00:00:00 UTC`.
  - Delayed intraday quotes (`YahooFinanceClient`) stamp `latest_market_price.as_of` with the upstream bar/quote timestamp (`Instant.ofEpochSecond(...)`), never `OffsetDateTime.now()`.

### Decision 2: Consolidate Delayed Intraday Polling in `YahooFinanceClient` + `LatestPriceRefreshJob`

- **Batch endpoint:** `YahooFinanceClient.fetchBatchQuotes` queries `GET /v8/finance/spark?symbols={up_to_20_csv}&range=1d&interval=5m` through a shared 1000ms `YahooFinanceRateLimiter`, taking the latest non-null `(timestamp[i], close[i])` intraday bar per symbol. All JSON parsing uses `DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS` + `JsonNode.decimalValue()` (zero `double` intermediates).
- **Sub-unit normalization & cold-LSE/JSE currency safety:**
  - `"GBp"` / `"GBX"` normalize to `"GBX"` with unscaled pence (compatible with `ExchangeRateService`, ADR-044).
  - `"ZAc"` ($\times 0.01 \to$ `"ZAR"`) and `"ILA"` ($\times 0.01 \to$ `"ILS"`) scale into major units at ingest.
  - Because `/v8/finance/spark` omits currency metadata, `LatestPriceRefreshJob` performs a single-symbol `/v8/finance/chart/{symbol}` metadata lookup whenever currency is absent on a cold `LSE` listing (preventing `100x` `"GBP"` vs `"GBX"` mislabelling) or any `JSE` listing (preventing `100x` unlabelled `ZAc` inflation). `MarketDataService` and `PriceService` always route single-symbol fetches through `/v8/finance/chart/{symbol}`.
- **Canonical symbol ownership preserved:** `YahooSymbolDerivationService` derives Yahoo tickers at read/poll time (`RELIANCE` + `NSE` $\to$ `RELIANCE.NS`, `BRK.B` + `NYSE` $\to$ `BRK-B`, `SHEL.LSE` $\to$ `SHEL.L`, `SAP.XETRA` $\to$ `SAP.DE`) while writing `latest_market_price` under the listing's existing canonical `provider_id` (`BHAVKOSH`, `EODHD`, etc.).
- **Schedule & scope:** `LatestPriceRefreshJob` polls active portfolio-referenced listings (`app.jobs.latest-price-refresh.scope=REFERENCED` by default; `ALL_ACTIVE` configurable), gated per listing via `MarketHours.isExchangeOpen` (backed by Flyway migration `V20261115120100__BackfillGlobalExchangeSchedules.sql`, with 30-minute post-close buffer to capture delayed closing prints). Cold unheld listings populate asynchronously on demand via `MarketDataService.enqueueYahooJitFetch`.
- **Tri-state negative cache in Java:** `YahooSymbolNegativeCache` ports ADR-042's `FOUND` / `REJECTED` / `FAILED` contract into `jobs`, storing 24h markers at `market_data:yahoo:invalid:{symbol}` in Redis with fail-open fallback to a bounded in-memory map on `DataAccessException`, and purging legacy `market_data:yahoo:*` price keys once on startup.

### Decision 3: Retire `price-sweeper` & Fyers End-to-End

- **Backend:** Removed `SweeperPriceCacheReader`, `PriceSweeperClient`, `FyersToken*`, `FyersClient`, `FyersAdminController`, `FyersSymbolMasterClient`, `SecurityListingRenameDetectionJob`, and dropped `fyers_token` via `V20261115120000__DropFyersTokenTable.sql`. (`security_listing_rename_history` is retained as `ExchangeSymbolLoadJob` writes `EXCHANGE_LOAD_JOB` audit rows to it.)
- **Frontend:** Removed `FyersCallbackComponent`, `AdminSettingsComponent`, Fyers methods in `ApiService`, and `fyers*` environment keys; `/admin` and `/admin/settings` redirect to `/admin/feature-flags`.
- **Infrastructure:** Removed `price-sweeper` and `FYERS_*` / `PRICE_SWEEPER_BASE_URL` from `docker-compose.yml` and `justfile` (saving 512 MB container RAM and eliminating cross-service DB/encryption coupling), adding `--remove-orphans` to full-stack `deploy`/`start`.
