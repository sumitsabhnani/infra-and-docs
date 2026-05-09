# ADR-035: Per-User Review Dismissal

**Status:** Accepted
**Date:** 2026-05-05
**Replaces:** [ADR-032 §Decision 2](032-oversold-gap-triage-review-dismissed-and-rights-buy.md) (global `review_dismissed` flag on `security_master`)
**Related:** Issue #280

---

## Context

ADR-032 stored the "Don't show in Needs-Review shelf" flag as a boolean column `security_master.review_dismissed`. The original framing was "ghost rows attach to a master, not to a user", which is true for synthetic ghosts but **false for any master held by more than one user**. User A dismissing the master hid it from user B, who has independent transactions and may legitimately want to act on the same OVERSOLD condition.

This is a multi-tenant correctness bug. The flag must be per-user.

---

## Decision: Per-User Association Table

A new association table `master_review_dismissal (user_id, master_id, dismissed_at)` replaces the global flag:

```sql
CREATE TABLE master_review_dismissal (
    user_id UUID NOT NULL,
    master_id UUID NOT NULL,
    dismissed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, master_id),
    CONSTRAINT fk_mrd_user FOREIGN KEY (user_id)
        REFERENCES users(id) ON DELETE CASCADE,
    CONSTRAINT fk_mrd_master FOREIGN KEY (master_id)
        REFERENCES security_master(id) ON DELETE CASCADE
);
CREATE INDEX idx_mrd_master_id ON master_review_dismissal(master_id);
```

`HoldingService.setMasterReviewDismissed(userId, masterId, dismissed)`:
- Auth check unchanged — `transactionRepository.existsByUserIdAndEffectiveMasterId` ensures the caller has a stake in the master.
- `dismissed=true` → idempotent INSERT (pre-check then save; DB-level uniqueness on the PK is a backstop).
- `dismissed=false` → DELETE by (userId, masterId).

`HoldingController` ghost-loop pre-loads the user's full dismissed set once per request (`findMasterIdsByUserId`) and intersects with the classified masters — no N+1.

ADR-032's split between `reviewDismissed` (nag-suppression) and `excludedFromCalculations` (calculation opt-out) is preserved. The new table only replaces the storage of the former.

## Decision: Backfill Existing Global Dismissals Per User

Migration `V20260505100100__CreateMasterReviewDismissal.sql` creates the table and runs:

```sql
INSERT INTO master_review_dismissal (user_id, master_id, dismissed_at)
SELECT DISTINCT p.user_id, sm.id, NOW()
FROM security_master sm
JOIN security_listing sl ON sl.security_id = sm.id
JOIN transactions t ON t.security_listing_id = sl.id
JOIN portfolios p ON p.id = t.portfolio_id
WHERE sm.review_dismissed = TRUE
ON CONFLICT (user_id, master_id) DO NOTHING;
```

Every user with at least one transaction on a globally-dismissed master inherits the dismissal. This preserves ADR-032's intent ("the user clicked dismiss; suppress for them") without leaking to others. The `INSERT ... ON CONFLICT DO NOTHING` is idempotent on retry.

## Decision: Drop the Column in a Separate, Later-Timestamped Migration

`V20260505100200__DropReviewDismissedFromSecurityMaster.sql` runs after the create+backfill in version order. **Splitting** the operations means a rollback between the two migrations is non-destructive — the column is still present, the new table is correctly populated. Both ship in the same PR; Flyway runs them in version order.

---

## Consequences

**Positive**
- User A's dismissal no longer affects User B.
- Backfill preserves existing user intent; nothing rolls forward as "un-dismissed."
- The dismissal lookup is per-request, batch-loaded — no N+1 across the ghost-loop.

**Negative**
- One join through `transactions` for the backfill. Cardinality is bounded by `(rows where review_dismissed=TRUE) × (users per master)`; small in the current solo-dev product. If the table grows significantly before deploy, switch to a chunked admin-endpoint backfill.
- ON DELETE CASCADE on both FKs means a hard-deleted user or master cleans up dismissal rows automatically. Acceptable — these rows have no value without their referent.

**Neutral**
- The `dismissed_at` timestamp is informational only; no UI surfaces it today. Future analytics on shelf engagement can use it.

---

## Verification

- `PerUserReviewDismissalIntegrationTest`:
  - `dismissalIsPerUser` — user A's dismiss leaves user B's shelf intact.
  - `idempotentDismiss` — clicking dismiss twice writes one row.
  - `undismissDeletesRow` — dismissed=false removes the row.
- The existing `HoldingControllerIntegrationTest.dismissTogglesGhostVisibility` continues to pass (single-user case is unchanged behavior).
