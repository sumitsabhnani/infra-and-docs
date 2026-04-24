# Feature Spec: Zero-State "Portfolio Movers" Dashboard

## 1. Overview

Replace the static empty state in the Detailed View with a live "Portfolio Movers" dashboard that surfaces the user's biggest daily winners and losers across all portfolios, in their reporting currency.

**Pattern:** Hybrid Zero-State — preserves the existing empty state (magnifying glass SVG, "Search for a holding" title, descriptive subtext) and injects the movers dashboard **below** it with spacing.
**Unmount:** Instantly via `@if` when a ticker is selected (the entire `@else` block including both the empty state and movers unmounts).

---

## 2. API Contract

### `GET /api/movers`

**Auth:** Bearer JWT (same as all `/api/*` endpoints).

**Query Parameters:**

| Param | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `reportingCurrency` | `string` | No | User's `reportingCurrency` from JWT profile | ISO 4217 currency code for impact calculations |

**Response: `200 OK`**

```json
{
  "reportingCurrency": "USD",
  "topGainersByImpact": [
    {
      "securityMasterId": "uuid",
      "ticker": "AAPL",
      "name": "Apple Inc.",
      "exchangeCode": "NASDAQ",
      "nativeCurrency": "USD",
      "currentPriceNative": 198.50,
      "previousClose": 195.20,
      "dayChangeNative": 3.30,
      "dayChangePercent": 1.69,
      "dayChangeImpactReporting": 660.00,
      "totalQuantity": 200.00
    }
  ],
  "bottomLosersByImpact": [ /* same shape, sorted ascending by dayChangeImpactReporting */ ],
  "topGainersByPercent": [ /* same shape, sorted descending by dayChangePercent */ ],
  "bottomLosersByPercent": [ /* same shape, sorted ascending by dayChangePercent */ ]
}
```

Each array contains at most **5 items**.

**`MoverItemDto` Field Definitions:**

| Field | Type | Description |
|-------|------|-------------|
| `securityMasterId` | `UUID` | Canonical security identity (ADR-005) |
| `ticker` | `string` | Primary listing ticker symbol |
| `name` | `string` | Company name from `SecurityMaster` |
| `exchangeCode` | `string` | Exchange code (e.g., "NASDAQ", "NSE") |
| `nativeCurrency` | `string` | Market price currency (ISO 4217) |
| `currentPriceNative` | `BigDecimal` | Latest price in native currency |
| `previousClose` | `BigDecimal` | Most recent close before today |
| `dayChangeNative` | `BigDecimal` | `currentPriceNative - previousClose` |
| `dayChangePercent` | `BigDecimal` | `(dayChangeNative / previousClose) × 100` |
| `dayChangeImpactReporting` | `BigDecimal` | `dayChangeNative × totalQuantity × fxRate(native→reporting)` |
| `totalQuantity` | `BigDecimal` | Sum of quantities across all portfolios for this security |

**Error Responses:**

| Code | When |
|------|------|
| `401` | Missing/invalid JWT |
| `500` | Internal error (logged, empty response fallback) |

**Weekend/Holiday Behavior:**
On non-trading days, `currentPriceNative ≈ previousClose`, producing `dayChangePercent ≈ 0.00` and `dayChangeImpactReporting ≈ 0.00`. No special handling — the math falls out naturally.

---

## 3. Backend Aggregation Algorithm

