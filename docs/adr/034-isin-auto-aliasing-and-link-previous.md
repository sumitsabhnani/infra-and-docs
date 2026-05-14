# ADR-034: ISIN Auto-Aliasing on Master Creation + User-Initiated "Link to Previous Ticker"

**Status:** Accepted
**Date:** 2026-05-05
**Extends:** ADR-019 (security master canonicalization)
**Related:** Issue #280

---

## Context

Two production cases produced orphan SELLs and OVERSOLD shelf entries:

1. **Pure rename** — `BURGERKING → RBA`. ISIN preserved (`INE608K01018`). The new listing was minted with a fresh `SecurityMaster` row instead of aliasing to the existing one, so transactions split across two masters.
2. **Demerger with ISIN change** — `ADANITRANS → ADANIENSOL`. ISIN changes; ISIN-based dedup cannot recover. No UI affordance let the user assert "these are the same security."

`SecurityMaster` already had the primitives (`isin` UNIQUE, `canonicalMasterId`, `getEffectiveId()`) but `SecurityListingService.createNewMaster` never read them when minting a new master.

---

## Decision 1: Centralize ISIN-Aware Reuse in a Single `resolveOrMintMaster` Seam

`SecurityListingService.resolveOrMintMaster(ticker, name, currency, securityType, isin)` is the only path that creates `SecurityMaster` rows. When `isin != null && findByIsin(isin).isPresent()`, the new row is saved as an alias:
- `canonicalMasterId = existing.getEffectiveId()` (resolves through any pre-existing chain to the canonical root)
- `isin = null` (the UNIQUE constraint forbids two masters sharing an ISIN; alias rows must not own the identifier)

When no match exists, the master is created with the ISIN set normally.

**Single seam, not threaded.** We deliberately do NOT add `isin` to every overload of `findOrCreateByTickerOrFigiOrExchange` — most callers don't have ISIN at the resolution point. The seam exists at exactly one place inside `createListing`.

`TickerMappingService.mapTicker` (the manual symbol-mapping endpoint) uses the same alias rule when enriching ISIN on a master that doesn't yet have one: if a different master already owns the ISIN, the current master becomes an alias of that one — never a competing duplicate.

`ExchangeSymbolLoadJob` (EODHD/CSV bulk symbol load) routes the same-ISIN-different-ticker case through `resolveOrMintMaster` to mint an alias master, creates a new listing for the new ticker, and writes a `security_listing_rename_history` audit row with `source = 'EXCHANGE_LOAD_JOB'` — matching the `SecurityListingRenameDetectionJob` pattern. The old `security_listing` row is never mutated (ADR-019); both old and new listings remain active under the same canonical master. The `applySecurityUpdates` guard forbidding `setIsin` on rows with `canonicalMasterId != null` remains in force — alias rows must not carry the identifier.

`FigiBasedIdentifierResolver.resolveByIsin` returns the ISIN holder directly. It is incidentally safe because alias rows have `isin = null` and `findByIsin` only returns canonical rows. A code comment documents this invariant for future maintainers.

## Decision 2: User-Initiated "Link to Previous Ticker" via `canonicalMasterId`

For the demerger case (ISIN changed), there is no automatic recovery. We expose a manual affordance:

- `PUT /api/holdings/master/{masterId}/link-to-previous` body `{previousMasterId: UUID}` returns 204 on success (including idempotent), 400 on cycle, 403 when the user does not own the new master, 404 when either master is missing, 409 on optimistic-lock failure.
- `GET /api/holdings/masters/search?q=...` returns up to 20 effective (non-alias) masters from the user's own transactions matching name or ticker substring. Cross-tenant isolation is enforced inside the JPQL `JOIN`, not as an appended filter — a missed `LIMIT` cannot leak.

The link endpoint writes `canonicalMasterId` only. We deliberately do NOT seed `corporate_action_merger` from this affordance — that table is admin-write-only and represents real, attestable corporate events. Alias is a user-scoped recovery primitive; it does not claim a corporate event happened.

