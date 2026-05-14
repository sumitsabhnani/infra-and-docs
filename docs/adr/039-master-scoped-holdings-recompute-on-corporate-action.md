# ADR-039: Master-Scoped Holdings Recompute for Corporate-Action Listeners

**Status:** Accepted
**Date:** 2026-05-14
**Related:** ADR-024 §Decision 1 (Holdings projection consumes the replay engine), ADR-018 (global chronological replay), ADR-019 (read-time canonicalization for security masters)

---

## Context

ADR-024 §Decision 1 routed the Holdings projection through `PortfolioReplayService.replay(...)` and made `HoldingService.updateHoldingsForPortfolio` the single persistence path. `HoldingsRecomputeOnCorporateActionListener` then called that portfolio-wide method on every `MasterCorporateActionsRefreshedEvent(SPLIT, …)` so JIT-seeded splits propagated into the Holdings card.

In practice, a single SnapTrade broker link with BhavKosh historical-price backfill produced a cascade:

1. `SnapTradeActivityMapper` writes transactions for tickers absent from the current-positions response. Each one mints a fresh `SecurityListing` (and skeleton `SecurityMaster` — `name=ticker`, `isin/security_type/country_code=NULL`).
2. `JitSecuritySetupService.onNewListingCreated` enqueues a BhavKosh price + splits backfill per master.
3. Each per-master split insert publishes a `MasterCorporateActionsRefreshedEvent` carrying one `masterId`.
4. The listener discarded the `masterId` and called `updateHoldingsForPortfolio(portfolioId)` — the portfolio-wide path replays every transaction, iterates `result.terminalByMaster()`, and calls `persistHoldingFromReplay` for **every** master with positive terminal qty. Masters without an existing `Holding` row got fresh skeleton Holdings.
5. `persistHoldingFromReplay` never set `broker_raw_ticker` (the column was only ever written by the broker sync paths), so the skeleton Holdings landed with `broker_raw_ticker = NULL`.

Empirically: ~47 SnapTrade positions expanded to ~85 Holdings, of which 38 were skeletons with NULL `broker_raw_ticker`, on a single Zerodha link. The 4-minute log spread matched BhavKosh's per-master split backfills landing one-by-one — each one triggered another portfolio-wide replay-and-persist.

---

## Decision 1: Listeners Route Through `updateHoldingForMaster(portfolioId, masterId)`

A new `HoldingService.updateHoldingForMaster(UUID portfolioId, UUID masterId)` persists exactly one Holding row per call. Structure mirrors `updateHoldingsForPortfolio`:

- Loads the portfolio + transactions; resolves the user's reporting currency.
- Resolves alias→canonical via `securityMasterRepository.findById(masterId).getCanonicalMasterId()` so the terminal lookup keys match `ReplayResult.terminalByMaster()` (replay always keys by effective master ID; ADR-019).
- Builds `firstTxnByMaster` and `txnCurrencies` over the full ledger — `PortfolioReplayService.step()` bails on missing FX for any transaction it walks, so the snapshot must cover every txn currency even though only one master's terminal is persisted.
- Calls `PortfolioReplayService.replay(...)` — cost basis for the target master depends on FIFO/AVCO across the whole portfolio; the scope reduction is in the persist loop, not the replay itself.
- Looks up `terminalByMaster().get(effectiveMasterId)`. Positive qty → `persistHoldingFromReplay`. Zero/oversold → delete the single Holding row. Null terminal → no persist.
- Runs `holdingRepository.deleteAliasHoldingsForPortfolio(portfolioId)` (portfolio-wide alias sweep — same invariant as the wider method).
- Publishes `UserHoldingsChangedEvent`.

`HoldingsRecomputeOnCorporateActionListener` calls this method instead of the portfolio-wide one. The portfolio-wide `updateHoldingsForPortfolio` remains the entry point for `POST /api/holdings/rebuild` (`HoldingController`) and `CsvImportService` commit-time recompute — both are correct in their portfolio-wide scope.

**The invariant for future corporate-action listeners:** if your listener receives a `masterId` from a refresh event (splits, cash dividends, mergers, spin-offs), route through `updateHoldingForMaster` — not `updateHoldingsForPortfolio`. The portfolio-wide method is reserved for callers that intentionally rebuild every position.

## Decision 2: `persistHoldingFromReplay` Backfills `broker_raw_ticker` Only When NULL

`Holding.broker_raw_ticker` is documented as "never overwritten" (SYSTEM_SNAPSHOT §2). The replay-driven persistence path used to land Holdings with a NULL value because the column was only ever set by the broker-sync paths (`SnapTradeHoldingsReconciler`, CSV import). After the cascade above, the 38 skeleton Holdings were never touched by a broker-sync path again, so the NULLs persisted.

`persistHoldingFromReplay` now backfills the column from `firstTxn.getSecurityListing().getTicker()` — **but only when the existing value is NULL**. Broker-specific suffixes (e.g., Zerodha's `RELIANCE-EQ` versus the canonical listing ticker `RELIANCE`) on existing rows must not be overwritten by the canonical listing ticker. The "never overwritten" rule remains intact; this is a fill-when-empty, not an update.

---

## Consequences

- **One split event = one Holding row touched.** A BhavKosh per-master split backfill no longer cascades into a portfolio-wide rewrite. Skeleton Holdings stop appearing for masters whose only ledger evidence is a Phase β transaction without a current-positions echo.
- **Replay engine cost unchanged.** `PortfolioReplayService.replay(...)` still walks the full ledger inside the per-master path — that's correct for cost-basis accuracy. If the call rate ever dominates CPU, the next step is per-master replay caching, not narrowing the replay itself.
- **Existing portfolio-wide callers unaffected.** `POST /api/holdings/rebuild`, CSV import commit, and any future "rebuild everything" surface continue to use `updateHoldingsForPortfolio`. The two methods are complementary: one for targeted listener-driven updates, one for intentional full-portfolio rebuilds.
- **`Holding.broker_raw_ticker`'s "never overwritten" rule is preserved.** The defensive backfill is fill-when-NULL only; broker-suffix data already in the column stays.
- **Skeleton SecurityMaster rows already in the DB are not retroactively cleaned by this ADR.** The cleanup path is either (a) manual `DELETE` of `country_code=NULL` Indian-listing masters and a SnapTrade relink, or (b) a separate one-shot data-fix task. Out of scope here; the upstream `SnapTradeActivityMapper` change that stops minting placeholder masters in the first place (passing `sym.name()` and `sym.currency()` instead of `null` / defaulted USD) is the load-bearing follow-up and is tracked separately.
- **Future listeners must follow the same pattern.** If a `MasterCorporateActionsRefreshedEvent.RefreshedAction` is added later (cash dividend recompute, merger basis transfer, etc.) and a listener needs to persist Holdings as a result, it routes through `updateHoldingForMaster`. The portfolio-wide method becomes a code-review red flag inside any `@TransactionalEventListener` handler.
