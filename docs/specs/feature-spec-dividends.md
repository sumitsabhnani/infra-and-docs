# Feature Spec: Cash Dividends & Analytics (Phase A)

**Status:** Draft
**Date:** 2026-04-21
**Phase:** A of 2 (Phase B covers mergers, spin-offs, global chronological replay — out of scope here)
**Depends on:**
- Existing `corporate_action_split` pattern (migration `V20260419120000`, entity `CorporateActionSplit`, job `CorporateActionSplitBackfillJob`) — this spec mirrors it.
- Existing `TransactionType.DIVIDEND` enum value (already populated via `BrokerSyncService`).
- Existing `HistoricalPriceBackfillCompletedEvent` (reused as the JIT trigger).
- Existing `backgroundJobExecutor` (`AsyncConfig`) and `CurrencyConversionService`.

---

## 1. Problem & Scope

### 1.1 Problem

The portfolio optimizer records broker-reported `DIVIDEND` transactions but surfaces nothing to the user — no column on the Holdings view, no KPI on the dashboard, and no reconciliation against company-declared events. As a result:

- Users can't see how much income a position has produced.
- Users can't compute yield-on-cost for dividend-focused positions.
- When a broker feed misses a payment (a known SnapTrade failure mode), the gap is silent; realized P/L looks lower than it should.

### 1.2 Goals

1. Store company-declared dividends in a new `corporate_action_cash_dividend` events table, fed from EODHD `/api/div/{SYMBOL}`.
2. Surface **Dividends Received** and **Yield on Cost** as optional columns on the Holdings view.
3. Surface **Total Dividend Income** (lifetime + YTD) as a new KPI on the dashboard.
4. Detect anomalies where a dividend was declared on a held position but no `DIVIDEND` transaction was imported — admin-only endpoint for Phase A.

### 1.3 Non-goals (explicitly deferred)

- **Phase B territory:** mergers (stock-for-stock or cash-for-stock), spin-offs, buyouts, rights offerings, the "global chronological replay" refactor of `RealizedGainCalculator`.
- **AVCO / realized P/L math** — this spec touches zero AVCO code. Realized P/L stays exactly as the splits PR left it.
- **Dividend tax-lot tracking** (qualified vs. non-qualified) — future tax feature.
- **DRIP reinvestment inference** — brokers that do DRIP already book a BUY transaction; that's the source of truth.
- **User-facing anomaly UI** — Phase A exposes anomalies only through an admin endpoint. A portfolio-level anomalies panel can land later once the detection logic is battle-tested.
- **Cross-portfolio dividend rollups** — each portfolio's analytics are scoped by `transactions.portfolio_id`.

### 1.4 Acceptance criteria

- [ ] `corporate_action_cash_dividend` table, entity, repository.
- [ ] EODHD ingest via `/api/div/{SYMBOL}` with JIT listener + weekly sweep.
- [ ] Admin endpoints: `POST /backfill-all`, `POST /backfill/{id}`, `POST /manual`, `GET /anomalies`.
- [ ] `HoldingDto` carries `totalDividendsNative`, `totalDividendsReporting`, `dividendYieldOnCostPct`.
- [ ] `PortfolioValuation` carries `totalDividendIncomeLifetime`, `totalDividendIncomeYtd`.
- [ ] Holdings view has two optional, default-hidden columns: **Dividends Received**, **Yield on Cost**.
- [ ] Dashboard KPI card shows lifetime primary / YTD secondary in reporting currency.
- [ ] Anomaly detection endpoint returns declared-but-not-received rows with computed expected totals.
- [ ] End-to-end integration tests (Testcontainers + Postgres) cover ingest, analytics, anomaly, admin auth.

---

## 2. Design Overview

### 2.1 Two sources, clearly separated

The single most important design rule — easy to get wrong and expensive to undo — is the separation between **declared events** and **received cash**:

| Concern | Source of truth | New in Phase A? |
|---|---|---|
| Company-declared dividend (ex_date, amount/share, currency) | `corporate_action_cash_dividend` | **Yes** — new table |
| User-received dividend cash | `transactions` (rows of type `DIVIDEND`) | No — already populated by broker sync |

**All analytics read from `transactions` only.** That table already respects partial ownership, multi-custody, multi-portfolio, and historical FX. The new events table is consumed **only** by the anomaly reconciliation service (and, in Phase B+, a future "expected forward yield" feature). **No existing analytics logic reads the events table.**

### 2.2 Data-flow diagram

```
          INGEST PATH (company facts)                     ANALYTICS PATH (user cash)
  ──────────────────────────────────────          ──────────────────────────────────────
  EODHD /api/div/{SYMBOL}                          transactions (DIVIDEND rows)
        │                                                │     ▲
        ▼                                                │     │
  EodhdDividendClient                                    │     │ broker sync (unchanged)
        │                                                │
        ▼                                                ▼
  CorporateActionDividendBackfillJob          DividendAnalyticsService
   • JIT listener (HistoricalPriceBackfillCompleted)   • aggregateByListing(portfolioId, rptCcy)
   • Weekly sweep (Sundays 04:30 UTC)                  • aggregatePortfolio(portfolioId, rptCcy)
   • Admin backfill/manual endpoints                            │
        │                                                       ▼
        ▼                                           HoldingDto.totalDividends{Native,Reporting}
  corporate_action_cash_dividend              HoldingDto.dividendYieldOnCostPct
        │                                     PortfolioValuation.totalDividendIncome{Lifetime,Ytd}
        │                                                       │
        │       RECONCILIATION PATH (admin-only)                ▼
        │      ─────────────────────────────                Dashboard KPI card
        └───►  DividendAnomalyService ◄────── transactions  Holdings table columns
                    │
                    ▼
              GET /api/admin/corporate-actions/dividends/anomalies?portfolioId=...
```

