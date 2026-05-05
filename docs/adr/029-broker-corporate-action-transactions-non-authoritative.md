# ADR-029: Broker-Reported Corporate-Action Transactions Are Non-Authoritative for AVCO

**Status:** Accepted
**Date:** 2026-05-03
**Supersedes:** ADR-028 §Decision 2 (the claim that `Transaction.{BONUS,SPLIT,MERGER_IN,MERGER_OUT,SPINOFF_IN,RIGHTS_IN}` feeds the AVCO walk)
**Extends:** ADR-014 (read-time stock splits), ADR-024 (cross-master corporate actions end-to-end), ADR-028 (SnapTrade activity dual-track routing)

---

## Context

ADR-014 established that splits live in `corporate_action_split` keyed by `security_master_id` and apply at read time inside `AvcoState.applySplit`. ADR-024 generalised the same pattern to cross-master mergers and spin-offs. ADR-028 §Decision 2 then claimed the per-account broker emissions — `Transaction` rows of types `BONUS, SPLIT, MERGER_IN, MERGER_OUT, SPINOFF_IN, RIGHTS_IN` — also feed AVCO via `RealizedGainCalculator.applyTransaction`. Both paths were live simultaneously.

For securities with both a broker-reported corp-action receipt AND an EODHD/BhavKosh canonical event (i.e. effectively every Indian or US split that affects an actively-held position), the AVCO walk applied both: the `corporate_action_split` row scaled `totalShares` via `applySplit(factor)`, and the `Transaction.SPLIT` row added its own quantity via `applyTransaction`. Result: silently doubled holdings on every replay. No NPE — `RealizedGainCalculator.AvcoState.step` handles `price = null` gracefully — just wrong numbers.

CSV import was a second writer of the same broker-reported rows: `BROKER_TYPE_ALIASES` mapped 13 broker labels (`BONUS_ISSUE`, `STOCK_SPLIT`, `DEMERGER`, `MERGER_RECEIPT`, `RIGHTS_ISSUE`, etc.) into the same six enum values. A user who included a `1:1 BONUS` row for INFY in a Zerodha CSV got a `Transaction.BONUS` row written; the EODHD JIT then wrote a `corporate_action_split` row for the same event; the next replay double-counted.

The principle violation is the same one ADR-014 was originally written to enforce: **`security_master_id`-keyed `corporate_action_*` tables are the single source of truth for system-wide ex-events**. ADR-028 §Decision 2 read that as compatible with broker-emitted per-account receipts also feeding AVCO. It is not. AVCO has one source of truth or none.

---

## Decision 1: `corporate_action_*` Is the Only AVCO-Authoritative Source for Corporate Events

`PortfolioReplayService` filters out every `Transaction` row whose type is in:

```java
BROKER_REPORTED_CORPORATE_ACTION_TYPES = { BONUS, SPLIT, MERGER_IN, MERGER_OUT, SPINOFF_IN, RIGHTS_IN }
```

The filter is applied at the timeline-build step in both walk paths — `walkMultiMasterChain` (the cross-master connected-component path from ADR-024) and `walkTrivialChain` (the single-master shortcut). Filtering at `txnsByMaster` grouping covers the trivial-chain path that delegates straight to `RealizedGainCalculator.computeEpisodesAndSellRealized` without going through the per-event `instanceof ReplayEvent.Txn` branch.

Filtered rows are logged at WARN with `(transaction_id, type, masterId)` once per row per replay so operators can see what's being skipped, but they contribute zero to `AvcoState.step` / `applySplit` / `mergeFrom`. The canonical `corporate_action_*` row (EODHD or BhavKosh) is the only thing that moves quantity or cost basis.

The `transactions` rows themselves stay in the ledger — ADR-002 "Never Drop Data" means we don't delete them, and they remain visible on the History page as audit. They are simply non-authoritative for position math.

## Decision 2: CSV Drops Broker-Reported Corp-Action Rows at Ingestion

CSV import never persists a `Transaction` row of a corporate-action type. `CsvImportService` strips the 13 broker-label entries from `BROKER_TYPE_ALIASES`, and `previewTransactions` / `previewAiFlexible` flag any row whose resolved type is in `CORPORATE_ACTION_TYPES` as `RowStatus.CORPORATE_ACTION_DROPPED`. Commit short-circuits these rows, increments `corporateActionsDropped` on the response, and never reaches `transactionRepository.save`. `AiCsvMapper.mergeCorporateActionSkipDefaults` pre-seeds the same broker labels into the LLM-supplied `skipTypes` so the user sees them tagged as auto-handled in the very first preview round-trip.

The frontend renders the count in a dedicated stat tile (`Corporate actions (auto-fetched)`) with a tooltip naming EODHD/BhavKosh as the source. The user is not asked to reclassify these — there is no correct reclassification.

This is belt-and-braces with Decision 1: the replay-side filter is the load-bearing guarantee, but blocking at ingestion keeps the ledger clean of rows that have no accounting purpose and means the `transactions` table for new CSV imports doesn't accumulate audit-only noise. SnapTrade's `SnapTradeActivityMapper` is **not** changed by this ADR — it continues to write per-account corp-action receipts to `transactions` for the audit trail. Decision 1's replay-side filter handles SnapTrade silently. Cleaning up the SnapTrade writer is tracked separately and is not blocking — the rows are inert under Decision 1.

