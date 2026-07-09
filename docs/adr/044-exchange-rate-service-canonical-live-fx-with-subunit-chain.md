# ADR-044: `ExchangeRateService` Is the Canonical Live-FX Path — Sub-Units Chain Through Their Major Currency

**Status:** Accepted
**Date:** 2026-05-18
**Extends:** ADR-011 (unified valuation engine — same tie-out principle, FX layer)

---

## Context

GBX-priced holdings (London Stock Exchange penny stocks, e.g. `SSLN` iShares Physical Silver) rendered wildly incorrect values in any reporting currency other than GBP. Concrete symptom: a holding with GBX 95,706 cost basis displayed as **$102,933 with 2737% allocation** in the USD view; the GBP view rendered correctly. Backend log on every holdings request:

```
WARN  ExchangeRateService.getConversionRateFromDatabase - FX conversion missing rate for GBX -> USD
WARN  ExchangeRateService.getConversionRateFromDatabase - FX conversion missing rate for USD -> GBX
```

GBX is not an ISO currency — it is the minor unit of GBP (`1 GBP = 100 GBX`), used as the price quotation unit on the LSE. The `fx_rate` table only carries real-currency pairs from EODHD (`EURUSD`, `GBPUSD`, `USDCAD`, `AUDUSD`, `USDINR`), and there is no `GBXUSD` pair to fetch. Pre-fix, `ExchangeRateService.getConversionRateInternal` short-circuited GBX↔GBP via a hardcoded `0.01` factor but had no branch for GBX↔X where X ≠ GBP; the call fell through to `getConversionRateFromDatabase`, returned null, and downstream consumers either silently dropped the holding (e.g. `AssetExposureAggregationService`) or rendered garbage values (the unrounded BigDecimal pipeline through `ValuationEngineService`).

Two parallel paths in the `api` module compounded the gap. `CurrencyConversionService.convert(BigDecimal, String, String)` handled only GBX↔GBP and **returned the unconverted amount on every other pair** with a WARN — a latent silent bug, never reached in production but masking the underlying contract. `PortfolioValuationService.resolveGBPPrice` pre-normalised GBX→GBP inline using `CurrencyConversionService.convertGBXtoGBP`, so the local code path "worked" for the GBP-denominated valuation it owned but bypassed the canonical FX engine, hiding the broken chain from anything that looked at the service. The sibling `HistoricalFxRateService` already implemented the correct chain for historical FX; live FX did not, and the divergence was invisible until a user with a GBX position switched reporting currency.

---

## Decision 1: Chain Sub-Units Through Their Major Currency Inside `ExchangeRateService`

`ExchangeRateService.getConversionRateInternal(from, to)` now has two new branches between the existing direct GBX↔GBP short-circuit and the DB fallback:

```
if (isGBX(from))  → rate = GBX_TO_GBP_FACTOR × getConversionRateInternal("GBP", to)
if (isGBX(to))    → rate = getConversionRateInternal(from, "GBP") / GBX_TO_GBP_FACTOR
```

The `0.01` `GBX_TO_GBP_FACTOR` stays a private constant — call sites never name it. The recursive call goes through `this` (Spring self-invocation, bypasses the `@Cacheable` proxy on the inner leg) and resolves the GBP↔X side via the existing DB path, so the only new I/O is one extra `findLatest` on a cold cache. The outer GBX↔X result is still cached at the proxy boundary via the public `getConversionRate(from, to)` entry point.

Future minor units (US cents `USc`, ZA cents `ZAc`, …) extend the same pattern: add a constant, add a chain branch. Call sites stay unchanged.

## Decision 2: Retire Parallel Live-FX Paths in the `api` Module

`CurrencyConversionService.convert(BigDecimal, String, String)` is **deleted**. Display helpers on the same class (`isGBX`, `isGBP`, `convertGBXtoGBP`, `convertGBPtoGBX`, `formatWithCurrency`, `getDisplayInfo`, `isMinorUnit`, `getMajorCurrency`, `CurrencyDisplayInfo`) are retained — they format `"5,611.00 GBX (£56.11)"`-style display strings and are not FX math. The deletion is safe by grep: zero non-test callers existed.

`PortfolioValuationService.resolveGBPPrice` now delegates: `exchangeRateService.convert(rawPrice, listingCurrency, "GBP")` with a fallback to `rawPrice` on null. The local `CurrencyConversionService` field on this service is removed; injection is `ExchangeRateService` directly.

The contract is now narrow: **all live-FX conversion routes through `ExchangeRateService.convert(amount, from, to)` or `ExchangeRateService.getRate(from, to)` / `getRateWithInverseFallback(from, to)`**. Historical FX continues to flow through `HistoricalFxRateService` per ADR-011's fallback hierarchy.

---

## Consequences

- Every consumer of `ExchangeRateService` — `ValuationEngineService` (cost basis + market price legs), `FxRateSnapshotBuilder` (pre-built snapshot for batched valuations), `AssetExposureAggregationService` (background asset-class rollup), `PriceService.buildLatestPriceDto`, `MoversService`, `TickerDetailService`, `RealizedGainCalculator`, `HistoryQueryService` — produces correct GBX values for any reporting currency. No downstream code changed.
- The two GBX-related WARN logs at `ExchangeRateService.getConversionRateFromDatabase:340,349` stop firing organically; GBX no longer reaches the DB fallback. The log lines stay in place — they remain correct for genuinely missing pairs (an unsupported ticker currency outside the `EodhdFxRateClient.FX_PAIRS` list).
- The Spring `@Cacheable` self-invocation on the recursive inner call bypasses the proxy. Net cost: one extra indexed `findLatest` per cold GBX↔X resolution. Outer rate is cached at the public boundary; warm-cache reads are unchanged. Not worth refactoring with `@Lazy self` injection.
- Pre-existing Redis cache entries that stored `null` for `GBX_USD`/`USD_GBX` keys (TTL = 1h, set by `unless = "#result == null"` on `getConversionRateInternal`) are flushed by triggering `POST /api/exchange-rates/sync` post-deploy (the existing `@CacheEvict(allEntries=true)` on `syncLatestRates`). Otherwise the cache self-heals within one TTL.
- Adding a new minor unit is a single-branch edit in `getConversionRateInternal` plus a constant. The `api` module never participates in the decision.
- The `core/test/ExchangeRateServiceTest.GbxChainViaGbp` nested class pins the magnitude: `convert(95705.98 GBX, "USD")` with `USD/GBP = 0.80` returns `~$1,196` — the exact regression-pin from the bug report. Eight additional tests cover GBX→EUR/INR, EUR→GBX, missing-leg fallbacks, and case-insensitivity.

---

## Alternatives Considered

- **Persist GBX in `fx_rate`.** Rejected: GBX is not an ISO currency, EODHD does not publish a `GBXUSD` pair, and the GBX↔GBP ratio is fixed (`100:1`). Storing it would invent a sync target with no upstream data source and create a second invariant to maintain.
- **Pre-normalise at every call site.** Rejected: this is exactly what the parallel paths did, and exactly what caused the original gap to stay invisible. Centralising the chain in the FX service is the only way to keep call sites unaware of minor-unit complexity.
- **Hoist the chain into `FxRateSnapshotBuilder` only.** Rejected: `AssetExposureAggregationService` and ad-hoc callers reach for `ExchangeRateService.convert` directly without going through the snapshot, and they would have remained silently broken.
