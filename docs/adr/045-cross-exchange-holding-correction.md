# ADR-045: Cross-Exchange Holding Correction — Step C Currency Guard + Same-Master Rebind

**Status:** Accepted
**Date:** 2026-05-28
**Extends:** ADR-005 (identity model — `holdings.acquired_listing_id` mutation rule), ADR-027 (resolver pipeline — narrows Step C), ADR-028-resilient-broker-linking (same write-time-vs-correction lineage as null-exchange promotion), ADR-039 (per-master vs portfolio-wide replay — documents an exception)

---

## Context

A user-linked Questrade account on staging persisted ARCA-quoted SPYD positions bound to the **XETRA** SPYD listing. The only `SPYD` row in `security_listing` at sync time was a EUR-denominated XETRA listing left over from a prior import; `SecurityListingService.findOrCreateByTickerOrFigiOrExchange` Step C (ticker-only fallback) reused it instead of creating a fresh ARCA listing. The user-visible symptom was wrong currency, wrong prices, and no UI affordance to "rebind to a different listing": the only correction surface available — `TickerMappingApplier.applyMapping` setting `override_market_data_symbol_id` — affected pricing only, not the holding's identity attachment.

Step C reuse was wrong by construction. SnapTrade's payload carried `currency = "USD"`, which Step B2 (`findByCurrencyIgnoreCase`) consulted and returned empty for. Falling through to ticker-only-pick-first reads as *"no currency information available"* — but the broker had explicitly told us otherwise. The single XETRA listing was a known currency mismatch. The same class of bug is primed for any US ETF with a same-ticker European cousin (BOTZ, URNU, SMH).

Even with the resolver fixed at the write side, the production cohort still contained holdings already wrongly bound. Closing the loop required two changes: a write-time guard so future binds are correct, and an admin correction surface for the residual rows. Fix 0 diagnostics on the staging Postgres confirmed broker-supplied currency is consistently present on the SnapTrade path (0 listings with `trading_currency IS NULL` across 418 rows), so the guard is reachable. The full investigation, devil's-advocate review, and Fix 0 probe results live in `~/.claude/plans/users-sumitsabhnani-downloads-portfolio-crispy-acorn.md`.

---

## Decision 1: Resolver Step C Is Skipped When Broker Currency Is Provided and Step B2 Found Zero

`SecurityListingService.findOrCreateByTickerOrFigiOrExchange` Step C runs *only* when one of the following holds:

- The caller supplied **no** broker currency (bare-CSV path, ADR-027), or
- Step B2 (`findByCurrencyIgnoreCase`) found **more than one** same-currency candidate (legacy first-by-id pick preserved).

When the caller supplied a broker currency AND Step B2 found exactly zero candidates, the resolver goes directly to `createListing(..., resolved = false)`. The existing listings on other currencies are not a degraded fallback for the broker-supplied currency — they are known mismatches, and reusing them re-creates the original bug.

Step B2 multi-match is the open follow-up (GBP/GBX/USD/EUR all coexist on LSE per Probe 1 — `XLON` carries four currencies in the staging dataset). Pursued only when a user case surfaces.

The country-derivation filter the devil's-advocate review originally proposed was rejected: multi-currency-per-exchange rows on LSE, EBS in USD on `XSWX`, and multi-currency `XSGO` rows all trip a country-based filter and emit false rejects. The currency-presence guard is structurally correct and routes exactly the failure mode.

## Decision 2: Holding Rebind Is the User-Correction Surface, Strictly Same-Master

`TickerMappingApplier.rebindAcquiredListing(holdingId, newListingId)` (`core`) reassigns `holding.acquired_listing_id` and re-points transactions matching `(portfolio_id, oldListingId)` to the new listing. It is wired behind `POST /api/v1/admin/holdings/{holdingId}/rebind` (`HoldingAdminController`, superuser-only) with a companion `GET /api/v1/admin/holdings/{holdingId}/sibling-listings` returning the same-master alternatives the picker shows. Frontend exposure: a new mode in `TickerMappingModalComponent` ("Rebind to a different exchange"), gated by `user.isSuperuser`.

**Same-master only.** The rebind refuses if `newListing.security != currentHolding.acquiredListing.security`. Cross-master rebind would re-shuffle corporate-action chains (`corporate_action_split/merger/spinoff` rows are keyed by `security_master_id`) and break `PortfolioReplayService.effectiveMasterId(t)` invariants: replay groups transactions into per-master `ReplayChain`s and walks AVCO chronologically. Moving a transaction from master A's chain to master B's chain silently mutates terminal AVCO on both. Same-master rebind preserves the chain (`getEffectiveId()` stable pre and post); the AVCO walk is mathematically unchanged.

**Side-effect contract.** The rebind, in one `@Transactional` block:

- Reassigns `holding.acquired_listing_id` to the new listing.
- Reassigns `transaction.security_listing_id` for every transaction matching `(portfolio_id, oldListingId)` via `TransactionRepository.repointSecurityListing` (native UPDATE — JPQL UPDATE on a `@ManyToOne` path is fussy under Hibernate; native keeps the generated query boring).
- Clears `holding.override_market_data_symbol_id` **only if** the new listing already has a `market_data_symbol`. If the new listing has none, the override is retained (so the user keeps working prices) and `JitSecuritySetupService.onNewListingCreated(newListing)` is invoked synchronously so the JIT chain is armed for the next refresh. The JIT call swallows its own exceptions and does not roll back the rebind transaction.
- Publishes `HoldingRebindEvent(holdingId, portfolioId, userId, oldListingId, newListingId, repointedTransactionCount)`.

`security_master_id` is NOT mutated — the rule is "same master, different listing." `holding.broker_raw_ticker` is left untouched (the ADR-029 / ADR-040 "never overwritten" rule on broker-specific suffixes).

**Replay re-trigger uses the portfolio-wide path.** `HoldingRebindListener` (`api`, `@TransactionalEventListener(AFTER_COMMIT)`) calls `HoldingService.updateHoldingsForPortfolio(portfolioId)` then publishes `UserHoldingsChangedEvent`. This is the documented exception to ADR-039's "recompute one master, not the whole portfolio" rule: a single listing swap can affect *other* holdings on the same master (a manual same-ticker entry on the same portfolio, or any future bulk-rebind path), so the read-side projection must reconcile across the whole portfolio rather than risk a partial recompute.

**Cross-master rebind is a separate ADR**, intentionally deferred. It would need corporate-action chain re-keying, AVCO re-walk under the new master, and a structured audit row. Out of scope here.

---

## Consequences

- The "transactions are immutable" claim under ADR-029 narrows by exactly one field: `security_listing_id` may be repointed by the rebind path, **only** between listings of the same `security_master_id` (so `effectiveMasterId(t)` is invariant). Quantity, price, type, date, FX columns, and `normalized_reporting_*` projections stay strictly immutable.
- `Holding.acquired_listing_id` joins `Holding.override_market_data_symbol_id` as a mutable post-creation field. ADR-005's holding-mutation surface is now `PUT /api/holdings/{id}` (metadata) + `POST /api/v1/admin/holdings/{holdingId}/rebind` (same-master listing swap) — no other path mutates a `holdings` row in place.
- The synchronous `JitSecuritySetupService.onNewListingCreated` call on the rebind request thread is consistent with the other admin write paths that exercise the same setup (`ListingExchangeOverrideService`, `UnresolvedListingRepairOperations` — both ADR-027 endpoints). The call is a single DB write plus a `HistoricalPriceBackfillRequestedEvent` publish; the actual EODHD HTTP fires on the dedicated `eodhdHistoricalBackfillExecutor` per ADR-028. The hot-path-no-sync-external rule is not violated.
- The portfolio-wide replay re-trigger means rebind cost scales with portfolio size, not with the single holding. For typical portfolios (< 200 holdings) this is sub-second; the rebind endpoint is admin-only and not invoked from a UI tight loop. If a bulk-rebind path emerges, batched replay re-triggers become the right shape.
- Fix 0 Probe 1 confirmed: 0 `security_listing.trading_currency IS NULL` rows on staging (out of 418), so the Step C guard is reachable on every SnapTrade re-link. The bare-CSV path (currency may be null) preserves the legacy Step C behaviour and stays compatible with ADR-027.
- 13 same-master holdings on the local staging dataset are eligible for user-facing rebind testing (all NSE→BSE Indian dual-listed tickers on the Zerodha portfolio: TCS, BAJAJ-AUTO, ADANIGREEN, CESC, PVRINOX, …). The integration test `TickerMappingApplierTest.RebindAcquiredListing` pins the same-master accept path, the cross-master refuse path, the identity-rebind refuse path, the override-clear branches, and the JIT-trigger branch.

---

## Alternatives Considered

- **Cross-master rebind in v1.** Rejected: corporate-action chain re-keying and AVCO re-walk are large surfaces; a wrong rebind could silently mutate realized P&L on both masters. The actual bug (ARCA SPYD ↔ XETRA SPYD) is fully covered by same-master because both listings already share a single `security_master_id` (the masters are deduplicated; the listings differ).
- **Country-code derived filter in Step C** (the original devil's-advocate proposal). Rejected: multi-currency-per-exchange rows on LSE (GBP/GBX/USD/EUR on `XLON`) and cross-listed CHF→USD ADRs on `XSWX` trip the filter and emit false rejects. Currency-presence is the structural guard.
- **One-shot SQL migration to "fix the wrong-bound holdings."** Rejected: the affected holdings on the user's friend's portfolio were already disconnected before deploy. The rebind endpoint covers the residual case; one-shot SQL was unnecessary risk.
- **Make `acquired_listing_id` immutable and require delete-then-recreate.** Rejected: deleting a holding cascades to its transactions via FK, and transactions are the immutable ledger. Repointing in place via a guarded admin endpoint is the only safe correction.
- **JPQL UPDATE for transaction re-pointing.** Rejected: Hibernate's `@ManyToOne`-path navigation in bulk UPDATEs is fussy and produces awkward generated SQL. Native UPDATE in `TransactionRepository.repointSecurityListing` is the boring choice.
