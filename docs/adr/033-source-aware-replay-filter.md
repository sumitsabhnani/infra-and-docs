# ADR-033: Source-Aware Replay Filter — Manual Entry as Failsafe for Broker-Reported Corporate Actions

**Status:** Accepted
**Date:** 2026-05-05
**Extends:** ADR-029 (broker corporate-action transactions non-authoritative), ADR-032 (oversold gap triage)
**Related:** Issue #280

---

## Context

`PortfolioReplayService.keepForReplayOrLogSkip` filters every `Transaction` of type `{BONUS, SPLIT, MERGER_IN, MERGER_OUT, SPINOFF_IN, RIGHTS_IN}` from the AVCO replay walk under ADR-029's "canonical CA tables are authoritative" rule. This is correct for the four types backed by canonical tables (`corporate_action_split` / `_merger` / `_spinoff` / `_cash_dividend`) but wrong for `RIGHTS_IN` and `BONUS` — neither has a canonical CA table, so the user's shares vanish and any subsequent `SELL` goes OVERSOLD with zero AVCO basis.

ADR-032 sanctioned `BUY @ price=0` as a manual workaround for `RIGHTS_IN`, but the underlying engine bug remains: a user creating a `Transaction` row of the appropriate enum type to record a corporate action they participated in has no effect.

---

## Decision 1: Add `Transaction.source` and Gate the Filter on It

A new enum `Transaction.TransactionSource = {BROKER_SYNCED, CSV_IMPORT, MANUAL_USER}` is persisted in `transactions.source` (NOT NULL, default `BROKER_SYNCED` for back-compat). The replay filter `shouldFilterCorporateActionTxn` becomes:

- `type ∉ BROKER_REPORTED_CORPORATE_ACTION_TYPES` → keep.
- `type == SPLIT` → drop (always — `corporate_action_split` is auto-fetched from EODHD JIT, so a manual SPLIT would double-count alongside `applySplit(factor)`).
- `source == MANUAL_USER && type ∈ {RIGHTS_IN, SPINOFF_IN, MERGER_IN, MERGER_OUT, BONUS}` → keep.
- Otherwise (broker-synced / CSV-import / null source) → drop with a WARN.

`source = null` fails closed (treated as broker-synced and dropped). This guards against corrupt fixtures and any path that bypasses the service-layer stamp.

`source` is stamped at the **service layer**, not the controller — `TransactionService.createTransaction` and `updateTransaction` set `MANUAL_USER`; `BrokerSyncService` and `SnapTradeActivityMapper` set `BROKER_SYNCED`; `CsvImportService` sets `CSV_IMPORT`. The controller is layer-pure (ADR memory: "Events publish from services").

The relaxation is partial: only `{RIGHTS_IN, SPINOFF_IN, MERGER_IN, MERGER_OUT, BONUS}` pass the filter for `MANUAL_USER`. `SPLIT` is excluded because the per-account broker SPLIT row would double-count with the canonical `corporate_action_split` table for the same master and ex-date. If `corporate_action_bonus_issue` ingestion is added in a future iteration, `BONUS` should be removed from the allow-list for the same reason.

`RealizedGainCalculator.AvcoState.step` already implements correct math for all five types (qty addition with row-price cost; MERGER_OUT zeros the predecessor's position with proportional cost reduction). No engine code change is needed beyond the filter.

## Decision 2: Stamp at Persistence, Not at Computation

Stamping at the builder site (rather than via a `@PrePersist` hook) makes provenance explicit at the call site and lets us require it. `Transaction.source` has **no builder default** — a missed call site fails at write time when the NOT NULL constraint rejects the insert. This forces every persistence path to make a deliberate choice.

Test fixtures set `source = BROKER_SYNCED` as their default — preserves existing behavior across the 27 builder sites in `core/src/test` and `api/src/test`.

## Decision 3: ADR-032 §Decision 1 (RIGHTS_IN inert) Is Relaxed, Not Replaced

ADR-032's "BUY @ price=0" path remains valid — it produces the same economics (free entitlement → 100% realized gain on subsequent SELL). After this ADR, both forms work:

- The user enters a `Transaction` of type `RIGHTS_IN` directly (preferred — matches the user's mental model and the broker's enum).
- The user enters a `BUY` with `price=0` (back-compat — what the frontend shipped in ADR-032).

The frontend can migrate at its own pace.

---

## Consequences

**Positive**
- User-entered RIGHTS_IN / SPINOFF_IN / MERGER_IN / MERGER_OUT / BONUS rows now mutate AVCO state correctly.
- The 6-type broker-reported filter still drops sync-pipeline rows (preserves ADR-029's invariant for the 4 types with canonical tables).
- The decision predicate is one method (`shouldFilterCorporateActionTxn`) — single source of truth for both the upstream filter and the multi-master walk's defence-in-depth check.

**Negative**
- One new column (`source`) on the largest table. `VALIDATE CONSTRAINT` takes a SHARE lock during deploy — non-blocking for INSERT/UPDATE but visible to operators.
- Manual SPLIT entries are silently inert. Acceptable today (the canonical table covers the case); revisit if users complain.
- `RIGHTS_IN` is now ambiguous between the ADR-032 workaround (BUY @ price=0) and the new direct path. Both produce identical realized gain; documentation in `Transaction.TransactionType.RIGHTS_IN` Javadoc explains.

**Neutral**
- Sources other than the three in the enum are not allowed (CHECK constraint enforces). Adding a new source (e.g. `IMPORT_FROM_OTHER_TOOL`) requires a migration.

---

## Alternatives Considered

1. **Per-row admin override flag.** Rejected — does not capture provenance, and the natural place for the flag is the entry path (which already knows where it came from).
2. **Synthetic broker_activity_log row for manual entries.** Rejected — couples manual entry to the SnapTrade-specific audit log.
3. **Ingest `corporate_action_bonus_issue` / `_rights_issue` from EODHD/BhavKosh.** Deferred (out of scope per issue #280). When this lands, BONUS should leave the MANUAL_USER allow-list and RIGHTS_IN should follow.

---

## Verification

- Unit tests in `PortfolioReplayServiceCorporateActionGuardTest`:
  - `manualSourceFiveAllowedTypes_areApplied` — each of the 5 allow-listed types contributes to AVCO qty.
  - `manualSourceSplit_isStillDropped` — manual SPLIT remains filtered.
  - `nullSourceFailsClosed` — corrupt fixtures don't accidentally enable the failsafe.
  - `bonusFromBrokerStillSkipped_butCanonicalSplitDrivesQty` — BhavKosh-bonus-as-split case.
- `TransactionFxNormalizerSourceTest` confirms FX normalization preserves source.
