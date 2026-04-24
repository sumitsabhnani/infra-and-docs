# ADR-020: Bulk CSV Import — AI-Assisted Mapper Pattern and OPENING_BALANCE Transaction Type

**Status:** Accepted  
**Date:** 2026-04-23  
**Context:** Users need to bulk-import transactions and current holdings from arbitrary broker CSV exports. The holdings import path previously wrote directly to the `holdings` table, bypassing the transaction ledger entirely — a correctness violation. AI-assisted import was wanted for arbitrary broker formats but posed prompt-injection and scalability risks if the LLM was allowed to extract financial data.

---

## Decision

### 1. Holdings Import Must Produce Transactions (OPENING_BALANCE)

The `holdings` table is a derived read-model. It must never be written directly by an import pipeline. All imports — whether transactions or current-position snapshots — converge on the same commit path: insert `Transaction` rows, then call `updateHoldingsForPortfolio`.

A new `TransactionType.OPENING_BALANCE` value represents a user-declared starting position. It is treated identically to `BUY` in `AvcoState.step()` and `HoldingService.updateHoldingsForPortfolio()`. The distinction exists so analytics can identify opening entries in the audit trail without mis-attributing them to market activity.

**Correctness > Convenience** — a holdings upload that bypasses the ledger corrupts cost-basis calculations for any subsequent buy or sell. The extra step of translating positions to `OPENING_BALANCE` transactions is non-negotiable.

### 2. Three-Mode Import with a Unified Preview → Commit Contract

| Mode | Column mapping | Row type produced |
|---|---|---|
| `TRANSACTIONS` | Built-in alias resolution | BUY / SELL / DIVIDEND / TRANSFER |
| `HOLDINGS` | Built-in alias resolution | OPENING_BALANCE |
| `AI_FLEXIBLE` | LLM-inferred, user-confirmed | Any of the above |

All three modes share the same `/preview` → (user reviews) → `/commit` two-step contract. Preview is read-only. Commit re-validates every row server-side; it never trusts the frontend payload.

### 3. AI-Assisted Mapper Pattern (LLM Infers Schema, Java Parses Data)

**The LLM's only job is schema inference.** It receives the CSV header row plus at most 5 sample data rows, and returns a `MappingProposal`: a JSON object mapping our canonical field names to the source column headers in the uploaded file, plus value-translation synonyms for transaction type and a date-format pattern.

```
POST /infer-mapping
  input:  header + 5 rows (≤ ~500 tokens)
  output: MappingProposal JSON

POST /preview
  input:  full file + user-confirmed mapping
  parse:  Apache Commons CSV + BigDecimal (Java, deterministic)

POST /commit
  writes: Transaction rows (re-validated server-side)
```

**Why this shape, and why not direct LLM extraction:**

| Concern | Direct extraction | AI-Assisted Mapper |
|---|---|---|
| Financial math correctness | LLM outputs strings → parse error risk, rounding ambiguity | `new BigDecimal(raw)` in Java, auditable line-for-line |
| File size | Row-count cap (LLM context limit) | One call regardless of row count; 100k rows costs the same as 50 |
| Prompt injection | Attacker data row `"AAPL","ignore instructions,..."` is extracted verbatim | Attacker payload maps to a column-name string at worst; server validates every non-null column name against the real header before accepting it |
| Cost | N tokens × rows | ~500 tokens in, ~200 out — fixed |
| Human review point | Every row is AI output | One mapping confirmation gate; deterministic preview thereafter |

The server rejects any `columnMapping` value that does not appear in the actual header row (`validateColumn`), closing the hallucinated-column and injection-via-LLM-response attack surfaces.

### 4. SHA-256 Row-Hash Dedup via externalId

For every imported row, we compute:

```
SHA-256(portfolioId | ticker | isoDate | type | qty.plainString | price.plainString)
```

stored as `externalId = "csv:v1:" + first16hexChars`. The `csv:v1:` prefix makes the scheme version-able without collisions. Re-uploading the same CSV is idempotent: the preview marks duplicate rows; commit skips them and reports `skippedDuplicates`.

---

## Consequences

- `TransactionType` gains `OPENING_BALANCE`. All AVCO and holdings-refresh logic already handles it identically to `BUY`.
- The legacy `POST /holdings/import-csv` endpoint is refactored in place (same URL) to delegate to the new pipeline rather than writing holdings directly. Existing integrations see no URL change.
- `POST /api/transactions/bulk-upload` (old single-step endpoint) is removed; no frontend callers existed.
- Admin backfill endpoint (`POST /api/admin/csv-import/backfill-opening-balances`) exists to retrofit `OPENING_BALANCE` transactions for any Holdings created by the pre-refactor path.
- AI-mode inference calls `LlmService.generateResponse` exactly once per import regardless of file size.
