# ADR-024: Cross-Master Corporate Actions End-to-End — Holdings on Replay, Server-Classified Triage, BhavKosh-Driven Backfill

**Status:** Accepted — §Decision 3 partially superseded by ADR-027 (mergers EODHD fallback default-off; spin-off auto-backfill never shipped — manual-entry only). Decisions 1, 2, 4 stand.
**Date:** 2026-04-30
**Supersedes:** ADR-018 §Decision 3 (EODHD-sourced spin-off backfill)

---

## Context

ADR-018 introduced the connected-component replay engine and shipped it in shadow mode behind `app.features.global-replay`. Three load-bearing seams remained open:

1. **Holdings drift.** `HoldingService.updateHoldingsForPortfolio` ran a parallel per-master AVCO loop that did not consume `PortfolioReplayService`. Cross-master mergers/spin-offs corrected the History page and dashboard but left the Holdings card showing a sold-from-cross-master position as a phantom row, or a renamed position as a missing one.
2. **Silent ledger gaps.** Anomalies (`SELL_BEFORE_BUY`, `NEGATIVE_QTY`) were detected by the replay engine but only surfaced on the History → Missing Transactions tab. The Holdings card clamped oversold qty to zero with no remediation path.
3. **Cross-master backfill blocked on EODHD.** `CorporateActionMergerBackfillJob` pointed at EODHD `/api/fundamentals` (subscription tier disabled it in practice) and no spinoff backfill existed at all. The `corporate_action_merger` and `corporate_action_spinoff` tables were superuser-admin-only writes.

Phase B's parity envelope had soaked clean across one release cycle. Closing the three seams together — and removing the shadow-mode flag — is this ADR.

---

## Decision 1: Holdings Projection Consumes the Replay Engine

`HoldingService.updateHoldingsForPortfolio` now calls `PortfolioReplayService.replay(...)` and persists `Holding` rows from `result.terminalByMaster()` — a new `Map<UUID, TerminalPosition>` field on `ReplayResult` carrying terminal qty, native + reporting cost, native currency (null when txns span multiple), and an `isOversold` flag. The legacy per-master AVCO loop is deleted, including `applyPendingSplitsBeforeTxn`. `HistoryQueryService`, `StockGroupService`, and `PortfolioSummaryService` follow suit: each unconditionally pre-computes the replay result and reads its per-master maps; the flag-gated branches and their `RealizedGainCalculator` / `CorporateActionSplitRepository` deps are gone.

`Holding.quantity == 0` is now a real persistence outcome (oversold or fully-closed), not a clamp. The row is deleted on `quantity ≤ 0` to match the legacy delete semantics; oversold remediation flows through Decision 2.

`TerminalPosition.quantity` is read from `nativeState.runningQuantity()` (FX-independent); `reportingState.step` bails on missing FX, so its qty can lag.

A new `POST /api/holdings/rebuild?portfolioId={id}` endpoint forces a projection rebuild after admin-seeded corporate actions or a reporting-currency change. Idempotent; transactions untouched; portfolio-ownership-checked.

**Rationale.** The "single replay engine" principle in ADR-018 was true for *analytics* surfaces (History, dashboard realized) but not for the Holdings projection itself. A user who held HDFC through the 2023 merger into HDFCBANK saw the History page reconcile the chain but the Holdings card show a sold HDFC row. One engine across History + Holdings + StockGroup + PortfolioSummary is the only shape that holds the Accounting Tie-Out Principle under cross-master events.

## Decision 2: Server-Classified Holdings Triage — Single Enum, Frontend `@switch`-Renders

A new `ReviewState` enum lives in `core/dto`:

