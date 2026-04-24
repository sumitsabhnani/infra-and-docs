# Feature Spec — Ingestion-Time Security Master Deduplication

## Problem

Every ingestion path (SnapTrade sync, manual add-transaction, Zerodha sync, CSV import) funnels through `SecurityListingService.createListing(...)`. On any listing miss, that method **unconditionally** calls `securityMasterRepository.save(...)` and creates a brand-new `SecurityMaster` row — even when the same underlying security already has a master on another exchange or under a slightly different broker display name.

This silently splits AVCO positions across masters. The realized-gain engine groups by `effective_master_id = COALESCE(canonical_master_id, id)`, so when BUYs sit on master A and SELLs on master B, it treats them as two independent positions: the SELL side gets a $0 cost basis and the realized gain is inflated by the full sell proceeds.

**Confirmed instance.** In the Ekta Zerodha portfolio, nine Indian tickers (EMBASSY, JIOFIN, MINDSPACE, MTARTECH, NESTLEIND, SBICARD, UJJIVANSFB, ARE&M, DREAMFOLKS) have their BUYs and SELLs split across duplicate master rows. Seven of them have **identical** `name` fields — they are pure duplicates. The Dashboard therefore shows $8,724.49 realized P/L where the true figure is materially lower.

Today the only defense is `FigiResolutionService.applyResolvedResults()` (jobs module) which *reactively* sets `canonical_master_id` after both masters resolve to the same composite FIGI. For Indian tickers where FIGI resolution is unreliable or null, duplicates remain unlinked indefinitely.

## Rule

**Ingestion must perform a deterministic lookup for an existing `SecurityMaster` before calling `securityMasterRepository.save(...)`.** On match, attach the new listing to the existing master. On miss, create a new master as before.

## Lookup key priority

All comparisons use normalized (UPPER, trimmed) values. Ticker/exchange comparisons are exact — no fuzzy matching.

1. **Same `(exchange, ticker)`** — look up an existing `security_listing` by exchange + normalized ticker and reuse its `security_id`. Covers: repeat syncs of the same account under slightly different name variants (e.g., `"ARE&M"` vs `"AMARA RAJA ENERGY MOB"`).
2. **Same `(country, ticker)` across any exchange in that country** — if no same-exchange match, fall back to listings sharing the given exchange's country code. Reuse **only** when the set of distinct masters across candidate listings is exactly one. Covers: NSE/BSE cross-listings where the underlying security is the same.
3. **Miss or ambiguity** → create a new master. FIGI resolution will canonicalize later.

## Non-goal — why no DB unique index

We explicitly will **not** add a partial unique index on `security_master (ticker, country)` or similar.

**Reason — "Never Drop Data" rule:** SnapTrade sync happens asynchronously and ingests whole batches of transactions. A unique-constraint violation thrown from inside `createListing(...)` during ingestion would bubble up and cause Hibernate to roll back the enclosing transaction. The user's broker data would silently not land. An over-eager duplicate is recoverable (link via `canonical_master_id`); a missing transaction is not.

Deduplication is **best-effort at the application layer**. Ambiguity, null data, or any lookup error falls through to the existing create-new behavior. Ingestion must always succeed. The async FIGI canonicalizer remains in place as a safety net.

## Observability

- `log.info("createListing dedup: reusing master {id} for (exchange={code}, ticker={t})")` on every reuse hit.
- `log.info("createListing dedup: reusing master {id} for (country={cc}, ticker={t}) via country-level match")` on country-level reuse.
- `log.warn("createListing dedup: ambiguous — {n} masters match (country={cc}, ticker={t}); creating new")` when step 2 returns multiple distinct masters.

Reuse rate vs. ambiguity rate over the first two weeks in production tells us whether the preventive lookup is landing hits or whether a one-shot data cleanup pass is still needed.

## Scope

**In scope (this slice):**
- Preventive dedup inside `SecurityListingService.createListing(...)`.
- Unit tests covering match, miss, ambiguity, and error paths.

**Out of scope (explicit follow-ups):**
- One-shot cleanup of the *existing* nine duplicate masters in Ekta Zerodha. Tracked separately.
- Category 2: tickers with zero BUYs anywhere in the DB (ADANIPORTS, CESC, EXIDEIND, HINDZINC, ITCHOTELS, KOTAKBANK, NMDC, TATASTEEL, ULTRACEMCO). Requires backfilling or excluding orphan SELLs.
- Name-variant fuzzy matching. Deterministic keys only.
- DB-level uniqueness constraints. Rejected by the Never Drop Data rule.
- Changes to `FigiResolutionService`. Stays as the reactive safety net.
