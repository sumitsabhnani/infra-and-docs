# ADR-005: Security Identity Model — Master, Listing, Symbol

**Status:** Accepted  
**Date:** 2026-04-12  
**Context:** A single security (e.g., Reliance Industries) can trade on multiple exchanges (NSE, BSE), under different tickers, and be priced by multiple data providers under different symbols. We need an identity model that supports cross-exchange aggregation without conflating distinct concepts.

---

## Decision

### Three-Layer Hierarchy

```
SecurityMaster          (what it IS — the security itself)
  │
  ├── SecurityListing   (where it TRADES — exchange + ticker)
  │     │
  │     └── MarketDataSymbol  (how it's PRICED — provider + symbol)
  │
  └── SecurityListing   (another exchange)
        │
        └── MarketDataSymbol  (another provider)
```

#### Layer 1: SecurityMaster (Identity)

```sql
security_master
  id                  UUID PRIMARY KEY
  isin                VARCHAR(12) UNIQUE     -- global identifier
  composite_figi      VARCHAR(32) UNIQUE     -- OpenFIGI composite
  name                TEXT
  security_type       VARCHAR                -- EQUITY, ETF, BOND, etc.
  base_currency       VARCHAR
  country_code        VARCHAR
  sector              VARCHAR
  industry            VARCHAR
  resolution_status   VARCHAR(16)            -- UNRESOLVED, RESOLVED, AMBIGUOUS, ERROR
  canonical_master_id UUID FK → self         -- deduplication pointer
  is_active           BOOLEAN
```

One row per *security*, regardless of how many exchanges it's listed on. The `canonical_master_id` self-FK handles deduplication: if two rows are discovered to represent the same security (same composite_figi), one becomes canonical and the other points to it.

#### Layer 2: SecurityListing (Trading Venue)

```sql
security_listing
  id                  UUID PRIMARY KEY
  security_id         UUID FK → security_master
  exchange_id         UUID FK → exchange
  ticker              VARCHAR
  listing_figi        VARCHAR(32) UNIQUE     -- OpenFIGI share-class level
  trading_currency    VARCHAR(3)
  is_primary          BOOLEAN
  is_active           BOOLEAN
  UNIQUE (exchange_id, ticker)
```

One row per *security-on-exchange* pair. Reliance on NSE and Reliance on BSE are two listings pointing to the same master. The `is_primary` flag marks the listing used for default pricing.

#### Layer 3: MarketDataSymbol (Pricing Source)

```sql
market_data_symbol
  id                    UUID PRIMARY KEY
  provider_id           UUID FK → market_data_provider
  security_listing_id   UUID FK → security_listing
  provider_symbol       VARCHAR(64)          -- e.g., "RELIANCE.NSE"
  provider_exchange     VARCHAR(32)
  is_active             BOOLEAN
  UNIQUE (provider_id, security_listing_id)
  UNIQUE (provider_id, provider_symbol)
```

One row per *listing-on-provider*. EODHD calls it `RELIANCE.NSE`, Yahoo calls it `RELIANCE.NS` — these are two `MarketDataSymbol` rows for the same `SecurityListing`.

### How Holdings Reference This Model

```sql
holdings
  security_master_id              UUID FK  -- canonical ownership (aggregation key)
  acquired_listing_id             UUID FK  -- where it was bought (optional)
  override_market_data_symbol_id  UUID FK  -- custom pricing source (optional, nullable)
```

**Aggregation rule:** Always `GROUP BY portfolio_id, security_master_id`. Never group by listing or symbol — that would split the same security bought on two exchanges into two line items.

**Pricing rule:**
1. If `override_market_data_symbol_id` is set → use that symbol for pricing.
2. Else → find the primary listing's default MarketDataSymbol for the active provider.

### Supporting Tables

```sql
exchange
  id              UUID PRIMARY KEY
  exchange_code   VARCHAR(16) UNIQUE   -- e.g., "NSE", "NYSE", "FSE"
  country_code    VARCHAR
  timezone        VARCHAR
  currency        VARCHAR
  mic_code        VARCHAR              -- ISO 10383 MIC

market_data_provider
  id              UUID PRIMARY KEY
  name            VARCHAR(32) UNIQUE   -- EODHD, YAHOO, BHAVKOSH, ZERODHA
  type            VARCHAR(32)          -- HISTORICAL, REALTIME
  supports_realtime BOOLEAN
  is_active       BOOLEAN
```

### Concrete Example

Reliance Industries, bought on NSE, priced via EODHD:

```
SecurityMaster (id: abc-123)
  isin: INE002A01018
  composite_figi: BBG000BPHFS9
  name: "Reliance Industries Ltd"
  resolution_status: RESOLVED
  │
  ├── SecurityListing (id: list-001)
  │     security_id: abc-123
  │     exchange: NSE
  │     ticker: "RELIANCE"
  │     is_primary: true
  │     │
  │     ├── MarketDataSymbol (provider: EODHD, symbol: "RELIANCE.NSE")
  │     └── MarketDataSymbol (provider: BHAVKOSH, symbol: "RELIANCE")
  │
  └── SecurityListing (id: list-002)
        security_id: abc-123
        exchange: BSE
        ticker: "500325"
        is_primary: false

Holding
  security_master_id: abc-123
  acquired_listing_id: list-001  (bought on NSE)
  override_market_data_symbol_id: NULL  (use default EODHD symbol)
  broker_raw_ticker: "RELIANCE"
```

## Why This Design

1. **Aggregation correctness** — Without a canonical SecurityMaster, a user who holds Reliance on both NSE and BSE would see two separate line items instead of one consolidated position. The three-layer model makes the aggregation key (`security_master_id`) unambiguous.

2. **Provider independence** — MarketDataSymbol isolates provider-specific naming from our identity model. Switching from EODHD to another provider means creating new MarketDataSymbol rows — no changes to SecurityMaster or SecurityListing.

3. **Explicit over implicit** — The `override_market_data_symbol_id` field makes pricing overrides visible and auditable, rather than hiding them in runtime logic.

4. **Deduplication via canonical_master_id** — Rather than deleting duplicate SecurityMaster rows (which would break FK references), we link them. Holdings always point to the canonical master, but the alias rows persist for traceability.

## Consequences

- Three joins are needed to go from a holding to its price: `holding → security_listing → market_data_symbol → market_data_price_daily`. This is acceptable for batch operations; cached for real-time reads.
- Creating a new security requires creating at least two rows (SecurityMaster + SecurityListing). The `JitSecuritySetupService` handles this atomically.
- The `is_primary` flag on SecurityListing must be maintained. If a security has listings on multiple exchanges, exactly one should be primary. This is currently set during FIGI resolution.
- The self-referential `canonical_master_id` means queries that aggregate holdings must either filter for canonical masters or follow the pointer. The convention is: holdings always reference canonical, so a simple `GROUP BY security_master_id` is sufficient.
