# ADR-040: Fyers Public Symbol Master + `symbol_kind` Classification + Non-Destructive Rename Detection

**Status:** Accepted — rename detection gated by `app.jobs.rename-detection.enabled=false` until canonical-master ISIN coverage reaches >80% (currently 0% on the active NSE/BSE universe; `ExchangeSymbolLoadJob` is the unblocker).
**Date:** 2026-05-14
**Extends:** ADR-006 (price-sweeper sidecar), ADR-019 (read-time canonicalization), ADR-032 (`-RE` ticker is load-bearing for OVERSOLD triage), ADR-034 (ISIN auto-aliasing + link-previous).

---

## Context

The Fyers `/quotes` price path (Python `price-sweeper` sidecar, ADR-006) was rejecting 33 of ~236 active Indian symbols per cycle with `code=-300, errmsg='Please provide a valid symbol'`. Root cause: `price-sweeper/app/fetcher.py` synthesized Fyers symbols by hardcoded `(prefix, series)` rules — `{".NS": ("NSE:", "-EQ"), ".BO": ("BSE:", "-A")}`. The rules are wrong for ~14% of the universe: BSE Group B trades as `-B`, REITs as `-RR`/`-IF`, debt as `-F`, and renamed companies (`AMARAJABAT → ARE&M`, `AKZOINDIA → JSWDULUX`, `LTIM → LTM`) no longer exist under the legacy ticker.

The fix had to (a) replace the synthesis rule with the canonical source — Fyers's own public symbol master — and (b) preserve three invariants the diagnosis surfaced: ADR-019's no-mutation of `security_listing` rows, ADR-032's dependency on the `-RE` ticker suffix for the OVERSOLD shelf, and CSV import dedup idempotency (`CsvImportService.computeRowHash` hashes ticker verbatim into a 16-byte truncated SHA-256 explicitly warned against migration).

---

## Decision 1: Fyers Public Symbol Master Is the Canonical Indian Resolver

`https://public.fyers.in/sym_details/NSE_CM_sym_master.json` and `BSE_CM_sym_master.json` are downloaded once daily (03:00 IST in the sidecar, 02:00 UTC in Java) and indexed two ways:

- `by_isin: (exchange_code, isin) → fyers_symbol` — primary lookup, transparent to renames and series moves.
- `by_ticker: (exchange_code, plain_ticker_upper) → fyers_symbol` — fallback when the canonical `security_master` row has `isin = NULL`.

Rows with `tradeStatus != 1` (halted/delisted) are excluded. The sidecar's `ACTIVE_UNIVERSE_QUERY` in `price-sweeper/app/db.py` walks `JOIN security_master sm_canonical ON sm_canonical.id = COALESCE(sm.canonical_master_id, sm.id)` to read ISIN from the canonical row — alias rows have `isin = NULL` per ADR-034.

`security_listing.isin` is not consulted. The column was dropped by `V20260302190200__RemoveIsinFromSecurityListing.sql`; ISIN lives only on `security_master`.

## Decision 2: `market_data_symbol.symbol_kind` Is the Classification Surface — Java Owns, Sweeper Obeys

A new column `market_data_symbol.symbol_kind VARCHAR(32)` carries the `SymbolKind` enum: `EQUITY | RIGHTS_ENTITLEMENT | REIT | BOND | ETF | UNKNOWN`. The sidecar filter is structured:

```sql
AND (mds.symbol_kind IS NULL OR mds.symbol_kind <> 'RIGHTS_ENTITLEMENT')
```

Not `WHERE ticker NOT LIKE '%-RE'`. The sidecar is a read-only consumer of structured DB state and must not contain broker-specific string heuristics. Classification is performed in Java at every `market_data_symbol` write site — `BhavKoshSymbolDerivationService`, `SnapTradeSymbolExtractor`, `EodhdSymbolMappingJob`, `ZerodhaSymbolMappingJob`, `PriceService` JIT, `HistoricalPricePrefillJob`, `TickerMappingApplier` — via the pure `SymbolKindClassifier.classify(exchangeCode, rawTicker)` function in `core/util`. The migration backfills existing rows by suffix pattern (`-RE → RIGHTS_ENTITLEMENT`, `-RR/-IF → REIT`, `-F → BOND`, remainder `EQUITY`) in NULL-guarded UPDATEs.