## Decision 3: Holdings Persistence Reads `Transaction.securityListing` Directly

`HoldingService.persistHoldingFromReplay` no longer round-trips through `IdentifierResolver.resolve(SecurityIdentifier.fromTicker(...))` to obtain the `security_master_id` for a holding. The transaction's `security_listing_id` FK is populated at every write path (CSV `resolveListing`, SnapTrade activity mapper, manual entry) and is the authoritative listing reference; `listing.getSecurity().getEffectiveId()` is the canonical master id. Both fields are loaded eagerly via the active JPA session — no extra DB round-trip.

The resolver call was the source of the `AmbiguousIdentifierException` WARN cascade observed for tickers that exist on multiple exchanges with the same currency (e.g. `RELIANCE` on NSE and BSE both INR). The catch-block fallback returned exactly `ResolvedIdentity.fromListing(listing.getId(), listing.getSecurity().getId(), listing.getTradingCurrency())` — the same data the new direct-navigation path returns, but without the WARN, the redundant query, or the silent risk of picking a different listing on a future resolver change.

This is a regression fix more than an architectural rule, but it codifies a related invariant: **read-time persistence trusts the FKs already on the row; the resolver is for write-time ingest only**. Future read paths added to `HoldingService` should follow the same pattern.

---

## Consequences

- **Holdings quantities for users with both CSV-imported and EODHD-canonical corp-action records will shift on next replay.** The shift is a correction — the formerly double-counted positions converge to the EODHD/BhavKosh-only number. Users who only have one source were never affected.
- **`Transaction.TransactionType` is not narrowed.** The six broker-emitted values (`BONUS, SPLIT, MERGER_IN, MERGER_OUT, SPINOFF_IN, RIGHTS_IN`) stay in the enum and stay in `RealizedGainCalculator.applyTransaction` for any future case where AVCO might consume them (e.g. an admin-only manual entry for a security with no canonical corp-action coverage). The replay filter is the gate; the math stays available behind it.
- **CSV import surfaces a new row outcome.** `RowStatus = CORPORATE_ACTION_DROPPED` joins `NEW | DUPLICATE | SKIPPED | INVALID`. `CsvCommitResponse` and `CsvPreviewResponse` carry `corporateActionsDropped` counters. The frontend renders a non-error stat tile.
- **Bug surface narrows.** A future ADR that adds a new broker corp-action vocabulary (e.g. SnapTrade emits `STOCK_DIVIDEND_2026`) cannot accidentally pollute AVCO unless it's added to `BROKER_REPORTED_CORPORATE_ACTION_TYPES`. The default is "non-authoritative" — opt-out, not opt-in.
- **`SnapTradeActivityMapper` cleanup is now optional.** It still writes per-account corp-action receipts; under Decision 1 they no longer affect holdings. A follow-up may route them to a dedicated `broker_reported_corporate_action_log` audit table to keep `transactions` purely trade-shaped, but is not required for correctness.
- **The WARN spam pattern from `FigiBasedIdentifierResolver:150` (`Legacy Ticker Resolution triggered`) loses its primary trigger.** The spam was driven by `HoldingService.persistHoldingFromReplay` round-tripping the resolver on every holding on every split-driven replay — Decision 3 removes the call entirely. The remaining `resolveMasterId` call site (line 470) only fires for legacy listings without a `security_master` link, which is the resolver's intended use.

## Alternatives Considered

- **Add a `(security_master_id, ex_date)` dedup check in the AVCO walk** — applying the broker-reported transaction only when no canonical `corporate_action_*` row exists for the same date. Rejected: brittle date-matching across timezones, doesn't help when the broker reports a slightly different ratio than EODHD (which is the more realistic broker-feed bug shape), and leaves the broker-vs-canonical disagreement silent. The flat "canonical wins" rule is simpler and audit-friendly.
- **Delete the broker-reported corp-action `Transaction` rows from production data** as a backfill. Rejected per ADR-002 — the rows are the audit trail of what the broker reported. Decision 1's read-time filter corrects holdings on next replay without touching the ledger.
- **Drop the six broker-emitted enum values entirely** (narrow `Transaction.TransactionType` back to the four trade-shaped values). Rejected: would force a migration to convert existing rows (or accept a Hibernate validation failure), removes the possibility of future admin-managed AVCO consumption for orphan masters, and conflates "non-authoritative" with "non-existent". The enum value is the broker's vocabulary; the AVCO consumption is the policy. Keep them separate.
- **Make CSV import accept the rows but mark them with a `replay_authoritative=false` column on `transactions`.** Rejected: adds a column to the immutable ledger to encode a pure read-time policy, and the same policy is already expressible at the read site via the type set. The replay filter is the simpler shape.
- **Update SnapTrade's `SnapTradeActivityMapper` in the same change to stop writing these rows.** Deferred: SnapTrade is a separate ingestion path with its own dedup contract and no preview UX to surface "this row was dropped". Decision 1 already neutralises the rows for AVCO; cleaning up the writer is cosmetic and can ship independently.
