# ADR-028: SnapTrade Activity Dual-Track Routing — `transactions` + `cash_flows` + `corporate_action_*`

**Status:** Accepted — §Decision 2 partially superseded by ADR-029
**Date:** 2026-05-02
**Extends:** ADR-002 (SnapTrade ledger ingestion), ADR-024 (cross-master corporate actions end-to-end)
**Superseded by:** ADR-029 (broker-reported corporate-action `Transaction` rows are non-authoritative for AVCO; the canonical source is `corporate_action_*` from EODHD/BhavKosh)

---

## Context

SnapTrade `Activity` payloads cover the full surface of broker bookkeeping, not just trades: contributions, withdrawals, dividends, fees, management fees, interest, tax, withholding, FX conversions, broker-initiated balance adjustments, and per-account corporate-action receipts (bonus issues, splits, merger legs, spin-off receipts, rights). ADR-002 described ingestion as a single path into the `transactions` table; in practice the ingest needs to fan out, because most of those types are not trades and the AVCO engine cannot consume them.

Phase A landed `broker_activity_log` as the immutable raw-payload audit table with a `parsed_status` (`PENDING | PARSED | UNMAPPED_TYPE | …`) and a `parsed_entity_type` discriminator. Phase D1 forced the question of where each activity type actually lands.