### 2.3 Mirror of the splits architecture

Structurally the ingest half is a near-clone of the stock-splits pipeline. The table and code below should feel like line-for-line copies of their split counterparts with three substantive differences:

1. **Shape:** `amount_per_share` + `currency` instead of `ratio_numerator / ratio_denominator`.
2. **`pay_date` column** (nullable) — dividends have a concept that splits don't.
3. **Read-time consumer is different** — the splits table feeds `RealizedGainCalculator`; the dividends table feeds only `DividendAnomalyService`.

---

## 3. Database Schema

### 3.1 Migration

**File:** `portfolio-optimizer-backend/api/src/main/resources/db/migration/V{TS}__CreateCorporateActionCashDividendTable.sql`
(where `{TS}` is a fresh `YYYYMMDDHHmmss` timestamp newer than `V20260419120000`)

```sql
-- Declared cash-dividend events, keyed by canonical security_master_id.
-- Read-time consumption: DividendAnomalyService reconciles declared events
-- against broker-imported transactions of type DIVIDEND. Analytics
-- (Dividends Received, Yield on Cost, totalDividendIncome*) read ONLY from
-- the transactions table; this table is NOT a source of user cash flow.

CREATE TABLE IF NOT EXISTS corporate_action_cash_dividend (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    security_master_id UUID NOT NULL REFERENCES security_master(id) ON DELETE CASCADE,
    ex_date            DATE NOT NULL,
    pay_date           DATE,                       -- nullable; EODHD sometimes omits
    amount_per_share   NUMERIC(20, 10) NOT NULL,
    currency           VARCHAR(3)      NOT NULL,   -- ISO 4217, e.g. "USD", "GBP"
    source             VARCHAR(64)     NOT NULL,   -- "EODHD" | "MANUAL"
    created_at         TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
    CONSTRAINT corporate_action_cash_dividend_amount_positive
        CHECK (amount_per_share > 0),
    CONSTRAINT corporate_action_cash_dividend_currency_format
        CHECK (char_length(currency) = 3),
    CONSTRAINT corporate_action_cash_dividend_unique
        UNIQUE (security_master_id, ex_date)
);

-- The UNIQUE constraint above creates an implicit btree index on
-- (security_master_id, ex_date) — sufficient for both per-master lookup
-- and batch IN-lookup. No additional index needed; mirrors the decision
-- made for corporate_action_split.
```

### 3.2 Why `UNIQUE(security_master_id, ex_date)`?

Same rationale as splits. EODHD can (rarely) return duplicate declarations for the same ex_date as it revises historical data; the unique constraint coerces re-runs of the backfill to be idempotent. On a race between the JIT listener and the weekly sweep, both insert the same row — the loser catches `DataIntegrityViolationException` and moves on.

### 3.3 Why `pay_date DATE` nullable?

Broker transaction records are keyed by the **cash-settlement date** (which is `pay_date + 0–2 business days`). We use `pay_date` to anchor the anomaly-detection date window. EODHD's `/api/div/` response almost always includes `paymentDate`, but some international securities omit it — in which case the anomaly service falls back to `ex_date + 30 calendar days`.

---

## 4. Backend: `core` Module

### 4.1 Entity — `CorporateActionCashDividend`

**File:** `portfolio-optimizer-backend/core/src/main/java/com/portfolio/tracker/core/model/CorporateActionCashDividend.java`

```java
package com.portfolio.tracker.core.model;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.PrePersist;
import jakarta.persistence.Table;
import jakarta.persistence.UniqueConstraint;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * Declared cash-dividend event, keyed by canonical security_master_id.
 *
 * <p>Analytics (totals, yield-on-cost) do NOT read this table — they read
 * DIVIDEND transactions. This table is reconciliation-only: the anomaly
 * service compares declared events against broker-imported transactions
 * and flags missing cash flows.
 *
 * <p><strong>amount_per_share</strong> is the raw (unadjusted) dividend
 * amount in the issuer's declared currency — e.g. $0.24 for AAPL Q3 2023.
 * The EODHD client prefers {@code unadjustedValue} over the split-adjusted
 * {@code value} to avoid double-counting interactions with the splits table.
 */
@Entity
@Table(name = "corporate_action_cash_dividend", uniqueConstraints = {
        @UniqueConstraint(name = "corporate_action_cash_dividend_unique",
                columnNames = {"security_master_id", "ex_date"})
})
@Data
@NoArgsConstructor
@AllArgsConstructor
@Builder(toBuilder = true)
public class CorporateActionCashDividend {

    @Id
    private UUID id;

    @Column(name = "security_master_id", nullable = false)
    private UUID securityMasterId;

    @Column(name = "ex_date", nullable = false)
    private LocalDate exDate;

    @Column(name = "pay_date")
    private LocalDate payDate;

    @Column(name = "amount_per_share", nullable = false, precision = 20, scale = 10)
    private BigDecimal amountPerShare;

    @Column(name = "currency", nullable = false, length = 3)
    private String currency;

    @Column(name = "source", nullable = false, length = 64)
    private String source;

    @Column(name = "created_at", nullable = false)
    private OffsetDateTime createdAt;

    @PrePersist
    public void prePersist() {
        if (id == null) {
            id = UUID.randomUUID();
        }
        if (createdAt == null) {
            createdAt = OffsetDateTime.now();
        }
    }
}
```