The rule generalises: any future cross-language consumer of `market_data_symbol` consults the column; classification stays in the JVM.

`IndianTickerNormalizer` (also in `core/util`) strips broker-leaked series suffixes (`-BZ`, `-BE`, `-T`, `-X`, `-XT`, `-Z`, `-ZP`, `-IT`, `-M`, `-MT`, `-RR`, `-IF`, `-F`, `-A`, `-B`) at SnapTrade ingest, scoped to `exchange_code ∈ {NSE, BSE}` only — US share-class suffixes (`BRK-B`) and any non-Indian exchange pass through unchanged. `-RE` is deliberately omitted from the strip set: the frontend `needs-review-shelf.component.ts:119` reads `.endsWith('-RE')` to flip OVERSOLD CTA priority (ADR-032 §Decision 3). The strip operates on `SnapTradeSymbolExtractor.extract()`; `Symbol.rawTicker()` carries the pre-strip value through to `SnapTradeHoldingsReconciler`, which writes it to `holdings.broker_raw_ticker` so the broker-truth audit trail is preserved.

## Decision 3: Rename Detection Is Non-Destructive

`SecurityListingRenameDetectionJob` (daily 02:00 UTC, in `jobs` module, disabled by default behind `app.jobs.rename-detection.enabled`) iterates active NSE/BSE listings whose canonical master has `isin IS NOT NULL`, fetches the live Fyers symbol via `FyersSymbolMasterClient`, and when the master's base ticker differs from `security_listing.ticker`:

1. Mints a new listing under the new ticker via `SecurityListingService.resolveOrMintMaster(newTicker, ..., isin)` — ADR-034's seam auto-aliases the new master to the canonical via the ISIN UNIQUE constraint; alias rows carry `canonicalMasterId = effective(existing)` and `isin = null`.
2. Writes an audit row to `security_listing_rename_history` (`canonical_master_id, old_listing_id, new_listing_id, exchange_code, isin, old_ticker, new_ticker, source='FYERS_MASTER_DIFF', observed_at`), unique on `(canonical_master_id, old_ticker, new_ticker, exchange_code)`.
3. Publishes `MasterAliasLinkedEvent` to fan out replay refresh to all affected users.

The job never mutates `security_listing.ticker`, never flips `is_active=false` on the old row, and never touches `transactions` or `holdings`. Both old and new listings remain active under the same canonical master; the read path canonicalizes via `getEffectiveId()` (ADR-019). CSV dedup hash idempotency is preserved by construction — the hash inputs (verbatim CSV ticker) never see the rename.

`security_listing_rename_history` is append-only audit. It does not participate in any resolution path. Read-side canonicalization remains `COALESCE(canonical_master_id, id)`.

## Decision 4: Fyers Public CDN Is a Non-Blocking Dependency

Both the Python `FyersSymbolResolver` and the Java `FyersSymbolMasterClient` follow the same resilience contract:

| Scenario | Behavior |
|---|---|
| Fresh download succeeds | Persist to local cache; build indexes; `available = True`. |
| Download fails + cache present | Log WARN, load cache, `available = True` (degraded). Retry every 10 min. |
| Download fails + no cache | Log ERROR, build empty indexes, `available = False`. **Do not raise.** Lifespan startup completes; `/health` stays 200; the sweep cycle emits REJECTED for every Indian symbol. Retry every 10 min. |
| Periodic refresh fails | Keep stale cache, log WARN, never raise. |

The sidecar Docker image bakes both master JSONs into `/data/fyers_cache/` at build time (`curl --fail`) as a never-empty baseline. HTTP request limits: 30s timeout, 50 MB body cap (DoS guard — real masters are ~10 MB each).

`/health` exposes `fyers_resolver_available` + `last_refresh` so deploy probes observe the degraded state without flipping unhealthy.

---

## Consequences

