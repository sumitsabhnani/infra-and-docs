# ADR-008: Asset Allocation Visibility & Manual Asset Decoupling

**Status:** Accepted  
**Date:** 2026-04-14  
**Context:** The portfolio tracker needed a dashboard-level asset allocation widget showing how a user's total net worth is distributed across asset classes (Equity, Cash, Gold, Bonds, Real Estate, etc.). Manual/static assets (cash savings, gold, real estate) were originally tied to the `Portfolio` entity via `manual_asset.portfolio_id`, inheriting a model designed for broker-synced equity holdings. This coupling was architecturally wrong: portfolios represent broker accounts with dynamic, transaction-based holdings synced via SnapTrade, while manual assets are user-entered static values for net worth visibility. The coupling forced users to select a portfolio when adding a manual asset (causing 400 errors when `portfolioId` was null), and would have surfaced manual assets on the Holdings page which isn't designed for them. Additionally, the frontend used Chart.js for charting, which lacked the rendering fidelity and configuration depth required for the donut-chart-plus-legend layout.

---

## Decision 1: Unified Read Model via Event-Driven `user_asset_exposures`

### Problem

Computing asset allocation on-the-fly requires joining holdings across multiple portfolios, fetching current prices in each holding's native currency, converting everything to the user's reporting currency via `ExchangeRateService`, and summing by asset class. This is 3+ table joins, N price lookups, and M currency conversions on every API call — unacceptable for a dashboard widget that renders on every page load.

### Decision

Introduce a `user_asset_exposures` PostgreSQL table as a pre-computed read model. The table stores per-user, per-asset-class rows with `weight_pct`, `total_value`, and `currency` already resolved.

```
┌──────────────────────────────────────────────────────┐
│  Write Path (async, event-driven)                    │
│                                                      │
│  ManualAssetService.create/update/delete()           │
│  SnapTrade broker sync completion                    │
│  "Calculate Now" button (POST /recalculate)          │
│       │                                              │
│       ▼                                              │
│  ApplicationEventPublisher                           │
│       │  ManualAssetChangedEvent(userId)              │
│       ▼                                              │
│  AssetExposureRecalculationListener  (@Async)        │
│       │                                              │
│       ├─ PriceService → latest prices                │
│       ├─ ExchangeRateService → FX conversion         │
│       └─ AssetExposureAggregationService.recalculate │
│            │                                         │
│            ▼                                         │
│       UPSERT user_asset_exposures                    │
└──────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────┐
│  Read Path (O(1))                                    │
│                                                      │
│  GET /api/asset-allocation                           │
│       └─ AssetAllocationReadService                  │
│            └─ SELECT FROM user_asset_exposures        │
│                 WHERE user_id = ?                    │
│            └─ JOIN user_asset_class_targets           │
│                 (if allocation tracking enabled)      │
│                                                      │
│  Response: weight_pct, total_value, target_pct,      │
│            max_drift_pct, exceeds_max (computed)      │
└──────────────────────────────────────────────────────┘
```

The `AssetExposureRecalculationListener` runs on `@Async("backgroundJobExecutor")` with `@TransactionalEventListener(phase = AFTER_COMMIT, fallbackExecution = true)`, ensuring recalculation never blocks the user's write operation and only fires after the triggering transaction commits.

### Alternatives Rejected

- **On-the-fly aggregation:** Unacceptable latency (100ms+ with FX lookups) for a dashboard widget. Would require caching anyway, deferring the same consistency problem.
- **Redis cache only:** Loses data on Redis restart. For financial data, PostgreSQL is the correct source of truth; Redis is used for ephemeral caches (market indices), not derived financial state.

---

## Decision 2: Domain Decoupling — Manual Assets Owned by User, Not Portfolio

### Problem

`manual_asset.portfolio_id` forced a foreign-key relationship to `portfolios`, but the two concepts are fundamentally different:

| Portfolios | Manual Assets |
|---|---|
| Broker accounts (SnapTrade-synced) | User-entered static values |
| Dynamic: quantity x market price | Static: user sets amount directly |
| Appear on Holdings page | Appear only in allocation & dashboard |
| Multiple per user, per broker | Global to user's net worth |

