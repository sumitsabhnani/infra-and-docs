# ADR-051: Bidirectional Position-vs-Ledger Reconciliation, Grace Window & Provider-Aware Historical Close Triage

**Status:** Accepted (`snaptrade_position_reconciliation` gated, default `false` on initial deploy)
**Date:** 2026-11-24
**Extends:** [ADR-013](013-history-page-architecture.md) (History page architecture), [ADR-014](014-read-time-stock-splits.md) (read-time stock splits), [ADR-031](031-manual-stock-add-removed.md) (three-way holdings authority), [ADR-032](032-oversold-gap-triage-review-dismissed-and-rights-buy.md) (Needs-Review triage), [ADR-034](034-isin-auto-aliasing-and-link-previous.md) (ISIN aliasing & link-previous), [ADR-037](037-feature-flags-perimeter-guarded-branch-by-abstraction.md) (Branch-by-Abstraction flags), [ADR-050](050-subscription-tiers-snaptrade-cogs-cleanup-and-manual-conversion.md) (cutoff-anchored manual conversion)

---

## Context

Broker activity feeds and tradebook CSVs (most notably Zerodha Console and SnapTrade Zerodha syncs) record exchange-executed trades only and omit off-market Demat movements (CDSL gifts, IPO allotments, ESOP grants, off-market transfers, and unlinked ticker renames). Five failure modes surfaced across sender and recipient portfolios:

1. **Ledger-only blind spots:** `LedgerGapDetector` inspected `ReplayResult` in isolation (`replayQty < 0` → `OVERSOLD`). Unsold received gifts (`heldQty > 0, replayQty == 0`) and gifted-out positions (`heldQty == 0, replayQty > 0`) classified as `OK`, leaving **Needs Review** and `/portfolio/history?tab=missing` empty while `PortfolioLedgerCoverageEvaluator` paused `XIRR` and the Performance chart.
2. **Partial-sell + gift-out terminal cliff:** In `PortfolioLedgerCoverageEvaluator`, a position with an earlier exchange `SELL` (`mastersWithSellActivity == true`) whose remaining shares were gifted out (`replayQty > 0, heldQty == 0`) was neither vetoed nor omitted, causing historical wealth/TWR curves to value those shares up to yesterday and crash vertically to `0` on `today`.
3. **Positions-vs-activities sync lag & positions-only accounts:** Incremental SnapTrade syncs fetch positions before activities, and positions-only brokers exhaust 6 empty catch-up attempts with `AccountSyncState.lastSyncedAt == null`. Naive immediate reconciliation would flag today's trades or flood Needs Review on positions-only accounts.
4. **Global alias-link hazard on coincidental round lots:** `SecurityMasterAliasService.linkAlias` mutates global `canonical_master_id`. Promoting one-click rename linking on uncorroborated quantity matches (e.g., round lots of `50` or `100` in gift batches) or allowing unverified holding-only `linkAlias` calls risks merging unrelated securities globally.
5. **Stale pre-split `BHAVKOSH` bars & manual historical price hunting:** `BHAVKOSH` daily bars are stored split-adjusted to terminal basis, whereas `EODHD`/`YAHOO` bars are stored unadjusted. Daily 5-day refreshes never re-fetched older `BHAVKOSH` bars when a new split arrived, distorting both charts and historical trade-date price lookups.

---

## Decisions

### Decision 1: Unified `PortfolioReviewClassifier` & Runtime ADR-037 Strategies

- All Needs-Review and History Data-Issues classification consolidates into `PortfolioReviewClassifier` (`core`), exposed through `PositionGapReconciliationStrategy` and `LedgerCoveragePolicy` (`PositionReconciliationConfig`, keyed on runtime flag `snaptrade_position_reconciliation` with bounded `DailyPortfolioShadowLogLimiter` logging at most once per portfolio per UTC day while disabled).
- **Master universe:** Evaluates `replayTerminals.keySet() ∪ heldByEffectiveMaster.keySet()` (`QTY_COVERAGE_TOLERANCE = 0.0001`), emitting `MISSING_BUY_HISTORY` (`heldQty - replayQty > 0.0001`) and `UNRECORDED_DISPOSAL` (`replayQty - heldQty > 0.0001`), upgrading `OVERSOLD` quantities to `max(shortfallOnD0, (heldQty - replayQty) / F(d0 -> today))` when held shares exceed replay, and unifying `HistoryQueryService` (`?tab=missing`, including `0`-transaction portfolios) with `HoldingService`.
- **Coverage cliff guard:** Under `snaptrade_position_reconciliation`, `PortfolioLedgerCoverageEvaluator` vetoes any unomitted master with `replayQty > 0.0001 && heldQty == 0` even when `mastersWithSellActivity` is `true`, eliminating terminal-day vertical chart cliffs.

