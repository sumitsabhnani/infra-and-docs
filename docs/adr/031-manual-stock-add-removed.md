# ADR-031: Manual Stock-Add Removed — Holdings Mutate Only Through Replay

**Status:** Accepted
**Date:** 2026-05-04
**Extends:** ADR-020 (Holdings Are Strictly Derived)

---

## Context

A "Stocks" tab in `<app-add-transaction-modal>` let the user manually type ticker + quantity + average price and create or update a single `holdings` row directly. Backed by `POST /api/holdings` and `DELETE /api/holdings/{id}` (plus `HoldingService.createOrUpdateHolding` and `deleteHolding`), the path bypassed the transaction ledger — a holding appeared with no AVCO history, no realized-gain trail, no episode boundaries.

Two consequences forced removal:

1. **The Needs-Review shelf and History page broke.** Both surfaces classify holdings via `LedgerGapDetector` (ADR-024), which expects a backing ledger. Manually-created holdings produced `ReviewState.MISSING_LOCAL_EVENT` immediately on creation, with a "fix" CTA that opened the same manual-add modal — a loop that could not converge on a clean state.
2. **Cost-basis math degraded silently.** Subsequent SnapTrade syncs or CSV imports for the same security replayed against an AVCO timeline that started without the manual buy, producing wrong realized gain and wrong reported FX impact. The user had no repair path short of deleting and re-uploading.

The other ingestion surfaces — SnapTrade sync and CSV bulk upload — both produce `Transaction` rows and converge on `HoldingService.updateHoldingsForPortfolio`, which is correct by construction. Manual stock-add was the only mutation surface that violated the immutable-ledger invariant.

---

## Decision

### 1. The public mutation surface for `holdings` is replay + metadata patches only

Removed:

- `HoldingController.createHolding` (`POST /api/holdings`) and `HoldingController.deleteHolding` (`DELETE /api/holdings/{id}`).
- `HoldingService.createOrUpdateHolding` (both overloads) and `HoldingService.deleteHolding`.
- The `<app-stocks-tab>` standalone component and its slot in `<app-add-transaction-modal>`.
- `ApiService.createHolding` and `ApiService.deleteHolding`.
- `portfolio.component.ts` orchestration: `handleTransaction`, `dispatchTransaction`, `addHoldingFromModal`, `openReviewModal`, the dead-code `updateHolding(holding: Holding)`, and the `reviewPrefillTicker` / `reviewPrefillQuantity` prefill state.

Retained:

- `HoldingController.updateHolding` (`PUT /api/holdings/{id}`) and `HoldingService.patchHolding` — but the legitimate caller surface is now restricted to **metadata fields**: `buyBelowPrice`, `maxAllocationPct`, `excludedFromCalculations`, `note`. Frontend callers (`handleBuyBelowSave`, `handleAllocationSave`) send only those keys; `quantity` and `averagePrice` are no longer written from any UI path.
- `PortfolioController.createManualPortfolio` (`POST /api/portfolios/manual`) and `MANUAL_BROKER_ID = 99` — used by the CSV upload flow to spin up a fresh portfolio on the fly.
- `ApiService.searchSymbols` — used by `<app-ticker-mapping-modal>` for unmapped-CSV-ticker resolution.
- `ApiService.createManualPortfolio` — used by `<app-bulk-changes-tab>`.

**Invariant:** the only paths that insert or remove `holdings` rows are (a) the replay engine writing `ReplayResult.terminalByMaster()` outputs into the projection via `updateHoldingsForPortfolio`, and (b) `deleteByPortfolioId` cascades on portfolio delete. No HTTP endpoint creates or deletes a holding directly.

### 2. Needs-Review CTAs that pointed at manual-add are passive badges now

The `OVERSOLD` and `REVIEW` indicators in the holdings table previously rendered as `<button (click)="openReviewModal(holding)">`, which opened the manual stocks tab pre-filled with the missing-buy ticker and quantity. Those become non-interactive `<span class="review-badge review-badge--static">` elements (new SCSS modifier strips `cursor: pointer` and hover/focus states). The semantic state still surfaces; the manual fix path is gone. `RENAME?` and `SUPPORT` badges remain interactive — the mailto-support path is unaffected.

The `(fix)` `@Output()` on `<app-needs-review-shelf>` is no longer bound by `<app-portfolio>`. Internal CTAs inside the shelf that still emit `(fix)` are no-ops; converting those to support-mailto CTAs is tracked as follow-up.

### 3. The Stocks tab is the only deletion in the modal

`<app-add-transaction-modal>`'s tab union narrows from `'broker' | 'stocks' | 'bulk' | 'others'` to `'broker' | 'bulk' | 'others'`. The default initial tab moves from `'stocks'` to `'broker'`. The other three tabs — broker linking, CSV bulk upload, manual user-level assets per ADR-008 — are untouched. `addAssetsModalInitialTab`, `openAddTransactionModal(tab)`, and `TransactionData.type` all lose the `'stocks'` variant; the supporting `transaction-data.model.ts` becomes empty after the prune and is deleted.

---

## Consequences

- **The "no projection writes outside replay" rule (ADR-020) is now enforceable at the HTTP boundary.** Previously the `holdings` projection had a write surface that bypassed the ledger; future regressions that re-introduce one would need to add a route, which is a visible change. The route table is the enforcement point.
- **Cost-basis correctness is no longer user-defeatable.** A user can no longer create a holding that the AVCO timeline does not know about; every position the system shows traces back to a `Transaction` row. The Needs-Review shelf surfaces gaps without offering a corruption path.
- **Migration impact is zero.** No tables, columns, or Flyway migrations were involved. Existing manually-created holdings (from before the removal) remain in the projection until the next replay rebuild; users can hide anomalous rows via the `excludedFromCalculations` toggle, which goes through the surviving `PUT /api/holdings/{id}` endpoint.
- **`HoldingDto` keeps a wider request-body shape than its current callers use.** `quantity` and `averagePrice` are still settable through the DTO because the projection-level columns must be patchable for replay-driven writes inside the service. No frontend caller sends those fields. Narrowing the request DTO to a metadata-only type is mechanical follow-up if a regression surfaces.
- **`FigiMigrationWorkflowTest` was restored and rewritten** (`api/src/test/java/com/portfolio/tracker/api/integration/FigiMigrationWorkflowTest.java`) to seed holdings via `holdingRepository.save(...)` directly. The test had used `createOrUpdateHolding` as a setup helper for end-to-end Phase 1/2/3/5/7 GBX-currency assertions, all of which are still load-bearing. It now runs on Testcontainers + Postgres 16 — the prior H2-with-raw-DDL setup violated the project's "Testcontainers for integration" rule.

---

## Alternatives Considered

- **Keep the endpoints; convert Needs-Review CTAs to a "create offsetting BUY transaction" flow** routed through `TransactionService.createTransaction` instead of `createHolding`. Rejected: it adds a second user-facing transaction-entry surface that competes with CSV upload, and the underlying broken assumption (users can correctly reconstruct missing trades) is the same. Users with missing data re-upload from the broker source.
- **Soft-delete by hiding the Stocks tab behind a feature flag.** Rejected: the orphaned controller, service, and frontend orchestration become weight that future agents must reason around without a corresponding capability shipped to users.
- **Tighten the `PUT /api/holdings/{id}` request DTO to a metadata-only shape now.** Rejected for now: no caller writes `quantity` / `averagePrice` from the UI, and the projection-level patch path inside the service still uses the wider shape. A second DTO without a paying caller is speculative.
