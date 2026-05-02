# ADR-027: Bare-CSV Listing Resolution — Broker Alias, FIGI Exchange Writeback, Manual Override

**Status:** Accepted
**Date:** 2026-05-01
**Supersedes:** ADR-024 §Decision 3 in two specific points (mergers EODHD-default-on; spin-off BhavKosh auto-backfill)

---

## Context

Trading 212-style CSVs ship rows with `ticker + currency` only — no exchange column, no ISIN. A user-reported batch of 12 such tickers (`VUAG`, `VWRP`, `BMWD`, `VOWD`, `OPEN`, `BUGG`, `SUPR`, `SSLN`, `FFIE`, `FRSH`, `NKLA`, `CRNT`) landed as `UNRESOLVED` `SecurityListing` rows with `exchange_id = NULL`. Three downstream effects followed:

1. **FIGI resolution short-circuited.** `FigiResolutionService.buildRequestForSecurity` returned `null` when the listing had no `exchange.exchange_code` to translate into a Bloomberg `exchCode`. Queue entries fell to `terminalIds` and were silently deleted without an OpenFIGI call.
2. **Even when FIGI succeeded, EODHD never got the venue.** The OpenFIGI response carried `exchCode` (Bloomberg form, e.g. `LN`, `UW`); resolution wrote `composite_figi` to `security_master` but no path projected the venue back onto the listing. `JitSecuritySetupService` derives EODHD provider symbols from `listing.exchange.exchange_code`, so a null exchange meant no `market_data_symbol` row and no historical price backfill.
3. **Broker descriptions never matched seeded codes.** CSV imports that *did* carry an exchange string ("London Stock Exchange", "Boerse Berlin Equiduct Trading", "Knight Equity Markets LP") fell through `findByExchangeCode` and `findByMicCodeIgnoreCase` because seeded `exchange.exchange_code` is constrained to length 16 and stores canonical codes (`LSE`, `BER`), not descriptive strings.

ADR-024 §Decision 3 also drifted from the shipped implementation in two specific places:

- It described both `CorporateActionMergerBackfillJob` and a `CorporateActionSpinoffBackfillJob` as gated by `app.jobs.corporate-actions-{mergers,spinoffs}.enabled` defaulting to `true`, with EODHD `/api/fundamentals` retained as a non-Indian merger fallback. The spin-off auto-backfill was never built; the merger EODHD fallback fires HTTP 403 on the production subscription tier and produced log noise on every newly-resolved security.
- It described spin-off ingest as JIT-listener + weekly-sweep + admin via BhavKosh. PR #172 shipped spin-off as manual-entry only (no listener, no sweep, no client).

This ADR records the shipped resolution architecture and reconciles the two divergences.

---

## Decision 1: Broker Alias Resolvers Sit Between Ingest and the Resolution Pipeline

`BrokerExchangeAliasResolver` (a hardcoded ~30-entry static map in `core`) normalises broker-supplied exchange descriptions to canonical `exchange.exchange_code` values. Wired into `SecurityListingService.findOrCreateByTickerOrFigiOrExchange` Step B, immediately after the direct `findByExchangeCode` lookup and before the `findByMicCodeIgnoreCase` fallback. Returns `Optional.empty()` for the broker placeholder `MULTIPLE` and any unmapped input. Hardcoded rather than persisted in an `exchange_alias` table because the volume is small, additions are version-controlled, and a DB query per CSV row is wasted I/O.

`BrokerTickerAliasResolver` (a separate `core` map keyed on `ticker@exchangeCode`) translates broker-form tickers like Trading 212's `BMWD` (BMW preferred on Berlin) → canonical Bloomberg `BMW3`. Applied at OpenFIGI request build time inside `FigiResolutionService.buildRequestForSecurity`, **only when the listing exchange is known** — without an exchange the broker form is submitted unchanged and OpenFIGI returns all venue matches. The `SecurityListing.ticker` keeps the user-facing broker form; only the OpenFIGI request uses the canonical form. The resolved `composite_figi` is global and applies to both representations.

## Decision 2: FIGI Resolution Persists `resolved_exch_code` and Writes Back `listing.exchange_id`

`figi_resolution_stage` gains a `resolved_exch_code VARCHAR(8)` column (Flyway `V20260427100000`). `FigiResolutionService.persistStageRecord` populates it from the chosen `FigiCandidate.exchCode` for every `RESOLVED` row.

`FigiResolutionService.applyResolvedResults`, after writing `security_master.composite_figi` and `security_listing.listing_figi`, now:

