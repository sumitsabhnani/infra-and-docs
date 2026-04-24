# ADR-004: Historical Market Data — EODHD Backfill and Local Storage

**Status:** Accepted  
**Date:** 2026-04-12  
**Context:** Portfolio valuation requires historical daily prices (OHLCV) for charting, performance calculation, and gain/loss attribution. We need a reliable local store of price history that doesn't depend on real-time API availability.

---

## Decision

### Data Model

```sql
market_data_price_daily
  id                    UUID PRIMARY KEY
  market_data_symbol_id UUID FK → market_data_symbol
  as_of_date            TIMESTAMP
  open                  NUMERIC
  high                  NUMERIC
  low                   NUMERIC
  close                 NUMERIC
  volume                BIGINT
  currency              VARCHAR
  source                VARCHAR(64)     -- 'EODHD', 'BHAVKOSH'
  is_active             BOOLEAN
  created_at            TIMESTAMP
  updated_at            TIMESTAMP
  UNIQUE (market_data_symbol_id, as_of_date)
```

This table stores **only historical end-of-day bars** — never intraday or real-time prices. The unique constraint on `(symbol, date)` makes upserts idempotent: re-running a backfill for the same date range is safe.

### Provider Symbol Mapping

Before fetching prices, we need to map our internal securities to provider-specific symbols:

```
SecurityListing (ticker: "RELIANCE", exchange: NSE)
       │
       ▼
EodhdSymbolDerivationService
       │  exchange_code → EODHD suffix mapping:
       │    NYSE, NASDAQ → ".US"
       │    NSE         → ".NSE"
       │    BSE         → ".BSE"
       │    FSE         → ".F"
       │    JPX         → ".T"
       │    LSE         → ".LSE"
       │
       ▼
MarketDataSymbol (provider_symbol: "RELIANCE.NSE", provider: EODHD)
```

The `market_data_symbol` table is the bridge between our internal identity model and provider-specific conventions:

```sql
market_data_symbol
  id                    UUID PRIMARY KEY
  provider_id           UUID FK → market_data_provider
  security_listing_id   UUID FK → security_listing
  provider_symbol       VARCHAR(64)   -- e.g., "RELIANCE.NSE", "AAPL.US"
  provider_exchange     VARCHAR(32)
  is_active             BOOLEAN
  UNIQUE (provider_id, security_listing_id)
  UNIQUE (provider_id, provider_symbol)
```

### Backfill Triggers

The `EodhdHistoricalPriceBackfillJob` fires in two scenarios:

**1. JIT (Just-In-Time) — Event-Driven**

```
Ticker resolution completes
       │
       ▼
TickerMappingApplier
  → creates MarketDataSymbol for EODHD
  → publishes HistoricalPriceBackfillRequestedEvent (AFTER_COMMIT)
       │
       ▼
EodhdHistoricalPriceBackfillJob.onBackfillRequested()
  → fetches OHLCV from 2001-01-01 to today
  → upserts into market_data_price_daily
  → publishes HistoricalPriceBackfillCompletedEvent
```

The `AFTER_COMMIT` timing ensures the `MarketDataSymbol` row is visible to the backfill job (no dirty reads).

**2. On-Demand — Bulk Backfill**

`backfillAll()` scans all active EODHD `MarketDataSymbol` rows that have zero bars in `market_data_price_daily` and backfills them. Used for bootstrapping or recovering from a failed initial load.

### Backfill Range

All backfills fetch from **2001-01-01 to today**. This is intentionally aggressive:
- Portfolio performance charts may need years of history.
- EODHD's historical API is cheap (one call per symbol, all dates included).
- Better to over-fetch once than to discover a gap when the user scrolls back.

### Data Providers

