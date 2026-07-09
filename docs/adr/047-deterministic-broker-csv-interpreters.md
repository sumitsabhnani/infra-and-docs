# ADR-047: Deterministic Broker CSV Interpreters — Amends ADR-026 ("No Broker-Named Code")

**Status:** Accepted
**Date:** 2026-06-05
**Amends:** ADR-026 §Consequences ("No broker-named code paths exist")
**Extends:** ADR-020 (AI-Assisted Mapper), ADR-028/029 (dual-track cash flows / corporate actions)

---

## Context

ADR-020's AI column-mapper and ADR-026's generic schema extension both assume every CSV is **columnar**: each canonical field (quantity, price, type, date) is a plain read of one column, and the only cross-broker variation is *which* column. That assumption holds for Freetrade, Trading 212, Schwab, Vanguard, Revolut — and ADR-026 was right to reject speculative per-broker presets for them.

A Questrade "Activities" export broke the assumption. It is **multi-modal**: one file interleaves structurally-distinct row schemas keyed off the `Action` column —

- `DIV` dividends carry the share count only inside a free-text `Description` (`"… CASH DIV ON 90 SHS …"`), a blank/`0` `Price`, and the cash in `Net Amount`;
- `Sell` quantities are signed negative;
- `CON / DEP / WDR / INT / FXT` are cash events whose money is in `Net Amount` (the price/quantity columns are `0`);
- `DIS` rows are stock splits mislabeled under "Dividends";
- `BRW / LFJ / …` are internal journals with no cash.

No column mapping can fix a row whose quantity is not in a column at all.

The first fix attempt (an unreleased "Phase 2") tried to keep the generic frame: per-user persisted "import profiles" (an exact header-fingerprint → JSONB config) plus an LLM that *selected* field-level value-extraction strategies (`QuantityExtractor` / `PriceDerivation` / `SignConvention`) from a 5-row sample. An independent review rejected it as a "bridge to nowhere":

- **Non-deterministic.** An LLM picking a value-extraction strategy from 5 rows can silently mis-handle a dividend line that isn't in the sample — a financial-ledger hazard.
- **Wrong axis of decomposition.** Field-level strategies force one global interpreter onto structurally-different row types; the "fall back to the quantity column" escape hatch was the smell.
- **A JSONB/fingerprint maintenance tail** — brittle to a trailing comma, un-versioned blobs that deserialize-crash on an enum rename. Precisely the tail ADR-026 set out to avoid, re-introduced in a new shape.

---

## Decision

Permit **deterministic, broker-named CSV interpreters**, and remove the Phase-2 profile/transform machinery entirely.

A `core` interface —

```java
public interface CsvRowInterpreter {
    boolean matches(List<String> headers, List<String> firstRowSample);
    ParsedActivity interpret(CsvRow row);   // header-keyed cells; no commons-csv in core
    String formatName();
}
```

— with one implementation per *anomalous* broker (`QuestradeRowInterpreter`). A `CsvInterpreterRegistry` (api) collects the beans; `CsvImportService.preview()` consults it **before** the mode switch, and `AiCsvMapper.inferMapping()` consults it **before** the LLM:

```
[ CSV upload ]
      │
[ header-set matcher ] ──matches a registered interpreter?──▶ [ deterministic interpreter ]  (LLM bypassed)
      │ no
[ LLM ADR-020 column mapper ] ──▶ [ deterministic Java parse / standard importer ]
```

`interpret` returns a neutral `ParsedActivity` (`TRADE | DIVIDEND | CASH_FLOW | CORP_ACTION_DROP | SKIP`) carrying only row semantics. The api layer maps it to the existing `PreviewRow` reusing the shared date / dedup-hash / validation / `buildCashFlowRow` helpers, so **`commit()` is unchanged** — it still consumes `PreviewRow`, and 1a reporting-normalization still runs there for the resulting trades and dividends.

This **supersedes only the "no broker-named code paths exist" principle of ADR-026.** ADR-026's four `ColumnMapping` fields, `RowStatus`, `parseFlexibleDateTime`, and ghost-state UX all stand and still serve the generic LLM path. ADR-026 was right to reject *speculative* per-broker presets for columnar files; it was wrong to imply a genuinely multi-modal file can be handled generically. The honest answer is an explicit, bounded interpreter — not the same broker-specific logic hidden inside a "generic" enum.

### Bounds — what keeps this from becoming the tail ADR-026 feared

