# ADR-048: Venue-Implied Currency + Same-National-Market Exchange Matching in FIGI Scoring

**Status:** Accepted — uncommitted; **live-confirmed** (fuzzer run 2026-07-06, `RESOLVED 1→20/50`)
**Date:** 2026-07-06
**Related:** ADR-027 (bare-CSV listing resolution, `TICKER_CONFIDENCE_THRESHOLD`), ADR-040 (Fyers symbol master — exchange-code discipline)

---

## Context

`FigiResolutionService.calculateConfidenceScore` sums weighted matches: ISIN (0.50), broker `listing_figi` (0.50), exchange (0.20), currency (0.20), asset class (0.10). Ticker-based lookups resolve at `TICKER_CONFIDENCE_THRESHOLD = 0.30` when exactly one distinct compositeFIGI survives validation.

A bare SnapTrade payload — no ISIN, no broker FIGI, `securityType=null` (the common case) — can only earn exchange and currency. Two facts, both confirmed against production `figi_resolution_stage`, made that unreachable:

1. **The currency weight has never fired.** OpenFIGI's `/mapping` endpoint does not return a currency, so `candidate.getCurrency()` is always null and the weight never applied. The production score histogram is exactly `{0.00×283, 0.20×252, 0.50×8, 0.70×21}` — every value explainable *without* currency, and the scores that would require it (`0.40`, `0.30`, `0.90`) appear zero times.
2. **The exchange weight required exact Bloomberg-code equality**, which fails systematically: OpenFIGI ticker searches return the composite code (`US`, `GR`, `IN`, `CN`) while our listings map to a venue (`NASDAQ→UW`); and the forward map assigns NYSE the composite `US`, so a candidate carrying the venue code `UN` also missed.

Net: a bare payload capped at **0.20** (exact exchange only), below the 0.30 bar. **95% of real resolution attempts (535 vs 29) landed AMBIGUOUS** — arithmetic, not accident.

An earlier attempt (composite-exchange matching alone) was implemented and reverted: it relied on `market 0.15 + currency 0.20 = 0.35`, but with the currency weight dead the real ceiling stayed at 0.20. Its unit tests passed only because they fabricated a candidate currency the API never sends; the live fuzzer caught it.

---

## Decision

Two changes, applied together.

**1. Tiered same-national-market exchange matching.** A static `BLOOMBERG_CODE_TO_MARKET` map groups composite + venue codes for the markets where Bloomberg distinguishes them (US: `US/UN/UW/UA/UP/UF`; Germany: `GR/GY/GF/GB/GT`; India: `IN/IB/IS`; Canada: `CN/CT/CV`; UK: `LN/LI`). `sameBloombergMarket(a,b)` is exact equality OR same-market membership; single-venue markets are absent (equality covers them). Scoring is tiered:

```
WEIGHT_EXCHANGE_MATCH        = 0.20   // exact Bloomberg-code equality
WEIGHT_EXCHANGE_MARKET_MATCH = 0.15   // same national market, non-exact (new)
```

so a venue-exact candidate always outranks a composite one for the same security.

**2. Venue-implied currency.** Since OpenFIGI can't confirm currency, corroborate the broker's listing currency against the currency the **resolved venue** trades in. `MARKET_TO_CURRENCY` maps national market → currency (`US→USD, DE→EUR, IN→INR, CA→CAD`), validated against `security_listing` (NASDAQ/NYSE 100% USD, XETRA/German venues EUR, NSE/BSE INR, TSX CAD). **GB is deliberately omitted** — LSE is genuinely multi-currency (GBX/GBP/EUR/USD), so a UK listing earns no boost rather than risk crediting the wrong one. The currency weight now fires when the listing currency equals `impliedCurrencyForExchCode(candidate.exchCode)` (the direct `candidate.getCurrency()` comparison is kept as a future-proof fallback).

Combined, a coherent bare payload reaches `exchange (0.15–0.20) + implied currency (0.20) = 0.35–0.40`, clearing 0.30. **Unchanged guards:** the single-distinct-compositeFIGI gate, the currency hard-reject in `passesValidation`, and both thresholds. The `passesValidation` exchange *note* was also corrected to compare in Bloomberg space (it previously compared the raw DB code `"NASDAQ"` to a Bloomberg exchCode and stamped "Exchange mismatch" on every candidate).

---

## Consequences

- **Bare ticker payloads become resolvable** when the venue and currency are coherent — the common SnapTrade case. Same-market + implied currency = 0.35 (or exact + currency = 0.40).
- **Currency-chaos is screened, not resolved.** A `NASDAQ/EUR` payload earns the exchange market credit but not the currency credit (US market trades USD, not EUR), stays at 0.15, and does not resolve. A wrong currency can never push a bare resolution through — this is the load-bearing safety property.
- **The correctness bet:** same ticker + same national market + venue-coherent currency + one distinct compositeFIGI ⇒ same security. The single-FIGI gate is the primary key; exchange and currency are corroboration; the 0.15/0.20 tier keeps venue-exact candidates strictly preferred.
- **Not resolved by this change:** the ~285 stage rows scoring `0.00` with a null `resolved_exch_code` (OpenFIGI returning a candidate with no venue) — a distinct failure mode. And populating ISINs (the 0.50 anchor) remains the breadth fix. Both tracked as follow-ups.
- **ISIN cases** may now score up to 1.00 (they previously capped at 0.80 with currency dead); no resolution outcome changes, since ISIN resolution runs through `pickBestIsinCandidate`, not the threshold.
- **Extending coverage is one map entry** (a new venue code joins its market; a new single-currency market joins `MARKET_TO_CURRENCY`); unmapped codes degrade to exact-equality / no-boost — never a regression.
- **Testing discipline:** scoring tests now model OpenFIGI's real `currency=null` responses. The prior attempt's failure traced directly to tests (and fuzzer mocks) fabricating a currency the API never sends.

---

## Live confirmation (fuzzer run 2026-07-06, seed `2137917611328737559`)

Re-ran the 50-case fuzzer through the deployed build. Breakdown `{RESOLVED=20, UNRESOLVED=30, AMBIGUOUS=0}` — up from the reverted cut's `RESOLVED=1`. Every prediction held:

- **The fix fires.** All 20 resolutions are coherent single-venue candidates, resolving to the correct security (spot-checked: `SAR→Saratoga`, `BKH→Black Hills`, `VALE→Vale SA ADR`, `MH→McGraw Hill`, `WTEQ→WisdomTree`, `AFFLE→Affle 3i`). Nothing resolved that shouldn't.
- **The safety property held live.** All four currency-chaos cases stayed UNRESOLVED. The two whose candidate carried a venue code scored **exactly `0.150`** (`PSN` NYSE→EUR `exch=UN`; `BJLL` XETRA→GBP `exch=GT`) — exchange market credit earned, currency credit correctly *withheld* because the venue-implied currency (USD/EUR) ≠ the mutated currency. A wrong currency never crossed `0.30`.
- **The residual is the null-exchCode mode, not this change.** All 26 coherent-but-unresolved cases scored `0.000` with **no `exch=` on the candidate** — OpenFIGI returned a FIGI with no venue code, so neither exchange nor (venue-implied) currency can fire. This matches production `figi_resolution_stage`: **233 of 283 zero-score rows have a null `resolved_exch_code`**. It is the distinct failure mode flagged below (ISIN population / the null-venue candidates), untouched by this ADR.