### 4.2 Repository — `CorporateActionCashDividendRepository`

**File:** `portfolio-optimizer-backend/core/src/main/java/com/portfolio/tracker/core/repository/CorporateActionCashDividendRepository.java`

```java
package com.portfolio.tracker.core.repository;

import com.portfolio.tracker.core.model.CorporateActionCashDividend;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.time.LocalDate;
import java.util.Collection;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

@Repository
public interface CorporateActionCashDividendRepository
        extends JpaRepository<CorporateActionCashDividend, UUID> {

    List<CorporateActionCashDividend> findBySecurityMasterIdOrderByExDateAsc(UUID securityMasterId);

    List<CorporateActionCashDividend> findBySecurityMasterIdInOrderByExDateAsc(
            Collection<UUID> securityMasterIds);

    Optional<CorporateActionCashDividend> findBySecurityMasterIdAndExDate(
            UUID securityMasterId, LocalDate exDate);
}
```

---

## 5. Backend: `jobs` Module

### 5.1 EODHD client — `EodhdDividendClient`

**File:** `portfolio-optimizer-backend/jobs/src/main/java/com/portfolio/tracker/jobs/service/EodhdDividendClient.java`

- URL: `https://eodhd.com/api/div/{SYMBOL}?api_token=…&fmt=json`
- Response (each array element):
  ```json
  {
    "date": "2024-02-09",
    "declarationDate": "2024-02-01",
    "recordDate": "2024-02-12",
    "paymentDate": "2024-02-15",
    "period": "Quarterly",
    "value": "0.24",
    "unadjustedValue": "0.24",
    "currency": "USD"
  }
  ```
- Parsing: **always prefer `unadjustedValue` when present**, fall back to `value` only if missing. Rationale: `value` is split-adjusted. A 2:1 split after a $1 dividend gives `value = 0.50`, `unadjustedValue = 1.00`. Because this system stores splits separately and applies them at read time, the raw amount is the right one to persist.
- Record emitted: `EodhdDividend(LocalDate exDate, LocalDate payDate, BigDecimal amountPerShare, String currency)`.
- Error handling mirrors `EodhdSplitsClient` exactly — `404 → empty list`, `429 → EodhdDividendRateLimitException`, other → `EodhdDividendApiException`.
- All BigDecimals constructed via `new BigDecimal(stringValue)` — no `double`/`float` anywhere.

Pseudocode skeleton (fill body from `EodhdSplitsClient.fetchSplits`):

```java
public List<EodhdDividend> fetchDividends(String providerSymbol) {
    // 1. Validate api key
    // 2. GET the URL, parse JSON to List<Map>
    // 3. Map each element to EodhdDividend:
    //      exDate        = LocalDate.parse(m.get("date"))
    //      payDate       = m.get("paymentDate") != null ? LocalDate.parse(...) : null
    //      amountPerShare = new BigDecimal(m.getOrDefault("unadjustedValue", m.get("value")))
    //      currency      = String.valueOf(m.get("currency")).trim().toUpperCase()
    // 4. Filter out: null dates, non-positive amounts, currency length != 3
    // 5. Sort by exDate ascending
}

public record EodhdDividend(
        LocalDate exDate,
        LocalDate payDate,
        BigDecimal amountPerShare,
        String currency) {}

public static class EodhdDividendApiException extends RuntimeException { ... }
public static class EodhdDividendRateLimitException extends EodhdDividendApiException { ... }
```

### 5.2 Backfill job — `CorporateActionDividendBackfillJob`

**File:** `portfolio-optimizer-backend/jobs/src/main/java/com/portfolio/tracker/jobs/task/marketdata/CorporateActionDividendBackfillJob.java`

Three trigger paths, mirroring `CorporateActionSplitBackfillJob`:

**Path 1 — JIT (just-in-time)**

```java
@EventListener
@Async("backgroundJobExecutor")
public void onHistoricalBackfillCompleted(HistoricalPriceBackfillCompletedEvent event) {
    // Same event the splits job listens to — no new event class needed.
    // Resolve symbolId → SecurityMaster (effective) → EODHD provider symbol,
    // then call backfillForMasterWithProviderSymbol(canonicalMasterId, providerSymbol).
    // Swallow rate-limit exceptions so the weekly sweep can retry.
}
```

**Path 2 — Weekly sweep (staggered from splits)**

