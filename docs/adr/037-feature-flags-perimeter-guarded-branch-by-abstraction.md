# ADR-037: Feature Flags — Postgres-Backed, Perimeter-Guarded, Branched by Abstraction

**Status:** Accepted
**Date:** 2026-05-08
**Related:** ADR-001 (core stack), ADR-007 (Redis caching), ADR-036 (superuser-gated admin surfaces)

---

## Context

Two operational needs collided: (1) we want to decouple deploys from releases — ship code dark, flip it on later — and (2) we want flags to die on a clock, not accumulate as permanent dead branches. Existing options were inadequate:

- **`@ConditionalOnProperty` / env vars.** Resolved at Spring context startup. Runtime toggling requires a redeploy, which defeats the entire premise.
- **In-memory map seeded from `application.properties`.** Same problem, plus no admin UI; still operator-edits-properties-and-redeploys.
- **External SaaS (LaunchDarkly, Unleash).** Adds a network dependency to the read path, conflicts with our single-origin Caddy posture, and overshoots the scale of one solo operator across three environments.

We also need per-environment isolation (dev/staging/prod toggle independently) without schema gymnastics, since each environment already runs its own Postgres.

A second, equally load-bearing concern is **flag rot**: every codebase that adopts feature flags eventually accumulates inline `if (enabled)` branches scattered across services, which become permanent dead code because nobody knows when it's safe to remove them. The architectural rule has to make retirement easy *and expected*, not optional.

---

## Decision 1: One Row Per Flag in a Per-Environment Postgres Table

`portfolio-optimizer-backend/api/src/main/resources/db/migration/V20260508120000__CreateFeatureFlagTable.sql`:

```sql
CREATE TABLE IF NOT EXISTS feature_flag (
    flag_key      VARCHAR(128) PRIMARY KEY,
    description   VARCHAR(512) NOT NULL DEFAULT '',
    is_enabled    BOOLEAN      NOT NULL DEFAULT FALSE,
    activated_at  TIMESTAMP WITH TIME ZONE,
    created_at    TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);
```

`flag_key` is the primary key — the value referenced from code, never reused. `activated_at` is set only on a `false → true` transition; disabling a flag, or re-enabling an already-on flag, leaves it untouched. This makes "Days Active = `now() - activated_at`" the single retirement signal in the admin UI.

Per-environment isolation is automatic: each environment already points at its own database (`SPRING_DATASOURCE_URL`), so the same migration produces three independent flag tables. No conditionals, no shared schema, no environment-aware code paths.

## Decision 2: Read Path Is Redis-Cached and Fail-Closed

`FeatureFlagService` lives in `core`. Two read methods, both Redis-backed under the dedicated `featureFlags` cache region (`RedisConfig.cacheConfigurations`, `Duration.ofMinutes(5)`):

```java
@Cacheable(value = "featureFlags", key = "#flagKey")
@Transactional(readOnly = true)
public boolean isEnabled(String flagKey) {
    return repository.findById(flagKey).map(FeatureFlag::isEnabled).orElse(false);
}

@Cacheable(value = "featureFlags", key = "'__enabled_keys__'")
@Transactional(readOnly = true)
public List<String> listEnabledKeys() { ... }
```

`isEnabled` returning `false` for unknown keys is the **fail-closed contract**: cache miss → DB miss → `false`. Redis unreachable → DB lookup → `false` for unknown keys. DB unreachable → exception bubbles up. Callers do not override this with permissive defaults.

The 5-minute TTL is a backstop only. Single-instance deploys (today) see no staleness — admin writes evict the entire region. Future multi-instance deploys would see at most 5 minutes of staleness on instances that missed the evict; flags are not safety-critical, so this trade is acceptable.

## Decision 3: Admin Mutations Live Behind `hasRole('SUPERUSER')` and Evict the Whole Cache

`FeatureFlagAdminController` at `/api/v1/admin/features` carries class-level `@PreAuthorize("hasRole('SUPERUSER')")` — same pattern as `SnapTradeAdminController` and `FyersAdminController` (ADR-036). GET/POST/PATCH/DELETE map onto `listAll` / `create` / `setEnabled` / `delete`. Every mutator carries:

```java
@CacheEvict(value = "featureFlags", allEntries = true)
@Transactional
```

Region-wide eviction is deliberately blunt — the cache is small (one entry per flag plus the `__enabled_keys__` list), mutations are rare (admin UI only), and per-key juggling adds bug surface for no measurable win.

`setEnabled` enforces the activation-timestamp invariant explicitly:

```java
boolean transitioningOn = !flag.isEnabled() && enabled;
flag.setEnabled(enabled);
if (transitioningOn) {
    flag.setActivatedAt(OffsetDateTime.now());
}
```

## Decision 4: Public Surface Returns Enabled Keys Only

`FeatureFlagController` at `/api/v1/features` (authenticated by `.anyRequest().authenticated()` in `SecurityConfig`, no role check) exposes `GET /` returning `List<String>` of currently-enabled flag keys. **Disabled flag keys are never returned** — disabled flags often name in-flight features whose existence is not yet public information. The frontend `FeatureFlagService` calls this once on app boot (and again after admin toggles, so the UI surface updates without a reload), stores keys in a `Set<string>` signal, and exposes `isEnabled(key): boolean` to templates.

## Decision 5: The Safe-Rollout Protocol

This is the architectural rule the codebase commits to. It is now in `agent-backend.md`, `agent-frontend.md`, and `SYSTEM_SNAPSHOT.md`.

