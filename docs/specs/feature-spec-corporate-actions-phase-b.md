# Feature Spec: Corporate Actions — Mergers, Spin-offs & Global Chronological Replay (Phase B)

**Status:** Draft
**Date:** 2026-04-22
**Phase:** B of 2 (Phase A — dividends & analytics — landed 2026-04-21)
**Depends on:**
- `corporate_action_split` pattern (ADR-014) — Phase B extends the same read-time-injection timeline.
- `corporate_action_cash_dividend` pattern (ADR-017) — confirms analytics read ledger, events are reconciliation; mergers/spin-offs follow the same rule.
- `RealizedGainCalculator.AvcoState` (core) — refactor target.
- `HistoryQueryService`, `StockGroupService`, `TickerDetailService` — per-master callers that migrate.
- `HistoricalPriceBackfillCompletedEvent`, `AsyncConfig.backgroundJobExecutor` — reused for JIT ingest.

---

## 1. Problem & Scope

### 1.1 Problem

The AVCO realized-gain engine is **structurally per-`security_master_id`**. Every entry point (`computeTxnCurrency`, `computeReportingCurrency`, `computeEpisodesAndSellRealized`, `detectAnomalies`) takes `List<Transaction> txnsForOneSecurity` and walks one master in isolation. Every caller — `HistoryQueryService.compute()`, `StockGroupService.computeTotalRealizedGain()`, `TickerDetailService.toTickerTransactionDtos()` — loops per master and never sees two masters sharing a walk.

Mergers and spin-offs break this invariant in two different ways:

- **Merger (A → B):** on ex_date, master A's position *becomes* master B's position. The cost basis must move from A's `AvcoState` into B's `AvcoState`. If the deal has a cash component, part of A's basis must be allocated to the cash and a realized P/L emitted.
- **Spin-off (P → C):** on ex_date, master P spawns master C. `basis_allocation_pct` of P's cost basis moves to C (P's quantity unchanged, C's quantity = `parent_qty × shares_per_parent`). For users who held P before the spin-off, C arrives with a non-zero cost basis that has never touched a broker DIVIDEND/BUY transaction.

Today, a user holding AT&T (T) through the 2022-04-08 WBD spin-off sees **zero cost basis** on WBD in our system. When they eventually sell WBD, the engine reports the full sale proceeds as realized gain — overstating taxable gain by whatever portion of T's original basis should have transferred.

### 1.2 What Phase B delivers

1. **`corporate_action_merger` + `corporate_action_spinoff` tables** — facts, keyed by canonical `security_master_id`.
2. **Connected-component replay refactor of `RealizedGainCalculator`** — the AVCO walker processes a connected component (masters linked by merger/spin-off edges) in one pass with per-master `AvcoState`s and cross-master event injection.
3. **Ephemeral `CorporateActionLedgerEntry` rows** surfaced on the History page, tracing exactly how cost basis moved from A to B without mutating the immutable `transactions` ledger.
4. **Cash-per-share merger handling** with auto-derived `cash_basis_pct` + optional admin override.
5. **Admin endpoints** `/api/admin/corporate-actions/{mergers,spinoffs}/*` for backfill + manual entry (spin-off `basis_allocation_pct` is manual-primary per IRS Form 8937 reality).
6. **Integration tests** against seeded real-world scenarios: AT&T → WBD 2022 spin-off, a stock-for-stock merger, a cash-boot merger, and a symbol-change no-op to confirm `canonicalMasterId` semantics are preserved.

### 1.3 Non-goals (explicitly deferred)

- **Tax-lot-specific treatment.** We stay AVCO everywhere. Phase C or beyond may add FIFO/LIFO/specific-lot.
- **User-facing merger/spin-off editor.** Admin-only in Phase B. End users see the ephemeral ledger rows and realized-P/L changes, but can't add/edit corporate actions.
- **Retroactive rebuild of Phase A analytics.** Dividend totals aren't affected by the replay refactor — they already derive from `transactions` directly.
- **Buyouts, rights offerings, symbol changes.** Per the Phase A ticket, these were confirmed no-op (brokers book them as SELL/BUY/SELL). One test each verifies the claim; no code path added.
- **Cross-portfolio replay.** Mergers don't cross portfolio boundaries (a position in Portfolio X is never merged with a position in Portfolio Y). Replay scope is always one portfolio's connected components.

### 1.4 Acceptance criteria

- [ ] `corporate_action_merger` + `corporate_action_spinoff` tables, entities, repositories.
- [ ] `AvcoState` gains three mutators (`mergeFrom`, `applyCashBoot`, `splitOffFraction`) with full `BigDecimal` correctness.
- [ ] `CorporateActionChainResolver` computes connected components over merger + spin-off edges.
- [ ] `PortfolioReplayService` replaces the three per-master callers with a single portfolio-scoped replay.
- [ ] `HistoryQueryService` emits `CorporateActionLedgerEntry` rows in-line with transactions.
- [ ] Cash-merger realized P/L auto-derives from ex_date market price; nullable `cash_basis_pct_override` admin field for manual correction.
- [ ] Spin-off `basis_allocation_pct` is manual-primary; replay emits a `SPINOFF_MISSING_BASIS` anomaly when null rather than silently skipping.
- [ ] Admin endpoints `/api/admin/corporate-actions/{mergers,spinoffs}/{backfill-all, backfill/{id}, manual}` — superuser-gated.
- [ ] Integration tests (Testcontainers + Postgres): AT&T → WBD 2022, cash-boot merger, multi-step chain, symbol-change no-op.
- [ ] ADR-018 documenting the global chronological replay architecture.
- [ ] `SYSTEM_SNAPSHOT.md` updated under §2 Core Business Entities.

---

## 2. Architecture

### 2.1 The core abstraction: `ReplayChain`

A **`ReplayChain`** is a connected component of `security_master_id`s under the graph whose edges are:

- **Merger edges:** `corporate_action_merger(from_master_id, to_master_id)` — directed A → B.
- **Spin-off edges:** `corporate_action_spinoff(parent_master_id, child_master_id)` — directed P → C.

Chains are computed on-demand per portfolio replay request by BFS-walking the merger + spin-off tables starting from every master id that appears in the portfolio's transactions.