```
1. portfolioRepository.findByUserId(userId)
   → List<Portfolio> portfolios

2. holdingRepository.findWithSecurityAndListingsAndGroupByPortfolioIdIn(portfolioIds)
   → List<Holding> allHoldings  (eager JPA fetch: securityMaster, acquiredListing, exchange, overrideMarketDataSymbol)

3. Filter: remove holdings where excludedFromCalculations == true

4. priceService.bulkWarmCache(allListingIds)
   → Warms Redis cache in 1 bulk query

5. holdingPriceDiffService.buildDiffMap(allHoldings)
   → Map<UUID, HoldingPriceDiffs>  (4 bulk DB queries total)

6. Group by holding.getSecurityMaster().getEffectiveId()
   → Map<UUID, List<Holding>> grouped by canonical SecurityMaster

7. For each canonical group:
   a. Representative holding = first with valid acquiredListing
   b. currentPriceNative = priceService.getLatestPrice(effectivePricingListing)
   c. previousClose = diffMap.get(holdingId).previousClose()
   d. marketPriceCurrency = priceService.getPricingCurrency(effectivePricingListing)
   e. totalQuantity = SUM(holding.quantity) across group
   f. dayChangeNative = currentPriceNative - previousClose
   g. dayChangePercent = (dayChangeNative / previousClose) × 100
   h. fxRate = exchangeRateService.getConversionRate(marketPriceCurrency, reportingCurrency)
   i. dayChangeImpactReporting = dayChangeNative × totalQuantity × fxRate

   Skip if: securityMaster is null, effectivePricingListing is null,
            currentPrice is null, previousClose is null.
   If FX rate unavailable: include in percent lists, exclude from impact lists.

8. Sort + slice:
   - topGainersByImpact: sort by dayChangeImpactReporting DESC, take 5
   - bottomLosersByImpact: sort by dayChangeImpactReporting ASC, take 5
   - topGainersByPercent: sort by dayChangePercent DESC, take 5
   - bottomLosersByPercent: sort by dayChangePercent ASC, take 5
```

**Total DB Queries:** 1 (portfolios) + 1 (holdings) + 1 (bulk cache warm) + 4 (price diffs) = **7 queries** regardless of portfolio/holding count.

**FX Rules:**
- Same currency → rate = 1 (no conversion)
- GBX ↔ GBP → hardcoded 0.01 factor
- Other → direct DB lookup, then inverse fallback, then cross-rate via USD
- Follows `ExchangeRateService` exactly (ADR-009 compliant)

---

## 4. Angular Component Tree

```
DetailedViewComponent (existing)
├── Search Box (existing)
├── @if (detailLoading())       → Loading spinner (existing)
├── @else if (detailError())    → Error message (existing)
├── @else if (tickerDetail())   → Ticker detail content (existing)
│   ├── TickerSummaryCardsComponent
│   ├── TickerPerformanceChartComponent
│   └── TransactionHistoryComponent
└── @else                       → Hybrid Zero-State
    ├── Empty State (PRESERVED: SVG icon + "Search for a holding" + subtext)
    └── ★ PortfolioMoversComponent (NEW — injected below empty state with 3rem spacing)
        ├── Header row (title + segmented toggle)
        ├── @if (loading())         → Loading skeleton
        ├── @else if (error())      → Error state with retry
        └── @else                   → 50/50 CSS Grid
            ├── Gainers Card (table: avatar | name+ticker | stacked day-change)
            └── Losers Card  (table: avatar | name+ticker | stacked day-change)
```

### Component Definition

```typescript
@Component({
  selector: 'app-portfolio-movers',
  standalone: true,
  imports: [CommonModule],
  changeDetection: ChangeDetectionStrategy.OnPush,
  templateUrl: './portfolio-movers.component.html',
  styleUrl: './portfolio-movers.component.scss'
})
export class PortfolioMoversComponent implements OnInit {
  @Input() reportingCurrency = 'USD';
}
```

**File Location:** `src/app/portfolio/detailed-view/portfolio-movers/`

---

## 5. State Management

All state is component-local via Angular Signals. No shared services needed.

```
┌─────────────────────────────────────────────┐
│ PortfolioMoversComponent                     │
│                                              │
│  Signals:                                    │
│  ├── moversData: signal<MoversResponse|null> │ ← API response
│  ├── loading: signal<boolean>                │ ← fetch in-flight
│  ├── error: signal<boolean>                  │ ← fetch failed
│  └── mode: signal<'impact'|'percentage'>     │ ← toggle state
│                                              │
│  Computed:                                   │
│  ├── gainers: computed(() => ...)            │ ← derives from mode + moversData
│  └── losers: computed(() => ...)             │ ← derives from mode + moversData
│                                              │
│  API Boundary (RxJS):                        │
│  └── ApiService.getMovers(reportingCurrency) │ ← single Observable, subscribed in ngOnInit
└─────────────────────────────────────────────┘
```

### Derived State Logic

```typescript
readonly gainers = computed(() => {
  const data = this.moversData();
  if (!data) return [];
  return this.mode() === 'impact'
    ? data.topGainersByImpact
    : data.topGainersByPercent;
});

readonly losers = computed(() => {
  const data = this.moversData();
  if (!data) return [];
  return this.mode() === 'impact'
    ? data.bottomLosersByImpact
    : data.bottomLosersByPercent;
});
```