Forcing manual assets into a portfolio created UX confusion (which portfolio does "Emergency Fund Cash" belong to?) and backend coupling (portfolio deletion would cascade-delete manual assets).

### Decision

Flyway migration `V20260413120000__MigrateManualAssetToUserLevel.sql`:

1. Add `user_id UUID` column (nullable initially)
2. Backfill: `UPDATE manual_asset SET user_id = p.user_id FROM portfolios p WHERE manual_asset.portfolio_id = p.id`
3. `ALTER COLUMN user_id SET NOT NULL`, add FK to `users(id) ON DELETE CASCADE`
4. Create index `idx_manual_asset_user ON manual_asset(user_id)`
5. Drop `portfolio_id` column and its old index

Clean break — no dual-column transition period. The data volume is small (single-user app), so the migration is safe as a single atomic operation.

### Entity Changes

```java
// Before
@ManyToOne @JoinColumn(name = "portfolio_id") private Portfolio portfolio;

// After
@ManyToOne @JoinColumn(name = "user_id") private User user;
```

`ManualAssetController` endpoints no longer require `portfolioId`:
- `POST /api/manual-assets` — body contains `name`, `amount`, `currency`, `assetClass`; user resolved from JWT
- `GET /api/manual-assets` — returns all manual assets for authenticated user
- `PUT/DELETE /{id}` — ownership validated via `asset.getUser().getId().equals(userId)`

### Frontend Impact

The "Others" tab in the Add Assets modal no longer requires a portfolio to be selected. A new `OtherAssetsComponent` on the dashboard provides view/edit/delete for manual assets independently of any portfolio context.

---

## Decision 3: Physical Increment vs. Transient Growth Calculation

### Problem

Manual assets like savings accounts or SIPs grow monthly. Users need a way to say "add 50,000 INR to this cash asset every month" without manual updates.

### Initial Plan (Rejected)

Compute effective amount transiently using `updatedAt`:

```java
public BigDecimal getEffectiveAmount() {
    long months = ChronoUnit.MONTHS.between(
        updatedAt.toLocalDate().withDayOfMonth(1),
        LocalDate.now().withDayOfMonth(1));
    return amount.add(monthlyIncrement.multiply(BigDecimal.valueOf(months)));
}
```

**Why rejected:**
- **Data-loss on edit:** When a user edits any field (name, currency, asset class), `updatedAt` resets, silently zeroing out months of accrued growth. The user would need to manually recalculate and adjust the base amount — exactly the manual work the feature was supposed to eliminate.
- **Debugging opacity:** The stored `amount` would never match what users see on the dashboard, making support and data verification difficult.
- **Inconsistent reads:** Two reads of the same asset on different days return different amounts despite no write occurring — violating the principle of least surprise for a financial application.

### Chosen Approach: Physical Increment via Scheduled Job

`MonthlyManualAssetIncrementJob` runs on the 1st of each month at 00:01 UTC (`@Scheduled(cron = "0 1 0 1 * ?")`):

1. `findEligibleForIncrement(firstOfMonth)` — selects assets with `monthly_increment > 0` and `last_increment_date < firstOfMonth`
2. `bulkApplyMonthlyIncrement(firstOfMonth, today)` — single UPDATE: `SET amount = amount + monthly_increment, last_increment_date = today`
3. Publishes `ManualAssetChangedEvent` per affected user to trigger allocation recalculation

**Idempotency:** The `last_increment_date` guard ensures running the job multiple times in one month has no additional effect. The job is also triggered on application startup (wrapped in try-catch to avoid blocking startup on failure).

**Database schema additions:**
```sql
ALTER TABLE manual_asset ADD COLUMN monthly_increment NUMERIC(20,8) NOT NULL DEFAULT 0;
ALTER TABLE manual_asset ADD COLUMN last_increment_date DATE;
```

### Trade-offs

- **Stale until 1st:** If a user adds a monthly increment on the 15th, they won't see the first increment until the 1st of next month. This is acceptable — the feature models calendar-month savings, not arbitrary intervals.
- **Edit resets timer:** Editing an asset's base amount is intentional; the `last_increment_date` is preserved on edit so no accrued growth is lost.

---

## Decision 4: Policy vs. Instance Separation — Asset Class Targets

### Problem