1. Reads the latest RESOLVED stage row's `resolvedExchCode`.
2. Reverse-maps via `BLOOMBERG_TO_EXCHANGE_CODE` (a sibling of the existing `EXCHANGE_CODE_TO_BLOOMBERG` forward map) to a DB `exchange.exchange_code`.
3. If `listing.exchange` is null and the lookup succeeds, sets `listing.exchange` and triggers `JitSecuritySetupService.onNewListingCreated(listing)` so a `market_data_symbol` row + `HistoricalPriceBackfillRequestedEvent` are produced.

**Tie-break**: when multiple DB codes share a Bloomberg code, the inverse picks the canonical primary venue. For Bloomberg `GR` (FSE / BER / XETRA in the forward map) the inverse picks **`XETRA`** — electronic primary, ~95% of German equity volume, broadest EODHD price coverage. This is mathematically lossy: a Berlin-only or Frankfurt-floor-only security gets `listing.exchange_id` set to XETRA after FIGI resolution, and EODHD price backfill for it will look up `<TICKER>.XETRA` and may return zero bars. The `Workaround` is the manual override endpoint in Decision 3.

**Confidence threshold split**. ISIN-based lookups continue to require `confidenceScore ≥ 0.90`. Ticker-based lookups use a separate `TICKER_CONFIDENCE_THRESHOLD = 0.30` because the maximum reachable score without an ISIN is 0.50 (exchange + currency + asset class) and `passesValidation` already hard-rejects currency mismatches — a single surviving compositeFIGI after that filter is unambiguous.

## Decision 3: Manual Exchange Override and Repair Are Part of the Resolution Loop

Two admin-token-gated endpoints close the gaps Decisions 1–2 cannot reach autonomously:

- **`PATCH /api/figi-resolution/listing/{id}/exchange`** — body `{"exchangeCode": "..."}`. Looks up the listing (404 on miss), looks up the exchange (400 on miss), sets `listing.exchange`, re-arms the FIGI queue via `UnresolvedListingRepairOperations.reEnqueueForResolution`, and triggers `JitSecuritySetupService.onNewListingCreated`. JIT and re-enqueue failures are caught and logged WARN — they do not roll back the exchange write. Returns `ApplyResult(listingId, oldExchangeCode, newExchangeCode, reEnqueued, jitTriggered)`.
- **`POST /api/figi-resolution/repair-unresolved`** — walks every UNRESOLVED listing whose `exchange_id IS NULL`, picks the modal broker exchange string from its `transactions` rows via `TransactionRepository.findModalExchangeForListing`, runs it through `BrokerExchangeAliasResolver`, attaches the resolved exchange and triggers JIT on a hit (`RepairOutcome.ATTACHED`), or re-enqueues the listing without an exchange so the ticker-only OpenFIGI path can try (`RepairOutcome.ENQUEUED_NO_EXCHANGE`) when there is no broker string or the alias map returns empty. `SKIPPED` covers listings missing or already-attached. Each row is repaired in its own transaction (via `UnresolvedListingRepairOperations` extracted as a separate bean for AOP-proxied `@Transactional`).

The frontend has no in-app form for either endpoint; both are admin-curl operations behind `X-Internal-Token`.

## Decision 4: Mergers EODHD Backfill Is Default-Off

`app.jobs.corporate-actions-mergers.enabled` defaults to **`false`** (was `true` in ADR-024 §Decision 3). The flag is read by `CorporateActionMergerBackfillJob.@Value` and short-circuits four entry points:

- `@EventListener onHistoricalBackfillCompleted` (JIT)
- `@Scheduled scheduledWeeklySweep` (Sunday 05:00 UTC)
- `@Async backfillAllActiveAsync` (admin `POST /backfill-all`)
- `@Async backfillForSecurityAsync` (admin `POST /backfill/{id}`)

Each path calls `EodhdMergerClient.fetchMergers(...)` → `https://eodhd.com/api/fundamentals/{symbol}`, which the production EODHD subscription tier does not include — it returns HTTP 403. With Phase 2 of the FIGI fix unblocking ticker resolution, every newly-resolved security woke the JIT listener and produced an ERROR log per ticker; the weekly sweep against ~1,100 active EODHD symbols would have produced one ERROR per security. The flag is the rollback surface; manual entry via `recordManualMerger` and `deleteMerger` are intentionally not gated. Re-enable once the EODHD fundamentals add-on is part of the subscription — tracked as GitHub issue #171.

`CorporateActionMergerBackfillJob` has no BhavKosh routing in its current form (the BhavKosh integration that ADR-024 §Decision 3 described for Indian merger ingest was not part of the shipped code; `BhavKoshCorporateActionsClient` is consumed only by the dividend and split backfill jobs). With the gate off, the merger table grows only through the manual admin endpoint until the EODHD subscription is upgraded or BhavKosh merger ingest is implemented.

