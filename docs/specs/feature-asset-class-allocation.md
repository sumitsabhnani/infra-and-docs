# Feature Spec: Asset Class Allocation Widget

**Status:** Draft
**Date:** 2026-04-12
**Depends on:** ADR-001 (tech stack), ADR-002 (SnapTrade ingestion), ADR-005 (security identity model)

---

## 1. Problem

The dashboard shows per-holding and per-group metrics but has no view of portfolio-wide asset class distribution (Equity, Debt, Gold, Real Estate, Cash). Users cannot see whether their actual allocation drifts from their target allocation, which is the most fundamental portfolio health indicator for a retail investor.

**Constraint (ADR-001):** Heavy calculations must never run in the API read path. The API must serve pre-computed data from cache or materialized tables.

---

## 2. Design Overview

```
                  WRITE PATH (async)                         READ PATH (sync, fast)
  ──────────────────────────────────                 ──────────────────────────────────
  SnapTrade sync completes                           GET /api/v1/portfolio/asset-allocation
        │                                                       │
        ▼                                                       ▼
  BrokerSyncCompletedEvent                           AssetAllocationController
        │                                              reads user_asset_exposures
  Manual asset created/updated/deleted                 reads user_asset_class_targets
        │                                              joins + returns DTO
        ▼                                                       │
  AssetExposureRecalculationListener                            ▼
        │  @TransactionalEventListener                 AssetClassExposureDto
        │  @Async("backgroundJobExecutor")                (current vs target vs max)
        ▼
  AssetExposureAggregationService
        │  1. load all holdings for user
        │  2. load all manual_assets for user
        │  3. resolve asset class per holding
        │  4. convert to reporting currency (FX)
        │  5. aggregate by asset_class
        ▼
  UPSERT → user_asset_exposures
```

---

## 3. Database

### 3.1 `user_asset_exposures` — Cached aggregated totals

Stores the most recent pre-computed, base-currency-denominated total per asset class per user. This is the **sole data source for the read path**.

```sql
-- V20260413120000__CreateUserAssetExposures.sql

CREATE TABLE IF NOT EXISTS user_asset_exposures (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    asset_class     VARCHAR(32)  NOT NULL,   -- EQUITY, DEBT, GOLD, REAL_ESTATE, CASH, OTHER
    total_value     NUMERIC(20, 8) NOT NULL,  -- in user's reporting_currency
    currency        VARCHAR(3)   NOT NULL,    -- always = user.reporting_currency
    weight_pct      NUMERIC(7, 4) NOT NULL,   -- 0.0000 – 100.0000
    computed_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT uq_user_asset_exposure UNIQUE (user_id, asset_class)
);

CREATE INDEX IF NOT EXISTS idx_user_asset_exposures_user
    ON user_asset_exposures(user_id);
```

**Key design choices:**

| Column | Why |
|--------|-----|
| `total_value` NUMERIC(20,8) | BigDecimal in Java. Financial correctness — never float/double (ADR-001). |
| `weight_pct` NUMERIC(7,4) | Pre-computed percentage avoids division in the read path. Four decimal places for precision (e.g., 33.3333%). |
| `currency` | Denormalized from `user.reporting_currency`. Makes the row self-describing. |
| `computed_at` | Staleness indicator — the frontend can show "as of 2 min ago" if desired. |
| `UNIQUE (user_id, asset_class)` | Enables idempotent `ON CONFLICT` upserts during recalculation. |

**Upsert pattern:**

```sql
INSERT INTO user_asset_exposures (user_id, asset_class, total_value, currency, weight_pct, computed_at)
VALUES (?, ?, ?, ?, ?, now())
ON CONFLICT (user_id, asset_class)
DO UPDATE SET total_value = EXCLUDED.total_value,
              currency    = EXCLUDED.currency,
              weight_pct  = EXCLUDED.weight_pct,
              computed_at = now();
```

### 3.2 `user_asset_class_targets` — User-defined allocation goals

Stores per-asset-class target percentage and maximum allowed drift. Only populated when the user explicitly configures targets (opt-in via `allocationTrackingEnabled` on the `users` table, which already exists).

