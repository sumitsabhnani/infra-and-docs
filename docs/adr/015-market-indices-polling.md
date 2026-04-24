# ADR-015: 3-Minute Polling + Flash Highlights for Live Market Indices

**Status:** Accepted
**Date:** 2026-04-21
**Depends on:** ADR-007 (Redis-first market indices, background-warmed cache)

---

## Context

ADR-007 made the top-bar market indices a pure Redis read: a scheduled job refreshes the `marketIndexes::all` entry every 5 minutes, and the `@Cacheable` controller serves it O(1). But the Angular top-bar still loaded once on session start and stayed frozen for the life of the tab — users had no way to know whether the numbers they were looking at were 10 seconds or 10 hours old.

Requirement: the top-bar must *feel* live — fresh data at a human cadence, with a visual acknowledgement when values actually move — **without** adding server push infrastructure or increasing load on external market data providers.

Options considered:

1. **WebSockets / SSE.** True push, sub-second latency. But requires a stateful push channel (broadcaster, client reconnect logic, per-connection state, backpressure thinking), a second auth path through Caddy, and a fan-out source of index updates — which we don't have; our source is a 5-minute cron job. The latency budget would be wasted and the infra cost is real.
2. **Shorter cache TTL + aggressive client refresh.** Pushes the external-API rate-limit budget problem ADR-007 solved right back onto the hot path if a miss occurs.
3. **Client-side polling of a cache-only endpoint.** The job already refreshes every 5 minutes; the cache is already warm; each poll is a single Redis `GET`. No new moving parts.

---

## Decision

Option 3. Client polls a dedicated **cache-only** endpoint every 3 minutes; any per-index value change produces a transient 500 ms color flash on that value.

### Backend — `GET /api/markets/indices/live`

New lightweight controller (`MarketIndicesLiveController`) that injects `CacheManager` directly and reads `marketIndexes::all`. It does **not** go through `MarketIndexService`, does **not** touch the database, and does **not** call EODHD — on a cache miss it returns `[]` and lets the background job repopulate on its next tick.

We deliberately did **not** extend the existing `/api/market-indexes` controller. That endpoint's contract is "give me the indices"; the new endpoint's contract is "give me the cached copy, or nothing." Keeping them separate prevents a future refactor from accidentally reintroducing a read-through external call on the user-facing poll path.

### Frontend — `timer(0, 180_000)` + diff + transient class

`MarketIndexesComponent` replaces its one-shot `ngOnInit` fetch with:

- `timer(0, 180_000)` piped through `switchMap(() => api.getLiveMarketIndices())` and `takeUntilDestroyed(destroyRef)`.
- An `indexes` signal updated on every tick.
- A `flashMap` signal: on each tick the component diffs new values against the previous `indexes` signal, builds `{ [symbol]: 'up' | 'down' }` for changed symbols, and clears the map 500 ms later via `setTimeout`.
- `IndexCardComponent` takes a `flash` input and binds `.flash-up`/`.flash-down` on the value container.

Errors on any tick do not clear existing data — stale-but-visible beats blank-and-confusing. `error` only flips to `true` if the very first load fails.

### Styling — layout stays frozen, paint changes

`.index-card__value` uses `font-variant-numeric: tabular-nums` (already in place) so digit width is fixed. The flash classes add `padding` + a cancelling negative `margin` so the box model is unchanged whether or not the class is applied; only `background-color` animates via a 160 ms transition. Muted green (`rgba(74, 222, 128, 0.18)`) / red (`rgba(248, 113, 113, 0.18)`) — subtle enough to not distract, perceptible enough to register.

---

## Why 3 minutes

The cache refreshes every 5 minutes. At a 3-minute client cadence, two clients polling out-of-phase will always observe the freshest write within ~3 minutes of it happening, and no client goes longer than ~5 minutes without *some* refresh. Shorter cadences waste cache hits without adding freshness; longer cadences risk a client watching a value go stale for close to a full refresh cycle.

---

## Consequences

**Positive**
- Zero new server infrastructure. No WS broker, no SSE endpoint, no connection state.
- Load is bounded and predictable: O(1) Redis reads scale linearly with active tabs × 1/180 s.
- Hot-path guarantee preserved (ADR-007): external market data providers are never contacted by a user-driven request.
- Visual freshness without layout jitter — the box model doesn't shift, only the paint.

**Trade-offs**
- Freshness ceiling is ~3 minutes + cache-refresh lag. Acceptable for display-only indices; not acceptable for anything an order would be placed against.
- Diff is by `currentValue` equality. Two successive equal writes (rare but possible if the market is closed) produce no flash — correct behaviour, but means "no flash" ≠ "no poll."

---

## Out of scope

- True tick-level updates, exchange-direct feeds, or per-ticker price streaming in holdings tables. If/when those are needed, they will get their own ADR and will not reuse this path.