Issue [#223](https://github.com/sumitsabhnani/portfolio-optimizer-backend/issues/223) §D1 originally proposed:

1. Unify all corporate actions under a single `corporate_actions` table keyed by `portfolio_id`.
2. Forbid extensions to the `Transaction.TransactionType` enum.

Both points conflicted with shipped behaviour:

- The existing `corporate_action_split / cash_dividend / merger / spinoff` tables are keyed by `security_master_id` because splits, dividends, and corporate actions apply to a security across every portfolio that holds it, not to one account. Per-table CHECK constraints (merger `cash_coherent`, spin-off `0 < basis_allocation_pct < 1`) encode invariants a unified table cannot express. Cross-master replay (ADR-024) walks `(security_master_id, ex_date)` edges; a portfolio-keyed table breaks the connected-component algorithm.
- `Transaction.TransactionType` already contains `BONUS, SPLIT, MERGER_IN, MERGER_OUT, SPINOFF_IN, RIGHTS_IN` in addition to `BUY, SELL, DIVIDEND, TRANSFER`. Eighteen broker-statement aliases in `CsvImportService` map into them, and `RealizedGainCalculator.applyTransaction` holds the AVCO math for each. CSV broker-statement round-tripping has no clean path that writes both a corp-action row and a transaction row from a single CSV line.

After audit, the unification proposal was rejected. The actual destinations were already three; D1 made them explicit and added the missing one.

A subsequent operator pass (`POST /api/v1/admin/snaptrade/replay-unmapped` against the residue) surfaced a Trading 212 `ADJUSTMENT` activity type that did not fit any of the original six FlowType values; it was added as a seventh.

---

## Decision 1: Three Destinations, Polymorphically Routed

Every parsed `broker_activity_log` row lands in exactly one of three destinations, recorded on the log row's `parsed_entity_type` discriminator:

| `parsed_entity_type` | Destination table | Keyed by | Owns |
|---|---|---|---|
| `TRANSACTION` | `transactions` | `(portfolio_id, external_id)` | Trades and per-account corporate-action receipts |
| `CASH_FLOW` | `cash_flows` (new in D1) | `(portfolio_id, external_id)` | Non-trade cash movements with no security listing |
| `CORPORATE_ACTION` | `corporate_action_split / cash_dividend / merger / spinoff` | `security_master_id` | System-wide ex-events (NOT broker-emitted; populated separately by EODHD/BhavKosh jobs and admin endpoints) |

`SnapTradeActivityMapper.parseActivityToTransaction` (extracted from `SnapTradeService` in D3) is the single switch point that decides the destination from the SnapTrade `activity.type` string. Unrecognised types stay `UNMAPPED_TYPE` for operator triage rather than being silently routed anywhere.

## Decision 2: `transactions` Carries Per-Account Corporate-Action Receipts

`Transaction.TransactionType` is the canonical AVCO-aware enum:

```
BUY | SELL | DIVIDEND | TRANSFER
| BONUS | SPLIT | MERGER_IN | MERGER_OUT | SPINOFF_IN | RIGHTS_IN
```

The first four are trade-shaped. The remaining six are per-account broker emissions — what the broker tells you happened to *your* position when a corporate action fired. **As of ADR-029 they are non-authoritative for AVCO**: `PortfolioReplayService` filters them out of the timeline so the canonical EODHD/BhavKosh `corporate_action_*` row is the only thing that moves quantity. The `RealizedGainCalculator.applyTransaction` cases (lines 516/532/547) remain as audit-trail behaviour for any future replay path that opts in, but no production walk consumes them today.

**MERGER direction is resolved by sign-of-quantity:**
- positive units → `MERGER_IN`
- negative units → `MERGER_OUT`
- null or zero units is genuinely ambiguous → row stays `UNMAPPED_TYPE` for operator inspection. We do not guess a direction; reversing one leg of a merger pair would silently corrupt the position.

`OPTION_*` activity types intentionally stay `UNMAPPED_TYPE`. We do not model options yet, and inventing a transaction type for them now would commit to a wrong AVCO treatment.

## Decision 3: `cash_flows` Is the Home for Non-Trade Cash Events

The `cash_flows` table (Flyway `V20260502120000__CreateCashFlows.sql` + `V20260502130000__AddAdjustmentFlowType.sql`) holds activities with no security listing and no trade semantics. Schema:

```sql
cash_flows (
    id              UUID PK,
    portfolio_id    UUID NOT NULL REFERENCES portfolios(id),
    flow_type       VARCHAR(50) NOT NULL,          -- CHECK whitelist below
    occurred_at     TIMESTAMPTZ NOT NULL,
    amount          NUMERIC(20,8) NOT NULL,         -- BigDecimal, signed verbatim
    currency        VARCHAR(10) NOT NULL,
    external_id     VARCHAR(255),                   -- partial UNIQUE WHERE NOT NULL
    raw_payload_ref UUID REFERENCES broker_activity_log(id),
    created_at      TIMESTAMPTZ NOT NULL
)
```

The CHECK constraint whitelists exactly seven canonical values:

```
DEPOSIT | WITHDRAWAL | FEE | INTEREST | TAX | FX_CONVERSION | ADJUSTMENT
```

`SnapTradeActivityMapper.mapToFlowType` collapses the broker's noisier vocabulary into this set: `CONTRIBUTION` → `DEPOSIT`, `MANAGEMENT_FEE` → `FEE`, `WITHHOLDING` → `TAX`, `CONVERSION` and `FX` → `FX_CONVERSION`. `ADJUSTMENT` is its own value because Trading 212 emits it for fractional-share rebalancing, FX rounding, and accrual fixes that are pure cash corrections; none of the other six fits cleanly and ADR-002's "Never Drop Data" forbids dropping or coercing them.

**Sign convention:** `amount` is stored verbatim from the SnapTrade payload. SnapTrade reports inflows positive and outflows negative on the same `amount` field regardless of activity type; the entity follows that convention. `DEPOSIT` and `INTEREST` are typically positive; `WITHDRAWAL`, `FEE`, and `TAX` are typically negative; `FX_CONVERSION` and `ADJUSTMENT` depend on direction.

**Synthetic `external_id` does not propagate.** When SnapTrade omits `activity.id`, the activity log computes a SHA-256 synthetic external id for dedup at the log layer. That synthetic id is **not** written to `cash_flows.external_id`; only broker-supplied ids are. This mirrors the same rule on `transactions.external_id` and avoids double-counting at backfill if SnapTrade later starts supplying ids for previously-anonymous activities.

`cash_flows` is **not read by any analytics path today**. It exists for audit completeness, future cash-balance reconciliation, and future reporting. The Accounting Tie-Out Principle still derives every user-visible number from `transactions` + `corporate_action_*`.

## Decision 4: Admin-Only Replay Endpoint

`POST /api/v1/admin/snaptrade/replay-unmapped` (superuser-gated, in `SnapTradeAdminController`) re-runs `SnapTradeActivityReplayService` against existing `broker_activity_log` rows whose `parsed_status != 'PARSED'`. Implementation invariants:

- **Keyset-paginated** (cursor on `id`), 500-row batches, halts when a batch makes no progress (prevents infinite loops on persistently-unmappable rows).
- **Idempotent** via the partial unique index on `cash_flows.external_id` plus an explicit `findByExternalId` short-circuit before insert; mirrors the same dedup contract on `transactions.external_id`.
- **One-shot, admin-triggered, never wired to a scheduled job** — per the architectural rule against startup backfills (`feedback_no_external_calls_in_loops`).
- Returns a `ReplaySummary` record with per-destination counts (`transactionsCreated`, `cashFlowsCreated`, `stillUnmapped`) and a capped error list.

The endpoint is the operational surface for adding a new FlowType / TransactionType: ship the migration + parser change, then drain the pre-existing UNMAPPED rows by hitting it once.

---

## Consequences

- **Adding a new SnapTrade activity type is a routing decision first.** Trade-shaped → `transactions` (with AVCO math review). Per-portfolio cash event → `cash_flows`. Security-wide event → already covered by `corporate_action_*` and is not in scope for SnapTrade ingest. If none fit, leave it `UNMAPPED_TYPE` and surface to operator.
- **`Transaction.TransactionType` additions are governed by AVCO impact, not SnapTrade convenience.** A new value MUST have a corresponding case in `RealizedGainCalculator.applyTransaction` and CSV alias coverage in `CsvImportService` — otherwise prefer `cash_flows` or `UNMAPPED_TYPE`.
- **`cash_flows` is write-only from analytics' perspective today.** Any future reader (cash-balance reconciliation, dividend yield, tax export) must respect the verbatim sign convention and treat `external_id` as broker-supplied-only.
- **The dual-track design is permanent.** ADR-024's "no path to user writes against `corporate_action_*` tables" still holds; this ADR adds "and no path from SnapTrade Activity to `corporate_action_*` either — those tables are populated by EODHD/BhavKosh jobs and superuser admin endpoints only."
- **Replay is the migration tool.** When this ADR's coverage extends (e.g. a seventh FlowType, a future ADR-029 for options), the procedure is: ship the migration + parser, then drain the UNMAPPED residue via the admin endpoint.

## Alternatives Considered

- **Single `corporate_actions` table keyed by `portfolio_id`, no enum extensions** (issue #223 §D1's original proposal). Rejected because (a) splits and dividends are global, not per-portfolio — `security_master_id` is the correct key; (b) per-table CHECK constraints encode invariants a unified table cannot; (c) the AVCO replay engine and CSV broker-statement round-trip both depend on the extended `TransactionType` enum.
- **Route ADJUSTMENT into `FEE` or invent a `MISC` flow type.** Rejected. `FEE` would silently misclassify rebalancing credits as expenses; `MISC` would defeat the CHECK constraint's purpose and re-create the UNMAPPED problem inside `cash_flows`. A dedicated value is cheaper and honest.
- **Drop `cash_flows.external_id` and dedup only on `(portfolio_id, occurred_at, amount, currency)`.** Rejected. SnapTrade does supply ids on most activity types; using them where available preserves replay idempotence at zero schema cost. The partial unique index handles the broker-omits-id case.
- **Wire the replay endpoint into a scheduled job.** Rejected per the project rule against startup backfills and external-call loops; replay is an operator-triggered tool for after-the-fact parser improvements, not a steady-state path.
