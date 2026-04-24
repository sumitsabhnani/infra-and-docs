# Feature Spec: Server-Authoritative Portfolio Summary Endpoint

## Problem

The Dashboard page (`/dashboard`) and Holdings Overview page (`/portfolio`) display realized-gain totals that disagree. Observed gap per portfolio (user-reported):

| Portfolio        | Dashboard  | Holdings Overview |
|------------------|------------|-------------------|
| Ekta Trading212  | $755.96    | ~$2700            |
| Sumit Trading212 | $1088.83   | ~$3000            |

Root cause: two different computation paths.

- **Holdings Overview** (`GET /api/groups/summary` → `StockGroupService`) walks all portfolio transactions via `PortfolioReplayService` and includes realized gain from fully liquidated (closed) positions.
- **Dashboard** (`GET /api/holdings` → `RealizedGainAnalyticsService` → `HoldingController.applyRealizedAggregate`) computes realized gain per effective-master but only attaches it to surviving active-holding DTOs. Closed positions produce no DTO, so their gains are silently dropped; the frontend then sums holding-level `realizedGainReporting` and undercounts.

Additional violation: the Dashboard sums every monetary card metric (`totalValue`, `unrealizedGain`, `realizedGain`, `dividendIncome`, `positionsCount`) client-side via `.reduce(...)`. This violates the project's **No client-side financial aggregation** rule.

## Architectural Principles Enforced

1. **Unified Valuation Engine / Accounting Tie-Out** — exactly one computation path for each metric: `PortfolioReplayService` + `ValuationEngineService`. Both pages tie out mathematically.
2. **Server-authoritative totals** — every monetary number rendered on a Dashboard card is a DTO field from the server. No `.reduce` on currency values in the frontend.
3. **Presentational math is client-side only** — percentages (`gainLossPercent`, `realizedGainPercent`) are two-term divisions on server-provided numerator/denominator. Not aggregations.
4. **Bulk by design** — one HTTP call returns all portfolios' summaries; one batched `findAllForReplay(portfolioIds)` DB call feeds all per-portfolio replays. No N+1.

## Endpoint Contract

```
GET /api/portfolios/summaries
    ?reportingCurrency={USD|EUR|...}   (optional; falls back to user profile default)

→ 200 OK  List<PortfolioSummaryDto>
```

Authorization: standard `@AuthenticationPrincipal User` — the response is scoped to the caller's owned portfolios. Consistent with `PortfolioController` routes and `HoldingController.getHoldingsByPortfolio`.

One entry per owned portfolio (even if totals are zero — the UI always renders a card per portfolio).

## DTO Schema

`core/src/main/java/com/portfolio/tracker/core/dto/PortfolioSummaryDto.java`

| Field                      | Type         | Units / Meaning                                                  | Nullable |
|----------------------------|--------------|------------------------------------------------------------------|----------|
| `portfolioId`              | `UUID`       | —                                                                | No       |
| `totalValue`               | `BigDecimal` | Current market value of active holdings, reporting currency      | No (zero if none) |
| `totalInvested`            | `BigDecimal` | Cost basis of active holdings (partial-buy-rule applied)         | No (zero if none) |
| `unrealizedGain`           | `BigDecimal` | `totalValue - totalInvested`                                     | No       |
| `realizedGainReporting`    | `BigDecimal` | Lifetime realized gain, **includes closed positions**            | No (zero if none) |
| `soldCostBasisReporting`   | `BigDecimal` | Sum of cost basis consumed by SELLs; denominator for `% return on sold` | No (zero if none) |
| `dividendIncomeLifetime`   | `BigDecimal` | Lifetime dividend income, reporting currency                     | No (zero if none) |
| `dividendIncomeYtd`        | `BigDecimal` | Year-to-date dividend income, reporting currency                 | No (zero if none) |
| `positionsCount`           | `int`        | Count of active (qty > 0, not excluded) holdings                 | No       |

All monetary fields are `BigDecimal` for precision (project rule — never `double`/`float` for money).

## Engine Reuse — Single Source of Truth

The service implementing this endpoint (`PortfolioSummaryService` in the `api` module) delegates to existing primitives and does NOT reimplement financial logic:

- **Realized gain / sold cost** — `PortfolioReplayService.replay(portfolioId, reportingCurrency, fxSnapshot, preloadedTxns)` when `globalReplayEnabled=true`; legacy `RealizedGainCalculator.computeReportingCurrencyWithSoldCost(...)` per-master loop otherwise. Same feature-flag branch as `StockGroupService.computeTotalRealizedGain()`.
- **Total value** — `ValuationEngineService.currentValueReporting(holding, fxSnapshot)` (same call path as `StockGroupService.sumCurrentValueReporting`).
- **Cost basis** — `StockGroupService.sumCostBasisReporting` idiom (partial-buy rule applied). Will be extracted package-private for reuse.
- **FX + prices** — `FxRateSnapshotBuilder.buildForHoldings(...)` + `PriceService.bulkWarmCache(...)`, shared snapshots built once for the whole request.
- **Dividends** — new portfolio-level aggregation method on `DividendAnalyticsService` (single SQL batched over all portfolioIds).

This guarantees that `sum(PortfolioSummaryDto.realizedGainReporting)` over a user's portfolios equals `StockGroupService`-reported realized total over the same portfolio set.

## Rollout Notes

- **Feature flag**: `globalReplayEnabled` behavior is identical to `/api/groups/summary`. Flipping the flag in either direction keeps both endpoints in lock-step.
- **Backwards compatibility**: additive — `/api/holdings` is unchanged. No existing consumer breaks.
- **Frontend adoption**: only the Dashboard's per-portfolio card totals migrate to the new endpoint. Holdings list continues to come from `/api/holdings` for the non-totals sections (`app-alignment`, `app-buy-below`, `app-asset-allocation`).

## Out of Scope (Tracked Follow-ups)

- **`snapshotMetrics`** (user-wide totals at the top of Dashboard): still client-aggregated across all holdings. Will require a separate `GET /api/users/snapshot` endpoint in a follow-up slice.
- **`alignmentAlerts` portfolio total** (`dashboard.component.ts:122`): sub-step of a presentational alert, not a card metric — untouched.
- **Holdings page**: already uses `/api/groups/summary` and is correct.
- **Server-computed percentages**: `gainLossPercent` / `realizedGainPercent` stay client-side (presentational two-term division). Move to the server if we later decide even presentational math should not run on the client.