```java
@Scheduled(cron = "${app.jobs.corporate-actions-dividends.cron:0 30 4 ? * SUN}", zone = "UTC")
public void scheduledWeeklySweep() {
    backfillAllActiveAsync();
}

@Async("backgroundJobExecutor")
public void backfillAllActiveAsync() {
    // 1. Load (providerSymbol, effectiveMasterId) pairs via the existing
    //    ActiveEodhdSymbolWithMasterView native projection.
    // 2. For each, call backfillForMasterWithProviderSymbol(...)
    //    — wrap in try/catch so one bad symbol doesn't stop the sweep.
    // 3. Thread.sleep(200) between symbols to stay under EODHD rate limits.
}
```

The sweep is staggered 30 minutes after the splits sweep (which runs at `0 0 4 ? * SUN`) to avoid two simultaneous batches hammering EODHD's rate limit.

**Path 3 — Admin-driven**

```java
@Async("backgroundJobExecutor")
public void backfillForSecurityAsync(UUID securityMasterId) { ... }

/** Idempotent manual insert (source = "MANUAL"). */
public Optional<CorporateActionCashDividend> recordManualDividend(
        UUID securityMasterId, LocalDate exDate, LocalDate payDate,
        BigDecimal amountPerShare, String currency) { ... }
```

**Idempotency pattern** (copy from `CorporateActionSplitBackfillJob`):

```java
protected int backfillForMasterWithProviderSymbol(UUID canonicalMasterId, String providerSymbol) {
    List<EodhdDividend> divs = eodhdDividendClient.fetchDividends(providerSymbol);
    if (divs.isEmpty()) return 0;

    Set<LocalDate> existingExDates = new HashSet<>();
    for (CorporateActionCashDividend d :
            dividendRepository.findBySecurityMasterIdOrderByExDateAsc(canonicalMasterId)) {
        existingExDates.add(d.getExDate());
    }

    int inserted = 0;
    for (EodhdDividend d : divs) {
        if (existingExDates.contains(d.exDate())) continue;
        try {
            dividendRepository.save(CorporateActionCashDividend.builder()
                    .securityMasterId(canonicalMasterId)
                    .exDate(d.exDate())
                    .payDate(d.payDate())
                    .amountPerShare(d.amountPerShare())
                    .currency(d.currency())
                    .source("EODHD")
                    .build());
            existingExDates.add(d.exDate());
            inserted++;
        } catch (DataIntegrityViolationException e) {
            // Concurrent backfill won the race; treat as already present.
            existingExDates.add(d.exDate());
        }
    }
    return inserted;
}
```

No outer `@Transactional` — each `save()` is a standalone transaction so a single unique-constraint violation never rolls back the whole batch. Identical discipline to the splits job.

---

## 6. Backend: `api` Module

### 6.1 Admin controller — `CorporateActionDividendAdminController`

**File:** `portfolio-optimizer-backend/api/src/main/java/com/portfolio/tracker/api/controller/CorporateActionDividendAdminController.java`

New class (not a method addition to the existing `CorporateActionAdminController` — that class is already near its scope boundary and keeping it scoped to splits is clearer).

```java
@Slf4j
@RestController
@RequestMapping("/api/admin/corporate-actions/dividends")
@RequiredArgsConstructor
@PreAuthorize("#user != null && T(java.lang.Boolean).TRUE.equals(#user.getIsSuperuser())")
public class CorporateActionDividendAdminController {

    private final CorporateActionDividendBackfillJob backfillJob;
    private final DividendAnomalyService anomalyService;

    @PostMapping("/backfill-all")
    public ResponseEntity<Map<String, String>> backfillAll(@AuthenticationPrincipal User user) {
        requireSuperuser(user);
        backfillJob.backfillAllActiveAsync();
        return ResponseEntity.accepted().body(Map.of(
                "status", "accepted",
                "message", "Dividend backfill started in background"));
    }

    @PostMapping("/backfill/{securityMasterId}")
    public ResponseEntity<Map<String, String>> backfillOne(
            @AuthenticationPrincipal User user, @PathVariable UUID securityMasterId) {
        requireSuperuser(user);
        backfillJob.backfillForSecurityAsync(securityMasterId);
        return ResponseEntity.accepted().body(Map.of(
                "status", "accepted",
                "securityMasterId", securityMasterId.toString()));
    }

    @PostMapping("/manual")
    public ResponseEntity<?> recordManual(
            @AuthenticationPrincipal User user, @RequestBody ManualDividendRequest req) {
        requireSuperuser(user);
        // validate non-null fields, currency length, amount > 0
        Optional<CorporateActionCashDividend> saved = backfillJob.recordManualDividend(
                req.securityMasterId(), req.exDate(), req.payDate(),
                req.amountPerShare(), req.currency());
        return ResponseEntity.ok(Map.of(
                "status", "ok",
                "id", saved.map(d -> d.getId().toString()).orElse(""),
                "source", saved.map(CorporateActionCashDividend::getSource).orElse("")));
    }

    @GetMapping("/anomalies")
    public ResponseEntity<List<DividendAnomaly>> anomalies(
            @AuthenticationPrincipal User user, @RequestParam UUID portfolioId) {
        requireSuperuser(user);
        return ResponseEntity.ok(anomalyService.findAnomalies(portfolioId));
    }

    public record ManualDividendRequest(
            UUID securityMasterId,
            @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate exDate,
            @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate payDate,
            BigDecimal amountPerShare,
            String currency) {}

    private static void requireSuperuser(User user) {
        if (user == null || !Boolean.TRUE.equals(user.getIsSuperuser())) {
            throw new ResponseStatusException(HttpStatus.FORBIDDEN, "Superuser access required");
        }
    }
}
```