```sql
-- V20260413130000__CreateUserAssetClassTargets.sql

CREATE TABLE IF NOT EXISTS user_asset_class_targets (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    asset_class         VARCHAR(32) NOT NULL,
    target_pct          NUMERIC(5, 2) NOT NULL,  -- 0.00 – 100.00
    max_drift_pct       NUMERIC(5, 2),            -- nullable = no ceiling
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_user_asset_target UNIQUE (user_id, asset_class),
    CONSTRAINT chk_target_range CHECK (target_pct >= 0 AND target_pct <= 100),
    CONSTRAINT chk_drift_range  CHECK (max_drift_pct IS NULL OR (max_drift_pct >= 0 AND max_drift_pct <= 100))
);

CREATE INDEX IF NOT EXISTS idx_user_asset_class_targets_user
    ON user_asset_class_targets(user_id);
```

**Notes:**
- `max_drift_pct` is the **absolute ceiling** — not the delta from target. If target is 30% and max_drift is 40%, a warning fires when the actual allocation exceeds 40%.
- `target_pct` values across all asset classes for a user should sum to 100, but this is enforced in application code (not a DB constraint) to allow incremental configuration.
- Nullable `max_drift_pct` means "no warning threshold configured for this class."

### 3.3 Asset Class Enum

Canonical values used in both tables:

```
EQUITY, DEBT, GOLD, REAL_ESTATE, CASH, CRYPTO, OTHER
```

- Holdings derive their asset class from `security_master.security_type` via a mapping (see Section 4.2).
- Manual assets already store `asset_class` directly (existing `manual_asset` table).

---

## 4. Backend

### 4.1 Event-Driven Aggregation (Write Path)

#### 4.1.1 New Event: `BrokerSyncCompletedEvent`

Published by `BrokerSyncService` when a full sync cycle completes (connection status transitions to `ACTIVE`, sync_phase to `COMPLETED`). If this event already exists in the sync flow, reuse it.

```java
// core/src/main/java/com/portfolio/tracker/core/event/BrokerSyncCompletedEvent.java
public class BrokerSyncCompletedEvent extends ApplicationEvent {
    private final UUID userId;
    private final UUID connectionId;
    // ...
}
```

#### 4.1.2 New Event: `ManualAssetChangedEvent`

Published by `ManualAssetService` (AFTER_COMMIT) when a manual asset is created, updated, or deleted.

```java
// core/src/main/java/com/portfolio/tracker/core/event/ManualAssetChangedEvent.java
public class ManualAssetChangedEvent extends ApplicationEvent {
    private final UUID userId;
    // ...
}
```

#### 4.1.3 Listener: `AssetExposureRecalculationListener`

Lives in the `api` module (it needs access to orchestration services and the full Spring context).

```java
// api/src/main/java/com/portfolio/tracker/api/listener/AssetExposureRecalculationListener.java

@Component
public class AssetExposureRecalculationListener {

    @Async("backgroundJobExecutor")
    @TransactionalEventListener(phase = TransactionPhase.AFTER_COMMIT)
    public void onBrokerSyncCompleted(BrokerSyncCompletedEvent event) {
        assetExposureAggregationService.recalculate(event.getUserId());
    }

    @Async("backgroundJobExecutor")
    @TransactionalEventListener(phase = TransactionPhase.AFTER_COMMIT)
    public void onManualAssetChanged(ManualAssetChangedEvent event) {
        assetExposureAggregationService.recalculate(event.getUserId());
    }
}
```

**Pattern alignment:** Matches `InitialBrokerSyncListener` — `@TransactionalEventListener(AFTER_COMMIT)` + `@Async("backgroundJobExecutor")`.

#### 4.1.4 Service: `AssetExposureAggregationService`

Lives in `core` module (pure domain logic, no HTTP dependencies).

