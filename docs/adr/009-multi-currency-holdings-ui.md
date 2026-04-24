# ADR-009: Multi-Currency Holdings UI — Stacked Layout & FX Transparency

**Status:** Accepted  
**Date:** 2026-04-14  
**Context:** Portfolio Optimizer serves users holding assets across multiple currencies (USD, EUR, GBP, INR, CAD, AUD). The Holdings table must present both native and reporting currency values without overwhelming the user or adding horizontal bloat.

---

## Decision 1: Stacked Currency Layout

**Choice:** Display the Native currency value as the primary line and the Reporting currency value directly beneath it in a smaller, lighter font — within the same column cell.

**Rationale:** Adding parallel columns (e.g., "Price (Native)" and "Price (Reporting)") would double the column count for four value columns (Avg Price, Current Price, Invested, Current Value), consuming horizontal space and breaking the table's scanability. The stacked approach preserves the existing column structure while giving users both data points at a glance.

**Applied to:** Avg Price, Current Price, Invested, Current Value columns.

**Exception:** The Gain/Loss column displays only Reporting currency because it must tie out to the portfolio-level summary (see Decision 4).

## Decision 2: Zero-Noise Rule

**Choice:** The secondary (reporting) line is hidden when `holding.currency === holding.reportingCurrency`.

**Rationale:** When both currencies are the same, the secondary line would be an exact duplicate of the primary — visual noise that erodes trust in the UI. Conditionally hiding it keeps the table clean for single-currency portfolios while automatically expanding for cross-currency holdings.

**Implementation:** `*ngIf="holding.currency !== holding.reportingCurrency && holding.currentPriceReporting"` on each secondary `<div>`.

## Decision 3: Progressive Disclosure of FX Impact

**Choice:** When a holding's native currency differs from the reporting currency, a subtle info icon (ⓘ) appears in the Gain/Loss cell. Hovering reveals a tooltip: `"Asset Return: +5.20% | FX Impact: -1.30%"`.

**Rationale:** Multi-currency investors face the "Illusion of Performance" — a stock may appear to gain 15% in reporting currency when the asset only gained 10% and the remaining 5% came from currency movement. Surfacing both numbers protects users from misattributing returns, but doing so inline would clutter the table. The tooltip strikes the balance: the information is one hover away, zero visual cost at rest.

**Backend support:** `HoldingDto` carries `nativeGainPercent` (pure asset return), `gainLossPercent` (reporting return including FX), and `fxImpactPercent` (the delta). The reporting gain percentage uses a historical cost basis derived from USD-normalized transaction amounts, ensuring the FX rate at purchase time is preserved rather than overwritten by today's live rate.

## Decision 4: Accounting Tie-Out Principle

**Choice:** The Gain/Loss column unconditionally displays the Reporting currency value and Reporting gain percentage. It never falls back to Native values.

**Rationale:** The portfolio-level summary header shows total value, total gain/loss, and gain percentage — all in the reporting currency. If individual holding rows showed Native gain percentages, they would not sum to the header total, breaking the user's ability to mentally reconcile rows against the summary. Forcing Reporting currency in this column ensures every row is denominated in the same unit and ties out to the global aggregation.

**Frontend enforcement:** `updateHoldingDisplayValues()` recalculates `gainLossPercent` as `(changes / costBasisReporting) * 100` from the same values used for the monetary display, preventing drift between the amount and percentage.

## Decision 5: All-or-Nothing Transaction Coverage Guard

**Context:** Historical holdings imported manually or via CSV lack full transaction history. The USD-normalized ledger (Decision 3) derives a weighted average USD price per share from BUY transactions. When transaction records cover only a fraction of the held shares (e.g., 4 out of 150), extrapolating that partial average across the full position produces massive mathematical hallucinations — phantom losses of -58% on positions that are actually profitable in native currency. Root cause: the transaction subset was purchased at a different price point than the holding's true average, and multiplying by the full quantity inflates the cost basis beyond reality.

**Choice:** Implement a strict coverage guard before the USD normalization path:

```java
boolean hasFullCoverage = totalBuyQty != null && quantity != null
        && totalBuyQty.compareTo(quantity) >= 0;
```

The USD-normalized cost basis (`quantity × avgUsdPricePerShare × fxRate(USD→reporting)`) is only applied when the sum of BUY transaction quantities **meets or exceeds** the holding's current quantity. Otherwise, the backend falls back to live FX conversion: `costBasisNative × liveFxRate(native→reporting)`.

**Rationale:** A blended approach (USD-normalized for transaction-covered shares, live FX for the rest) was considered but rejected. Blending mismatched data sources — broker transaction prices vs. manually entered average prices — would still produce misleading cost bases. The all-or-nothing guard ensures the numbers are either fully accurate (complete transaction history) or consistently derived from a single source of truth (the holding's own average price + live FX).

**Trade-off accepted:** Holdings without full transaction coverage will show **0% FX impact** because both cost basis and current value use the same live FX rate. This sacrifices historical FX transparency for those specific legacy assets in exchange for stable, accurate portfolio totals. As transaction history grows to full coverage (via broker sync or manual entry), the USD normalization automatically activates.

**Data observed at time of decision (2026-04-14):**

| Holding | Held Qty | BUY Txn Qty | Coverage | USD Path |
|---------|----------|-------------|----------|----------|
| RELIANCE | 150 | 4 | 2.7% | Skipped |
| ASIANPAINT | 150 | 78 | 52% | Skipped |
| HINDUNILVR | 233 | 121 | 52% | Skipped |
| SETFNIF50 | 2641 | 865 | 33% | Skipped |
| CDSL | 16 | 0 | 0% | Skipped (no data) |

---

## Consequences

- Users see native prices (what the market quotes) and reporting equivalents (what it means for their portfolio) without horizontal scrolling.
- Single-currency portfolios look identical to before — no regression in simplicity.
- FX impact is available on demand but never forced on users who don't need it.
- The Gain/Loss column is the single source of truth for portfolio-level accounting.
- Historical FX rates (from USD-normalized transactions) are required for accurate FX impact; holdings without full transaction coverage show 0% FX impact and use live FX conversion as a stable fallback.
- Legacy/manually-imported holdings are protected from mathematical hallucinations caused by partial transaction data; portfolio totals remain accurate at all times.
- The coverage guard is self-healing: as transaction history reaches full coverage (via broker sync or bulk import), the USD normalization activates automatically with no code changes.