Users need to define macro allocation rules ("no more than 70% in Equity", "target 20% in Bonds"). These are portfolio-wide policies, not properties of individual assets or transactions.

### Decision

A dedicated `AssetTargetsModalComponent` manages the `user_asset_class_targets` table, which stores per-user, per-asset-class rows with `target_pct` (must sum to 100%) and `max_drift_pct` (optional ceiling per class).

This is intentionally separated from the "Add Asset" transaction flow:

- **Add Asset modal:** Instance-level — "I have $50,000 in cash savings"
- **Asset Targets modal:** Policy-level — "I want no more than 30% of my net worth in cash"

Conflating these would mean users must think about allocation policy every time they add an asset — cognitive overhead that discourages frequent updates.

### Enforcement

The `AssetAllocationReadService` compares current `weight_pct` from `user_asset_exposures` against `max_drift_pct` from `user_asset_class_targets`. When `actual > max`, it sets `exceedsMax = true` on the response DTO. The frontend renders a warning icon and red highlight on the affected row.

`target_pct` is currently display-only (shown as a reference column in the allocation legend). It enables future features like under-allocation alerts and rebalancing suggestions, but no active enforcement exists today.

---

## Decision 5: Chart.js to Apache ECharts Migration

### Problem

The allocation widget requires two interactive donut charts (asset allocation + equity by portfolio) with:
- Configurable inner/outer radius for donut style
- Pad angle between slices
- Emphasis animations on hover
- Custom tooltip formatting with monospace numbers
- Responsive sizing with center-label overlays

Chart.js could achieve this but required significant plugin/callback configuration and produced visually flat charts. The project was also accumulating Chart.js-specific workarounds for Angular lifecycle integration.

### Decision

Migrate to Apache ECharts via `ngx-echarts@17.2.0`. ECharts provides:

- **Declarative configuration:** Full chart spec as a single `EChartsOption` object, set via Angular signal — no imperative API calls or lifecycle hooks
- **Built-in donut features:** `padAngle`, `borderRadius`, `emphasis.scale`, `emphasis.scaleSize` work out of the box
- **Rich tooltips:** HTML formatter with full styling control
- **Enterprise pedigree:** Apache Foundation project used at scale for financial dashboards

### Integration Pattern

```typescript
// Reactive signal drives the chart — Angular OnPush just works
readonly allocationChartOptions = signal<EChartsOption>({});

// Template binding — no ViewChild, no manual resize handling
<div echarts [options]="allocationChartOptions()" class="allocation-widget__echart"></div>
```

The chart wrapper is a fixed-size container (160x160px) with an absolutely-positioned center label overlay showing the total invested value. The legend is a separate CSS Grid using `subgrid` for cross-row column alignment — not an ECharts legend — giving full styling control with CSS custom properties.

### Trade-offs

- **Bundle size:** ECharts (~800KB minified) is larger than Chart.js (~200KB). Acceptable given the application is not a lightweight landing page, and ECharts supports tree-shaking for production builds.
- **Learning curve:** ECharts' option-based API is different from Chart.js' imperative style. However, the declarative model aligns better with Angular's signal-based reactivity.

---

## Consequences

### Positive

- **Dashboard latency protected:** Asset allocation reads are a single indexed SELECT — no joins, price lookups, or FX conversions on the hot path.
- **Clean domain model:** Manual assets belong to users, not portfolios. Adding/editing/deleting manual assets has no portfolio side effects.
- **Reliable growth tracking:** Physical monthly increments produce an audit-friendly `amount` column that always matches what the user sees. No transient math surprises.
- **Separation of concerns:** Transaction flow (Add Asset) and policy management (Asset Targets) are independent workflows with independent UI surfaces.
- **Visual quality:** ECharts donut charts with pad angles, border radius, and emphasis animations produce a professional dashboard aesthetic.

### Trade-offs

- **Eventual consistency:** Asset allocation data can be up to a few seconds stale after a write (async recalculation). The "Calculate Now" button provides an escape hatch.
- **Monthly increment granularity:** Fixed to calendar months. Users wanting weekly or arbitrary-interval increments would need a different mechanism.
- **Breaking migration:** The `portfolio_id` column drop is irreversible. Acceptable for the current single-user deployment; would require a more cautious migration strategy in a multi-tenant SaaS context.
