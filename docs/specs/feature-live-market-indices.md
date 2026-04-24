# Feature Spec: Live Market Indices Polling & Flash Highlights

**Status:** Draft
**Date:** 2026-04-21
**Depends on:** Existing `MarketIndexRefreshJob` (jobs module), Redis cache `marketIndexes` from `RedisConfig`

---

## 1. Problem

The top-bar `MarketIndexesComponent` loads market indices once via `/api/market-indexes` on component init and stays static for the entire session. Users have no visual signal that the numbers are current, and the existing endpoint routes through the full `MarketIndexService` / `MarketIndexClient` stack — which today relies on the cache but is not contractually bound to, and could regress to synchronous external calls on the user-facing read path.

We want the top-bar to feel **live without being heavy**:

- A 3-minute poll cadence (aligns with the 5-minute cache refresh without drifting past it).
- A subtle color flash on the value whenever a specific index moves.
- Zero horizontal layout jitter during updates.
- A read-path guarantee that each poll costs exactly one Redis `GET` — no DB, no HTTP to Yahoo, no fallback refresh.

---

## 2. Design Overview

```
            WRITE PATH (unchanged, every 5 min)              READ PATH (new, every 3 min per client)
  ────────────────────────────────────────────        ─────────────────────────────────────────────
  MarketIndexRefreshJob @Scheduled                    Browser timer(0, 180_000)
        │ cron "0 0/5 * * * *"                                │
        ▼                                                     ▼
  MarketIndexClient → external API                    GET /api/markets/indices/live
        │                                                     │
        ▼                                                     ▼
  cacheManager.getCache("marketIndexes")              MarketIndicesLiveController
        .put("all", List<MarketIndexDto>)             cacheManager.getCache("marketIndexes")
                                                            .get("all", List.class)
                                                              │
                                                              ▼  ← O(1), no DB, no external call
                                                      List<MarketIndexDto> (or [] on cache miss)
                                                              │
                                                              ▼
                                                      MarketIndexesComponent
                                                        diff vs current signal →
                                                        flashMap{symbol: 'up'|'down'}
                                                        → 500ms CSS class → clear
```

---

## 3. Backend

### 3.1 New endpoint — `GET /api/markets/indices/live`

**File:** `portfolio-optimizer-backend/api/src/main/java/com/portfolio/tracker/api/controller/MarketIndicesLiveController.java`

```java
package com.portfolio.tracker.api.controller;

import com.portfolio.tracker.core.dto.MarketIndexDto;
import org.springframework.cache.Cache;
import org.springframework.cache.CacheManager;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

@RestController
@RequestMapping("/api/markets/indices")
public class MarketIndicesLiveController {

    private final CacheManager cacheManager;

    public MarketIndicesLiveController(CacheManager cacheManager) {
        this.cacheManager = cacheManager;
    }

    @GetMapping("/live")
    public ResponseEntity<List<MarketIndexDto>> live() {
        Cache cache = cacheManager.getCache("marketIndexes");
        if (cache == null) {
            return ResponseEntity.ok(List.of());
        }
        @SuppressWarnings("unchecked")
        List<MarketIndexDto> cached = cache.get("all", List.class);
        return ResponseEntity.ok(cached != null ? cached : List.of());
    }
}
```

**Contract:**
- 200 OK with a (possibly empty) JSON array of `MarketIndexDto`.
- Empty array iff the cache is cold (not yet primed by `MarketIndexRefreshJob`) or expired.
- Never triggers a refresh, never queries the database, never calls an external API.

### 3.2 DTO (reused as-is)

**File:** `portfolio-optimizer-backend/core/src/main/java/com/portfolio/tracker/core/dto/MarketIndexDto.java`

```
symbol          : String
name            : String
currentValue    : BigDecimal
changeAmount    : BigDecimal
changePercent   : BigDecimal
currency        : String
```

### 3.3 Caching (reused as-is)

- Cache name: `marketIndexes`, key `"all"` (see `api/.../config/RedisConfig.java`).
- TTL: 10 minutes (2× refresh interval buffer).
- Writer: `MarketIndexRefreshJob` in the `jobs` module, cron `0 0/5 * * * *`.

### 3.4 Security

`SecurityConfig` terminates with `.anyRequest().authenticated()`. `/api/markets/indices/**` has no explicit public matcher, so the new endpoint is **authenticated** — matching the existing `/api/market-indexes` posture used by the logged-in top-bar. No `SecurityConfig` change.

### 3.5 Tests

**File:** `api/src/test/java/com/portfolio/tracker/api/controller/MarketIndicesLiveControllerTest.java`

`@WebMvcTest(MarketIndicesLiveController.class)` with a mocked `CacheManager`:

- Cache populated → 200 + JSON array with fields mapped from `MarketIndexDto`.
- Cache returns `null` for key `"all"` → 200 + `[]`.
- `cacheManager.getCache("marketIndexes")` returns `null` (unconfigured) → 200 + `[]`.

No Testcontainers needed — pure cache read, no DB, no WireMock.

---

## 4. Frontend

### 4.1 `ApiService` — new method

**File:** `portfolio-optimizer-frontend/src/app/services/api.service.ts`

```ts
getLiveMarketIndices(): Observable<MarketIndex[]> {
  return this.http.get<MarketIndex[]>(
    `${this.apiUrl}/markets/indices/live`,
    { headers: this.getHeaders() }
  );
}
```

Reuses `environment.apiUrl` and the existing auth-header helper.

### 4.2 `MarketIndexesComponent` — polling + diffing

**File:** `portfolio-optimizer-frontend/src/app/shared/market-indexes/market-indexes.component.ts`