### 6.2 Analytics service — `DividendAnalyticsService`

**File:** `portfolio-optimizer-backend/api/src/main/java/com/portfolio/tracker/api/service/DividendAnalyticsService.java`

Reads exclusively from `transactions` (type `DIVIDEND`). FX-converts to the portfolio's reporting currency using **the transaction's own date** — matching how realized P/L is priced.

```java
@Service
@RequiredArgsConstructor
public class DividendAnalyticsService {

    private final TransactionRepository transactionRepository;
    private final CurrencyConversionService fx;

    /** Sum DIVIDEND transactions by security_listing_id. */
    public Map<UUID, DividendAggregate> aggregateByListing(
            UUID portfolioId, String reportingCurrency) {
        List<Transaction> txns = transactionRepository
                .findByPortfolioIdAndTransactionType(portfolioId, TransactionType.DIVIDEND);
        Map<UUID, DividendAggregate> out = new HashMap<>();
        for (Transaction t : txns) {
            UUID listingId = t.getSecurityListingId();
            BigDecimal native_ = safeAmount(t);
            BigDecimal reporting = fx.convert(
                    native_, t.getTransactionCurrency(), reportingCurrency,
                    t.getTransactionDate().toLocalDate());
            out.merge(listingId,
                    new DividendAggregate(native_, reporting),
                    DividendAggregate::plus);
        }
        return out;
    }

    /** Lifetime + YTD totals for the whole portfolio, in reporting currency. */
    public PortfolioDividendTotals aggregatePortfolio(
            UUID portfolioId, String reportingCurrency) {
        List<Transaction> txns = transactionRepository
                .findByPortfolioIdAndTransactionType(portfolioId, TransactionType.DIVIDEND);
        BigDecimal lifetime = BigDecimal.ZERO;
        BigDecimal ytd      = BigDecimal.ZERO;
        OffsetDateTime yearStart = OffsetDateTime.of(
                LocalDate.now().withDayOfYear(1), LocalTime.MIDNIGHT, ZoneOffset.UTC);
        for (Transaction t : txns) {
            BigDecimal reporting = fx.convert(
                    safeAmount(t), t.getTransactionCurrency(), reportingCurrency,
                    t.getTransactionDate().toLocalDate());
            lifetime = lifetime.add(reporting);
            if (!t.getTransactionDate().isBefore(yearStart)) {
                ytd = ytd.add(reporting);
            }
        }
        return new PortfolioDividendTotals(lifetime, ytd);
    }

    private static BigDecimal safeAmount(Transaction t) {
        // DIVIDEND transactions store total received in .price (brokers vary);
        // if that's null, fall back to quantity × price. Defensive for legacy rows.
        if (t.getPrice() != null && (t.getQuantity() == null
                || t.getQuantity().signum() == 0)) {
            return t.getPrice();
        }
        return t.getQuantity().multiply(t.getPrice());
    }

    public record DividendAggregate(BigDecimal totalNative, BigDecimal totalReporting) {
        public DividendAggregate plus(DividendAggregate other) {
            return new DividendAggregate(
                    totalNative.add(other.totalNative),
                    totalReporting.add(other.totalReporting));
        }
    }

    public record PortfolioDividendTotals(BigDecimal lifetime, BigDecimal ytd) {}
}
```

> **Implementation note:** The `safeAmount` heuristic needs confirmation against how `TransactionService` currently persists `DIVIDEND` rows from SnapTrade. Audit during implementation — if there's one consistent convention, simplify.

### 6.3 Anomaly service — `DividendAnomalyService`

**File:** `portfolio-optimizer-backend/api/src/main/java/com/portfolio/tracker/api/service/DividendAnomalyService.java`

Admin-only consumer of the events table. Walks each holding's declared dividends and asserts a matching broker transaction exists in a forgiving date window.