```java
// core/src/main/java/com/portfolio/tracker/core/service/AssetExposureAggregationService.java

@Service
public class AssetExposureAggregationService {

    @Transactional
    public void recalculate(UUID userId) {
        // 1. Load user's reporting currency
        Currency reportingCurrency = userRepository.findById(userId)
            .orElseThrow().getReportingCurrency();

        // 2. Load all active holdings across all user's portfolios
        List<Holding> holdings = holdingRepository
            .findAllByPortfolioUserIdAndExcludeFromCalculationsFalse(userId);

        // 3. Load all manual assets across all user's portfolios
        List<ManualAsset> manualAssets = manualAssetRepository
            .findAllByPortfolioUserIdAndExcludedFromCalculationsFalse(userId);

        // 4. For each holding: resolve asset class from security_master.security_type
        //    Map security_type → asset_class using SecurityTypeToAssetClassMapper
        //    Get current value = quantity × latest_price
        //    Convert to reporting currency using ExchangeRateService

        // 5. For each manual asset: asset_class is already on the row
        //    Convert amount to reporting currency using ExchangeRateService

        // 6. Aggregate by asset_class → Map<AssetClass, BigDecimal>
        // 7. Compute total portfolio value, then weight_pct = (class_value / total) * 100
        // 8. Upsert into user_asset_exposures (ON CONFLICT DO UPDATE)
        // 9. Delete any rows for asset classes that dropped to zero
    }
}
```

#### 4.1.5 Mapper: `SecurityTypeToAssetClassMapper`

Maps `security_master.security_type` to the canonical asset class:

| security_type | asset_class |
|---------------|-------------|
| EQUITY        | EQUITY      |
| ETF           | EQUITY      |
| MUTUAL_FUND   | EQUITY (default, overrideable) |
| BOND          | DEBT        |
| CRYPTO        | CRYPTO      |
| *(unknown)*   | OTHER       |

This is a static utility — no Spring bean needed. If a security's asset class should differ from the default (e.g., a debt ETF), a future `asset_class_override` column on `security_master` can handle it.

### 4.2 API Read Path

#### 4.2.1 Controller: `AssetAllocationController`

```java
// api/src/main/java/com/portfolio/tracker/api/controller/AssetAllocationController.java

@RestController
@RequestMapping("/api/v1/portfolio")
@RequiredArgsConstructor
public class AssetAllocationController {

    private final AssetAllocationReadService assetAllocationReadService;

    @GetMapping("/asset-allocation")
    public ResponseEntity<AssetAllocationResponseDto> getAssetAllocation(
            @AuthenticationPrincipal User user) {
        return ResponseEntity.ok(
            assetAllocationReadService.getForUser(user.getId(), user.isAllocationTrackingEnabled())
        );
    }
}
```

**No computation here.** The controller reads pre-aggregated rows and joins them with targets.

#### 4.2.2 Read Service: `AssetAllocationReadService`

```java
// api/src/main/java/com/portfolio/tracker/api/service/AssetAllocationReadService.java

@Service
@RequiredArgsConstructor
public class AssetAllocationReadService {

    public AssetAllocationResponseDto getForUser(UUID userId, boolean allocationTrackingEnabled) {
        List<UserAssetExposure> exposures = exposureRepository.findAllByUserId(userId);
        List<UserAssetClassTarget> targets = allocationTrackingEnabled
            ? targetRepository.findAllByUserId(userId)
            : List.of();

        // Build map: asset_class → target/max
        Map<String, UserAssetClassTarget> targetMap = targets.stream()
            .collect(toMap(UserAssetClassTarget::getAssetClass, identity()));

        List<AssetClassExposureDto> slices = exposures.stream().map(exp -> {
            UserAssetClassTarget target = targetMap.get(exp.getAssetClass());
            return AssetClassExposureDto.builder()
                .assetClass(exp.getAssetClass())
                .totalValue(exp.getTotalValue())
                .currency(exp.getCurrency())
                .weightPct(exp.getWeightPct())
                .targetPct(target != null ? target.getTargetPct() : null)
                .maxDriftPct(target != null ? target.getMaxDriftPct() : null)
                .exceedsMax(target != null && target.getMaxDriftPct() != null
                    && exp.getWeightPct().compareTo(target.getMaxDriftPct()) > 0)
                .build();
        }).toList();

        return AssetAllocationResponseDto.builder()
            .slices(slices)
            .allocationTrackingEnabled(allocationTrackingEnabled)
            .computedAt(exposures.isEmpty() ? null : exposures.get(0).getComputedAt())
            .build();
    }
}
```

#### 4.2.3 DTOs

```java
// core/src/main/java/com/portfolio/tracker/core/dto/AssetAllocationResponseDto.java

@Data @Builder @NoArgsConstructor @AllArgsConstructor
public class AssetAllocationResponseDto {
    private List<AssetClassExposureDto> slices;
    private boolean allocationTrackingEnabled;
    private Instant computedAt;
}
```