Toggle switch is **instant** — no re-fetch. All 4 lists are pre-computed by the backend and cached in `moversData`. Switching mode only changes which computed signal reads from.

### Data Flow

```
ngOnInit()
  → ApiService.getMovers(reportingCurrency)
  → subscribe: moversData.set(response), loading.set(false)

User clicks toggle
  → mode.set('percentage')
  → gainers/losers recompute (no API call)

User selects a ticker (parent)
  → tickerDetail becomes truthy
  → @else if (tickerDetail()) branch activates → entire @else block unmounts
  → Both empty state and PortfolioMoversComponent destroyed (ngOnDestroy)

User clears search / deselects ticker (parent)
  → tickerDetail is null, not loading, no error
  → @else branch → empty state + PortfolioMoversComponent re-mount (ngOnInit → fresh API call)
```

---

## 6. Template Structure

```html
<div class="movers">
  <!-- Header -->
  <div class="movers__header">
    <h3 class="movers__title">Portfolio Movers</h3>
    <div class="movers__toggle">
      <button class="movers__toggle-btn"
        [class.movers__toggle-btn--active]="mode() === 'impact'"
        (click)="setMode('impact')">Impact</button>
      <button class="movers__toggle-btn"
        [class.movers__toggle-btn--active]="mode() === 'percentage'"
        (click)="setMode('percentage')">Percentage</button>
    </div>
  </div>

  <!-- Loading -->
  @if (loading()) {
    <div class="movers__loading">...</div>
  } @else if (error()) {
    <div class="movers__error">Failed to load movers data.</div>
  } @else {
    <!-- 50/50 Grid -->
    <div class="movers__grid">
      <!-- Gainers Card -->
      <div class="movers__card">
        <h4 class="movers__card-title movers__card-title--gain">Top Gainers</h4>
        <table class="movers__table">
          @for (item of gainers(); track item.securityMasterId) {
            <tr class="movers__row">
              <td class="movers__avatar-cell">
                <span class="movers__avatar">{{ item.ticker[0] }}</span>
              </td>
              <td class="movers__name-cell">
                <span class="movers__ticker">{{ item.ticker }}</span>
                <span class="movers__company">{{ item.name }}</span>
              </td>
              <td class="movers__change-cell positive">
                <span class="movers__change-amount">
                  +{{ formatCurrency(item.dayChangeImpactReporting, reportingCurrency) }}
                </span>
                <span class="movers__change-pct">+{{ item.dayChangePercent }}%</span>
              </td>
            </tr>
          } @empty {
            <tr><td colspan="3" class="movers__empty-row">No gainers today</td></tr>
          }
        </table>
      </div>

      <!-- Losers Card (mirror structure, negative class) -->
      <div class="movers__card">
        <h4 class="movers__card-title movers__card-title--loss">Top Losers</h4>
        <!-- ... same table structure, negative class ... -->
      </div>
    </div>
  }
</div>
```

### Day-Change Cell (Stacked Layout)

Each row's rightmost cell shows two lines:
```
  +$660.00    ← absolute impact in reporting currency (or native day change in % mode)
  +1.69%      ← percentage change
```

Both lines colored green (positive) or red (negative). The top line shows the primary metric for the active mode:
- **Impact mode:** `dayChangeImpactReporting` (reporting currency)
- **Percentage mode:** `dayChangePercent`

The bottom line always shows the complementary metric.

---

## 7. CSS Layout