**Positive**
- Resolves 24 of 33 rejections immediately via `by_ticker` fallback even at 0% canonical-master ISIN coverage (Buckets A, B, partial D — BSE Group B, REITs, broker-leaked series suffixes). Bucket C (renamed companies, 9 tickers) resolves once `security_master.isin` is populated via `ExchangeSymbolLoadJob`.
- Composes with ADR-019: rename detection is the proactive sibling of the reactive `FigiResolutionService.applyResolvedResults` canonicalizer. Both write `canonical_master_id`; neither rewrites ledger or listing rows.
- Composes with ADR-032: `-RE` listings continue to exist as their own `security_listing` rows; the OVERSOLD shelf's `.endsWith('-RE')` trigger is unaffected. `holdings.broker_raw_ticker` preserves the broker-truth value so the audit trail survives the canonical-ticker strip.

**Negative**
- Adds an external dependency on `public.fyers.in` — mitigated by the resilience contract and Docker-image-baked baseline.
- Rename detection is a no-op until `security_master.isin` is populated. Production state at this ADR's authoring is 0% ISIN coverage on canonical masters for NSE/BSE; `ExchangeSymbolLoadJob` (manual-trigger today — only invocable by uncommenting calls in `ApiApplication.java`) is the unblocker.
- `ExchangeSymbolLoadJob.updateListing` mutates `security_listing.ticker` in place when the bulk load supplies a same-ISIN, different-ticker row. This violates ADR-019 and the rule established here; refactor is queued as a follow-up. Until then, the bulk-load path is a second source of listing-row mutation that the rename detection job is not.

**Neutral**
- `IndianTickerNormalizer`'s strip set is an explicit allowlist; extending it requires verifying the suffix is exclusively an Indian series indicator. US share-class suffixes (`BRK-B`, `BRK.A`) are protected by the `exchange_code ∈ {NSE, BSE}` gate.

---

## Alternatives Considered

- **`WHERE ticker NOT LIKE '%-RE'` in the sidecar SQL.** Rejected — leaks domain classification into a language and layer that does not own it; the heuristic would have to be duplicated in every cross-language consumer of `market_data_symbol`. The `symbol_kind` column centralises the rule.
- **In-place rename via `security_listing.setTicker(newTicker)`.** Rejected — violates ADR-019 and corrupts CSV dedup idempotency: `CsvImportService.computeRowHash` (line 1189) hashes ticker verbatim into a 16-byte truncated SHA-256 explicitly warned against migration.
- **Repurpose `global_ticker_mapping` for same-exchange rename mappings.** Rejected — its unique key is `(source_ticker, source_exchange, resolved_provider_symbol)` and its reader (`TickerAutoResolutionService.applyGlobalMapping`) treats `resolved_provider_symbol` as a cross-provider (EODHD) target. Mixing semantics would corrupt the cross-provider contract.
- **Java-managed Fyers master mirror in `market_data_symbol`.** Considered for a future iteration — the Java side could fetch the Fyers master daily and write `(security_listing_id, FYERS) → fyers_symbol` rows under a new provider, keeping the sidecar read-only against the DB. Deferred; the current design (each language fetches its own copy with shared resilience contract) ships sooner and removes the schema-coupling risk.

---

## Verification

- `price-sweeper/tests/test_fyers_symbols.py` — resolver indexes, `tradeStatus != 1` exclusion, fallback order, resilience scenarios (download 503 + cache present / no cache).
- `portfolio-optimizer-backend/jobs/src/test/.../FyersSymbolMasterClientTest.java` — Java client mirror.
- `SecurityListingRenameDetectionJobTest` — happy-path rename, idempotency via pre-check, idempotency via existing-listing reuse, concurrent `DataIntegrityViolationException` swallow, ticker-unchanged no-op, empty-master no-op, missing-exchange skip, scheduled-run-disabled no-op.
- `IndianTickerNormalizerTest`, `SymbolKindClassifierTest` — pure-function suffix tests including `-RE` preservation and US share-class passthrough.
- Live smoke against the Fyers CDN at this ADR's authoring confirmed 8/8 bucket cases: `RELIANCE → NSE:RELIANCE-EQ`, `SUNDARMFIN → BSE:SUNDARMFIN-B`, `AMARAJABAT + ISIN INE885A01032 → NSE:ARE&M-EQ`, `RAJESHEXPO → NSE:RAJESHEXPO-BZ`, `EMBASSY → NSE:EMBASSY-RR / BSE:EMBASSY-IF`, `LTIM + ISIN INE214T01019 → NSE:LTM-EQ`, `AKZOINDIA + ISIN INE133A01011 → NSE:JSWDULUX-EQ`.
