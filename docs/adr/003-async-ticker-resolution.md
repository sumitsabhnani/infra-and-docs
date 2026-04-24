# ADR-003: Async Ticker Resolution via OpenFIGI

**Status:** Accepted  
**Date:** 2026-04-12  
**Context:** Securities ingested from brokers arrive as raw tickers (e.g., `"RELIANCE"`, `"AAPL"`). We need to resolve these to globally unique identifiers (FIGI) to enable deduplication, cross-broker aggregation, and market data linkage.

---

## Decision

### Two Resolution Pipelines

There are two distinct async pipelines, each with its own queue table:

1. **FIGI Resolution** (`figi_resolution_queue`) — Resolves a `SecurityMaster` to its composite/listing FIGI via the OpenFIGI API.
2. **Ticker Resolution** (`ticker_resolution_queue`) — Resolves a `Holding` to the correct `SecurityMaster` + `MarketDataSymbol` using a cascade of local strategies before falling back to FIGI.

### Pipeline 1: FIGI Resolution

#### Queue Table

```sql
figi_resolution_queue
  id                BIGSERIAL PRIMARY KEY
  security_master_id UUID UNIQUE FK  -- one entry per security
  listing_id         UUID FK         -- the listing to resolve against
  broker_symbol      VARCHAR(64)     -- raw ticker from broker
  mic_code           VARCHAR(8)      -- exchange MIC (if known)
  enqueued_at        TIMESTAMP
  picked_at          TIMESTAMP       -- set when a worker claims the row
  retry_count        INT DEFAULT 0
```

#### SKIP LOCKED Batch Polling

The `FigiBatchPollerJob` runs on a configurable interval (`figi.poller.interval-ms`) and claims work using PostgreSQL's `SELECT FOR UPDATE SKIP LOCKED`:

```
FigiBatchPollerJob (scheduled)
     │
     ▼
SELECT * FROM figi_resolution_queue
WHERE picked_at IS NULL
  AND retry_count < {max-retries}       -- default: 3
ORDER BY enqueued_at
LIMIT {batch-size}                      -- default: 100
FOR UPDATE SKIP LOCKED
     │
     ▼
UPDATE SET picked_at = NOW()            -- atomically claim
     │
     ▼
OpenFigiClient.batchResolve()
     │  POST https://api.openfigi.com/v3/mapping
     │  Max 10 items per API call (auto-splits larger batches)
     │  500ms delay between API calls (free tier: 25 req/min)
     │
     ├── Success → write to figi_resolution_stage
     │              update security_master (composite_figi, resolution_status)
     │              DELETE from queue
     │
     ├── Retriable failure → UPDATE SET picked_at = NULL, retry_count + 1
     │
     └── Terminal failure (max retries) → DELETE from queue
                                           mark security_master as ERROR
```

**Why SKIP LOCKED:**
- Multiple job instances (or restarts) can poll concurrently without deadlocking.
- A crashed worker's claimed rows remain locked only until the transaction times out, then become available again.
- No external message broker needed — Postgres is the queue.

#### Staging Table

```sql
figi_resolution_stage
  id                BIGSERIAL PRIMARY KEY
  security_master_id UUID FK
  input_type         VARCHAR(50)     -- 'ISIN', 'TICKER', 'LISTING_FIGI'
  input_value        VARCHAR(255)
  composite_figi     VARCHAR(32)     -- result from OpenFIGI
  listing_figi       VARCHAR(32)
  resolution_status  VARCHAR(50)     -- 'MATCHED', 'AMBIGUOUS', 'NO_MATCH'
  confidence_score   NUMERIC(4,3)    -- 0.000 to 1.000
  raw_response       JSONB           -- full OpenFIGI API response
  attempted_at       TIMESTAMP
```

The staging table serves two purposes:
1. **Audit trail** — Every OpenFIGI call is recorded with its raw response, even if the result isn't applied.
2. **Ambiguity handling** — When multiple candidates are returned, all are staged with confidence scores. The `FigiResolutionService.applyResolvedResults()` picks the highest-confidence match or marks the security as `AMBIGUOUS` for manual review.

### Pipeline 2: Ticker Resolution (Local-First Cascade)

#### Queue Table

```sql
ticker_resolution_queue
  id                BIGSERIAL PRIMARY KEY
  holding_id         UUID UNIQUE FK
  broker_raw_ticker  VARCHAR(64)
  exchange_code      VARCHAR(32)
  currency           VARCHAR(3)
  isin               VARCHAR(12)
  enqueued_at        TIMESTAMP
  picked_at          TIMESTAMP
  retry_count        INT DEFAULT 0
  resolution_status  VARCHAR(32)     -- PENDING, RESOLVED, FAILED
  resolution_notes   TEXT
  resolved_at        TIMESTAMP
```