**Most chains are singletons.** A master with no edges forms a chain of size 1 — which walks identically to today's per-master AVCO pass. A portfolio of 50 positions with no mergers/spin-offs costs exactly what it costs today. Only chains of size ≥ 2 pay for cross-master replay.

### 2.2 Timeline construction

For each chain, a single sorted `List<ReplayEvent>` is built from four sources:

- **Transactions** on any master in the chain, fetched via existing `TransactionRepository.findAllForReplay(List.of(portfolioId))` and filtered to the chain's masters.
- **Splits** on any master in the chain.
- **Mergers** where `from_master_id` is in the chain.
- **Spin-offs** where `parent_master_id` is in the chain.

Dividends are *not* injected — they don't touch cost basis (ADR-017).

### 2.3 Timeline timestamp convention

Transactions carry `OffsetDateTime` (UTC). Corporate-action events carry `LocalDate` (ex_date). We synthesize each event's position in the timeline as `ex_date T00:00:00Z`. Any transaction on or after the ex_date is therefore post-event, matching the splits convention locked in by ADR-014 §Ex-date convention.

Secondary sort on same-instant ties: `(eventKind ordinal, id)` where `SPLIT=0 < MERGER=1 < SPINOFF=2 < TRANSACTION=3`. Rationale: if a 2:1 split and a merger share an ex_date (rare but possible — an acquirer splits its shares on the same date the merger closes), the split fires first so the merger's `ratio` can be applied against post-split quantities. The `< TRANSACTION` ordering guarantees a transaction dated on the ex_date is processed after any event on that date.

### 2.4 The replay loop

```
   Load all transactions for portfolio
           │
           ▼
   Seed master ids = { t.securityListing.security.effectiveId : t ∈ txns }
           │
           ▼
   chains = CorporateActionChainResolver.resolveChains(seed master ids)
           │
           ▼
   for each chain:
     events = mergeSorted(txns on chain masters,
                          splits on chain masters,
                          mergers with from_master ∈ chain,
                          spin-offs with parent ∈ chain)
     statesByMaster : Map<UUID, AvcoState> = empty

     for event in events:
         ensure statesByMaster has the master(s) involved (lazy init)
         switch event:
             case Txn(t):       states[t.master].step(t)
             case Split(s):     states[s.master].applySplit(s.factor())
             case Merger(m):    transferState(states, m)        # cross-state mutation
             case Spinoff(sp):  splitState(states, sp)           # cross-state mutation
           │
           ▼
   ReplayResult aggregates across chains
```

`transferState` and `splitState` are the cross-master mutations — the moments where the AVCO math departs from the per-master model. Their semantics are specified in § 5.

### 2.5 Per-master attribution after cross-state events

Realized P/L and episodes are attributed to the **master on which the state mutation originated**. Specifically:

- Cash-boot realized from a merger A → B is attributed to **A** (the cash came out of A's position).
- An episode closure on A because a merger consumed all its quantity gets `episodeKind = MERGER_CLOSED` (vs. the normal SELL-closed), so the History page can render "AT&T — closed via Warner Bros Discovery merger 2022-04-08" distinctly from "AT&T — sold".
- Post-merger transactions on B are attributed to B as normal.
- A spin-off never emits realized P/L on the parent (IRS treatment — cost basis moves, no gain recognized); the `SPINOFF_BASIS_OUT` ephemeral ledger entry is pure basis movement.

### 2.6 Why not `canonicalMasterId`

ADR-005 defines `SecurityMaster.canonicalMasterId` as a **static same-security deduplication alias** — used for cross-exchange listings of the same security (NSE + BSE Reliance). Every consumer assumes it's bidirectional and eternal. `TransactionRepository.findByPortfolioIdAndEffectiveSecurityMasterIdOrderByTransactionDateAsc` uses the expression `t.security.id = :id OR t.security.canonicalMasterId = :id` — a bidirectional merge with no date filter. Reusing this field for merger routing would silently bleed pre-merger A transactions into pre-merger B analytics, corrupting realized P/L for any user who held both A and B before the merger (common case: index-fund portfolios that held both pieces before the deal).

Phase B uses the `corporate_action_merger` **table itself** as the chain source of truth. A separate resolver walks it with date awareness; `canonicalMasterId` keeps its current semantics untouched. ADR-018 records this decision.

---

## 3. Database Schema

Two migrations, next free timestamps after Phase A's `V20260421120000`:

- `V20260422120000__CreateCorporateActionMergerTable.sql`
- `V20260422130000__CreateCorporateActionSpinoffTable.sql`

### 3.1 `corporate_action_merger`

```sql
-- Declared stock-for-stock or cash-plus-stock merger, keyed by the acquired
-- master. One row per merger; compound deals (M&A with scrip + cash-in-lieu +
-- option conversion) that involve a single acquiree collapse into one row
-- because cash_per_share and ratio together describe the consideration.
--
-- Read-time consumption: RealizedGainCalculator replay walks this table as
-- part of the merged event timeline; applies transferState(A, B) at ex_date.
-- Analytics (Holdings, Dashboard KPIs) see post-merger numbers because the
-- replay result feeds them — no direct reads from this table by UI.

CREATE TABLE IF NOT EXISTS corporate_action_merger (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    from_master_id           UUID NOT NULL REFERENCES security_master(id) ON DELETE CASCADE,
    to_master_id             UUID NOT NULL REFERENCES security_master(id) ON DELETE CASCADE,
    ex_date                  DATE NOT NULL,
    ratio_numerator          NUMERIC(20, 10) NOT NULL,   -- new shares per old share (numerator)
    ratio_denominator        NUMERIC(20, 10) NOT NULL,   -- ... / denominator; e.g. 0.241917 ⇒ 241917/1000000
    cash_per_share           NUMERIC(20, 10),            -- nullable; pure-stock deals have none
    cash_currency            VARCHAR(3),                 -- required iff cash_per_share NOT NULL
    cash_basis_pct_override  NUMERIC(10, 8),             -- optional; overrides auto cash_basis_pct computation
    source                   VARCHAR(64) NOT NULL,       -- "EODHD" | "MANUAL"
    created_at               TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
    CONSTRAINT corporate_action_merger_ratio_positive
        CHECK (ratio_numerator > 0 AND ratio_denominator > 0),
    CONSTRAINT corporate_action_merger_cash_coherent
        CHECK ((cash_per_share IS NULL AND cash_currency IS NULL)
            OR (cash_per_share > 0 AND cash_currency IS NOT NULL
                AND char_length(cash_currency) = 3)),
    CONSTRAINT corporate_action_merger_override_range
        CHECK (cash_basis_pct_override IS NULL
            OR (cash_basis_pct_override >= 0 AND cash_basis_pct_override <= 1)),
    CONSTRAINT corporate_action_merger_distinct
        CHECK (from_master_id <> to_master_id),
    CONSTRAINT corporate_action_merger_unique
        UNIQUE (from_master_id, ex_date)
);
CREATE INDEX idx_corporate_action_merger_to_master_id
    ON corporate_action_merger(to_master_id);
```

**Key constraints:**
- `UNIQUE(from_master_id, ex_date)` — a master can only merge out once per ex_date. Re-runs of the backfill are idempotent.
- `cash_coherent` — no half-populated cash metadata; either cash+currency or neither.
- `override_range` — if override is provided, it's a valid probability.
- `distinct` — no self-merger (would mean a no-op).
- Implicit btree from the unique constraint covers the `from_master_id` lookup path; explicit `idx_…_to_master_id` covers the chain-build lookup from the receiving side.

### 3.2 `corporate_action_spinoff`

```sql
-- Declared spin-off event: one row per (parent, child, ex_date) edge.
-- Parent spawns child; basis_allocation_pct of parent basis moves to child;
-- parent quantity unchanged, child quantity = parent_qty × shares_per_parent.
--
-- basis_allocation_pct is NULLABLE because EODHD does not reliably provide it
-- (IRS Form 8937 is the authoritative source and typically requires manual
-- entry). The replay walker treats null pct as an anomaly and skips the
-- basis transfer — emitting SPINOFF_MISSING_BASIS rather than silently
-- under-allocating.

CREATE TABLE IF NOT EXISTS corporate_action_spinoff (
    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    parent_master_id       UUID NOT NULL REFERENCES security_master(id) ON DELETE CASCADE,
    child_master_id        UUID NOT NULL REFERENCES security_master(id) ON DELETE CASCADE,
    ex_date                DATE NOT NULL,
    shares_per_parent      NUMERIC(20, 10) NOT NULL,    -- child shares per 1 parent share
    basis_allocation_pct   NUMERIC(10, 8),              -- nullable; manual-primary; 0..1 exclusive
    source                 VARCHAR(64) NOT NULL,        -- "EODHD_PARTIAL" | "MANUAL"
    created_at             TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
    CONSTRAINT corporate_action_spinoff_shares_positive
        CHECK (shares_per_parent > 0),
    CONSTRAINT corporate_action_spinoff_alloc_range
        CHECK (basis_allocation_pct IS NULL
            OR (basis_allocation_pct > 0 AND basis_allocation_pct < 1)),
    CONSTRAINT corporate_action_spinoff_distinct
        CHECK (parent_master_id <> child_master_id),
    CONSTRAINT corporate_action_spinoff_unique
        UNIQUE (parent_master_id, child_master_id, ex_date)
);
CREATE INDEX idx_corporate_action_spinoff_child_master_id
    ON corporate_action_spinoff(child_master_id);
```

**Key constraints:**
- `UNIQUE(parent, child, ex_date)` — allows a parent to spin off multiple children on the same ex_date (HP Inc. / HPE 2015 was a single-child split; multi-child deals would get one row per edge).
- `alloc_range` exclusive — `0` means no basis transferred (treat as split with `shares_per_parent`-only effect) which is not a spin-off; `1` means parent fully liquidated, which is a merger, not a spin-off.

### 3.3 BigDecimal precision rationale

- `NUMERIC(20, 10)` for quantities / ratios / cash-per-share — same precision as `corporate_action_split.ratio_numerator`. Supports >99 billion-share positions with 10 decimal places of precision on per-share values.
- `NUMERIC(10, 8)` for percentages — 2 digits of integer + 8 of fraction, representing 0.00000001 to 99.99999999. Overkill for basis percentages (which typically have 4-5 decimals on Form 8937), but cheap and future-proof.

---

## 4. Backend: `core` Module

### 4.1 Entities

Identical Lombok shape to `CorporateActionSplit` (see ADR-014).

**`CorporateActionMerger`** (file `core/model/CorporateActionMerger.java`):
```java
@Entity
@Table(name = "corporate_action_merger", uniqueConstraints = {
        @UniqueConstraint(name = "corporate_action_merger_unique",
                columnNames = {"from_master_id", "ex_date"})})
@Data @NoArgsConstructor @AllArgsConstructor @Builder(toBuilder = true)
public class CorporateActionMerger {
    @Id private UUID id;
    @Column(name = "from_master_id", nullable = false) private UUID fromMasterId;
    @Column(name = "to_master_id",   nullable = false) private UUID toMasterId;
    @Column(name = "ex_date",        nullable = false) private LocalDate exDate;
    @Column(name = "ratio_numerator",   nullable = false, precision = 20, scale = 10) private BigDecimal ratioNumerator;
    @Column(name = "ratio_denominator", nullable = false, precision = 20, scale = 10) private BigDecimal ratioDenominator;
    @Column(name = "cash_per_share",           precision = 20, scale = 10) private BigDecimal cashPerShare;
    @Column(name = "cash_currency", length = 3)                            private String cashCurrency;
    @Column(name = "cash_basis_pct_override",  precision = 10, scale = 8)  private BigDecimal cashBasisPctOverride;
    @Column(name = "source", nullable = false, length = 64) private String source;
    @Column(name = "created_at", nullable = false) private OffsetDateTime createdAt;

    /** new shares per old share = numerator/denominator; DECIMAL128 precision matches split.factor() */
    public BigDecimal ratioFactor() {
        if (ratioNumerator == null || ratioDenominator == null || ratioDenominator.signum() == 0) {
            return BigDecimal.ONE;
        }
        return ratioNumerator.divide(ratioDenominator, MathContext.DECIMAL128);
    }

    /** true iff this merger has a cash consideration alongside the stock. */
    public boolean hasCashComponent() {
        return cashPerShare != null && cashPerShare.signum() > 0;
    }

    @PrePersist
    public void prePersist() {
        if (id == null) id = UUID.randomUUID();
        if (createdAt == null) createdAt = OffsetDateTime.now();
    }
}
```

**`CorporateActionSpinoff`** (file `core/model/CorporateActionSpinoff.java`) follows the same pattern with `parentMasterId`, `childMasterId`, `sharesPerParent`, `basisAllocationPct` fields; no derived method.

### 4.2 Repositories

Both follow the Phase A three-method shape:

```java
// CorporateActionMergerRepository
List<CorporateActionMerger> findByFromMasterIdOrderByExDateAsc(UUID fromMasterId);
List<CorporateActionMerger> findByFromMasterIdInOrderByExDateAsc(Collection<UUID> fromMasterIds);
List<CorporateActionMerger> findByToMasterIdInOrderByExDateAsc(Collection<UUID> toMasterIds);
Optional<CorporateActionMerger> findByFromMasterIdAndExDate(UUID fromMasterId, LocalDate exDate);
```

Note the extra `findByToMasterIdIn…` method: chain resolution must walk edges in both directions (starting from any master in the portfolio, find mergers INTO it as well as OUT of it).

Spin-off repo has the analogous `findByParentMasterIdIn…`, `findByChildMasterIdIn…`, and unique lookup.

### 4.3 `ReplayEvent` sealed type

File: `core/dto/replay/ReplayEvent.java`

```java
public sealed interface ReplayEvent
        permits ReplayEvent.Txn, ReplayEvent.Split, ReplayEvent.Merger, ReplayEvent.Spinoff {

    /** Effective UTC timestamp for chronological sort. */
    OffsetDateTime timestamp();

    /** Same-instant tiebreaker: 0=split, 1=merger, 2=spinoff, 3=transaction. */
    int kindOrdinal();

    record Txn(Transaction transaction) implements ReplayEvent {
        public OffsetDateTime timestamp() { return transaction.getTransactionDate(); }
        public int kindOrdinal() { return 3; }
    }

    record Split(CorporateActionSplit split) implements ReplayEvent {
        public OffsetDateTime timestamp() {
            return split.getExDate().atStartOfDay().atOffset(ZoneOffset.UTC);
        }
        public int kindOrdinal() { return 0; }
    }

    record Merger(CorporateActionMerger merger) implements ReplayEvent {
        public OffsetDateTime timestamp() {
            return merger.getExDate().atStartOfDay().atOffset(ZoneOffset.UTC);
        }
        public int kindOrdinal() { return 1; }
    }

    record Spinoff(CorporateActionSpinoff spinoff) implements ReplayEvent {
        public OffsetDateTime timestamp() {
            return spinoff.getExDate().atStartOfDay().atOffset(ZoneOffset.UTC);
        }
        public int kindOrdinal() { return 2; }
    }

    /** Canonical comparator for the merged timeline. */
    Comparator<ReplayEvent> TIMELINE_ORDER =
            Comparator.comparing(ReplayEvent::timestamp,
                    Comparator.nullsLast(Comparator.naturalOrder()))
                .thenComparingInt(ReplayEvent::kindOrdinal);
}
```

### 4.4 `CorporateActionLedgerEntry` record

File: `core/dto/replay/CorporateActionLedgerEntry.java`

```java
/**
 * An ephemeral audit row emitted by the replay walker. Never persisted.
 * Surfaced on the History page alongside real transactions so users can trace
 * exactly how cost basis moved across a merger or spin-off.
 */
public record CorporateActionLedgerEntry(
        UUID portfolioId,
        UUID masterId,                         // the master affected on this side
        String ticker,
        LocalDate exDate,
        EntryKind kind,
        BigDecimal quantityDelta,              // signed: negative on OUT, positive on IN
        BigDecimal basisDeltaReporting,        // signed: reporting currency basis movement
        BigDecimal cashRealizedReporting,      // non-null only on MERGER_CASH_BOOT
        String counterpartyTicker,             // for readability; null on spin-off creation of new ticker
        UUID counterpartyMasterId,
        UUID sourceEventId                     // merger.id or spinoff.id — stable UUID for UI keying
) {
    public enum EntryKind {
        MERGER_TRANSFER_OUT,   // on A: qty + basis leave
        MERGER_TRANSFER_IN,    // on B: qty + basis arrive
        MERGER_CASH_BOOT,      // on A: realized P/L emitted for cash portion
        SPINOFF_BASIS_OUT,     // on P: basis leaves; qty unchanged
        SPINOFF_CREATION       // on C: qty + basis arrive
    }
}
```

Each merger emits two entries on its ex_date: `MERGER_TRANSFER_OUT` on A and `MERGER_TRANSFER_IN` on B, plus a third `MERGER_CASH_BOOT` on A when `cashPerShare > 0`. Each spin-off emits two: `SPINOFF_BASIS_OUT` on P and `SPINOFF_CREATION` on C. All carry the same `sourceEventId` so the UI can render them as paired rows.

### 4.5 `CorporateActionChainResolver` service

File: `core/service/CorporateActionChainResolver.java`

```java
@Service
@RequiredArgsConstructor
public class CorporateActionChainResolver {

    private final CorporateActionMergerRepository mergerRepo;
    private final CorporateActionSpinoffRepository spinoffRepo;

    /**
     * Build connected components of the merger + spin-off edge graph, starting
     * from the given seed masters. Every seed ends up in exactly one chain
     * (possibly a singleton). Cycles (pathological data) collapse into one
     * component without infinite walk.
     */
    public List<ReplayChain> resolveChains(Collection<UUID> seedMasterIds) {
        if (seedMasterIds == null || seedMasterIds.isEmpty()) return List.of();

        // BFS; visited tracks masters assigned to a chain
        Set<UUID> visited = new HashSet<>();
        List<ReplayChain> chains = new ArrayList<>();

        for (UUID seed : seedMasterIds) {
            if (visited.contains(seed)) continue;
            Set<UUID> component = new HashSet<>();
            Deque<UUID> frontier = new ArrayDeque<>();
            frontier.push(seed);
            while (!frontier.isEmpty()) {
                UUID cur = frontier.pop();
                if (!component.add(cur)) continue;

                // edges out-of: mergers A→? and spin-offs P→?
                for (CorporateActionMerger m : mergerRepo.findByFromMasterIdInOrderByExDateAsc(List.of(cur))) {
                    if (!component.contains(m.getToMasterId())) frontier.push(m.getToMasterId());
                }
                for (CorporateActionSpinoff sp : spinoffRepo.findByParentMasterIdInOrderByExDateAsc(List.of(cur))) {
                    if (!component.contains(sp.getChildMasterId())) frontier.push(sp.getChildMasterId());
                }
                // edges into: mergers ?→A and spin-offs ?→C
                for (CorporateActionMerger m : mergerRepo.findByToMasterIdInOrderByExDateAsc(List.of(cur))) {
                    if (!component.contains(m.getFromMasterId())) frontier.push(m.getFromMasterId());
                }
                for (CorporateActionSpinoff sp : spinoffRepo.findByChildMasterIdInOrderByExDateAsc(List.of(cur))) {
                    if (!component.contains(sp.getParentMasterId())) frontier.push(sp.getParentMasterId());
                }
            }
            visited.addAll(component);

            List<CorporateActionMerger> mergers = mergerRepo.findByFromMasterIdInOrderByExDateAsc(component);
            List<CorporateActionSpinoff> spinoffs = spinoffRepo.findByParentMasterIdInOrderByExDateAsc(component);
            chains.add(new ReplayChain(Set.copyOf(component), mergers, spinoffs));
        }
        return chains;
    }

    public record ReplayChain(
            Set<UUID> masterIds,
            List<CorporateActionMerger> mergers,
            List<CorporateActionSpinoff> spinoffs) {}
}
```

The BFS batches repo calls per-node; for large portfolios this can be optimized to one batch per visited-delta. For Phase B the non-batched version is acceptable — mergers are rare events, and the typical portfolio sees most seeds as singletons (repo returns empty immediately).

---

## 5. AVCO Math: The Three New `AvcoState` Mutators

Preserved: the existing `step(Transaction)` and `applySplit(BigDecimal)` — unchanged. Refactor is purely additive.

### 5.1 `mergeFrom` — stock-for-stock state absorption

**Signature:**
```java
public void mergeFrom(AvcoState other, BigDecimal ratioFactor);
```

**Semantics:**
```
this.totalShares += other.totalShares × ratioFactor
this.totalCost   += other.totalCost      // reporting currency; caller's mode must match
```

The weighted-merge form is correct because the broker is giving B shares in exchange for A shares; the basis that used to be on A's state IS the basis that should now live in B's state. If B had no pre-existing position, `this.totalCost` starts at zero and ends up equal to A's surrendered basis — arithmetically identical to "transfer basis wholesale."

Caller responsibility: after calling `mergeFrom`, zero out the `other` state (set `totalShares = totalCost = ZERO`). A's state is now empty; A is closed.

**Episode emission:** if `other.totalShares > 0` before the call, A's running quantity drops to 0; the caller emits a `ClosedEpisode` with `episodeKind = MERGER_CLOSED`.

### 5.2 `applyCashBoot` — cash-to-boot realized P/L emission

**Signature:**
```java
public BigDecimal applyCashBoot(BigDecimal cashPerShare, BigDecimal cashBasisPct);
```

**Semantics:**
```
basisAllocatedToCash = this.totalCost × cashBasisPct
realized             = (cashPerShare × this.totalShares) − basisAllocatedToCash
this.totalCost       -= basisAllocatedToCash
// this.totalShares unchanged — cash doesn't reduce quantity; the subsequent mergeFrom does
```

Returns the `realized` value for the caller to record in `ReplayResult.realizedByMaster` for master A.

**`cashBasisPct` resolution** (caller responsibility, not `AvcoState`'s):
1. If `merger.cashBasisPctOverride != null` → use override.
2. Else attempt auto-compute:
   ```
   toClosePrice = marketDataPriceDaily.findCloseOnOrBefore(toMaster, exDate)
   cashBasisPct = cashPerShare / (cashPerShare + ratioFactor × toClosePrice)
   ```
3. If auto-compute fails (no close price for B on ex_date), treat this merger as a "parity issue" — emit an anomaly `MERGER_MISSING_PRICE` and fall back to `cashBasisPct = 0` (transfers all basis to B; cash becomes pure proceeds, under-recognizes gain). The anomaly surfaces in the History page so the admin can supply the override.

Why this formula: under US IRC §356 proportional-boot treatment, the basis is allocated between the cash and stock components pro-rata to their fair values on ex_date. Fair value of stock received = `ratioFactor × toClosePrice`; fair value of cash = `cashPerShare`. The formula is the exact pro-rata split.

### 5.3 `splitOffFraction` — spin-off basis split

**Signature:**
```java
public AvcoState splitOffFraction(BigDecimal basisPct, BigDecimal childSharesPerParent);
```

**Semantics:**
```
child = new AvcoState(this.reportingCurrency, this.fxSnapshot)
child.totalCost   = this.totalCost   × basisPct
child.totalShares = this.totalShares × childSharesPerParent

this.totalCost   *= (1 − basisPct)
// this.totalShares unchanged — parent quantity not reduced by spin-off
```

Returns the fresh child `AvcoState` for the caller to insert into the chain's `statesByMaster` map.

**Pre-existing child position handling:** if the user held C before the spin-off (rare but possible — held both parent and child pre-spin-off, with C being created by a separate earlier event), the caller must `child_existing.mergeFrom(child_from_splitoff, BigDecimal.ONE)` to merge the newly-created basis into the existing state. The `ONE` ratio makes `mergeFrom` a clean add.

### 5.4 Precision guarantees

All three mutators use `BigDecimal.multiply` and `BigDecimal.subtract` directly (no divides except `ratioFactor()` which already uses `MathContext.DECIMAL128`). Running totals never re-compute from scratch, so rounding cannot accumulate across a walk. The broker's raw post-merger qty/price in subsequent transactions IS the authoritative post-event number; the AVCO state only has to faithfully transport basis to meet it — identical discipline to ADR-014's splits rationale.

---

## 6. `PortfolioReplayService` & Caller Migration

### 6.1 `PortfolioReplayService`

File: `core/service/PortfolioReplayService.java`

**Public surface:**
```java
@Service
@RequiredArgsConstructor
public class PortfolioReplayService {

    private final TransactionRepository transactionRepo;
    private final CorporateActionSplitRepository splitRepo;
    private final CorporateActionChainResolver chainResolver;
    private final MarketDataPriceDailyRepository priceRepo;  // for cash-boot auto-compute

    public ReplayResult replay(
            UUID portfolioId,
            String reportingCurrency,
            FxRateSnapshot fxSnapshot);

    public record ReplayResult(
            Map<UUID, BigDecimal> realizedByMaster,
            Map<UUID, BigDecimal> realizedReportingByMaster,
            Map<UUID, BigDecimal> perSellRealizedReporting,
            List<ClosedEpisode> episodes,
            List<Anomaly> anomalies,
            List<CorporateActionLedgerEntry> ephemeralEntries
    ) {}
}
```

**Internal flow:** as described in § 2.4. All cross-master transitions emit ephemeral entries; all realized P/L and episodes go into the `per master` maps; anomalies include the existing ledger anomalies (`SELL_BEFORE_BUY`, `NEGATIVE_QTY`) plus new ones (`SPINOFF_MISSING_BASIS`, `MERGER_MISSING_PRICE`).

### 6.2 Caller migration

Three services migrate; the fourth (`TickerDetailService`) doesn't.

**`HistoryQueryService.compute()`** — today loops per `(portfolio, effectiveMasterId)` key calling `realizedCalc.computeEpisodesAndSellRealized(...)` then `realizedCalc.detectAnomalies(...)`. Post-refactor:
```java
ReplayResult replay = portfolioReplayService.replay(portfolioId, reporting, snapshot);

// Transactions ← existing txns + replay.ephemeralEntries mapped to TransactionHistoryRow with synthetic=true
// Closed positions ← replay.episodes
// Missing transactions ← replay.anomalies (existing + new kinds)
// Per-sell realized ← replay.perSellRealizedReporting
```

**`StockGroupService.computeTotalRealizedGain()`** — today: nested loop over (portfolioId × effectiveMasterId). Post:
```java
BigDecimal total = BigDecimal.ZERO;
for (UUID portfolioId : portfolioIds) {
    ReplayResult r = portfolioReplayService.replay(portfolioId, reporting, snapshot);
    total = total.add(r.realizedReportingByMaster().values().stream()
            .filter(Objects::nonNull).reduce(BigDecimal.ZERO, BigDecimal::add));
}
return total;
```

**`TickerDetailService.toTickerTransactionDtos()`** — unchanged. A ticker detail page is scoped to one master's transactions as they exist in the ledger; showing post-merger basis here would surprise users who came to see "the AT&T position specifically." The chain-level view lives on History.

### 6.3 `TransactionHistoryRow` additions

```java
public record TransactionHistoryRow(
        // ...existing fields
        Boolean synthetic,                  // defaults null → treat as false; true for ephemeral CA entries
        String counterpartyTicker,          // nullable; only on synthetic rows
        UUID sourceEventId                  // nullable; FK-style to merger/spinoff
) { }
```

Frontend key off `synthetic == true` to render the timeline-marker style (lock icon, different background, hover tooltip explaining the transfer).

**`Transaction.TransactionType` enum is NOT extended.** `TransactionHistoryRow.transactionType` is already a freeform `String`; ephemeral rows populate it with the `EntryKind.name()` (e.g. `"MERGER_TRANSFER_OUT"`). Keeping the ledger enum pristine eliminates any risk of a mock row being accidentally persisted to `transactions`.

### 6.4 Parity test harness

Between PRs 2 and 3 (AvcoState mutators land vs. replay service takes over callers), a `ReplayParityTest` runs the legacy per-master walks and the new replay side-by-side on seeded merger-free portfolios, asserting byte-identical `realized`, `episodes`, `anomalies`. Guarantees the refactor doesn't silently regress existing cases. Only drops when Phase B mergers/spin-offs are seeded.

### 6.5 Feature flag

`app.features.global-replay=true` (default `true` in prod after staging verification). When `false`, callers use the legacy per-master path — safe rollback during the first week of production.

---

## 7. Ingest & Admin Endpoints

### 7.1 EODHD coverage

- **Mergers:** EODHD `/api/fundamentals/{SYMBOL}` has a `CorporateActions → Mergers` section with partial coverage. Ingest parses it for `(from_figi, to_figi, ex_date, ratio)`; cash-deal metadata is often missing. `source = "EODHD"` when full fields present, `"EODHD_PARTIAL"` when cash metadata is absent.
- **Spin-offs:** EODHD fundamentals includes spin-off event metadata (parent, child, ex_date, shares_per_parent) but never `basis_allocation_pct`. All spin-offs ingest with `basis_allocation_pct = NULL` and `source = "EODHD_PARTIAL"`. The replay walker refuses to apply null-pct spin-offs and emits `Anomaly{SPINOFF_MISSING_BASIS, parent}` — admin must run the manual endpoint to supply the pct from IRS Form 8937.

### 7.2 Clients

Two new clients in `jobs/service/`:
- `EodhdMergerClient` — fetches the fundamentals endpoint, extracts merger rows.
- `EodhdSpinoffClient` — extracts spin-off rows, pct always null.

Both mirror `EodhdSplitsClient` / `EodhdDividendClient` error-handling: 404 → empty, 429 → `EodhdMergerRateLimitException`, other → `EodhdMergerApiException`. BigDecimal-via-String, no floating point.

### 7.3 Backfill jobs

Two new jobs in `jobs/task/marketdata/`, same three-trigger shape as Phase A:
- `CorporateActionMergerBackfillJob` — JIT on `HistoricalPriceBackfillCompletedEvent`, weekly Sunday 05:00 UTC, admin.
- `CorporateActionSpinoffBackfillJob` — JIT, weekly Sunday 05:30 UTC, admin.

Idempotent upsert pattern identical to splits/dividends: batch-load existing rows, filter in memory, `save()` per row outside an outer `@Transactional`, catch `DataIntegrityViolationException`.

### 7.4 Admin controllers

Two new controllers in `api/controller/`, superuser-gated, verbatim copy of `CorporateActionDividendAdminController`:

```
POST /api/admin/corporate-actions/mergers/backfill-all               → 202
POST /api/admin/corporate-actions/mergers/backfill/{securityMasterId} → 202
POST /api/admin/corporate-actions/mergers/manual                      → 200
Body: { fromMasterId, toMasterId, exDate, ratioNumerator, ratioDenominator,
        cashPerShare?, cashCurrency?, cashBasisPctOverride? }

POST /api/admin/corporate-actions/spinoffs/backfill-all                 → 202
POST /api/admin/corporate-actions/spinoffs/backfill/{securityMasterId}  → 202
POST /api/admin/corporate-actions/spinoffs/manual                       → 200
Body: { parentMasterId, childMasterId, exDate, sharesPerParent, basisAllocationPct }
```

Manual endpoints are idempotent on the respective unique key; concurrent-insert races catch `DataIntegrityViolationException` and return the existing row.

### 7.5 Cache eviction

`PortfolioValuationService.@Cacheable("portfolioValuations")` must evict on any write to `corporate_action_merger` or `corporate_action_spinoff` — same pattern Phase A added for dividend eviction. `HistoryQueryService` reads aren't cached at this layer but depend on the replay service.

---

## 8. Frontend

### 8.1 History page — ephemeral row rendering

`TransactionHistoryRow` with `synthetic == true` renders with:
- A distinct background color (subtle accent — e.g., `--color-timeline-marker`) separating it from ledger rows.
- A small lock icon (from the existing icon set) indicating non-editable.
- `transactionType` label shown as `"Merger — Transfer Out"` / `"Spin-off — Creation"` etc. (friendly-cased from `EntryKind.name()`).
- Hover tooltip: "Cost basis moved from [counterparty ticker] on [exDate] per Phase B replay. Not a broker-booked transaction."
- No action buttons (edit/delete hidden).

### 8.2 Holdings page — merger/spin-off timeline indicator

Out of scope for Phase B. A small "chain" icon next to tickers that have been affected by mergers/spin-offs is a follow-up UI enhancement.

### 8.3 No dashboard changes

Phase B doesn't add new KPIs. Realized gain (which the dashboard already shows post-Phase-A) continues to render correctly — it now sums `replay.realizedReportingByMaster`.

---

## 9. Testing

### 9.1 Unit (core module)

**Entity tests** — `CorporateActionMergerTest`, `CorporateActionSpinoffTest`: PrePersist assigns UUID + createdAt; `CorporateActionMerger.ratioFactor()` uses DECIMAL128 precision; `CorporateActionMerger.hasCashComponent()` respects null/zero cashPerShare.

**`CorporateActionChainResolverTest`:**
- Singleton case: seed a master with no edges → chain size 1, no mergers, no spin-offs.
- Simple merger: `A → B` → seed A → chain `{A, B}`; seed B → same chain.
- Simple spin-off: `P → C` → seed P → chain `{P, C}`; seed C → same chain.
- Multi-step: `A → B` merger then `B → C` spin-off → seed any of A/B/C → chain `{A, B, C}`.
- Disconnected chains: two independent mergers → two chains, no bleed.
- Cycle safety: pathological `A → B → A` (shouldn't exist in real data) → collapses into one chain without infinite loop.

**`AvcoStateTest` (new cases alongside existing split tests):**
- `mergeFrom` — existing B state `(qty=10, cost=400)` + A state `(qty=5, cost=200)` with ratio 2.0 → B becomes `(qty=20, cost=600)`.
- `mergeFrom` with empty B — effectively a wholesale transfer.
- `applyCashBoot` pure math — qty=100, cost=5000, cashPerShare=20, cashBasisPct=0.5 → realized = `100×20 − 5000×0.5 = −500` (loss); state becomes `(qty=100, cost=2500)`.
- `applyCashBoot` with BigDecimal precision edge — 1/3 basis allocation against $10000.
- `splitOffFraction` — parent `(qty=100, cost=5000)`, basisPct=0.25, childSharesPerParent=0.5 → child `(qty=50, cost=1250)`, parent `(qty=100, cost=3750)`.
- `splitOffFraction` qty invariance — parent qty does NOT change; only cost reduces.

**`PortfolioReplayServiceTest` (integration-lite, seeded):**
- **AT&T → WBD 2022 spin-off:** 100 T shares bought pre-spin; `shares_per_parent = 0.241917`, `basis_allocation_pct = 0.2395` (IRS Form 8937). Expected post-spin: T qty=100, T basis=original×0.7605; WBD qty=24.1917, WBD basis=original×0.2395. Subsequent sell of all WBD emits correct realized P/L.
- **Cash-boot merger:** 100 A @ $50 basis; merger: 0.5 shares B + $20 cash; B close on ex_date = $40 → `cash_basis_pct = 0.5` auto-computed. Realized on A = `−500` loss; B receives qty 50, basis $2500.
- **Multi-step chain:** `A → B` merger 2022-01-15, then `B → C` spin-off 2023-06-30 with basis_pct=0.3. Pre-merger BUYs on A, post-merger BUYs on B. Full replay produces correct per-master basis at every stage.
- **`SPINOFF_MISSING_BASIS` anomaly:** spin-off seeded with null pct → replay skips the transfer, emits an anomaly, parent basis untouched.
- **`MERGER_MISSING_PRICE` anomaly:** cash-boot merger seeded with no price data and no override → anomaly emitted, fallback `cashBasisPct = 0`.

### 9.2 Integration (api module, Testcontainers + Postgres — per project rule)

- `HistoryQueryMergerIntegrationTest` — full HTTP path; assert `TransactionHistoryRow` with `synthetic=true` appears on the ex_date with correct `counterpartyTicker` and `sourceEventId`.
- `StockGroupRealizedMergerIntegrationTest` — dashboard total realized equals sum across chain masters.
- `SymbolChangeNoOpIntegrationTest` — seed a `canonicalMasterId` alias between two masters with no merger/spin-off edge; assert replay does NOT emit any ephemeral row. Confirms the explicit Phase B non-goal.
- `CorporateActionMergerAdminControllerIT` — 403 for non-superuser, 202 for async, 200 idempotent manual insert.
- `CorporateActionSpinoffAdminControllerIT` — ditto; 200 with null basis_pct accepted and flagged in subsequent replay.

### 9.3 Parity testing

`ReplayParityTest` runs between PR 2 and PR 3: seeds a merger-free portfolio, runs legacy per-master walks, runs new `PortfolioReplayService.replay`, asserts equality on realized, episodes, and anomaly lists. Merger-free portfolios must produce identical output.

### 9.4 Frontend (Karma)

- `history-row.component.spec.ts`: synthetic row renders with lock icon and muted style.
- `history.component.spec.ts`: a response containing one synthetic row after a real BUY renders both in chronological order.
- Skip the broken-tests list per CLAUDE.md.

---

## 10. Rollout Sequence

Six PRs, each standalone-deployable, merged in strict order:

1. **Migrations + entities + repositories** (zero risk). Deploys to prod; tables exist, no reads yet.
2. **`AvcoState` mutators + `CorporateActionChainResolver` + `ReplayEvent` + `CorporateActionLedgerEntry`** (library code). Unit-tested only; no callers wired.
3. **`PortfolioReplayService` introduction + caller migration** (largest PR). Guarded by `app.features.global-replay=true`. `ReplayParityTest` runs green against merger-free portfolios.
4. **Ephemeral ledger entries in History page** — backend emission + frontend styling.
5. **Merger + spin-off EODHD clients, backfill jobs, admin endpoints.**
6. **ADR-018 + SYSTEM_SNAPSHOT update.** Documents the final architecture.

PR 3 is the moment Phase B starts being structurally different from Phase A; PRs 1–2 are pure infrastructure with no behavioral change.

---

## 11. Risks & Known Edge Cases

- **Cash-boot US-tax assumption.** The proportional-boot auto-formula follows IRC §356 treatment. Users in other jurisdictions may need manual `cashBasisPctOverride` for accurate local tax reporting. Phase B scope records this as a US-default; international tax support is future work.
- **EODHD merger feed quality is unknown in production.** Phase B may need a human spot-check workflow per merger. Admin endpoint for "list pending-EODHD-mergers-awaiting-review" is a follow-up.
- **Spin-off basis_allocation_pct discipline.** Users whose portfolio crosses a spin-off we haven't manually seeded will see an anomaly on History rather than a silent basis drop. Admin workflow: monitor anomalies, cross-check Form 8937, POST to `/spinoffs/manual`.
- **FX across a chain.** A merger from GBP-denominated A to USD-denominated B requires FX for both currencies into the reporting currency. `FxRateSnapshotBuilder` will need a `buildForMasters(Collection<ChainMaster>, reportingCurrency)` sibling that collects transaction currencies across the chain. Scoped to PR 3.
- **Pre-existing position in merger target.** If a user already held B before the A → B merger (index-fund case), B's pre-merger state is preserved and A's merged-in state weighted-adds via `mergeFrom`. Tested in `PortfolioReplayServiceTest.mergerWithPreExistingTargetPosition`.
- **Cache invalidation.** `PortfolioValuationService.@Cacheable("portfolioValuations")` must evict on writes to both new tables. Tracked in PR 5.
- **Performance on very-large chains.** A master with dozens of spin-offs over decades (conglomerate breakups) forms a large chain. Replay is `O(txns + events)`; for 10,000 txns + 100 events this is milliseconds. No concern for realistic portfolios.

---

## Appendix A — Reference files

| Role | Path |
|---|---|
| Splits ADR (template for ADR-018) | `docs/adr/014-read-time-stock-splits.md` |
| Dividends ADR (read-model separation) | `docs/adr/017-cash-dividend-read-model.md` |
| Splits migration template | `portfolio-optimizer-backend/api/src/main/resources/db/migration/V20260419120000__CreateCorporateActionSplitTable.sql` |
| Dividends migration template | `portfolio-optimizer-backend/api/src/main/resources/db/migration/V20260421120000__CreateCorporateActionCashDividendTable.sql` |
| `RealizedGainCalculator` — extend | `portfolio-optimizer-backend/core/src/main/java/com/portfolio/tracker/core/service/RealizedGainCalculator.java` |
| `HistoryQueryService` — migrate | `portfolio-optimizer-backend/core/src/main/java/com/portfolio/tracker/core/service/HistoryQueryService.java` |
| `StockGroupService` — migrate | `portfolio-optimizer-backend/api/src/main/java/com/portfolio/tracker/api/service/StockGroupService.java` |
| `TransactionRepository.findAllForReplay` | `portfolio-optimizer-backend/core/src/main/java/com/portfolio/tracker/core/repository/TransactionRepository.java` |
| Splits client (Phase B mirror) | `portfolio-optimizer-backend/jobs/src/main/java/com/portfolio/tracker/jobs/service/EodhdSplitsClient.java` |
| Dividend admin controller (Phase B mirror) | `portfolio-optimizer-backend/api/src/main/java/com/portfolio/tracker/api/controller/CorporateActionDividendAdminController.java` |
| `AsyncConfig.backgroundJobExecutor` | `portfolio-optimizer-backend/jobs/src/main/java/com/portfolio/tracker/jobs/config/AsyncConfig.java` |
| `HistoricalPriceBackfillCompletedEvent` | `portfolio-optimizer-backend/jobs/src/main/java/com/portfolio/tracker/jobs/event/HistoricalPriceBackfillCompletedEvent.java` |
| `TransactionHistoryRow` — extend | `portfolio-optimizer-backend/core/src/main/java/com/portfolio/tracker/core/dto/history/TransactionHistoryRow.java` |
| `ClosedPositionRow` — extend with `episodeKind` | `portfolio-optimizer-backend/core/src/main/java/com/portfolio/tracker/core/dto/history/ClosedPositionRow.java` |
| SYSTEM_SNAPSHOT | `docs/adr/SYSTEM_SNAPSHOT.md` |
