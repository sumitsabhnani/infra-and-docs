# ADR-002: SnapTrade Ledger Ingestion — "Never Drop Data"

**Status:** Accepted  
**Date:** 2026-04-12  
**Context:** Broker-connected portfolios import holdings and transactions from SnapTrade. Broker data is messy — tickers are inconsistent, exchanges are missing, and the same security can appear under different symbols across brokers.

---

## Decision

### Core Principle: Never Drop Data

When SnapTrade sends a holding or transaction, we persist it *immediately* — even if we cannot resolve the ticker to a known security. Resolution is a separate, async concern. The ingestion path never blocks on, fails on, or discards an unresolvable ticker.

### Ingestion Data Flow

```
SnapTrade API
     │
     ▼
SnapTradeController (OAuth callback / sync trigger)
     │
     ▼
BrokerSyncService.syncRecentTransactions()
     │  cursor: snaptrade_connection.last_synced_at
     │
     ├──→ transactions table
     │      raw_data JSONB ← full SnapTrade response (audit trail)
     │      ticker VARCHAR  ← broker's raw ticker string
     │
     └──→ JitSecuritySetupService
            │
            ├── Creates SecurityMaster (resolution_status = 'UNRESOLVED')
            ├── Creates SecurityListing (ticker + exchange)
            └── Creates Holding
                   broker_raw_ticker ← original broker ticker (immutable)
                   security_master_id ← newly created SecurityMaster
```

### How Ambiguous Tickers Are Persisted

1. **`transactions.raw_data`** (JSONB) — The complete SnapTrade API response, stored verbatim. This is the immutable audit trail. If our parsing logic improves, we can replay from raw_data.

2. **`holdings.broker_raw_ticker`** (VARCHAR) — The exact ticker string the broker sent (e.g., `"RELIANCE"`, `"AAPL"`). This field is never overwritten by resolution logic. It exists so we can always trace back to what the broker originally reported.

3. **`security_master.resolution_status`** — Tracks where the security is in the resolution pipeline:
   - `UNRESOLVED` — Just ingested, no FIGI yet
   - `RESOLVED` — composite_figi populated, ready for valuation
   - `AMBIGUOUS` — Multiple FIGI candidates, needs manual intervention

4. **`ticker_resolution_queue`** — When a holding's ticker can't be auto-resolved, a row is enqueued here. The `TickerResolutionPollerJob` picks it up asynchronously (see ADR-003).

### The `override_market_data_symbol_id` Alias Pattern

Sometimes automatic resolution picks the wrong market data symbol, or the user needs a specific pricing source. The override pattern solves this without mutating the canonical identity:

```
holdings
  ├── security_master_id        → what the user owns (canonical identity)
  ├── acquired_listing_id       → where it was acquired (exchange + ticker)
  └── override_market_data_symbol_id  → where to get the price (nullable FK)
         │
         ▼
    market_data_symbol
         provider_symbol: "RELIANCE.NSE"
         provider_id: → EODHD
```

**How it works:**
- If `override_market_data_symbol_id` is NULL → pricing uses the default symbol derived from the security's primary listing.
- If set → pricing uses the override symbol, regardless of what the listing says.
- The `TickerMappingApplier` service sets this field and triggers a historical backfill event (`HistoricalPriceBackfillRequestedEvent`).

**Why a nullable FK instead of changing the listing:**
- The listing represents a fact (where the security trades). The override represents a preference (where to get the price).
- Multiple holdings of the same security can have different overrides (e.g., one priced via EODHD, another via Bhavkosh).
- Deleting the override (`ON DELETE SET NULL`) gracefully falls back to default pricing.

### SnapTrade Connection Lifecycle

```sql
snaptrade_connection
  status:     PENDING → SYNCING → ACTIVE (or FAILED)
  sync_phase: STARTING → HOLDINGS_SYNCED → TRANSACTIONS_SYNCED → COMPLETED
```

The two-dimensional state (connection status + sync phase) allows the UI to show granular progress:
- **PENDING** — OAuth initiated, waiting for callback
- **SYNCING / HOLDINGS_SYNCED** — Partial sync in progress, holdings visible but transactions still loading
- **ACTIVE / COMPLETED** — Fully synced and ready

`BrokerSyncScheduler` runs hourly, using `last_synced_at` as a cursor to pull only new transactions.

### Global Ticker Mapping (Crowdsourced Knowledge)

```sql
global_ticker_mapping
  source_ticker        VARCHAR(64)   -- e.g., "RELIANCE"
  source_exchange      VARCHAR(32)   -- e.g., "NSE"
  resolved_provider_symbol  VARCHAR(64)  -- e.g., "RELIANCE.NSE"
  mapping_count        INT           -- how many times this mapping was confirmed
  confidence_source    VARCHAR(32)   -- 'MANUAL' or 'AUTO'
```

When a ticker is manually resolved, the mapping is saved here. Future holdings with the same broker ticker + exchange auto-resolve via lookup, skipping the FIGI pipeline entirely. The `mapping_count` field tracks reliability — higher counts mean higher confidence in auto-application.

## Why This Design

1. **Audit completeness** — `raw_data` JSONB means we never lose information the broker sent. If SnapTrade changes their response format or we discover a parsing bug, we can reprocess from the stored payload.

2. **Separation of identity and pricing** — `security_master_id` is *what you own*. `override_market_data_symbol_id` is *how we price it*. Conflating these leads to bugs where changing a price source changes portfolio aggregation.

3. **Async resolution** — Blocking ingestion on FIGI/EODHD lookups would make the sync path fragile and slow. The queue-based approach means ingestion always succeeds, and resolution catches up in the background.

4. **Progressive enhancement** — A holding is usable (visible in the portfolio) as soon as it's ingested, even without resolved pricing. The UI shows the broker's raw ticker until resolution completes.

## Consequences

- Holdings can exist in a partially-resolved state. The UI must handle `UNRESOLVED` securities gracefully (show ticker, hide valuation).
- The `global_ticker_mapping` table grows over time. Stale mappings (e.g., after a corporate action/ticker change) need periodic review.
- The `override_market_data_symbol_id` pattern means pricing logic must always check for overrides before falling back to defaults — a code path that must be tested.

## Key Tables

| Table | Role |
|-------|------|
| `snaptrade_user` | SnapTrade OAuth credentials (encrypted) |
| `snaptrade_connection` | Connection state, sync phase, account_ids (JSONB) |
| `transactions` | Immutable ledger with raw_data JSONB |
| `holdings` | Current positions with broker_raw_ticker + override FK |
| `security_master` | Canonical security identity with resolution_status |
| `ticker_resolution_queue` | Async queue for unresolved tickers |
| `global_ticker_mapping` | Crowdsourced ticker → provider symbol cache |