```scss
.movers {
  // No extra card wrapper — inherits detailed-view spacing

  &__header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 20px;
  }

  &__title {
    font-size: 18px;
    font-weight: 700;
    color: var(--text-primary);
  }

  // Segmented toggle (matches transaction-history filter pattern)
  &__toggle {
    display: flex;
    gap: 4px;
    background: var(--bg-primary);
    border-radius: 8px;
    padding: 3px;
  }

  &__toggle-btn {
    padding: 6px 14px;
    border-radius: 6px;
    border: none;
    background: transparent;
    color: var(--text-muted);
    font-size: 13px;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.15s ease;

    &--active {
      background: var(--accent);
      color: var(--bg-primary);
    }
  }

  // 50/50 Grid
  &__grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 16px;

    @media (max-width: 768px) {
      grid-template-columns: 1fr;
    }
  }

  // Card (institutional table container)
  &__card {
    background: var(--bg-secondary);
    border-radius: 14px;
    border: 1px solid var(--border-default);
    box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.04),
                0 4px 24px rgba(0, 0, 0, 0.3);
    padding: 20px;
  }

  // Table
  &__table {
    width: 100%;
    border-collapse: collapse;
  }

  &__row {
    &:hover { background: rgba(20, 184, 166, 0.04); }
  }

  // Avatar
  &__avatar {
    width: 36px;
    height: 36px;
    border-radius: 8px;
    background: linear-gradient(135deg, var(--accent), var(--accent-hover));
    display: flex;
    align-items: center;
    justify-content: center;
    font-weight: 700;
    font-size: 14px;
    color: white;
  }

  // Name cell (stacked ticker + company)
  &__name-cell {
    display: flex;
    flex-direction: column;
    gap: 2px;
    padding: 10px 12px;
  }

  &__ticker { font-weight: 600; font-size: 14px; color: var(--text-primary); }
  &__company { font-size: 12px; color: var(--text-muted); }

  // Change cell (stacked absolute + percent, right-aligned)
  &__change-cell {
    text-align: right;
    padding: 10px 0;
    font-variant-numeric: tabular-nums;
    font-family: 'IBM Plex Mono', monospace;

    &.positive { color: var(--color-positive); }
    &.negative { color: var(--color-negative); }
  }

  &__change-amount {
    display: block;
    font-size: 14px;
    font-weight: 600;
  }

  &__change-pct {
    display: block;
    font-size: 12px;
    opacity: 0.8;
  }
}
```

### Avatar Fallback Chain

1. **CSS gradient avatar** with first letter of ticker (default, always works)
2. No external image sources — keeps the component self-contained and avoids CORS/404 issues

---

## 8. Edge Cases

| Scenario | Behavior |
|----------|----------|
| User has 0 portfolios | Empty response, all 4 arrays = `[]`. Frontend shows "No movers data available" |
| User has 1 holding | Single item appears in both gainers and losers if it moved. If 0 change, it appears in both with 0.00% |
| Weekend/holiday | All day changes ≈ 0.00. Lists populated with 0-change items |
| FX rate unavailable | Security excluded from impact lists, included in percent lists (% is currency-neutral) |
| Security with no price data | Skipped entirely (no currentPrice or previousClose) |
| Same security across 3 portfolios | Quantities summed; single row in output |
| `excludedFromCalculations = true` | Filtered out before aggregation |
| Override pricing listing | `getEffectivePricingListing()` correctly routes to override symbol's listing |

---

## 9. Files to Create/Modify

### New Files (8)

| # | Path | Description |
|---|------|-------------|
| 1 | `portfolio-optimizer-backend/api/src/main/java/com/portfolio/tracker/api/dto/MoverItemDto.java` | Per-security DTO |
| 2 | `portfolio-optimizer-backend/api/src/main/java/com/portfolio/tracker/api/dto/MoversResponseDto.java` | Response wrapper DTO |
| 3 | `portfolio-optimizer-backend/api/src/main/java/com/portfolio/tracker/api/service/MoversService.java` | Aggregation service |
| 4 | `portfolio-optimizer-backend/api/src/main/java/com/portfolio/tracker/api/controller/MoversController.java` | REST endpoint |
| 5 | `portfolio-optimizer-frontend/src/app/portfolio/detailed-view/portfolio-movers/movers.models.ts` | TS interfaces |
| 6 | `portfolio-optimizer-frontend/src/app/portfolio/detailed-view/portfolio-movers/portfolio-movers.component.ts` | Component |
| 7 | `portfolio-optimizer-frontend/src/app/portfolio/detailed-view/portfolio-movers/portfolio-movers.component.html` | Template |
| 8 | `portfolio-optimizer-frontend/src/app/portfolio/detailed-view/portfolio-movers/portfolio-movers.component.scss` | Styles |

### Modified Files (3)

| # | Path | Change |
|---|------|--------|
| 1 | `portfolio-optimizer-frontend/src/app/services/api.service.ts` | Add `getMovers()` method |
| 2 | `portfolio-optimizer-frontend/src/app/portfolio/detailed-view/detailed-view.component.ts` | Import `PortfolioMoversComponent` |
| 3 | `portfolio-optimizer-frontend/src/app/portfolio/detailed-view/detailed-view.component.html` | Inject `<app-portfolio-movers>` below existing empty state in `@else` block |