```java
// core/src/main/java/com/portfolio/tracker/core/dto/AssetClassExposureDto.java

@Data @Builder @NoArgsConstructor @AllArgsConstructor
public class AssetClassExposureDto {
    private String assetClass;        // "EQUITY", "DEBT", "GOLD", etc.
    private BigDecimal totalValue;    // in reporting currency
    private String currency;          // e.g., "USD", "INR"
    private BigDecimal weightPct;     // 0.00 – 100.00
    private BigDecimal targetPct;     // nullable — only if tracking enabled + target set
    private BigDecimal maxDriftPct;   // nullable
    private boolean exceedsMax;       // pre-computed flag for frontend convenience
}
```

#### 4.2.4 Targets CRUD Endpoint

```java
// api/src/main/java/com/portfolio/tracker/api/controller/AssetAllocationController.java

@PutMapping("/asset-allocation/targets")
public ResponseEntity<List<AssetClassTargetDto>> updateTargets(
        @AuthenticationPrincipal User user,
        @Valid @RequestBody List<AssetClassTargetDto> targets) {
    return ResponseEntity.ok(
        assetAllocationTargetService.saveTargets(user.getId(), targets)
    );
}

@GetMapping("/asset-allocation/targets")
public ResponseEntity<List<AssetClassTargetDto>> getTargets(
        @AuthenticationPrincipal User user) {
    return ResponseEntity.ok(
        assetAllocationTargetService.getTargets(user.getId())
    );
}
```

### 4.3 Module Boundaries

| Class | Module | Rationale |
|-------|--------|-----------|
| `UserAssetExposure` (entity) | core | Domain entity |
| `UserAssetClassTarget` (entity) | core | Domain entity |
| `UserAssetExposureRepository` | core | JPA repository |
| `UserAssetClassTargetRepository` | core | JPA repository |
| `AssetExposureAggregationService` | core | Pure domain logic (no HTTP) |
| `SecurityTypeToAssetClassMapper` | core | Static utility |
| `AssetClassExposureDto` | core | Shared DTO |
| `AssetAllocationResponseDto` | core | Shared DTO |
| `BrokerSyncCompletedEvent` | core | Domain event (consumed by api + jobs) |
| `ManualAssetChangedEvent` | core | Domain event |
| `AssetAllocationController` | api | REST endpoint |
| `AssetAllocationReadService` | api | Read-path orchestration |
| `AssetExposureRecalculationListener` | api | Async event listener |

---

## 5. Frontend (Angular 17)

### 5.1 Component: `AssetAllocationWidgetComponent`

**Location:** `src/app/dashboard/asset-allocation-widget/`

Standalone component, `OnPush`, rendered as a card on the dashboard.

#### 5.1.1 State (Signals)

```typescript
// asset-allocation-widget.component.ts

readonly loading = signal(true);
readonly error = signal<string | null>(null);
readonly allocation = signal<AssetAllocationResponse | null>(null);

readonly allocationTrackingEnabled = computed(() =>
  this.allocation()?.allocationTrackingEnabled ?? false
);

readonly hasExceeded = computed(() =>
  this.allocation()?.slices.some(s => s.exceedsMax) ?? false
);
```

#### 5.1.2 Data Fetching

```typescript
ngOnInit(): void {
  this.api.getAssetAllocation()
    .pipe(finalize(() => this.loading.set(false)))
    .subscribe({
      next: (data) => this.allocation.set(data),
      error: (err) => this.error.set('Failed to load allocation data'),
    });
}
```

**ApiService addition:**

```typescript
getAssetAllocation(): Observable<AssetAllocationResponse> {
  return this.http.get<AssetAllocationResponse>(`${this.apiUrl}/v1/portfolio/asset-allocation`);
}
```

#### 5.1.3 Template Structure

