# ADR-032: Oversold Gap Triage — reviewDismissed Flag and Rights Allotments as BUY @ price=0

**Status:** Accepted (with amendments — see banner below)
**Date:** 2026-05-04
**Extends:** ADR-029 (broker corporate-action transactions non-authoritative), ADR-031 (holdings mutate only through replay)

> **Amendments**
> - **§Decision 1** (RIGHTS_IN inert in the AVCO timeline) is **relaxed by [ADR-033](033-source-aware-replay-filter.md)**: rows of type `RIGHTS_IN` (and four sibling broker-reported corporate-action types) now pass the replay filter when `source = MANUAL_USER`. The "BUY @ price=0" workaround documented here remains valid for back-compat but is no longer the only correct path — ADR-033 §Decision 1 covers manual rows of the type's intended enum directly.
> - **§Decision 2** (global `security_master.review_dismissed`) is **replaced by [ADR-035](035-per-user-review-dismissal.md)**: dismissals are now stored per-user in a new `master_review_dismissal` association table. Two users with independent transactions on the same master no longer share dismissal state.

---

## Context

The Needs-Review shelf surfaced OVERSOLD positions (terminal quantity < 0) but had a broken CTA wired to the manual-stock-add feature removed in ADR-031. Real-world OVERSOLD causes split into three families:

- **Rights / bonus allotments** (`-RE` ticker series) — entitlement received free, sold for proceeds, no recorded BUY ever existed.
- **Genuinely missing trades** — broker history is incomplete; the user wants to record the real BUY.
- **Renames / mergers** (e.g. `RBA←BURGERKING`, `ADANIENSOL←ADANITRANS`) — solvable via `corporate_action_merger`; deferred.
- **Don't know** — user needs an escape hatch that mutes the badge without falsifying realized gain.

Two architectural decisions arose: (1) how to record a user-acknowledged rights allotment without silently poisoning the AVCO timeline, and (2) how to let users suppress a review nag without affecting their calculated positions.

---

## Decision 1: User-Initiated Rights Allotments Are BUY Transactions at price=0

`RIGHTS_IN` is in `PortfolioReplayService.BROKER_REPORTED_CORPORATE_ACTION_TYPES` (ADR-029 Decision 1) and is **dropped from the AVCO timeline at the timeline-build step**. A user-submitted `Transaction` of type `RIGHTS_IN` would be silently inert — no quantity added, no cost basis recorded — without any error surfaced to the user.

The correct form is `transactionType='BUY'` with `price=0`:

- The `BUY` row enters the AVCO walk as a real acquisition event (`quantity` added to position, cost basis = `0`).
- A subsequent `SELL` on the same position produces `100% realized gain = sell proceeds`, which is the mathematically correct treatment of a free entitlement.
- This is identical accounting to how broker-reported `RIGHTS_IN` rows *would* behave if they were not filtered — the economics are the same, only the enum value differs.

The frontend `onReviewMarkRights` path in `portfolio.component.ts` sends `transactionType='BUY'` explicitly. `securityListingId` is forwarded in the payload to bypass `findOrCreateByTicker`, which can create phantom listings for unusual symbols (e.g. `-RE` rights series).

The `-RE` ticker suffix auto-promotes "Mark as rights allotment" to the primary CTA in the shelf for visual ergonomics, but the user still clicks once and confirms — no silent auto-mutation.

**Invariant:** `RIGHTS_IN` must not be used for any user-initiated allotment entry. Any UI path that submits `RIGHTS_IN` will be silently inert under ADR-029's replay filter, producing no position change and no error.

---

## Decision 2: `SecurityMaster.reviewDismissed` Is Nag-Suppression Only — Distinct from `excludedFromCalculations`

A new boolean field `reviewDismissed` on `SecurityMaster` (Flyway `V20260504140000__AddReviewDismissedToSecurityMaster.sql`, `NOT NULL DEFAULT FALSE`) suppresses the review-shelf appearance of a master without altering any calculation.

This is explicitly distinct from `Holding.excludedFromCalculations`:

| Flag | Lives on | Effect |
|------|----------|--------|
| `excludedFromCalculations` | `Holding` | Removes position from all totals, analytics, and allocation math — opt-out semantics. |
| `reviewDismissed` | `SecurityMaster` | Suppresses only the review-shelf badge; the position remains in all calculations at full weight; realized gain still accrues against zero cost basis. |