```java
@Service
@RequiredArgsConstructor
public class DividendAnomalyService {

    private static final int BUSINESS_DAY_WINDOW = 10;
    private static final int FALLBACK_WINDOW_DAYS = 30;

    private final CorporateActionCashDividendRepository dividendRepo;
    private final TransactionRepository transactionRepo;
    private final HoldingRepository holdingRepo;
    // ...plus SecurityListing lookup

    public List<DividendAnomaly> findAnomalies(UUID portfolioId) {
        List<DividendAnomaly> result = new ArrayList<>();
        LocalDate today = LocalDate.now();

        for (Holding holding : holdingRepo.findActiveByPortfolioId(portfolioId)) {
            UUID masterId = holding.getSecurityListing().getSecurity().getEffectiveId();
            List<CorporateActionCashDividend> declared =
                    dividendRepo.findBySecurityMasterIdOrderByExDateAsc(masterId);

            for (CorporateActionCashDividend d : declared) {
                // Skip future / too-recent events — give the broker 10 business days.
                LocalDate anchor = d.getPayDate() != null ? d.getPayDate() : d.getExDate();
                if (!anchor.isBefore(today.minusDays(FALLBACK_WINDOW_DAYS))) continue;

                BigDecimal qtyAtExDate = quantityHeldAt(portfolioId,
                        holding.getSecurityListingId(), d.getExDate());
                if (qtyAtExDate.signum() <= 0) continue;

                if (!hasMatchingTransaction(portfolioId, holding.getSecurityListingId(),
                        anchor, d.getPayDate() == null)) {
                    BigDecimal expected = qtyAtExDate.multiply(d.getAmountPerShare());
                    result.add(new DividendAnomaly(
                            holding.getSecurityListingId(),
                            holding.getSecurityListing().getTicker(),
                            d.getExDate(), d.getPayDate(),
                            d.getAmountPerShare(), d.getCurrency(),
                            qtyAtExDate, expected));
                }
            }
        }
        return result;
    }

    // quantityHeldAt: sum BUY − SELL for listing up to and including ex_date
    // hasMatchingTransaction: any DIVIDEND txn within anchor ± 10 business days,
    //                        or anchor + FALLBACK_WINDOW_DAYS when payDate unknown

    public record DividendAnomaly(
            UUID securityListingId, String ticker,
            LocalDate exDate, LocalDate payDate,
            BigDecimal declaredAmountPerShare, String currency,
            BigDecimal qtyHeldAtExDate, BigDecimal expectedTotal) {}
}
```

### 6.4 DTO wiring — `HoldingDto`, `HoldingMapper`, `HoldingService`

**`HoldingDto` — add three fields** (all nullable; legacy payloads deserialize cleanly):

```java
// Dividend analytics (lifetime)
private BigDecimal totalDividendsNative;      // in transaction currency
private BigDecimal totalDividendsReporting;   // in reporting currency
private BigDecimal dividendYieldOnCostPct;    // totalDividendsReporting / costBasisReporting × 100
```

**`HoldingService`** — in whatever method builds the per-portfolio holdings list (e.g. `getHoldingsForPortfolio(portfolioId, reportingCurrency)`), call `DividendAnalyticsService.aggregateByListing(...)` **once per request** and thread the map into the mapper:

```java
Map<UUID, DividendAggregate> divMap =
        dividendAnalyticsService.aggregateByListing(portfolioId, reportingCurrency);
return holdings.stream()
    .map(h -> holdingMapper.toDto(h, ..., divMap.get(h.getSecurityListingId())))
    .toList();
```

**`HoldingMapper.toDto(...)`** — accept the optional `DividendAggregate`; when non-null:

```java
dto.setTotalDividendsNative(agg.totalNative());
dto.setTotalDividendsReporting(agg.totalReporting());
if (dto.getCostBasisReporting() != null
        && dto.getCostBasisReporting().signum() > 0) {
    dto.setDividendYieldOnCostPct(
            agg.totalReporting()
               .divide(dto.getCostBasisReporting(), 4, RoundingMode.HALF_UP)
               .multiply(BigDecimal.valueOf(100)));
}
```

### 6.5 `PortfolioValuation` — dashboard totals

Extend the inner class in `PortfolioValuationService`:

```java
public static class PortfolioValuation {
    // ... existing fields
    private BigDecimal totalDividendIncomeLifetime; // reporting currency
    private BigDecimal totalDividendIncomeYtd;      // reporting currency
    // getters, setters, builder methods
}
```

In `calculatePortfolioValuation(UUID portfolioId)` — resolve the portfolio's reporting currency, then call `dividendAnalyticsService.aggregatePortfolio(portfolioId, reportingCurrency)` and set the two fields on the builder. Zero-row portfolios return `BigDecimal.ZERO` for both.

**Cache consideration:** `@Cacheable(value = "portfolioValuations", key = "#portfolioId")`. Verify during implementation that the existing transaction-create/update/delete path evicts this cache; if not, annotate those call sites with `@CacheEvict(value = "portfolioValuations", key = "#portfolioId")`. Without eviction, adding a `DIVIDEND` transaction won't update the KPI until cache TTL — a silent bug.

### 6.6 Existing files that don't change

- `Transaction.java` — `TransactionType.DIVIDEND` already exists. No change.
- `RealizedGainCalculator.java` — AVCO already skips DIVIDEND (`no episode accumulator impact`). No change.
- `HistoricalPriceBackfillCompletedEvent.java` — reused as-is for the JIT listener.
- `BrokerSyncService.java` — already maps SnapTrade "DIVIDEND" → `TransactionType.DIVIDEND`. No change.

---

## 7. Frontend

### 7.1 `SnapshotMetrics` model

**File:** `portfolio-optimizer-frontend/src/app/dashboard/dashboard.models.ts`

```ts
export interface SnapshotMetrics {
  totalValue: number;
  totalInvested: number;
  dailyGainLoss: number;
  dailyGainLossPct: number;
  totalGainLoss: number;
  totalGainLossPct: number;
  dailyCoverageCount: number;
  totalHoldingsCount: number;

  /** Lifetime dividend income, reporting currency. */
  totalDividendIncomeLifetime: number;

  /** Current-calendar-year dividend income, reporting currency. */
  totalDividendIncomeYtd: number;
}
```

### 7.2 Dashboard KPI card

**File:** `portfolio-optimizer-frontend/src/app/dashboard/dashboard.component.html`