```sql
market_data_provider (seeded)
  ┌──────────┬────────────┬──────────────┐
  │ name     │ type       │ supports_rt  │
  ├──────────┼────────────┼──────────────┤
  │ EODHD    │ HISTORICAL │ false        │ -- global equities, historical OHLCV
  │ YAHOO    │ REALTIME   │ true         │ -- via price-sweeper sidecar
  │ BHAVKOSH │ HISTORICAL │ false        │ -- Indian equities (NSE/BSE)
  │ ZERODHA  │ REALTIME   │ true         │ -- Indian broker real-time
  └──────────┴────────────┴──────────────┘
```

**EODHD** is the primary source for historical data across global markets. **Bhavkosh** (`BhavKoshHistoricalClient`) provides an alternative for Indian securities (NSE/BSE), useful when EODHD coverage is spotty for smaller Indian stocks.

### Latest Prices (Separate Concern)

Current/latest prices live in a separate table, not in `market_data_price_daily`:

```sql
latest_market_price
  id                    UUID PRIMARY KEY
  security_listing_id   UUID FK
  provider_id           UUID FK
  last_price            NUMERIC
  currency              VARCHAR
  updated_at            TIMESTAMP
```

The `DailyPriceRefreshJob` updates this table on schedule. The `price-sweeper` microservice (see ADR-006) also writes here for Yahoo-sourced prices. Redis caches these with a 20-minute TTL for fast API reads.

**Why separate tables:** Historical bars are immutable (yesterday's close never changes). Latest prices are volatile (updated every few minutes during market hours). Mixing them in one table would require either a wide row with nullable "latest" columns or constant updates to the most recent row — both problematic for query performance and cache invalidation.

### Price Validation

`PriceDataValidationJob` runs sanity checks on ingested data:
- OHLCV consistency: `low ≤ open ≤ high`, `low ≤ close ≤ high`
- Volume non-negative
- No duplicate dates per symbol

Broken symbols are deactivated or re-enqueued for resolution.

## Why This Design

1. **Local storage over live API calls** — Portfolio valuation and charting must work even if EODHD is down. Once backfilled, historical data is self-contained. Only latest prices require live API access.

2. **Provider-agnostic symbol mapping** — The `market_data_symbol` table decouples our identity model from any single provider's naming convention. Switching from EODHD to another provider means adding new rows, not changing existing ones.

3. **Event-driven backfill** — The JIT trigger ensures that as soon as a ticker is resolved, its price history starts loading. No manual intervention, no scheduled "catch-up" scan needed (though `backfillAll` exists as a safety net).

4. **Idempotent upserts** — The unique constraint on `(symbol, date)` means backfills are safe to retry. Network failures mid-backfill don't corrupt data — just re-run.

## Consequences

- The initial backfill for a new symbol fetches 20+ years of data. For symbols with thin history, most of that range returns no data, but the API call is still made.
- `market_data_price_daily` grows linearly with `symbols × trading_days`. At ~250 trading days/year and hundreds of symbols, this is manageable (tens of thousands of rows per year).
- The `source` column on `market_data_price_daily` tracks provenance. If we switch providers for a symbol, old rows retain their original source for audit.
- Adding a new provider requires: seeding `market_data_provider`, implementing a client, and adding exchange → suffix mappings. The backfill infrastructure is reusable.

## Key Files

| File | Role |
|------|------|
| `jobs/.../EodhdHistoricalPriceBackfillJob.java` | JIT + bulk backfill orchestration |
| `jobs/.../EodhdHistoricalClient.java` | HTTP client for EODHD historical API |
| `jobs/.../BhavKoshHistoricalClient.java` | HTTP client for Bhavkosh (Indian equities) |
| `jobs/.../DailyPriceRefreshJob.java` | Scheduled latest price refresh |
| `core/.../EodhdSymbolDerivationService.java` | Exchange code → EODHD suffix mapping |
| `core/.../MarketDataSymbolRepository.java` | Provider symbol CRUD |
| `core/.../MarketDataPriceDailyRepository.java` | Historical bar queries |
