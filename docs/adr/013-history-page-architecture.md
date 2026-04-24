# ADR-013: History Page Architecture and Server-Authoritative Aggregation

**Status:** Accepted
**Date:** 2026-04-19
**Context:** Users need a unified view of their trading history — raw transactions, fully-closed position episodes, and data-quality anomalies — across all portfolios. The obvious path of "ship every transaction to the browser and aggregate in JavaScript" degrades linearly with account age: a five-year-old portfolio with thousands of transactions across multiple brokers turns into a multi-megabyte JSON payload, duplicated AVCO logic on the client, and a new place where realized-gain math can drift from ADR-012. The alternative — exposing one endpoint per concern — keeps the browser a dumb renderer and concentrates correctness on the server. A third class of concern, broker-sync gap detection ("the broker says I hold 100 shares but my ledger only accounts for 80"), requires broker-positions snapshots that don't yet exist in our data model. Deferring it cleanly matters so the rest of the feature can ship.

---

## Decision 1: URL-Driven State Sync — No Client Session, No Server Preferences

**Choice:** All user-observable History state lives in the URL query string: `tab`, `p` (comma-joined portfolio ids), `q` (search), `from` / `to` (ISO-8601 date-time bounds), `act` (action filter), `plmin` / `plmax`, `page`. The Angular component hydrates its Signals from `ActivatedRoute.snapshot.queryParamMap` on init, then syncs on every filter/tab/page change via `router.navigate([], { queryParams, queryParamsHandling: 'merge', replaceUrl: true })`. No sessionStorage, no backend preferences table, no "remember last view" cookie.

**Rationale:** A History URL is inherently shareable — an analyst pastes it into a bug report, a CFO forwards it to tax prep, the user bookmarks the exact view they care about. Once the URL is the source of truth, we get deep-linkable state, browser-back navigation, and precise reproducibility for free. Storing state server-side would require a schema migration for a purely cosmetic concern and fragments "what view does the user see?" across tabs. The `replaceUrl: true` hygiene prevents browser history pollution on every keystroke; page changes use the same merge strategy so a pasted URL with `page=3` survives subsequent filter edits.

**Enforcement:** The spec (`history.component.spec.ts`) covers URL → state hydration (including graceful rejection of invalid `tab` / `act` values), state change → URL sync via a spied `Router.navigate`, and tab-change resetting `page` to 0 (so a shared URL never leaves the user stranded on an empty tail page).

## Decision 2: Server-Side Per-Request AVCO Replay, Single Ledger Scan

**Choice:** `HistoryQueryService` (core module) answers all four History endpoints — `/api/history/{summary,transactions,closed-positions,missing-transactions}` — with one pass over the caller's transactions. The scan groups by `(portfolioId, effectiveSecurityMasterId)` and runs a fresh `RealizedGainCalculator.AvcoState` per group. That same state machine emits three aligned result sets: transaction rows (with per-SELL realized P/L attached), closed-position episodes (running qty `>0 → 0` transition), and anomaly rows (SELL-before-BUY, oversell). Counts and sums for the summary endpoint are derived from these filtered sets after the scan — no separate count query. The filter surface is applied in-service (in-memory) after replay; pagination is `List.subList(offset, offset+pageSize)`.

**Rationale:** Both closed-episode detection and realized-P/L attribution require walking the ledger in chronological order per security — you cannot page a SQL query and get correct AVCO. Given that constraint, the efficient choice is one scan that feeds every tab, not one scan per endpoint. Keeping the aggregation in `core` matches the module-boundary rule from ADR-011 and reuses the `RealizedGainCalculator` + FX-snapshot machinery from ADR-012 verbatim — no parallel math, so any AVCO fix propagates to every surface. The in-service pagination is a deliberate simplification: a user's transaction volume is bounded (thousands, not millions), and the browser receives only the visible page. If volume ever forces a change, the pagination seam is localized to one service method and the API contract doesn't move.

**Extension points on `RealizedGainCalculator`:** `AvcoState.runningQuantity()` and `AvcoState.totalCost()` read-only accessors; `computeClosedEpisodes(txns, reportingCurrency, fxSnapshot) → List<ClosedEpisode>` that watches the running-qty transition; `detectAnomalies(txns) → List<Anomaly>` with the `AnomalyType` enum. Existing `computeTxnCurrency` / `computeReportingCurrency` entry points are untouched; legacy callers (TickerDetailService, StockGroupService per ADR-012) are byte-identical.

**Enforcement:** `HistoryQueryIntegrationTest` seeds a user with USD/EUR/INR transactions covering open position, fully-closed single-episode, re-opened/re-closed (two episodes), SELL-before-BUY, and oversell. Asserts summary realized-P/L sums, pagination boundaries, and per-anomaly type. Portfolio-id authorization (filtering out ids the caller doesn't own) is covered explicitly.

## Decision 3: Defer Broker-Sync Gap Detection to a Later Phase

**Choice:** Phase-1 anomaly detection emits only `SELL_BEFORE_BUY` and `NEGATIVE_QTY` — both derivable from the immutable transaction ledger alone. `BROKER_POSITION_MISMATCH` (broker reports N shares, our ledger computes M≠N) is explicitly deferred until a persistent broker-positions snapshot table lands, populated by an async job off the SnapTrade-sync event stream.

**Rationale:** Hitting the broker synchronously from the History hot path would violate "No sync external calls on hot path" (SYSTEM_SNAPSHOT §4) — the History page would be as slow as the worst broker rate-limit on the worst day. Storing a snapshot is the right answer, but it requires schema, a job, a reconciliation window policy, and UX around "how stale is too stale?" — all of which can ship independently of the ledger-derived anomalies users can already act on today. The UI is contract-stable: the `anomalyType` field on `MissingTransactionRow` is a string, so adding a third enum value doesn't break the frontend. The info note on the Missing tab tells the user this is the current scope.

---

## Consequences

- History URLs are fully shareable; every filter/tab/page round-trips losslessly.
- Every number the History page shows — counts, realized P/L, episode averages, return % — comes through the same `AvcoState` that powers per-stock detail views and the overview Realized-Gain card (ADR-012). Drift between surfaces is architecturally impossible.
- Cross-currency realized gain inherits the ADR-011 FX fallback hierarchy automatically: stored `normalizedReportingAmount` first, live `FxRateSnapshot` second. Changing reporting currency is already handled by the existing async normalizer — no bespoke rebuild for History.
- Closed episodes respect re-openings: a security that's sold to zero, re-bought, and sold again emits two rows with `episodeIndex` 0 and 1. Realized-gain attribution per episode is independent and accurate.
- In-service pagination means list responses carry exactly one page of rows. Typical portfolios never notice; pathological portfolios get one slower endpoint, not a 10-MB download.
- Broker-position reconciliation is architected-in (anomaly enum, DTO shape, UI placement) but not shipped. When Phase-5 lands, only `HistoryQueryService.detectAnomalies` and its enum grow — no UI churn, no endpoint churn, no URL-schema churn.
- Integration tests execute against real Postgres via Testcontainers; unit tests for `RealizedGainCalculator` cover the new episode/anomaly emitters without Spring context. No H2 anywhere in the test tree, consistent with project policy.