Add a new card inside the portfolio-row ledger section, between the "Realized Gain" placeholder and the "Positions" card. Matches the existing `.kpi-card` class convention.

```html
<div class="kpi-card">
  <span class="kpi-card__label">Dividend Income</span>
  <span class="kpi-card__value">
    {{ snapshotMetrics().totalDividendIncomeLifetime | currency:reportingCurrency():'symbol':'1.2-2' }}
  </span>
  <span class="kpi-card__subtitle">
    YTD: {{ snapshotMetrics().totalDividendIncomeYtd | currency:reportingCurrency():'symbol':'1.2-2' }}
  </span>
</div>
```

The `snapshotMetrics` computed signal already reduces holdings to a single object; extend its aggregation to read the two new backend fields straight through from the portfolio summary API response.

### 7.3 Holdings columns

**File:** `portfolio-optimizer-frontend/src/app/portfolio/column-defs.ts`

Append two new optional, default-hidden columns after `gainLoss` and before `oneMonthDiff` (keeps monetary columns grouped):

```ts
{ id: 'dividendsReceived', label: 'Dividends Received', defaultWidth: 130,
  sortKey: 'dividendsReceived', numeric: true, optional: true, defaultVisible: false,
  tooltip: 'Lifetime cash dividends received for this position, in reporting currency.' },
{ id: 'yieldOnCost',       label: 'Yield on Cost',      defaultWidth: 110,
  sortKey: 'yieldOnCost',    numeric: true, optional: true, defaultVisible: false,
  tooltip: 'Lifetime dividends received ÷ cost basis × 100.' },
```

### 7.4 Holdings table template + logic

**File:** `portfolio-optimizer-frontend/src/app/portfolio/portfolio.component.html`

Add two new `@case` branches in the row-cell `@switch` (near the existing `gainLoss` case):

```html
@case ('dividendsReceived') {
  <td class="cell cell--numeric">
    {{ holding.totalDividendsReporting | currency:reportingCurrency():'symbol':'1.2-2' }}
  </td>
}
@case ('yieldOnCost') {
  <td class="cell cell--numeric">
    @if (holding.dividendYieldOnCostPct != null) {
      {{ holding.dividendYieldOnCostPct | number:'1.2-2' }}%
    } @else {
      —
    }
  </td>
}
```

**File:** `portfolio-optimizer-frontend/src/app/portfolio/portfolio.component.ts`

Extend the sort-key-to-holding-field map so the new columns sort correctly. Typed numeric comparisons; nulls sort last in both directions.

### 7.5 What doesn't change on the frontend

- `ApiService` — no new endpoints; the new fields ride on the existing `GET /api/holdings` and portfolio-summary responses.
- No new routes, no new components, no new design tokens.

---

## 8. Testing

### 8.1 Unit — `core` module

- `CorporateActionCashDividendTest` — `@PrePersist` assigns `id` and `createdAt`; doesn't overwrite an explicit `id`.
- `EodhdDividendClientTest` —
  - Parses a realistic EODHD JSON sample.
  - Prefers `unadjustedValue` over `value` when both present.
  - Falls back to `value` when `unadjustedValue` is missing.
  - 404 → empty list.
  - 429 → `EodhdDividendRateLimitException`.
  - Blank / `"[]"` body → empty list.
  - Negative or zero `amount_per_share` filtered out.

### 8.2 Integration — `api` module (Testcontainers + Postgres, never H2)

- `CorporateActionDividendBackfillJobIT` —
  - JIT path: publish a `HistoricalPriceBackfillCompletedEvent` → row lands.
  - Weekly sweep path: seed two symbols → both are backfilled.
  - Idempotency: run backfill twice → second run inserts zero rows.
  - Rate limit: mock client throws `EodhdDividendRateLimitException` → sweep logs and continues.
- `DividendAnalyticsServiceIT` —
  - Single currency: sum three transactions correctly.
  - Multi-currency: USD-denominated transaction sums correctly into a GBP reporting currency via `CurrencyConversionService`.
  - YTD boundary: a transaction on `Dec 31 23:59 UTC` is **not** in YTD; a transaction on `Jan 1 00:00 UTC` **is**.
  - Yield on cost: cost basis = 0 returns null (not `Infinity`).
- `DividendAnomalyServiceIT` —
  - Declared event with no matching transaction → anomaly.
  - Declared event with transaction within `±10 business days` of `pay_date` → no anomaly.
  - Declared event with `qty_at_ex_date = 0` → ignored.
  - Declared event with `pay_date` null → falls back to `ex_date + 30 days` window.
  - Declared event in the future → not flagged.
- `CorporateActionDividendAdminControllerIT` —
  - Non-superuser → `403`.
  - Superuser `backfill-all` → `202`.
  - Superuser `manual` POST twice for same `(securityMasterId, exDate)` → both return `200`, only one row in DB.
  - `anomalies` without `portfolioId` param → `400`.

### 8.3 Frontend (Karma/Jasmine)

- `dashboard.component.spec.ts` — new case: KPI card renders `totalDividendIncomeLifetime` and `totalDividendIncomeYtd`.
- `column-defs.spec.ts` — snapshot-style assertion that `dividendsReceived` and `yieldOnCost` appear with the expected shape.
- Skip `portfolio.component.spec.ts` per `CLAUDE.md`'s known-broken list.