- `OK` — position consistent with the ledger.
- `OVERSOLD` — terminal qty < 0 (replay's no-clamp output) or any `NEGATIVE_QTY`/`SELL_BEFORE_BUY` anomaly on the master. Action hint includes the missing-BUY qty for deep-link prefill.
- `ORPHANED_BUY_NEEDS_RENAME` — BUY activity exists with zero realized trail and zero terminal qty. Action hint sets `supportContact = true`.
- `MISSING_LOCAL_EVENT` — user-fixable ledger gap (IPO/buyback/rights). Hint carries `suggestedTransactionType` + qty.
- `MISSING_GLOBAL_RENAME` — counterparty unresolved at backfill time; admin-only fix.

Classification lives in `LedgerGapDetector` (a pure `core` service) consuming `ReplayResult` outputs; `HoldingService.classifyHoldings` calls it, and `HoldingController.getHoldings` decorates each `HoldingDto` with `reviewState` + `reviewActionHint`. **Excluded holdings (`excludedFromCalculations = true`) are exempt** from classification — opting out of calculations means opting out of nagging.

Fully-liquidated anomalous masters have no `Holding` row to decorate. The controller appends **synthetic ghost DTOs** (`HoldingDto.synthetic = true`, `quantity = 0`) for these so the shelf can render them; the holdings table filters `synthetic === true` so a sold position does not reappear as a zero-qty mid-table ghost.

Frontend renders a `NeedsReviewShelfComponent` above the holdings table when any `reviewState !== 'OK'` exists, plus an inline `@switch` badge in the ticker cell. CTAs deep-link the Add Transaction modal with `prefillTicker` + `prefillQuantity`, or open a `mailto:` for the support paths. No client-side derivation; the frontend `@switch`-renders a server enum (ADR-013).

**Rationale.** A per-event-kind state machine on the frontend (`@switch` on N values per anomaly subtype) is brittle and duplicates backend logic. Collapsing onto five enum values plus a structured `ReviewActionHint` payload keeps the frontend purely presentational. Surfacing oversold as a *flag with remediation* rather than silently clamping to zero is the correctness fix; a few users will see "missing" positions reappear flagged after this ships.

## Decision 3: BhavKosh Is the Authoritative Source for Indian Merger/Spin-off Metadata

The `bhavkosh-mono` collector schema gains `corporate_actions.from_security_id` / `to_security_id` (FK to `securities` with `ON DELETE SET NULL`) and the `action_type` CHECK constraint admits `MERGER` (DEMERGER was already permitted). Migration `002_add_corporate_action_counterparty.sql`. The Java API surface (`CorporateActionRecord`) and `CorporateActionJdbcRepository` LEFT JOIN the new columns and expose them as `from_symbol` / `to_symbol`; null for single-security events, populated for MERGER/DEMERGER.

In Portfolio Optimizer:

- `BhavKoshCorporateActionsClient.BhavKoshCorporateAction` adds `fromSymbol` / `toSymbol`.
- `CorporateActionMergerBackfillJob.backfillForSecurity` routes Indian listings through `backfillForMasterViaBhavKosh` (NSE/BSE via `IndianMarketUtils.isIndianExchange`); non-Indian listings retain the EODHD `/api/fundamentals` fallback. Persists only when the queried ticker matches `from_symbol` so the to-side row is not duplicated when its own ticker is iterated.
- New `CorporateActionSpinoffBackfillJob` mirrors the merger job: JIT listener on `HistoricalPriceBackfillCompletedEvent`, weekly Sunday 05:30 UTC sweep, admin endpoint. **Persists `basis_allocation_pct = NULL`** — the IRS Form 8937 contract from ADR-018 §Decision 3 stays load-bearing; BhavKosh seeds metadata, admin curates the pct via `CorporateActionSpinoffService.recordManualSpinoff` (idempotent on `(parent, child, ex_date)`, flips `source` to `MANUAL`). `PortfolioReplayService.applySpinoff` already treats null pct as `SPINOFF_MISSING_BASIS` and skips basis transfer.
- Unresolved counterparties (BhavKosh row with `from_symbol`/`to_symbol` set but no matching `SecurityListing`) log a structured WARN and skip the row. The user-facing surface for those is `MISSING_GLOBAL_RENAME` (Decision 2).
- Both jobs are gated by `app.jobs.corporate-actions-mergers.enabled` / `app.jobs.corporate-actions-spinoffs.enabled` (default `true`). Per-job `@ConditionalOnProperty` is the rollback surface.

**Rationale.** EODHD's `/api/fundamentals` was the original target in ADR-018 §Decision 3 but is empirically unreliable for Indian listings and gated by subscription tier. BhavKosh has the data, owns the NSE/BSE corporate-actions feed end-to-end, and shares the same database with the price-sweeper sidecar. Repointing was infrastructure-free; the only schema work was the bhavkosh-mono collector migration. ADR-018 Decision 3 stays correct on the *NULL-as-sentinel* discipline; this ADR replaces the EODHD-driven ingest path with BhavKosh.

## Decision 4: Remove `app.features.global-replay`

The flag and every gated branch are deleted. `ReplayParityTest` is deleted with them — it compared two paths and only one remains. `HoldingService`, `HistoryQueryService`, `StockGroupService`, `PortfolioSummaryService` no longer inject `RealizedGainCalculator` directly except where they wrap replay output. `@TestPropertySource(global-replay=true)` is gone from three integration tests. Three legacy regression tests in `HoldingServiceTest` (chronological sort, BONUS dilution, split application on the per-master walk) are deleted; the math is exercised by `PortfolioReplayServiceTest`.

**Rationale.** Carrying both paths beyond burn-in becomes dead code that drifts. The two-commit sequence (ship Holdings-on-replay → remove flag) preserved rollback for one release cycle, which was the original ADR-018 contract.

---

## Consequences

- **Single engine across History, Holdings, StockGroup, PortfolioSummary.** Cross-master mergers/spin-offs now correct every user-visible number from the same `ReplayResult`; the `Accounting Tie-Out Principle` holds across surfaces by construction.
- **Oversold positions surface, not silently disappear.** Users with broken CSVs (gifts, broker transfers, missing IPOs) will see flagged rows on the Needs-Review shelf after this ships. Fix instructions are in the action hint; the shelf's CTA opens Add Transaction prefilled.
- **`Holding.quantity == 0` is a legitimate state.** Code that queries `WHERE quantity > 0` continues to work; code that assumes `holdings` table presence implies a live position breaks. The shelf and `findActive*` repository queries already use exclusion semantics.
- **BhavKosh is now load-bearing for Indian cross-master events.** The bhavkosh-mono service must surface `from_security_id` / `to_security_id` for the Portfolio Optimizer backfill to populate `corporate_action_merger` / `corporate_action_spinoff`. Operationally this is the same dependency that already serves splits, dividends, and historical prices; no new SLO.
- **No path to user writes against `corporate_action_*` tables.** All writes are admin-gated (`CorporateActionSpinoffService.recordManualSpinoff`, `CorporateActionMergerBackfillJob.recordManualMerger`) or job-gated (BhavKosh ingest). The `MISSING_GLOBAL_RENAME` review state is the only frontend signal to the user that they are seeing the gap; no in-app form lets them write to global market data.
- **Spin-off `basis_allocation_pct` is still nullable, still authoritative-only via Form 8937.** ADR-018 §Decision 3's principle stands; only its EODHD-driven ingest plumbing is replaced.
- **Rollback surface is per-job, not global.** Setting `CORPORATE_ACTIONS_MERGERS_ENABLED=false` / `CORPORATE_ACTIONS_SPINOFFS_ENABLED=false` halts the BhavKosh ingest paths without disabling the read-time replay engine. The flag-flip-and-keep-legacy rollback that ADR-018 retained is gone — restoring it is a `git revert` of `fc26b7b`.