### Decision 2: Settled Gate, `portfolio_position_change` Grace Window & DAG Deferral

- **Settled gate:** Live SnapTrade reconciliation runs iff **every** portfolio connection is `ACTIVE + COMPLETED + SUCCESS` with non-null `lastSyncedAt` and **every** scoped account has `STATUS_SUCCESS`, `nextCatchupAt == null`, and `lastSyncedAt != null` (excluding positions-only accounts). Cutoff-anchored converted portfolios (`convertedFromBrokerSyncAt != null`, ADR-050) are settled by construction. When `> 10` `MISSING_BUY_HISTORY` rows appear on the shelf, `NeedsReviewShelfComponent` collapses them into a single expandable summary card.
- **Grace window (`portfolio_position_change`):** Tracks `(portfolio_id, security_master_id)` (`ON DELETE CASCADE` on both FKs) with `first_observed_at`, `last_changed_at`, `last_observed_quantity`, `syncs_since_change`, and `last_sync_counted_at`. `SnapTradeHoldingsReconciler.persistHoldings` resets `syncs_since_change = 0` on quantity changes (`> 0.0001`), and `SnapTradeService.markSyncCompleted` increments `syncs_since_change` at most **once per clean portfolio-wide sync cycle** (requiring every connection on the portfolio to be settled and `lastSyncedAt > max(lastChangedAt, lastSyncCountedAt)`). Live SnapTrade gaps are suppressed while `last_changed_at > now - 7d`, `syncs_since_change < 2`, or any `BROKER_SYNCED` transaction on that master has `transaction_date > now - 7d` (`MANUAL_USER` and `CSV_IMPORT` fixes never trigger suppression).
- **Corporate-action DAG deferral:** Any descendant master reachable via `corporate_action_spinoff`, `corporate_action_merger`, or replay `CorporateActionLedgerEntry` edges (even with `> 0` transactions) is deferred while any ancestor has an open review state.

### Decision 3: Corroborated Rename-Pair Confidence & Classifier-Verified `linkAlias`

- Unique 1:1 split-equivalent same-currency pairs `(UNRECORDED_DISPOSAL [held=0], MISSING_BUY_HISTORY [replay=0, 0 txns])` carry `suggestedCounterpartyMasterId`, `suggestedSymbol`, and `renameConfidence`:
  - **`HIGH` (Primary CTA `Link to <ticker>`):** Corroborated by `security_listing_rename_history`, shared 6-char same-country ISIN issuer prefix, or `|exitDate - firstObservedDate| <= 14d` post-initial-sync.
  - **`LOW` (Secondary CTA `Possibly renamed from <ticker>?`):** Quantity-only match keeps `Add missing BUY / Gift` primary and warns against coincidental round-lot global merges.
- On the holding-only authorization path (`0` transactions on `newMasterId`), `SecurityMasterAliasService.linkAlias` requires transactions on `previousMasterId` **and** re-runs `PositionGapReconciliationStrategy` on the caller's portfolio(s), returning `FORBIDDEN` unless `effectivePreviousId.equals(hint.suggestedCounterpartyMasterId())`.

### Decision 4: BhavKosh Post-Split History Refresh & Scalar `historical-close` Endpoint

- Inserting a split/bonus in `CorporateActionSplitBackfillJob` (or startup `ApplicationReadyEvent` self-heal) re-queues active `BHAVKOSH` symbols on that canonical master to `backfill_status = 'PENDING'` and fires `HistoricalPriceBackfillRequestedEvent`.
- `DailyBarSplitAdjuster` (`core/util`) centralizes terminal-basis (`PortfolioPerformanceService`, `TickerDetailService`) and trade-date unadjusted-basis (`HistoricalCloseLookupService`) `BigDecimal` math.
- `GET /api/holdings/listings/{listingId}/historical-close` (`120 req/hr/user`, owner-scoped via `Holding` or `Transaction` on effective master) returns a single scalar unadjusted close (10-day holiday step-back, withholding `BHAVKOSH` prices while `backfill_status IN ('PENDING','SYNCING')`) plus `preSplitEquivalentQuantity` for the dual-mode (`BUY`/`SELL`) `AddBuyDialogComponent` — never a candle series.

---

## Consequences

- **End-to-end gift & transfer triage:** Both recipient (`MISSING_BUY_HISTORY`) and sender (`UNRECORDED_DISPOSAL`) accounts surface accurate, split-aware fixes across **Needs Review** and **History → Data Issues**, unlocking `XIRR` and Performance curves without vertical cliffs or `BUY @ 0` return distortion.
- **Zero false-positive sync churn or accidental global merges:** Multi-connection portfolios, delayed broker activity feeds, positions-only brokers, and round-lot gift batches are protected deterministically before any prompt or alias link fires.