```html
<div class="allocation-widget dashboard-card">
  <h3 class="allocation-widget__title">Asset Allocation</h3>

  @if (loading()) {
    <div class="allocation-widget__skeleton">
      <!-- skeleton loader matching donut shape -->
    </div>
  } @else if (error()) {
    <div class="allocation-widget__error">{{ error() }}</div>
  } @else if (allocation(); as alloc) {
    <div class="allocation-widget__chart">
      <canvas #donutCanvas></canvas>
    </div>

    <ul class="allocation-widget__legend">
      @for (slice of alloc.slices; track slice.assetClass) {
        <li class="allocation-widget__legend-item"
            [class.allocation-widget__legend-item--exceeded]="
              allocationTrackingEnabled() && slice.exceedsMax
            ">
          <span class="allocation-widget__dot"
                [style.background-color]="colorFor(slice.assetClass)"></span>
          <span class="allocation-widget__label">{{ slice.assetClass }}</span>
          <span class="allocation-widget__value">{{ slice.weightPct | number:'1.1-1' }}%</span>

          @if (allocationTrackingEnabled() && slice.targetPct != null) {
            <span class="allocation-widget__target">
              target {{ slice.targetPct | number:'1.0-0' }}%
            </span>
          }

          @if (allocationTrackingEnabled() && slice.exceedsMax) {
            <span class="allocation-widget__warning">
              exceeds {{ slice.maxDriftPct | number:'1.0-0' }}% max
            </span>
          }
        </li>
      }
    </ul>

    @if (alloc.computedAt) {
      <p class="allocation-widget__timestamp">
        as of {{ alloc.computedAt | date:'short' }}
      </p>
    }
  }
</div>
```

#### 5.1.4 Donut Chart (Chart.js)

Uses Chart.js directly (same pattern as `TickerPerformanceChartComponent`):

```typescript
private renderChart(slices: AssetClassExposureDto[]): void {
  if (this.chart) this.chart.destroy();

  this.chart = new Chart(this.donutCanvas.nativeElement, {
    type: 'doughnut',
    data: {
      labels: slices.map(s => s.assetClass),
      datasets: [{
        data: slices.map(s => Number(s.weightPct)),
        backgroundColor: slices.map(s => this.colorFor(s.assetClass)),
        borderColor: 'var(--bg-secondary)',
        borderWidth: 2,
      }],
    },
    options: {
      responsive: true,
      cutout: '65%',
      plugins: {
        legend: { display: false },  // custom legend via HTML (above)
        tooltip: {
          callbacks: {
            label: (ctx) => `${ctx.label}: ${ctx.parsed}%`,
          },
        },
      },
    },
  });
}
```

**Color Palette** (aligned with design system):

| Asset Class | Color | Rationale |
|-------------|-------|-----------|
| EQUITY      | `#14b8a6` (accent/teal) | Primary investment type |
| DEBT        | `#58a6ff` (info/blue) | Stable, conservative |
| GOLD        | `#d29922` (warning/amber) | Precious metal convention |
| REAL_ESTATE | `#a371f7` (purple) | Distinct from financial assets |
| CASH        | `#768390` (text-muted) | Neutral, low-yield |
| CRYPTO      | `#f778ba` (pink) | High-volatility, distinct |
| OTHER       | `#444c56` (text-faint) | Catch-all |

#### 5.1.5 Conditional Warning Styles

When `allocationTrackingEnabled` is true and a slice's `exceedsMax` flag is set:

```scss
.allocation-widget__legend-item--exceeded {
  border-left: 3px solid var(--color-negative);
  padding-left: 8px;
  background: rgba(229, 83, 75, 0.06);
  border-radius: 4px;

  .allocation-widget__value {
    color: var(--color-negative);
    font-weight: 600;
  }
}

.allocation-widget__warning {
  color: var(--color-negative);
  font-size: 0.75rem;
  font-weight: 500;
}
```

The donut chart slice for an exceeded asset class gets a highlighted border ring:

```typescript
borderColor: slices.map(s =>
  this.allocationTrackingEnabled() && s.exceedsMax
    ? '#e5534b'  // --color-negative
    : 'var(--bg-secondary)'
),
borderWidth: slices.map(s =>
  this.allocationTrackingEnabled() && s.exceedsMax ? 4 : 2
),
```

### 5.2 Dashboard Integration

Add the widget to `DashboardComponent`:

```typescript
// dashboard.component.ts imports
import { AssetAllocationWidgetComponent } from './asset-allocation-widget/asset-allocation-widget.component';

// In template, after the portfolio overview cards:
<app-asset-allocation-widget />
```

