# ADR-030: Closed-Loop Broker Selection — DB-Vetted Brokers, Direct-Login by ID, Structured Failure Reason

**Status:** Accepted
**Date:** 2026-05-04
**Extends:** ADR-002 (SnapTrade ledger ingestion)

---

## Context

The "Add account" modal hardcoded eight broker tiles in `link-account-modal.component.ts` and exposed an implicit "Browse all" SnapTrade hub-mode path via `broker-tab.component.ts`. The backend's `POST /api/brokers/snaptrade/connect/start` accepted an optional `brokerSlug`; when omitted, SnapTrade rendered its generic broker hub, which let users link any broker SnapTrade supports — including brokers we cannot ingest because their feeds expose only balances, not the immutable transaction ledger AVCO requires.

The backend's `UnsupportedBrokerException` was the only guarantee. It fired *after* the user completed the OAuth flow, marked the connection FAILED with a free-text `lastSyncError`, and the frontend rendered a generic "Sync failed" banner — the user discovered "we don't support your broker" only after picking it. The closed-loop property the platform requires (only AVCO-compatible brokers reach the user) was a runtime exception, not a UI invariant.

Three secondary issues compounded:

1. **Slug casing trap.** Our seeded slugs (`trading_212`, `zerodha`, `schwab`, `interactive_brokers`, `fidelity`) all returned 404/1011 from SnapTrade's `loginSnapTradeUser`. The canonical slugs in SnapTrade's `referenceData.listAllBrokerages` catalog are uppercase + hyphenated — `TRADING212`, `ZERODHA`, `SCHWAB`, `INTERACTIVE-BROKERS-FLEX`, `FIDELITY`. Every active SnapTrade tile was silently broken; the bug surfaced only when a user clicked it.

2. **Free-text failure reason.** `SnaptradeConnection.lastSyncError` is a `TEXT` column. The frontend had no structured way to render category-specific copy (e.g. "Broker not supported …" vs. a generic retry message); pattern-matching the English string couples the frontend to backend log messages and breaks on copy edits.

3. **Redis-backed cache survives restarts.** `BrokerService.{getActiveBrokers, getActiveSnapTradeBrokers, getBrokerById}` are `@Cacheable("brokers")`, and `spring.cache.type=redis`. A Flyway migration that fixes a slug therefore *cannot* repair a running deployment — the cached `Broker` entity in Redis still has the old slug after the JVM reboots.

---

## Decision 1: `GET /api/brokers` Is the Single Source of Selectable Brokers — Server-Filtered

A new `BrokerController` exposes `GET /api/brokers` returning `List<BrokerDto>` filtered server-side via `BrokerService.getActiveSnapTradeBrokers()` →
`BrokerRepository.findByIsActiveTrueAndSnaptradeSlugIsNotNull()`.

The filter excludes:
- The Manual placeholder (`id=99`, `snaptrade_slug IS NULL`).
- Any future Direct-API-only entry (slug-less rows are structurally non-SnapTrade).
- Any soft-deleted broker (`is_active = FALSE`).

The frontend `BrokerService.getActiveBrokers()` is the only call site. The `link-account-modal` and `broker-tab` components now render `@for (broker of filteredBrokers(); …)` over the API response with a client-side search filter on `name` / `description` — no hardcoded array, no "Browse all" hub button. The hub-mode escape hatch is gone.

**Invariant:** the modal cannot display a broker that is not in `broker_metadata`. The closed-loop property is an HTTP contract, not a runtime exception.

## Decision 2: `connect/start` Accepts `brokerId` Only; Backend Resolves to Slug

`SnapTradeController.StartRequest` is now `(state, nonce, @NotNull @Positive Integer brokerId)`. The optional `brokerSlug` field is removed.

