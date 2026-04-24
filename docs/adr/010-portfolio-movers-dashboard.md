# ADR-010: Zero-State Portfolio Movers Dashboard

**Status:** Accepted
**Date:** 2026-04-16

## Context

The Detailed View (`/portfolio?view=detailed`) displays a search-driven interface for exploring individual holdings. When no ticker is selected, the page renders a static empty state — a magnifying glass icon with instructional text. This wastes significant viewport real estate, especially on smaller screens, and provides no actionable data to the user until they explicitly search.

Users opening the Detailed View want immediate visibility into their portfolio's daily performance without needing to know which ticker to look up first. The empty state should surface the most impactful daily movements across all portfolios.

## Decision

Implement a **Hybrid Zero-State** pattern: preserve the existing search affordance (SVG + instructional text) and inject a live **Portfolio Movers** dashboard directly below it. The movers dashboard displays the Top 5 gainers and losers across all user portfolios, with both Absolute Impact and Percentage sorting modes.

### Backend: `GET /api/movers`

A new lightweight endpoint aggregates holdings across all portfolios for the authenticated user:

1. Fetches all holdings via `HoldingRepository.findWithSecurityAndListingsAndGroupByPortfolioIdIn()` (single eager query).
2. Groups by canonical `SecurityMaster.getEffectiveId()` (ADR-005 compliant deduplication).
3. Leverages existing `HoldingPriceDiffService.buildDiffMap()` for bulk previous-close resolution — 4 DB queries regardless of portfolio size, avoiding N+1.
4. Computes day-change impact in the user's reporting currency via `ExchangeRateService` with the same two-leg FX pattern from `HoldingMapper` (ADR-009).
5. Returns pre-sorted Top/Bottom 5 arrays for both Impact and Percentage dimensions.

**Total query budget:** 7 DB queries (1 portfolios + 1 holdings + 1 cache warm + 4 price diffs), independent of holding count.

The endpoint lives in a dedicated `MoversController` (not HoldingController) since it is a cross-portfolio read-only aggregation — a fundamentally different concern from single-portfolio CRUD.

### Frontend: `<app-portfolio-movers>`

- **Standalone component**, OnPush change detection, Angular Signals for all state.
- Fetches once on mount. Segmented toggle (Impact | Percentage) switches instantly via `computed()` signals — no re-fetch, all 4 lists are pre-computed by the backend.
- 50/50 CSS Grid layout (Top Gainers | Top Losers) with institutional table styling.
- Clickable rows: selecting a mover ticker matches it against the user's `allTickers()` list and triggers the existing `selectTicker()` flow.
- Unmounts when the user selects a ticker (the `@else` block unmounts entirely), and re-mounts on clear.

## Consequences

**Positive:**
- Immediate daily P&L visibility without any user action — the most impactful movers are visible above the fold.
- The primary search affordance is fully preserved (hybrid pattern).
- Zero additional database tables or materialized views — entirely derived from existing data paths.
- Constant query budget (7 queries) regardless of portfolio/holding count.
- Clickable tickers create a natural discovery flow: movers dashboard → ticker detail.

**Negative:**
- The endpoint re-computes on every page load (no caching). For users with hundreds of holdings across many portfolios, the aggregation may add ~200-400ms latency. Redis caching with a short TTL (e.g., 2 minutes) can be added later if telemetry shows this is a bottleneck.
- On weekends/holidays, all day changes are ~0%, making the dashboard less useful. The data is technically correct but visually inert.

**Neutral:**
- The `MoversService` duplicates some FX resolution logic from `HoldingMapper` (the `resolveFxRate` pattern). This is intentional — the movers service needs only day-change FX conversion, not the full cost-basis / gain-loss calculation, and coupling it to `HoldingMapper` would pull in unnecessary complexity.
