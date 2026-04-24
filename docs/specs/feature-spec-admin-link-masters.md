# Feature Spec — Admin Endpoint: Link Duplicate `SecurityMaster` Rows

## Problem

The ingestion dedup fix stops *new* duplicate `security_master` rows from being created. It does not heal the nine duplicate clusters already in the DB (EMBASSY, JIOFIN, MINDSPACE, MTARTECH, NESTLEIND, SBICARD, UJJIVANSFB, ARE&M, DREAMFOLKS in Ekta Zerodha), which still inflate realized gain because BUYs live on one master and SELLs on another.

We need a superuser-gated admin tool to link pre-existing duplicates to a chosen canonical master. The fix runs entirely through `security_master.canonical_master_id` — one column, one table.

## Endpoint Contract

`POST /api/admin/securities/link`

**Authorization:** superuser only. Class-level `@PreAuthorize("#user != null && T(java.lang.Boolean).TRUE.equals(#user.getIsSuperuser())")` plus an in-handler `requireSuperuser(user)` guard — identical to every other admin controller in the codebase.

**Request body:**

```json
{
  "targetMasterId": "UUID",
  "duplicateMasterIds": ["UUID", "UUID", "..."]
}
```

Both fields required. `duplicateMasterIds` must be non-empty. `targetMasterId` must not appear in `duplicateMasterIds` (self-reference guard). All UUIDs must reference existing `security_master` rows.

**Response body (200):**

```json
{
  "targetMasterId": "UUID",
  "linkedCount": 3,
  "linkedMasterIds": ["UUID", "..."],
  "transitiveRepointCount": 1
}
```

`linkedMasterIds` is the subset of duplicates whose `canonical_master_id` was actually mutated — already-linked rows are skipped (idempotent). `transitiveRepointCount` is the number of additional masters whose existing `canonical_master_id` pointed at one of the duplicates and was re-routed directly to the target (prevents two-hop chains).

**Error codes:**
- `400 BAD_REQUEST` — validation failure (empty list, self-reference, or target itself is already a duplicate of another master).
- `403 FORBIDDEN` — non-superuser caller.
- `404 NOT_FOUND` — one or more IDs don't resolve to a `security_master` row. The response body lists the missing IDs.

## What It Does

Inside one `@Transactional` service method:

1. `UPDATE security_master SET canonical_master_id = :target WHERE id IN (:duplicates)` — links the named duplicates.
2. `UPDATE security_master SET canonical_master_id = :target WHERE canonical_master_id IN (:duplicates)` — re-points any master that was already pointing at one of the duplicates, preventing two-hop chains.

## What It Does NOT Do

- Does not modify `transactions`, `holdings`, `security_listing`, `dividend_cache`, `snaptrade_raw_activities`, or any other table. **Only `security_master.canonical_master_id` changes.**
- Does not bust caches, warm caches, or trigger any job.
- Does not automatically detect duplicate clusters. The operator picks IDs explicitly.
- Does not add or modify any DB constraint or schema.

## Architectural Note

**No transactions are modified. Because `PortfolioReplayService` groups by `COALESCE(canonical_master_id, id)` at read-time, updating this self-FK instantly heals the AVCO math.**

Every downstream calculation — `PortfolioReplayService`, `RealizedGainCalculator`, `PortfolioSummaryService`, `StockGroupService` — resolves `effective_master_id` via `SecurityMaster.getEffectiveId()` (which is `canonicalMasterId != null ? canonicalMasterId : id`) or the equivalent `COALESCE` in SQL. Changing the column heals every read that happens next. No replay is needed because the replay engine itself consults the column on the next invocation.

This is the intended design of `canonical_master_id` — we are leveraging it, not working around it. The same primitive is already used reactively by `FigiResolutionService.applyResolvedResults()` when FIGI lookup discovers two masters share a composite FIGI.

## Safety Rails

- **Verification before mutation:** both the target and every duplicate must resolve. Missing IDs → 404 with the missing list.
- **Self-reference guard:** `targetMasterId` cannot be in `duplicateMasterIds`.
- **Chain-target guard:** if `targetMasterId` is itself already pointing at some other canonical (i.e., it's a duplicate), the request is rejected with instructions to link against the root canonical instead.
- **Idempotency:** duplicates already pointing at the target are left alone and excluded from `linkedMasterIds`.
- **Transitive integrity:** any third-party master whose `canonical_master_id` was one of the duplicates is re-pointed to the new target so `getEffectiveId()` stays single-hop everywhere.
- **Single transaction:** the entire update is atomic.

## Non-Goals

- Automatic duplicate detection. A separate slice if/when we want "find all duplicate clusters for user X" — this endpoint is the low-level primitive either way.
- UI affordance. Backend-only; called via curl/Postman by the operator (sumitsabhnani@gmail.com, superuser).
- Un-linking (reverting `canonical_master_id` back to null). Possible follow-up; not needed today.
- Cross-user validation. The operator is a superuser and is trusted to pick valid IDs; we don't enforce that all master IDs belong to the same user because masters themselves have no user ownership.