## Decision 5: Spin-off Is Manual-Entry Only

`CorporateActionSpinoffBackfillJob` was deleted; the bean was renamed to `CorporateActionSpinoffService` and moved to `jobs/service/`. `EodhdSpinoffClient` was deleted. The class now exposes only:

- `recordManualSpinoff(parentMasterId, childMasterId, exDate, sharesPerParent, basisAllocationPct)` — idempotent on `(parent, child, ex_date)`, upgrades a pre-existing partial row in place when the admin supplies a previously-null `basisAllocationPct`.
- `deleteSpinoff(id)`.

There is no JIT listener, no scheduled sweep, no admin async backfill, and no `app.jobs.corporate-actions-spinoffs.enabled` property. The IRS Form 8937 contract from ADR-018 §Decision 3 / ADR-024 §Decision 3 stays load-bearing: `basis_allocation_pct` is `NULL` until an admin enters it, and `PortfolioReplayService.applySpinoff` treats null pct as `SPINOFF_MISSING_BASIS` (skip transfer, parent retains 100% basis).

This contradicts ADR-024 §Decision 3's "New `CorporateActionSpinoffBackfillJob` mirrors the merger job: JIT listener … weekly Sunday 05:30 UTC sweep, admin endpoint" and "Both jobs are gated by `app.jobs.corporate-actions-…enabled`" descriptions of the spin-off side. PR #172 shipped the manual-only design; ADR-027 records what shipped.

---

## Consequences

- **Trading 212-style CSVs (ticker + currency only) now resolve to RESOLVED + priced**, provided OpenFIGI returns a candidate at all. The chain is: ticker-only OpenFIGI request → `applyResolvedResults` → exchange writeback → JIT EODHD setup → `HistoricalPriceBackfillRequestedEvent`.
- **The Bloomberg ⇄ DB exchange map is now load-bearing in two directions.** Previously only `EXCHANGE_CODE_TO_BLOOMBERG` was consulted (forward, request building); now `BLOOMBERG_TO_EXCHANGE_CODE` is consulted (reverse, writeback). Adding a new seeded exchange requires both directions; a missing reverse entry leaves listings with no exchange after RESOLVED.
- **`GR → XETRA` is a known-imperfect tie-break.** Berlin-only or Frankfurt-floor-only securities will be mis-attributed to XETRA. The manual override endpoint (Decision 3) is the documented escape hatch. Documented in [docs/market-data-workflows.md](../../portfolio-optimizer-backend/docs/market-data-workflows.md).
- **The merger and spin-off `corporate_action_*` tables are admin-only writes again.** With Decision 4's gate off and Decision 5's auto-paths gone, both tables grow only through:
  - `recordManualMerger` / `recordManualSpinoff` superuser endpoints, and
  - the BhavKosh path for Indian mergers (still gated by Decision 4's flag).
  This is consistent with ADR-024's "No path to user writes against `corporate_action_*` tables" consequence; it strengthens it (no path to *automated* EODHD writes either, on the merger side, until the subscription is upgraded).
- **AOP-proxied `@Transactional` discipline is preserved.** `UnresolvedListingRepairOperations` is a separate bean from `UnresolvedListingRepairService` because the orchestrator self-invokes the per-row method; same shape as `Holdings*Service` decomposition elsewhere.
- **Re-enable path is explicit.** Setting `CORPORATE_ACTIONS_MERGERS_ENABLED=true` once the EODHD fundamentals add-on is purchased restores the JIT + weekly + admin auto-paths without code change. Tracked as GH issue #171.

## Alternatives Considered

- **Persist broker-exchange aliases in a DB table.** Rejected — the volume is small (~30 entries), aliases change rarely and require code review, and a DB hit on every CSV row trades runtime cost for zero operational benefit.
- **Auto-fix the `GR → XETRA` tie-break by storing all DB exchanges sharing a Bloomberg code and trying each.** Rejected for now — would require iterating EODHD price-fetch attempts per attempted venue, defeating the "no sync external calls on hot path" principle, and the manual override endpoint already covers the rare cases.
- **Remove the merger EODHD path entirely instead of gating.** Rejected — the path is correct when the fundamentals tier is licensed; deleting it forces a re-implementation later. The flag is the cheaper surface.
- **Backfill `figi_resolution_stage.resolved_exch_code` for the 7 existing RESOLVED rows.** Rejected — only 1 of the 7 listings has `exchange_id IS NULL` (BABA), and BABA's raw `exchCode` is `EO`, which is not in the reverse map. Touching 7 rows would improve 0 cases. Manual override is the documented path for that listing.