## Decision 3: Concurrent Safety — `@Version` + Pessimistic Lock + Transitive Flatten

`SecurityMasterAliasService.linkAlias` is the single write-site for `canonicalMasterId`:

1. **Auth check** via `transactionRepository.existsByUserIdAndEffectiveMasterId(userId, newMasterId)` — caller must own ≥1 transaction on the new master.
2. **Pessimistic locks in id order** via `findByIdForUpdate` — A↔B race converges on a single ordering, no deadlock.
3. **Resolve `effective(previous)`** through any pre-existing alias chain.
4. **Cycle prevention** — reject if `effective(previous) == newMasterId` or `previousMasterId == newMasterId`.
5. **Idempotent short-circuit** — if `newMaster.canonicalMasterId == effective(previous)` already, return without write or event publish.
6. **Set `newMaster.canonicalMasterId = effective(previous)`** and clear any stale `isin` (alias rows must have `isin = null`).
7. **Transitive flatten** — `findByCanonicalMasterIdIn(newMasterId)` finds rows that already aliased to `newMaster` and re-points them to `effective(previous)`. This keeps `getEffectiveId()` single-hop.
8. **Publish `MasterAliasLinkedEvent`** with the affected user-id set computed from `findUserIdsWithTransactionsOnMasters`.

`SecurityMaster.@Version` is a hard requirement: without it, two threads racing to set `canonicalMasterId` on the same master can both succeed and the chain is in an inconsistent state. With it, the loser receives `OptimisticLockException` which the controller surfaces as HTTP 409. The pessimistic lock is belt-and-braces; the version field is the actual correctness guarantee.

## Decision 4: Fan-Out to All Affected Users on Link

`MasterAliasLinkedEvent` is consumed by `MasterAliasLinkedListener` which fans out one `UserHoldingsChangedEvent` per affected user. Two users on different listings of the same eventual canonical master both need their replay re-run, not just the caller. The fan-out runs `AFTER_COMMIT` so a rolled-back link does not trigger phantom recomputes.

---

## Consequences

**Positive**
- Pure renames (BURGERKING→RBA) are recovered automatically on the next listing-creation path that supplies the ISIN.
- Demergers (ADANITRANS→ADANIENSOL) have a one-click recovery affordance.
- Concurrent linkers cannot corrupt the chain — `OptimisticLockException` surfaces cleanly as 409.
- `getEffectiveId()` remains single-hop after every link via the transitive flatten step.

**Negative**
- One new column (`security_master.version`) on every existing row. Constant default keeps the migration fast on Postgres 15.
- The user can set `canonicalMasterId` on a master they own — admins cannot easily audit "is this alias claim correct?" beyond the user's own intent. This is acceptable given the alias is per-user-scoped (no cross-tenant impact).

**Neutral**
- The search endpoint scopes to the user's own masters with at least one transaction. Masters they could theoretically alias to but have no transactions on are not searchable. Acceptable — the affordance is for recovery, not exploration.

---

## Alternatives Considered

1. **Crowdsourced rename detection.** Rejected for now — ratings and quorum would significantly extend scope. Manual link covers the same recovery without crowd input.
2. **Admin endpoint to write `corporate_action_merger`.** Deferred (out of scope per #280). Still useful for true demergers; this ADR covers the user-scoped path that does not require admin attention.
3. **Threading `isin` through every overload.** Rejected — most callers don't have ISIN; the seam is a clean centralization.

---

## Verification

- `SecurityListingServiceIsinAliasTest` — unit test for the seam.
- `SecurityMasterAliasServiceIntegrationTest` — concurrent race, transitive flatten, idempotent re-link, cycle prevention.
- `HoldingControllerLinkPreviousTest` — endpoint auth, cycle, 404, idempotent re-link, masters search filter.
- `MasterAliasLinkedEventFanOutTest` — both userA and userB receive the fan-out event when a chain spans both their transactions.