1. **Guard at the perimeter, never inline.** A new endpoint, a new route, or a new top-level UI surface checks the flag at the entry point — `ResponseStatusException(NOT_FOUND)` in the controller, `CanActivate` guard on the route, single `@if` at the top of the surface. Inline `if (enabled)` deep in services or shared templates is **forbidden** — it's what makes the legacy path uncleanable.
2. **Branch by abstraction for behavior changes.** A flag that swaps existing logic uses Strategy + factory, never inline branches. Backend: extract an interface, keep current code as `Legacy{Name}Impl`, write new code as `V2{Name}Impl`, choose between them in a `@Configuration @Bean` factory that calls `FeatureFlagService.isEnabled(...)` at injection time. Frontend: same shape via a `useFactory` provider in `app.config.ts`. Spring's `@ConditionalOnProperty` is **not** viable — flags are runtime-mutable, not startup-time.
3. **Fail closed.** `isEnabled(key)` returns `false` on missing keys, cache miss, and Redis outage. Don't override.
4. **Retire the flag.** A flag past its rollout window is tech debt. The cleanup PR deletes `Legacy*`, renames `V2*` to canonical, removes the factory bean, and deletes the row from `/admin/feature-flags`. The "Days Active" column is the visible retirement signal — no automated enforcement; humans read the column.

---

## Consequences

**Positive**

- Per-env isolation falls out of the existing per-env database posture — zero new infrastructure.
- Read path latency is bounded by a Redis round-trip, evicted on every admin write, so toggling is observable in single-instance prod within milliseconds.
- The protocol's perimeter rule means the legacy path is one file (or one route guard, or one `@if`) to delete at retirement, not an N-call-site grep.
- Adding a flag requires creating exactly one row in the admin UI; new flag keys can be referenced from code without pre-seeding a migration (unknown keys read as `false` by contract).

**Negative**

- The factory-bean pattern produces three files (interface + Legacy + V2 + factory) for a behavior-change flag where an inline branch would be three lines. The trade is intentional: cleanup is N-1 file deletions plus a rename, instead of an N-grep editing pass.
- Retirement is a human discipline, not an enforced rule. There is no scheduled job that warns about flags older than X days; "Days Active" is a passive signal. If the operator stops reading the admin UI, flags will accumulate. Mitigation lives in the protocol section of `SYSTEM_SNAPSHOT.md` and the agent files — every future flag-touching task is briefed to retire deliberately.
- Spring's `@CacheEvict(allEntries = true)` evicts every flag's cached value on any admin write, including the `isEnabled('foo')` cache for a flag that wasn't touched. This is acceptable at our flag count (single digits expected); a wider deployment with hundreds of flags would need per-key eviction.

**Neutral**

- The `feature_flag` table sits in `core` (entity + repository + service + DTO), the controllers sit in `api`. Admin and public read controllers are separate classes — same shape as `SnapTradeAdminController` vs the user-facing broker controller — so the security boundary is visible at the file level, not buried in path matchers.
- The admin UI lives at `/admin/feature-flags`, accessible from a tabbed Admin shell at `/admin` (alongside `/admin/settings`). Sidebar entry is gated on `User.isSuperuser`; backend `@PreAuthorize` is the actual security boundary, the sidebar gate is UX only — same RBAC pattern as ADR-036.

---

## Verification

- **Migration:** `V20260508120000__CreateFeatureFlagTable.sql` runs idempotently against an empty schema; re-running is a no-op.
- **Service:** `FeatureFlagService.isEnabled` returns `false` for an unknown key without persisting; `setEnabled(key, true)` on a never-activated flag stamps `activated_at`; `setEnabled(key, false)` followed by `setEnabled(key, true)` advances `activated_at` to the latest on-edge.
- **Cache:** A repeat `isEnabled("foo")` after the first call hits Redis (no DB query); a `PATCH /api/v1/admin/features/foo` then `isEnabled("foo")` misses cache (region evicted, DB hit).
- **Admin auth:** `GET /api/v1/admin/features` returns 401 anonymous, 403 with non-superuser JWT, 200 with superuser JWT.
- **Public surface:** `GET /api/v1/features` returns the sorted list of currently-enabled flag keys; disabled keys are absent from the response.
- **Frontend:** `FeatureFlagService.refresh()` is called from `app.component.ts` on init when authenticated and from the admin component after every successful toggle; the public-facing UI reads via `featureFlags.isEnabled('key')` from a Signal, no manual subscription management.

---

## Alternatives Considered

- **LaunchDarkly / Unleash / external flag SaaS.** Rejected: adds a network dependency to the read path, breaks the single-origin Caddy posture (no third-party domain), and is overscaled for a solo operator. The Redis-cached Postgres read path costs a sub-millisecond Redis hit; outsourcing it to a SaaS adds tens of milliseconds and a new failure mode.
- **`@ConditionalOnProperty` with environment variables.** Rejected: resolved at Spring context startup. Toggling requires a redeploy, which defeats the entire decouple-deploy-from-release motivation.
- **In-memory map seeded from `application.properties`.** Rejected: same restart problem as `@ConditionalOnProperty`, plus no admin UI, plus no per-environment isolation beyond what env-var injection already provides.
- **Boolean column on `User` for per-user flag state.** Rejected: flags here are global to the environment, not per-user. Per-user gating is a different problem (cohort rollouts, A/B tests) that this ADR does not address; if needed, it gets its own table, not a column.
- **Auto-create unknown flag keys on first read.** Rejected: makes the admin table grow without admin action and leaks future-feature names into the table the first time the flag-checking code path is exercised. Manual create is one extra step in exchange for an admin table that only contains flags the operator deliberately introduced.
- **Per-key cache eviction instead of `allEntries = true`.** Rejected for now: flag count is single-digits and admin writes are rare, so per-key juggling adds a bug surface (forgetting to evict `__enabled_keys__` on toggle, e.g.) for no measurable performance win. Revisit if the flag table ever crosses ~50 rows.