```ts
import { ChangeDetectionStrategy, Component, DestroyRef, OnInit, inject, signal } from '@angular/core';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { switchMap, timer } from 'rxjs';
import { ApiService } from '../../services/api.service';
import type { MarketIndex } from './market-indexes.models';
import { IndexCardComponent } from './index-card/index-card.component';

@Component({
  selector: 'app-market-indexes',
  standalone: true,
  imports: [IndexCardComponent],
  changeDetection: ChangeDetectionStrategy.OnPush,
  templateUrl: './market-indexes.component.html',
  styleUrl: './market-indexes.component.scss'
})
export class MarketIndexesComponent implements OnInit {
  readonly indexes = signal<MarketIndex[]>([]);
  readonly loading = signal(true);
  readonly error = signal(false);
  readonly flashMap = signal<Record<string, 'up' | 'down' | undefined>>({});

  private readonly api = inject(ApiService);
  private readonly destroyRef = inject(DestroyRef);

  private readonly POLL_MS = 180_000;
  private readonly FLASH_MS = 500;

  ngOnInit(): void {
    timer(0, this.POLL_MS).pipe(
      switchMap(() => this.api.getLiveMarketIndices()),
      takeUntilDestroyed(this.destroyRef)
    ).subscribe({
      next: (next) => this.applyUpdate(next),
      error: () => {
        this.loading.set(false);
        if (this.indexes().length === 0) this.error.set(true);
      }
    });
  }

  private applyUpdate(next: MarketIndex[]): void {
    const prev = this.indexes();
    const prevBySymbol = new Map(prev.map(i => [i.symbol, i]));
    const flashes: Record<string, 'up' | 'down' | undefined> = {};

    for (const n of next) {
      const p = prevBySymbol.get(n.symbol);
      if (p && n.currentValue !== p.currentValue) {
        flashes[n.symbol] = n.currentValue > p.currentValue ? 'up' : 'down';
      }
    }

    this.indexes.set(next);
    this.loading.set(false);
    this.error.set(false);

    if (Object.keys(flashes).length > 0) {
      this.flashMap.set(flashes);
      setTimeout(() => this.flashMap.set({}), this.FLASH_MS);
    }
  }
}
```

**Key properties:**
- `timer(0, 180_000)` fires immediately, then every 3 minutes.
- `switchMap` cancels any in-flight request when the next tick fires.
- `takeUntilDestroyed(destroyRef)` avoids leaks without a manual `Subscription` field.
- Errors during polling do **not** clear existing indices — stale data stays visible; `error` signal only flips if we've never received data.

### 4.3 Template pass-through

**File:** `portfolio-optimizer-frontend/src/app/shared/market-indexes/market-indexes.component.html`

```html
@if (!loading() && !error() && indexes().length) {
  <div class="ticker-static">
    @for (index of indexes(); track index.symbol) {
      <app-index-card [index]="index" [flash]="flashMap()[index.symbol]" />
    }
  </div>
} @else if (loading()) {
  <div class="ticker-static">
    @for (i of [1,2,3,4,5]; track i) {
      <div class="ticker-skeleton"></div>
    }
  </div>
}
```

### 4.4 `IndexCardComponent` — consume flash

**File:** `portfolio-optimizer-frontend/src/app/shared/market-indexes/index-card/index-card.component.ts`

```ts
@Input() flash: 'up' | 'down' | undefined;
```

**Template (`index-card.component.html`)** — bind class on the value container:

```html
<span class="index-card__value"
      [class.flash-up]="flash === 'up'"
      [class.flash-down]="flash === 'down'">
  {{ index.currentValue | number:'1.2-2' }}
</span>
```

### 4.5 Styling — flash + jitter guard

**File:** `portfolio-optimizer-frontend/src/app/shared/market-indexes/index-card/index-card.component.scss`

`font-variant-numeric: tabular-nums` is already applied to `.index-card__value` and `.index-card__change`, which locks digit width. Add flash classes that only change paint (not layout):

```scss
.index-card__value {
  border-radius: 3px;
  padding: 1px 4px;
  margin: -1px -4px; // cancel padding so layout width is unchanged
  transition: background-color 160ms ease-out;

  &.flash-up   { background-color: rgba(74, 222, 128, 0.18); }  // muted green
  &.flash-down { background-color: rgba(248, 113, 113, 0.18); } // muted red
}
```

Colors match the existing `#4ade80` / `#f87171` palette used for `__change--positive/negative`. Alpha 0.18 keeps them subtle on both dark and light themes.

---

## 5. Verification

### Backend

1. `cd "portfolio-optimizer-backend" && ./gradlew :api:test --tests "*MarketIndicesLiveControllerTest"` → green.
2. Local run: `./gradlew :api:bootRun`; once `MarketIndexRefreshJob` has primed the cache:
   ```bash
   curl -H "Authorization: Bearer <jwt>" http://localhost:8080/api/markets/indices/live
   ```
   → 200 + JSON array (same shape as `/api/market-indexes`). Empty array on cold cache.
3. Inspect logs: no DB or external HTTP for this path — cache hit only.

### Frontend

1. `cd "portfolio-optimizer-frontend" && npm test -- --include='**/market-indexes.component.spec.ts'` → green.
2. `npm start`, log in, watch the top-bar:
   - Indices appear on load.
   - Network tab: `/api/markets/indices/live` every ~3 minutes.
   - Force a flash by mutating the Redis cache value between ticks (`redis-cli`) or stubbing the service in devtools. Confirm the value briefly flashes muted green/red for ~500 ms.
3. Jitter check: shrink the viewport; cycle digit-count-changing values (4999.99 ↔ 5000.01). No horizontal shift.
4. Theme check: both flash colors legible in dark and light themes.