---

## 9. Rollout Sequence

Each numbered step is a standalone PR so production risk stays bounded at each merge.

1. **Migration + entity + repository.** Zero-risk additive change. Deploy. Verify table exists in prod.
2. **EODHD client + backfill job + 3 admin mutation endpoints.** Guarded by config flag `app.features.corporate-actions-dividends=false`; the `@Scheduled` and `@EventListener` no-op while the flag is off. Deploy. Unit + integration tests pass.
3. **`DividendAnalyticsService` + DTO field wiring.** New fields are nullable so older frontend builds ignore them safely. Deploy. Confirm `GET /api/holdings` response includes the new keys.
4. **`DividendAnomalyService` + `GET /anomalies`.** Admin-only; no UI surface. Deploy.
5. **Frontend — SnapshotMetrics, KPI card, column defs, template cases.** Deploy. New columns are opt-in (default hidden).
6. **Flip the feature flag in staging.** Run `POST /backfill-all`. Inspect `GET /anomalies` for the dev-team portfolio. If clean, flip in prod.

---

## 10. Risks & Known Edge Cases

- **Currency mismatch on ADRs.** BABA ADR pays USD; its listing trades as USD too, so benign. But GSK ADR pays GBP while trading in USD. The analytics FX conversion **must use the transaction's own currency**, not the listing's trading currency, and the anomaly service must compare `qty × amountPerShare × divCurrency→txnCurrency FX`. Add a multi-currency ADR case to `DividendAnalyticsServiceIT`.
- **Split-adjusted vs. raw dividend amounts.** EODHD's `value` is split-adjusted; `unadjustedValue` is raw. Because splits are applied at read-time in `RealizedGainCalculator` and not baked into transactions, the raw amount is the one that aligns. `EodhdDividendClient` must prefer `unadjustedValue` and the test suite must assert that preference explicitly.
- **Future-dated declarations.** EODHD sometimes returns ex_dates beyond today (the board declared the Q+1 dividend). Ingest them (no analytics impact) but `DividendAnomalyService` must filter to events anchored at least `FALLBACK_WINDOW_DAYS` before today before flagging anything.
- **Multi-portfolio same security.** One security held in two portfolios — each portfolio's analytics are independently scoped by `transactions.portfolio_id`. No cross-portfolio rollup. If a user expects one, that's a Phase C feature.
- **Cache eviction.** `PortfolioValuationService` is `@Cacheable`. If the existing transaction-insert path doesn't already evict `portfolioValuations`, adding a `DIVIDEND` transaction will **not** update the KPI until cache TTL. Verify during implementation of § 6.5; add `@CacheEvict` if missing.
- **Broker dividend amount conventions.** Some brokers store the total received in `transaction.price` with `quantity = 0` or `null`; others store `quantity × per-share price`. `DividendAnalyticsService.safeAmount` has a defensive heuristic — but the cleaner long-term fix is to canonicalize at ingest in `TransactionService`. Tracked as a follow-up (not in Phase A).

---

## Appendix A — Reference files

| Role | Path |
|---|---|
| Splits migration (template) | `portfolio-optimizer-backend/api/src/main/resources/db/migration/V20260419120000__CreateCorporateActionSplitTable.sql` |
| Splits entity (template) | `portfolio-optimizer-backend/core/src/main/java/com/portfolio/tracker/core/model/CorporateActionSplit.java` |
| Splits repository (template) | `portfolio-optimizer-backend/core/src/main/java/com/portfolio/tracker/core/repository/CorporateActionSplitRepository.java` |
| Splits EODHD client (template) | `portfolio-optimizer-backend/jobs/src/main/java/com/portfolio/tracker/jobs/service/EodhdSplitsClient.java` |
| Splits backfill job (template) | `portfolio-optimizer-backend/jobs/src/main/java/com/portfolio/tracker/jobs/task/marketdata/CorporateActionSplitBackfillJob.java` |
| Splits admin controller (template) | `portfolio-optimizer-backend/api/src/main/java/com/portfolio/tracker/api/controller/CorporateActionAdminController.java` |
| `HoldingDto` (extend) | `portfolio-optimizer-backend/core/src/main/java/com/portfolio/tracker/core/dto/HoldingDto.java` |
| `PortfolioValuationService` (extend) | `portfolio-optimizer-backend/api/src/main/java/com/portfolio/tracker/api/service/PortfolioValuationService.java` |
| `Transaction` enum (unchanged) | `portfolio-optimizer-backend/core/src/main/java/com/portfolio/tracker/core/model/Transaction.java` |
| `AsyncConfig.backgroundJobExecutor` (reused) | `portfolio-optimizer-backend/jobs/src/main/java/com/portfolio/tracker/jobs/config/AsyncConfig.java` |
| `HistoricalPriceBackfillCompletedEvent` (reused) | `portfolio-optimizer-backend/jobs/src/main/java/com/portfolio/tracker/jobs/event/HistoricalPriceBackfillCompletedEvent.java` |
| `SnapshotMetrics` (extend) | `portfolio-optimizer-frontend/src/app/dashboard/dashboard.models.ts` |
| Column defs (extend) | `portfolio-optimizer-frontend/src/app/portfolio/column-defs.ts` |