`SnapTradeService.start(...)`:
1. `brokerService.getBrokerById(brokerId)` — `IllegalArgumentException` (HTTP 400) if absent.
2. `broker.getIsActive() && broker.getSnaptradeSlug() != null` — same exception otherwise.
3. Forwards `broker.getSnaptradeSlug()` into `client.createConnectionPortal(...)`, which calls `.broker(slug).execute()` on the SnapTrade SDK builder for direct-login (bypasses the SnapTrade hub).

The frontend never deals with slugs. SnapTrade slugs are an implementation detail of the backend's binding to the SDK; the closed-loop property is enforced by the validation chain.

**Invariant:** any HTTP path that reaches `client.createConnectionPortal(..., brokerSlug)` resolves the slug from `broker_metadata` first. There is no other code path.

## Decision 3: SnapTrade's `referenceData.listAllBrokerages` Catalog Is the Slug Authority

`broker_metadata.snaptrade_slug` values must match the canonical catalog returned by SnapTrade's `referenceData.listAllBrokerages` SDK call verbatim (case- and punctuation-sensitive). The case-insensitive lookup on `findBySnaptradeSlugIgnoreCase` is for *our* internal queries only — what we forward to SnapTrade is whatever string is stored, and SnapTrade's API takes it as-is.

Discovery path for new brokers:

```
curl -H "Authorization: Bearer $SUPERUSER_JWT" \
  https://<host>/api/v1/admin/snaptrade/brokerages | \
  jq '.[] | select(.displayName | test("(?i)<broker name>"))'
```

`SnapTradeAdminController.listBrokerages()` (superuser-only via class-level `@PreAuthorize("hasRole('SUPERUSER')")`) wraps `SnapTradeClient.listAllBrokerages()` which calls `sdk.referenceData.listAllBrokerages().execute()` and projects each `Brokerage` to `{slug, name, displayName, enabled, maintenanceMode, allowsTrading, id}`. Empty list + WARN log on any SDK exception — diagnostic endpoints must never throw.

Migration `V20260504120000__FixSnapTradeSlugCasingForAllBrokers.sql` reset every existing seeded slug to its canonical form. Future seeds use the catalog as the source of truth, not docs intuition.

## Decision 4: Failure Reason Is Structured — `SnaptradeConnection.FailureReason` Enum

A new column `snaptrade_connection.failure_reason VARCHAR(32)` (migration `V20260503120000`) backs a JPA enum field on `SnaptradeConnection.FailureReason ∈ { UNSUPPORTED_BROKER, UNKNOWN }`. `BackfillStatusResponse` and `SnapTradeStatus` both expose it; `getConnectionSyncStatus(...)` returns it as a top-level field.

Wiring:
- The catch block in `SnapTradeService` that handles `UnsupportedBrokerException` (the safety net for any bypass of Decisions 1–2) calls `persistConnectionAsFailed(connection, FailureReason.UNSUPPORTED_BROKER, "Unsupported brokerage; …")`.
- All other persist-as-failed sites pass `FailureReason.UNKNOWN`.

The frontend (`portfolio.component.html` FAILED banner) branches on `failureReason === 'UNSUPPORTED_BROKER'` to render:

> **Broker not supported**
> This broker does not provide the complete transaction history required for our institutional-grade tax calculations.

…and suppresses the Retry button (retry won't help — the broker still isn't in `broker_metadata`). Other failures fall through to the existing generic message + Retry.

**Invariant:** the frontend never pattern-matches `lastSyncError` text. New failure categories add an enum value; the branch in the template is the only place they need to be handled in the UI.

## Decision 5: `brokers` Cache Is Cleared at Every JVM Start

`BrokerCacheStartupClearRunner` (`@Component`, `@Order(0)`, implements `ApplicationRunner`) calls `BrokerService.evictAllBrokerCache()` (a no-body method annotated `@CacheEvict(value = "brokers", allEntries = true)`) once at startup, before the first request can be served.