Partial index: `(enqueued_at) WHERE picked_at IS NULL AND resolution_status = 'PENDING'` — only pending, unclaimed rows are indexed for efficient polling.

#### Resolution Cascade

The `TickerResolutionPollerJob` runs a cascade of strategies, stopping at the first success:

```
1. global_ticker_mapping lookup
   │  (source_ticker + source_exchange → resolved_provider_symbol)
   │  Fast path: if a prior manual mapping exists, apply it immediately.
   │
   ▼ (miss)
2. ISIN search
   │  If the holding has an ISIN, search security_master by ISIN.
   │
   ▼ (miss)
3. Ticker + exchange search
   │  Search security_listing by (ticker, exchange_code).
   │
   ▼ (miss)
4. Enqueue to figi_resolution_queue
   │  Fall back to OpenFIGI API resolution (Pipeline 1).
   │
   ▼ (on resolve)
5. TickerMappingApplier
      Sets holding.override_market_data_symbol_id
      Saves to global_ticker_mapping (for future reuse)
      Fires HistoricalPriceBackfillRequestedEvent
```

### Canonical Identity & Deduplication

```sql
security_master
  id                  UUID PRIMARY KEY
  composite_figi      VARCHAR(32) UNIQUE
  canonical_master_id UUID FK → security_master(id)  -- self-referential
  resolution_status   VARCHAR(16)  -- UNRESOLVED, RESOLVED, AMBIGUOUS, ERROR
```

When FIGI resolution discovers that two `SecurityMaster` rows represent the same security (same composite_figi), one is designated canonical and the other's `canonical_master_id` points to it. All holdings reference the canonical master, ensuring correct aggregation across brokers.

### Priority Resolution Logic (FigiBasedIdentifierResolver)

When looking up a security, the resolver tries identifiers in priority order:

```
listing_figi  →  (most specific: exact listing on exact exchange)
composite_figi →  (security-level: same security, any exchange)
ticker + exchange → (fuzzy: string match, less reliable)
isin → (fallback: ISIN is not always unique across exchanges)
```

## Why This Design

1. **Postgres-as-queue** — For our throughput (hundreds of securities, not millions), a dedicated message broker (Kafka, RabbitMQ) adds operational complexity with no benefit. `SKIP LOCKED` gives us exactly-once delivery semantics with zero additional infrastructure.

2. **Local-first resolution** — The `global_ticker_mapping` table short-circuits the expensive OpenFIGI API call for tickers we've seen before. Over time, the system becomes self-healing: each manual resolution improves future auto-resolution.

3. **Staging before applying** — Writing to `figi_resolution_stage` before updating `security_master` means we can review ambiguous results without corrupting the canonical identity. The raw JSONB response enables debugging and reprocessing.

4. **Two separate queues** — FIGI resolution operates at the `SecurityMaster` level (one security, one FIGI). Ticker resolution operates at the `Holding` level (one holding, one broker ticker). Separating them avoids conflating the two concerns and allows independent polling intervals.

## Consequences

- OpenFIGI's free tier (25 requests/minute) limits throughput. Large initial imports may take hours to fully resolve. The UI must show partial resolution states gracefully.
- The `global_ticker_mapping` table is a form of learned state. Incorrect mappings (e.g., after a ticker change) propagate to new holdings. Periodic mapping review is needed.
- `SKIP LOCKED` requires careful transaction scoping — long transactions hold locks and starve other pollers.
- The staging table grows unbounded. A retention policy (e.g., delete stages older than 90 days for resolved securities) should be added.

## Key Files

| File | Role |
|------|------|
| `jobs/.../FigiBatchPollerJob.java` | Scheduled FIGI queue poller |
| `jobs/.../TickerResolutionPollerJob.java` | Scheduled ticker queue poller |
| `jobs/.../OpenFigiClient.java` | HTTP client for OpenFIGI v3 API |
| `jobs/.../FigiResolutionService.java` | Builds requests, scores results, applies to security_master |
| `jobs/.../TickerAutoResolutionService.java` | Cascade resolution strategies |
| `core/.../FigiBasedIdentifierResolver.java` | Priority-based identifier lookup |
| `core/.../TickerMappingApplier.java` | Sets override_market_data_symbol_id, fires backfill event |