These two flags **must never be merged or conflated**. A user who dismisses an OVERSOLD row is saying "I know about this, leave me alone." They are not saying "exclude this from my net worth." Merging the two would either corrupt analytics (wrong net worth) or leave a user permanently nagged about a position they have already decided to ignore.

**Endpoint:** `PUT /api/holdings/master/{masterId}/dismiss-review` body `{"dismissed": boolean}` → 204. `HoldingService.setMasterReviewDismissed` validates that the authenticated user owns at least one transaction touching the master (auth scope). Synthetic ghost DTOs for dismissed masters are skipped in `HoldingController`'s ghost loop — they do not appear on the shelf.

---

## Decision 3: Structured Three-Action Triage Surface per OVERSOLD Row

Each OVERSOLD row renders three actions: primary + secondary + overflow (`…`). Action order is CTA-flipped for `-RE` tickers:

| Ticker pattern | Primary | Secondary | Overflow |
|---|---|---|---|
| Ends with `-RE` | Mark as rights allotment | Add missing BUY | Dismiss |
| Anything else | Add missing BUY | Mark as rights allotment | Dismiss |

Supporting infrastructure:

- `ReviewActionHint` extended with `suggestedTransactionDate` (`OffsetDateTime`, day before earliest SELL) — seeds the date picker in the new `add-buy-dialog` component so the user lands on the correct default date without manual computation.
- `HoldingDto.securityMasterId` added (canonical effective master ID via `SecurityMaster.getEffectiveId()`) — gives the dismiss CTA a stable FK to call the dismiss endpoint; critical because OVERSOLD surfaces as a synthetic ghost DTO with no `Holding` row from which to derive the master.
- New `add-buy-dialog` Angular component — purpose-built for the single-transaction manual entry path that ADR-031 removed from the generic `add-transaction-modal`. Validates date (required, not in future) and price (required, > 0). Sends `securityListingId` when present to bypass ticker resolution.

---

## Consequences

- **BUY @ price=0 is the sanctioned path for all user-initiated free allotments.** `RIGHTS_IN` is permanently reserved for broker-reported rows that are inert under ADR-029. Any future feature that constructs a rights entitlement transaction must use `BUY` with `price=0`.
- **`reviewDismissed` and `excludedFromCalculations` must not be unified.** Future metadata-patch endpoints for holdings must keep the two suppression flags orthogonal.
- **Dismissed OVERSOLD positions retain their calculated state.** The position quantity remains 0 in the projection, cost basis remains 0, and realized gain remains equal to the full sell proceeds. The flag changes shelf visibility only.
- **`HoldingDto.securityMasterId` is now a load-bearing field for the dismiss flow.** Any refactor that removes or nullifies this field will break the dismiss CTA for ghost-only masters.
- **Stale `RIGHTS_IN` rows from the test period are inert.** Any `Transaction` rows of type `RIGHTS_IN` written before this ADR was applied are filtered by ADR-029's replay filter and contribute zero to position math. They remain in the ledger per ADR-002 (Never Drop Data).

---

## Alternatives Considered

- **Use RIGHTS_IN natively with a new `corporate_action_rights_issue` table as the authoritative source.** Rejected: no such table exists, EODHD does not provide rights-issue data via the existing ingestion jobs, and the manual-admin entry path for rights coverage is net-new scope. BUY @ price=0 achieves the identical accounting through the existing AVCO machinery.
- **Extend `Holding.excludedFromCalculations` to serve as the dismiss mechanism.** Rejected: it removes the position from all totals — incorrect for a user who knows the allotment is real and only wants to suppress the nag badge. The two suppression semantics are categorically different.
- **Place `reviewDismissed` on `Holding` rather than `SecurityMaster`.** Rejected: OVERSOLD positions surface as synthetic ghost DTOs; there is no `Holding` row to carry the flag. Placing it on `SecurityMaster` also means a dismissed status survives holding-table replays without needing to be re-applied.
- **Auto-detect -RE as rights and record BUY @ price=0 without user confirmation.** Rejected: the `-RE` suffix is a heuristic hint, not a guarantee. A single confirmation dialog costs one click and eliminates silent ledger mutations for any false-positive ticker match.