The trade-off:
- **Cost:** one extra DB read per restart for `getActiveSnapTradeBrokers` / `getBrokerById` on the first post-startup call. The table holds a handful of rows; the query is cheap.
- **Benefit:** every Flyway migration that touches `broker_metadata` (e.g. a slug fix) is self-healing on the next restart. No operator step, no `redis-cli FLUSHDB`, no admin-endpoint cache eviction. The deploy → migrate → restart pattern is correct by construction.

Best-effort: a Redis outage at boot logs a WARN and continues; the cache simply isn't hit until Redis recovers, at which point `@Cacheable` populates it from the post-migration DB read anyway.

**Pattern generalisation:** Redis-backed Spring caches over small config tables (rows in single digits, change cadence in months) should clear at startup. The cache exists to avoid in-JVM redundant queries, not to persist state across restarts.

---

## Consequences

- **Hardcoded broker arrays are gone.** `link-account-modal.component.ts` and `broker-tab.component.ts` lost their `BrokerOption` interface, the eight-broker array, and the SnapTrade hub-mode "Browse all" button. The Trading 212 Direct API form path was retired wholesale — Trading 212's `broker_metadata` row already had a SnapTrade slug, so nothing user-visible was lost. `<app-link-account-modal>` no longer emits `(link)`; `preferences.component`'s `onLinkSubmit` and `ApiService.saveNewPortfolio` are dead code (left in place for an out-of-scope sweep).
- **Frontend has no `brokerSlug` references.** Search confirms zero remaining occurrences of the old optional-slug payload. Any future regression that re-introduces slug-on-the-wire fails type-checking immediately.
- **A new `Transaction.TransactionType` value or a new failure category is now a typed change end-to-end.** `FailureReason` is `UNSUPPORTED_BROKER | UNKNOWN` today; adding `BROKER_AUTH_REVOKED` (e.g.) requires the enum, the polling JSON shape, and the template branch. The compiler catches anything that drifts.
- **Admin discovery is one curl away.** When a user reports their broker is missing, hit `/api/v1/admin/snaptrade/brokerages`, copy the slug, write a one-row seed migration, deploy. The cache clear runner makes the seed take effect on the next restart with no extra step.
- **`UnsupportedBrokerException` is now strictly a safety net.** Under normal flow, no user can reach a brokerage that isn't in `broker_metadata`. The exception fires only on API tampering (e.g. a hand-crafted POST to `connect/start` with a bogus `brokerId`) or on a race during a broker deactivation. The structured failure reason guarantees the user still sees the right message even when the safety net is the source of the FAILED state.

## Alternatives Considered

- **Pattern-match `lastSyncError` for "Unsupported brokerage"** instead of adding `failure_reason`. Rejected: brittle to copy edits, couples the frontend to English log strings, and is not searchable in the DB. The structured enum is one column + one nullable JPA field — cheap.
- **Keep the Direct API form path for Trading 212.** Rejected: the DB row already has `snaptrade_slug='TRADING212'`, so the SnapTrade flow covers it; preserving a second ingestion mode for one broker delivers no user value and keeps the modal carrying form state and an Output the closed-loop change is meant to delete.
- **Add an admin "evict cache" endpoint instead of clearing on startup.** Rejected: requires an operator step on every broker_metadata change, easy to forget, and the cache benefit (avoiding a sub-millisecond query for ~5 rows) does not survive being weighed against the deploy-time correctness gain. Startup clear is durable.
- **Filter the broker list client-side from a wider `getActiveBrokers()` response.** Rejected: makes the frontend the policy enforcer for which brokers are connectable. Server-side filtering keeps the closed-loop guarantee at the HTTP boundary — the wire never carries an un-vetted broker.
- **Add a `connection_type` enum (`SNAPTRADE | DIRECT_API | MANUAL`) to `broker_metadata`** to support multiple ingestion modes per broker. Rejected for now: the only Direct-API broker (Trading 212) is also SnapTrade-supported, and Manual is already encoded by `snaptrade_slug IS NULL`. Adding the column without a second active connection mode is speculative.
