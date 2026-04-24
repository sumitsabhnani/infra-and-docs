# Feature Spec: Manual Add Holdings

## Overview

Expanded "Add New Holding" flow supporting portfolio selection, EODHD-powered stock search, enhanced CSV import with exchange resolution, and a new "Others" tab for non-equity assets (Cash, Gold, Bonds, Real Estate).

---

## 1. Updated Database Schema

### New Table: `manual_asset`

Stores non-equity assets that do not fit the SecurityMaster/SecurityListing/Holding chain. These assets have no FIGI, ISIN, ticker, or exchange listing — valuation is entirely user-provided.

| Column | Type | Constraints |
|--------|------|-------------|
| `id` | UUID | PK, default `gen_random_uuid()` |
| `portfolio_id` | UUID | FK → `portfolios(id)` ON DELETE CASCADE, NOT NULL |
| `asset_class` | VARCHAR(32) | NOT NULL (CASH, GOLD, BONDS, REAL_ESTATE, OTHER) |
| `name` | VARCHAR(255) | NOT NULL |
| `amount` | NUMERIC(20,8) | NOT NULL |
| `currency` | VARCHAR(3) | NOT NULL, default 'USD' |
| `note` | TEXT | nullable |
| `excluded_from_calculations` | BOOLEAN | NOT NULL, default FALSE |
| `created_at` | TIMESTAMPTZ | NOT NULL, default now() |
| `updated_at` | TIMESTAMPTZ | NOT NULL, default now() |

Index: `idx_manual_asset_portfolio` on `portfolio_id`.

### Seeded Broker: `broker_metadata` row (id=99)

Manual portfolios are assigned broker ID 99 ("Manual") with no API credentials. This avoids making `broker` nullable on the `portfolios` table.

### No Changes to Existing Tables

`holdings`, `security_master`, `security_listing`, and `exchange` tables remain unchanged. The exchange-aware holding creation is a code-level enhancement using the existing `findOrCreateByTickerOrFigiOrExchange` method in `SecurityListingService`.

---

## 2. REST API Contract

### Modified Endpoints

#### `GET /api/portfolios` — Added `isLinked` field

Response DTO now includes `isLinked: Boolean` (read-only). Derived via batch JOIN on `snaptrade_connection` — true if a connection exists for the portfolio.

#### `POST /api/holdings` — Accepts exchange code

`HoldingDto` now accepts optional write fields: `exchangeCode` (EODHD suffix), `name`, `isin`. When `exchangeCode` is present, the backend converts it via `EodhdSymbolDerivationService` and uses `findOrCreateByTickerOrFigiOrExchange` for reliable exchange-specific resolution.

#### `POST /api/holdings/import-csv` — Parses exchange column

CSV format expanded to: `symbol, shares, avgPricePaid, exchange, currency`. The `exchange` and `currency` columns are optional — old CSVs without them work identically (backward compatible).

### New Endpoints

#### `POST /api/portfolios/manual` — Create manual portfolio

```
Request:  { "portfolioName": "My Portfolio", "currency": "USD" }
Response: { "id": "uuid", "portfolioName": "...", "currency": "USD", "isLinked": false }
```

Creates a portfolio with broker=99 (Manual), no API credentials.

#### `POST /api/manual-assets` — Create manual asset

```
Request:  { "portfolioId": "uuid", "assetClass": "CASH", "name": "ICICI Bank Savings", "amount": 300000.00, "currency": "INR" }
Response: 201 { "id": "uuid", ... full ManualAssetDto }
```

Validates: portfolio ownership, asset class enum, amount > 0.

#### `GET /api/manual-assets?portfolioId={uuid}` — List manual assets

Returns all manual assets for the given portfolio. Verifies user ownership.

#### `PUT /api/manual-assets/{id}` — Update manual asset

Partial update of: `name`, `amount`, `currency`, `assetClass`, `note`, `excludedFromCalculations`.

#### `DELETE /api/manual-assets/{id}` — Delete manual asset

Returns 204. Verifies ownership.

#### `GET /api/stocks/search-symbols?q={query}&limit=10` — EODHD search (existing)

Already exists. Returns `{ code, exchange, name, country, currency, isin }`. Used by the new stock autocomplete.

---

## 3. Frontend Component Architecture

### Refactored: `AddTransactionModalComponent`

**Before:** 3 tabs (Stock/Cash/Bulk), blind ticker text input, no portfolio selector, no OnPush, no signals.