1. **Recognition is a header-set match** (`headers.containsAll(SIGNATURE)`), not a fingerprint — robust to column reorder/append; only a *removed* signature column de-selects it.
2. **Behaviour is deterministic and in-code** — no persisted config, no JSONB, no LLM-chosen strategy. Same file → same parse, every time, for every user.
3. **One class + one golden test per broker**, and an interpreter only pre-empts the LLM for files it positively recognises. A new anomalous broker is a reviewed code change (a class + a test), not a silent database row.

### Kept from the rejected attempt (independently sound)

- **Inline reporting normalization.** `commit()` calls `TransactionReportingNormalizer.normalize(tx, reportingCurrency)` synchronously per row — the `@TransactionalEventListener(AFTER_COMMIT)` listener cannot fire on the intentionally non-transactional commit path. Fixes CSV dividends silently contributing `0` to `DividendAnalyticsService` (it hard-filters `normalized_reporting_amount IS NOT NULL`, no live-FX fallback).
- **Shared cash-flow classifier.** `core/util/BrokerActivityClassifier` unifies the SnapTrade + CSV cash vocabularies; both ingestion paths and the new interpreter delegate to it.
- **AM/PM date fallback.** `parseFlexibleDateTime`'s curated English-locale formats parse `2026-05-22 12:00:00 AM` even when a 24-hour pattern was supplied.

### Interpreter-local exchange inference & instrument classification (Fix A/B)

The interpreter owns two further broker-specific decisions that must **not** leak into the shared `ParsedActivity` model, the LLM mapper, or `SecurityListingService` — the same boundary that justifies the pattern at all.

- **Exchange inference (Fix B).** Questrade omits an exchange column, so listings were minted exchange-less → an ambiguous ticker-only OpenFIGI lookup resolved to nothing ("Applied 0 RESOLVED") → no EODHD price. `QuestradeRowInterpreter.inferExchange` derives `CAD`/`.TO` → `TSX`, `USD` → `NYSE` (a routing hint into EODHD's single `.US` feed — only NYSE/NASDAQ/AMEX map to it, `ARCA`/`BATS`/`IEX` do not), strips the `.TO` suffix from the ticker (FIGI then resolves `RY`, the EODHD symbol re-derives `RY.TO`, and Questrade's twin `RY` / `RY.TO` forms collapse to one listing), and carries the result as data on `ParsedActivity.exchange()` → `PreviewRow` → unchanged `commit()` / `resolveListing`. Sound only because Questrade is single-country; the same `CAD → TSX` assumption is wrong for a multi-country broker (an IB export could price a EUR asset in CAD) — which is exactly why it lives in the interpreter, not the resolver. The ADR-027 FIGI exchange writeback only fires on a *null* exchange, so the inferred venue is never clobbered.
- **Instrument classification (Fix A).** Options (`CALL `/`PUT ` Description) and GIC/term-deposits (literal `GIC` or the `MAT <date> <rate>%` maturity pattern) are not EODHD-priceable equities; booking them as positions yielded $0-valued holdings (a fake loss). They `SKIP` (surfaced in preview) in `trade()` and `dividend()` — detected by **Description, never symbol pattern** (Questrade hides them behind internal ids like `9LNFFG5` / `5VXBZJ4`). Genuine GIC `INTEREST` (the `INT` action) still books to `cash_flows`, and broker-internal-id *real* securities (`A603109` = an Apple dividend) are deliberately **kept** — the dividend still counts, and the unpriced positionless listing self-heals out of the backfill banner.

---

## Consequences

- **Questrade imports deterministically end-to-end** — dividends with qty/price (share count from the description, per-share = `|Net Amount| ÷ shares`), signed sells normalised to magnitude, cash events routed to `cash_flows`, splits dropped as corporate actions, journals skipped — with **no LLM in the loop**.
- **The generic ADR-020/026 mechanism is unchanged** and remains the path for columnar brokers; the registry is empty for them, so their behaviour is byte-for-byte identical.
- **Transaction-type vocabulary remains dual-track** (ADR-028/029) — deliberately not unified.
- **Deleted:** the `import_profile` table / entity / repo / migration, `ImportProfileService`, `ImportProfileFingerprint`, the three value-transform enums, `ImportTransforms` / `ImportProfilePayload`, and the frontend "Advanced value handling" UI.
- **`MappingProposal` gains `deterministicInterpreter`** (the recognised format name) so the frontend shows a "recognised format" banner and skips the column-confirmation step.
- **`.RY` / `.TO` ticker normalization and exchange inference shipped** (Fix A/B above); **still deferred:** broker-internal-id → ticker mapping (`A603109`, kept-unpriced), GIC-at-cost as a non-priced asset class (currently skipped), an amount-primary dividend model (the deeper reason dividends need share-count reverse-engineering), and raw-landing/replay for CSV.