### 5.3 TypeScript Interfaces

```typescript
// src/app/models/asset-allocation.model.ts

export interface AssetAllocationResponse {
  slices: AssetClassExposureDto[];
  allocationTrackingEnabled: boolean;
  computedAt: string | null;  // ISO-8601
}

export interface AssetClassExposureDto {
  assetClass: string;
  totalValue: number;
  currency: string;
  weightPct: number;
  targetPct: number | null;
  maxDriftPct: number | null;
  exceedsMax: boolean;
}
```

---

## 6. Data Flow Summary

```
┌─────────────────────────────────────────────────────────────────────┐
│  TRIGGERS                                                           │
│                                                                     │
│  1. SnapTrade sync completes → BrokerSyncCompletedEvent             │
│  2. Manual asset CUD         → ManualAssetChangedEvent              │
│                                                                     │
│  Both fire AFTER_COMMIT, handled by                                 │
│  AssetExposureRecalculationListener (@Async)                        │
└──────────────────────────┬──────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│  AGGREGATION (AssetExposureAggregationService)                      │
│                                                                     │
│  For user U:                                                        │
│  1. holdings[]  → security_master.security_type → asset_class       │
│     + latest_price × quantity → value (in holding currency)         │
│     + ExchangeRateService → value (in reporting currency)           │
│                                                                     │
│  2. manual_assets[] → asset_class + amount (convert to reporting)   │
│                                                                     │
│  3. GROUP BY asset_class → SUM(value)                               │
│  4. total = SUM(all classes)                                        │
│  5. weight_pct = class_value / total × 100                          │
│  6. UPSERT → user_asset_exposures                                   │
└─────────────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│  READ PATH                                                          │
│                                                                     │
│  GET /api/v1/portfolio/asset-allocation                             │
│    → SELECT * FROM user_asset_exposures WHERE user_id = ?           │
│    → LEFT JOIN user_asset_class_targets (if tracking enabled)       │
│    → Return AssetAllocationResponseDto                              │
│                                                                     │
│  No computation. Two indexed queries. Sub-millisecond.              │
└─────────────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│  FRONTEND                                                           │
│                                                                     │
│  AssetAllocationWidgetComponent                                     │
│    → async load via ApiService                                      │
│    → Chart.js doughnut chart                                        │
│    → @if (allocationTrackingEnabled && slice.exceedsMax)            │
│        → red border, warning text, highlighted legend item          │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 7. Edge Cases

| Scenario | Behavior |
|----------|----------|
| User has no holdings or manual assets | `user_asset_exposures` has zero rows → widget shows empty state: "No assets to display" |
| Holdings exist but no latest price available | Holding value = 0 (excluded from calculation), not an error. `UNRESOLVED` securities are skipped. |
| FX rate unavailable for currency conversion | Log warning, skip that holding. Partial aggregation is better than failure. |
| `allocationTrackingEnabled` = false | Targets not loaded, `exceedsMax` always false, no warning CSS applied. Donut chart still renders. |
| Target percentages don't sum to 100 | Allowed — user may configure targets incrementally. Frontend can show a "targets incomplete" hint. |
| Recalculation triggered mid-recalculation | The `UNIQUE (user_id, asset_class)` constraint + `ON CONFLICT` upsert makes concurrent writes safe. Last writer wins, which is correct since both compute from the same source data. |
| Manual asset deleted (last of its class) | Aggregation produces 0 for that class → DELETE the exposure row (don't leave a zero-value row). |

---

## 8. Future Considerations (Out of Scope)

- **Redis caching of exposures**: Not needed initially. The query is two indexed reads from Postgres. Add a `userAssetExposures` Redis cache (TTL: 5 min, invalidated on recalculation) if latency becomes an issue.
- **Per-portfolio breakdown**: Current design aggregates across all portfolios. A `portfolio_id` filter on the endpoint could be added later.
- **Asset class override on security_master**: For securities where the default mapping is wrong (e.g., a debt ETF classified as EQUITY), add an `asset_class_override` column. Not needed for v1.
- **WebSocket push on recalculation**: After `AssetExposureAggregationService.recalculate()` completes, push a notification to the frontend to refresh. For v1, the widget loads on page navigation.