**After:**

```
+---------------------------------------+
| Portfolio: [Select Manual v] [+ New]  |
|   (or inline: Name + Currency fields) |
+---------------------------------------+
|  [ Stocks ]    [ Others ]             |
+---------------------------------------+
| STOCKS TAB:                           |
|  Search: [EODHD autocomplete input]   |
|  [results: AAPL.US - Apple Inc ...]   |
|  Selected: AAPL.US - Apple Inc  [x]   |
|  Shares: [___]  Avg Price: [___]      |
|  ----------- or -----------           |
|  Bulk CSV Import (file + paste)       |
|  Format: symbol,shares,price,exch,cur |
|  [Import Options: keep/replace...]    |
+---------------------------------------+
| OTHERS TAB:                           |
|  Asset Class: [Cash v]               |
|  Name: [ICICI Bank Savings]          |
|  Amount: [300000]  Currency: [INR v] |
+---------------------------------------+
| [Cancel]              [Add Stock]     |
+---------------------------------------+
```

**Key architectural changes:**
- `ChangeDetectionStrategy.OnPush`
- All state via Angular Signals
- Modern `@if`/`@for` control flow (no `*ngIf`/`*ngFor`)
- EODHD autocomplete reuses `TickerMappingModal` RxJS pattern: `fromEvent → debounceTime(400) → distinctUntilChanged → switchMap(searchSymbols)`
- `@Input() preselectedPortfolioId` from parent
- Portfolio list filtered to manual-only (`!isLinked`)

**Updated `TransactionData` interface:**
```typescript
interface TransactionData {
  type: 'stock' | 'bulk' | 'manual-asset';
  portfolioId?: string;
  newPortfolio?: { name: string; currency: string };
  // Stock (enriched from EODHD)
  ticker?: string;
  exchangeCode?: string;
  securityName?: string;
  isin?: string;
  quantity?: number;
  price?: number;
  currency?: string;
  // CSV
  csvContent?: string;
  importOptions?: { keepUnchanged: boolean; replaceExisting: boolean };
  // Manual asset
  manualAsset?: { assetClass: string; name: string; amount: number; currency: string };
}
```

### Modified: `PortfolioComponent`

- `handleTransaction()` now chains portfolio creation (if `newPortfolio` set) before dispatching
- `addHoldingFromModal()` passes `exchangeCode`, `name`, `isin` to `createHolding()`
- New `manual-asset` type dispatches to `apiService.createManualAsset()`

### New ApiService methods

- `createManualPortfolio(data)` → `POST /api/portfolios/manual`
- `createManualAsset(data)` → `POST /api/manual-assets`
- `getManualAssets(portfolioId)` → `GET /api/manual-assets`
- `updateManualAsset(id, data)` → `PUT /api/manual-assets/{id}`
- `deleteManualAsset(id)` → `DELETE /api/manual-assets/{id}`

---

## 4. CSV Format Enhancement

**Old format:** `symbol, shares, avgPricePaid`
- Problem: No exchange info; `findOrCreateByTicker("RELIANCE")` guesses exchange

**New format:** `symbol, shares, avgPricePaid, exchange, currency`
- `exchange`: EODHD suffix (US, NSE, XETRA, TO, etc.) — converted to DB exchange code via `EodhdSymbolDerivationService`
- `currency`: 3-letter ISO code per row
- Both columns optional — backward compatible

**Example:**
```csv
symbol,shares,avgPricePaid,exchange,currency
AAPL,10,150,US,USD
RELIANCE,50,2800,NSE,INR
SAP,20,180,XETRA,EUR
```

---

## 5. Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Non-equity storage | New `manual_asset` table | No FIGI/ISIN/ticker applies; clean domain separation from equity pipeline |
| Portfolio type | Derived from `snaptrade_connection` JOIN | Single source of truth; no data duplication |
| Manual broker | Seed `broker_metadata` row (id=99) | Avoids making `broker` nullable on `portfolios` |
| CSV exchange format | EODHD suffixes | Matches what the search API returns; user-friendly |
| Exchange resolution | Reuse `findOrCreateByTickerOrFigiOrExchange` | Already handles exchange lookup, currency disambiguation, graceful fallback |
| Frontend autocomplete | Reuse `TickerMappingModal` RxJS pattern | Proven debounce/switchMap/signals pattern |
