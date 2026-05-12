# ADR-006: Price Sweeper — Python Sidecar for Real-Time Prices

**Status:** Accepted  
**Date:** 2026-04-12  
**Context:** The Java backend needs near-real-time stock prices during Indian market hours (09:15–15:30 IST). Yahoo Finance provides free delayed quotes (~15 min), but the `yahooquery` Python library is significantly more mature and reliable than available Java alternatives. Rather than fighting the ecosystem, we built a dedicated Python microservice.

---

## Decision

### Architecture

The price-sweeper is a **Python 3.12 FastAPI service** that runs alongside the Java backend in Docker Compose. It shares the same PostgreSQL database and Redis instance — no separate infrastructure.

```
┌──────────────────────────────────────────────────┐
│  Docker Compose (app-network)                    │
│                                                  │
│  ┌───────────┐     ┌──────────────┐             │
│  │  Backend   │────▶│ price-sweeper │             │
│  │ (Java)    │     │  (Python)    │             │
│  └─────┬─────┘     └──┬───────┬──┘             │
│        │              │       │                  │
│        ▼              ▼       ▼                  │
│  ┌──────────┐   ┌──────────┐                    │
│  │ Postgres │   │  Redis   │                    │
│  └──────────┘   └──────────┘                    │
└──────────────────────────────────────────────────┘
```

### Data Flow

#### Scheduled Sweep (Every 5 Minutes During Market Hours)

```
APScheduler CronTrigger
  days: mon-fri
  hours: 9-15 IST
  minutes: */5
  guard: _is_within_market_window() (09:15–15:30 IST)
       │
       ▼
1. fetch_active_symbols()
   SELECT from market_data_symbol
     JOIN market_data_provider (name = 'BHAVKOSH')
     JOIN security_listing
     JOIN exchange
   WHERE is_active = TRUE
       │
       ▼
   Transform to Yahoo format:
     NSE tickers → append ".NS"  (e.g., RELIANCE → RELIANCE.NS)
     BSE tickers → append ".BO"  (e.g., 500325 → 500325.BO)
       │
       ▼
2. fetch_bulk_prices(symbols, batch_size=50)
   yahooquery.Ticker(batch).price
     → extract regularMarketPrice, currency
     → retry with exponential backoff on 429/rate-limit
     → 2s delay between batches
       │
       ▼
3. Write to Redis (atomic pipeline)
   Key: "market_data:yahoo:{symbol}"
   Value: {"price": 2847.5, "currency": "INR", "timestamp": "..."}
   TTL: 600 seconds (10 min)
       │
       ▼
4. Upsert to PostgreSQL
   INSERT INTO latest_market_price
     (security_listing_id, provider_id, last_price, currency, updated_at)
   ON CONFLICT (security_listing_id, provider_id)
     DO UPDATE SET last_price, currency, updated_at
```

#### On-Demand Fetch (Cache Miss)

When the Java backend needs a price that isn't in Redis (e.g., newly added holding), it calls the price-sweeper's HTTP endpoint:

```
Java Backend
  GET http://price-sweeper:8000/force-fetch?symbol=RELIANCE.NS
       │
       ▼
price-sweeper
  → fetch_single_price(symbol)  (throttled: min 1s between calls)
  → write to Redis + upsert to Postgres
  → return {"symbol": "...", "price": 2847.5, "currency": "INR"}
```

### Why a Separate Service

| Concern | In Java | In Python |
|---------|---------|-----------|
| Yahoo Finance client | No mature library; unofficial APIs break frequently | `yahooquery` — actively maintained, handles auth/crumbs |
| Batch fetching | Would need custom HTTP + parsing | Built into yahooquery |
| Rate limiting | Manual implementation | yahooquery handles some; we add exponential backoff |
| Deployment coupling | Price fetching failures could affect the main API | Isolated: if price-sweeper crashes, the backend still serves cached data |

### Configuration

All configuration via environment variables (Pydantic `BaseSettings`):

| Variable | Default | Purpose |
|----------|---------|---------|
| `PROVIDER_NAME` | `BHAVKOSH` | Filter: only sweep symbols from this provider |
| `POLL_CRON_HOUR` | `9-15` | IST hours to sweep |
| `POLL_CRON_MINUTE` | `*/5` | Frequency within active hours |
| `MARKET_OPEN_TIME` | `09:15` | Guard: skip polls before market open |
| `MARKET_CLOSE_TIME` | `15:30` | Guard: skip polls after market close |
| `YAHOO_BATCH_SIZE` | `50` | Symbols per yahooquery call |
| `YAHOO_RETRY_MAX_ATTEMPTS` | `3` | Retries on transient failure |
| `YAHOO_RETRY_BASE_DELAY` | `5.0` | Exponential backoff base (seconds) |
| `REDIS_KEY_PREFIX` | `market_data:yahoo:` | Redis key namespace |
| `REDIS_PRICE_TTL` | `600` | Cache TTL in seconds |

### Shared Database Access

The price-sweeper reads from the same Postgres tables the Java backend writes to:
- **Reads:** `market_data_symbol`, `market_data_provider`, `security_listing`, `exchange` — to build its sweep universe.
- **Writes:** `latest_market_price` — upserts current prices.

It does **not** write to `market_data_price_daily` (historical data is EODHD's domain, see ADR-004).

### Resilience

- **Market window guard:** Even if the cron fires at 09:05, the `_is_within_market_window()` check skips execution before 09:15. This prevents fetching pre-market prices that would be stale.
- **Batch retry:** Transient Yahoo failures (429, crumb errors) trigger exponential backoff. One bad batch doesn't kill the entire sweep.
- **Max instances = 1:** APScheduler prevents overlapping sweeps. If a sweep takes longer than 5 minutes, the next trigger is skipped rather than queued.
- **Graceful degradation:** If the price-sweeper is down, the Java backend continues serving from Redis (until TTL expires) or falls back to the last known `latest_market_price` in Postgres.

### HTTP Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/health` | GET | Docker health check (`{"status": "ok"}`) |
| `/force-fetch?symbol=X` | GET | On-demand single-symbol fetch |
| `/universe` | GET | Debug: list active symbol universe |

## Consequences

- The price-sweeper shares Postgres credentials with the backend. A schema migration in Java could break the Python SQL queries. The Python queries use explicit column names (not `SELECT *`) to minimize this risk.
- Currently scoped to Indian markets (BHAVKOSH provider, IST market hours). Expanding to global markets would require configurable provider filters and multi-timezone scheduling.
- Yahoo Finance's delayed quotes (~15 min) mean `latest_market_price` is never truly real-time. (Originally tracked via an `is_realtime` BOOLEAN column; the column was dropped in migration `V20260510120000` because no consumer ever read it. Freshness, where it matters, is derived from `as_of`.)
- The `force-fetch` endpoint is not authenticated. It's internal-only (not exposed through Caddy), but adding a simple API key would be prudent if the network topology changes.

## Key Files

| File | Role |
|------|------|
| `price-sweeper/app/main.py` | FastAPI app, endpoints, lifespan management |
| `price-sweeper/app/scheduler.py` | APScheduler cron setup, market window guard |
| `price-sweeper/app/fetcher.py` | Yahoo Finance integration (bulk + single fetch) |
| `price-sweeper/app/redis_client.py` | Redis write operations (single + pipeline) |
| `price-sweeper/app/db.py` | Postgres queries, symbol transformation, price upsert |
| `price-sweeper/app/config.py` | Pydantic Settings with all env var definitions |
| `price-sweeper/Dockerfile` | Python 3.12-slim + libpq5, runs on port 8000 |
