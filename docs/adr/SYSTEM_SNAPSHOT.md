# SYSTEM SNAPSHOT

High-density context for AI coding agents. Reflects the active state of the system. For deeper rationale, see the numbered ADRs in this directory.

---

## 1. Product Vision & Domain

An **institutional-grade personal portfolio management and wealth analytics platform**. It competes with high-end tools like Bloomberg Terminal and InvestingPro — **not** consumer apps (Robinhood, Mint). Priorities, in order:

1. **Accuracy** — every number the UI shows must be mathematically defensible.
2. **Rigorous financial math** — `BigDecimal` everywhere, historical FX preserved, AVCO as the single realized-gain algorithm, immutable transaction ledger as truth.
3. **Premium data density** — multi-currency, multi-broker, cross-exchange aggregation surfaced without horizontal bloat.

Users are sophisticated investors tracking global portfolios across brokers, currencies, and asset classes. "Correctness > Convenience" is non-negotiable.

---

## 2. Core Business Entities

- **User** — owner of everything; reporting currency is a user-level preference.
- **Portfolio** — a broker account (SnapTrade-synced) or a manual container; has dynamic transaction-backed holdings.
- **SnapTradeConnection / SnapTradeUser** — broker linkage; state = (`status`, `sync_phase`); async event-driven sync with polling.
- **Transaction** — immutable ledger row; carries `raw_data` JSONB audit trail, `broker_fx_rate`, USD-normalized fields, and cached `normalized_reporting_*` projections. `TransactionType` = `BUY | SELL | DIVIDEND | TRANSFER`.
- **Holding** — current position; references `security_master_id` (canonical), `acquired_listing_id`, nullable `override_market_data_symbol_id`, and `broker_raw_ticker` (never overwritten).
- **SecurityMaster / SecurityListing / MarketDataSymbol** — three-layer identity: *what it is* → *where it trades* → *how it's priced*. `canonical_master_id` self-FK handles deduplication.
- **ManualAsset** — user-level static assets (cash, gold, real estate). **Owned by User, never by Portfolio.** Supports `monthly_increment` via a scheduled physical-apply job.
- **UserAssetExposures** — pre-computed per-user per-asset-class read model for the allocation widget.
- **UserAssetClassTargets** — policy-level allocation rules (target %, max drift %).
- **MarketDataPriceDaily / LatestMarketPrice / FxRate** — historical OHLCV (EODHD/Bhavkosh), current prices (Yahoo via sidecar), historical FX (EODHD).
- **CorporateActionSplit** — keyed by canonical `security_master_id`; read-time multiplier (`factor = ratioNumerator / ratioDenominator`) applied in `RealizedGainCalculator.AvcoState.applySplit` during the AVCO walk. Covers stock splits (20:1, 1:10 reverse) and stock dividends (21:20) identically. Ingested by `CorporateActionSplitBackfillJob` via JIT event, weekly sweep, and superuser admin endpoints (ADR-014).
- **CorporateActionCashDividend** — declared cash-dividend events (EODHD `/api/div/{SYMBOL}`), keyed by canonical `security_master_id`, `(security_master_id, ex_date)` unique. **Reconciliation-only, never read by analytics.** All user-visible dividend totals (`HoldingDto.totalDividends*`, dashboard per-portfolio `totalDividendIncome{Lifetime,Ytd}`) derive exclusively from `transactions` rows of type `DIVIDEND` via `DividendAnalyticsService`, summing `normalized_reporting_amount` at historical FX. The events table feeds `DividendAnomalyService` only — an admin-gated `/anomalies` endpoint with a `minExpectedTotal` triage filter — to flag broker-feed gaps against company declarations. Ingested via JIT event, Sunday 04:30 UTC sweep, and superuser admin endpoints (ADR-017).
- **CorporateActionMerger / CorporateActionSpinoff** — declared cross-master events that drive basis transfer between `security_master_id`s at an exact ex_date UTC. Merger: `(from_master_id, to_master_id, ex_date, ratio_numerator/denominator, cash_per_share?, cash_basis_pct_override?)`, unique on `(from_master_id, ex_date)`. Spin-off: `(parent_master_id, child_master_id, ex_date, shares_per_parent, basis_allocation_pct)` — pct is **nullable** because EODHD never supplies it; authoritative source is IRS Form 8937 entered via the superuser admin endpoint. Consumed exclusively by `PortfolioReplayService` at read time via the new `AvcoState.mergeFrom / applyCashBoot / splitOffFraction` mutators; emit ephemeral `CorporateActionLedgerEntry` rows that surface on the History page as `synthetic=true` audit rows (never persisted). Ingested via JIT event, Sunday 05:00/05:30 UTC sweeps, and superuser admin endpoints (ADR-018).
- **Queues** — `figi_resolution_queue`, `ticker_resolution_queue`, `global_ticker_mapping` (crowdsourced cache).
- **Copilot Chat Sessions** — LLM-assisted analysis surface (currency-normalized inputs required).

---

## 3. Core Tech Stack & Versions

- **Frontend:** Angular 17 (standalone, Signals, OnPush, `@if`/`@for`), TypeScript 5.2, SCSS, Apache ECharts via `ngx-echarts@17.2.0`.
- **Backend:** Java 21 + Spring Boot 3.3, Gradle multi-module (`core` / `api` / `jobs`), JJWT 0.12.3, OAuth 2.0 (Google/GitHub/Apple).
- **Database:** PostgreSQL 15 + Flyway 11 (Hibernate `validate` mode).
- **Cache:** Redis 7 (Jackson JSON with `@class` metadata — prevents `BigDecimal`→`Double` coercion).
- **Sidecar:** Python 3.12 FastAPI `price-sweeper` (yahooquery, APScheduler).
- **Infra:** Docker Compose on Hetzner VPS, Caddy 2 reverse proxy (single domain, no CORS).

---

## 4. Strict Architectural Principles

- **Accounting Tie-Out Principle** — every row must sum to the summary header. Holdings rows and group summaries compute through the same `ValuationEngineService`; realized gain flows through a single `AvcoState` state-machine (`RealizedGainCalculator`).
- **History / Ledger View — Server-Authoritative, URL-Driven** — `/api/history/{summary,transactions,closed-positions,missing-transactions}` (ADR-013) replays the ledger once per request through the same `AvcoState` to emit raw txns, closed-episode rows (qty transition `>0 → 0`, with `episodeIndex` for re-opens), and ledger-only anomaly rows (`SELL_BEFORE_BUY`, `NEGATIVE_QTY`). Filter/tab/page state lives in URL query params; broker-sync gap detection deferred until persistent broker-position snapshots exist.
- **Unified Valuation Engine** — all reporting-currency cost basis, gain/loss, and FX impact math lives in one place. Any new aggregator calls in; never re-implements.
- **Immutable Ledger, Cached Projection** — `transactions` is truth and is never rewritten. Corporate actions (stock splits, stock dividends) live in `corporate_action_split` and are applied **at read time** inside `AvcoState` during the ledger replay — never back-adjusted into transaction rows (ADR-014). `normalized_reporting_*` columns are a rebuildable cache. Changing reporting currency or correcting a split invalidates the cache, never the ledger.
- **Master Deduplication via Read-Time Canonicalization** — never modify transaction or holding rows to fix duplicate `security_master` entries. Set `security_master.canonical_master_id` on the loser; every aggregator resolves via `SecurityMaster.getEffectiveId()` / `COALESCE(canonical_master_id, id)` at read time. Ingestion dedup is best-effort (never throws), and the superuser `POST /api/admin/securities/link` endpoint is the manual counterpart to the async FIGI canonicalizer (ADR-019).
- **Connected-Component Valuation Engine** — `PortfolioReplayService` walks each portfolio as a set of `ReplayChain`s (connected components of masters under merger + spin-off edges). Cross-master basis transfer fires at an exact ex_date UTC timestamp via `AvcoState.mergeFrom / applyCashBoot / splitOffFraction`; audit surfaces as ephemeral `CorporateActionLedgerEntry` rows on the History page (`synthetic=true`). The `transactions` table stays strictly append-only — no merger/spin-off row is ever written to it, and the `Transaction.TransactionType` enum is not extended. Trivial chains (no CA edges) delegate byte-identically to the legacy per-master walk. Currently gated by `app.features.global-replay` (default `false`) until parity is burned in; `ReplayParityTest` asserts bit-identical output across the flag on merger-free portfolios (ADR-018).
- **Session-Scoped View Toggles, Not Profile Writes** — global UI context modifiers (notably the reporting-currency dropdown) live in session-only Angular Signals (`NavbarStateService`), seeded from the user profile at authentication and reset on logout. They MUST NOT call `PUT /api/users` or write to `localStorage` — profile-level currency changes publish `ReportingCurrencyChangedEvent` and force a full `normalized_reporting_*` rebuild across the user's ledger, which is correct for a Settings action and catastrophic for a header toggle. Backend endpoints respect the signal via an optional `?reportingCurrency=XXX` param with a profile fallback (ADR-016).
- **Holdings Are Strictly Derived** — the `holdings` table is a rebuildable projection of the `transactions` ledger. No import pipeline may write to it directly. Holdings-snapshot upload is not supported; all imports produce real transaction types (`BUY`, `SELL`, `DIVIDEND`, `TRANSFER`), and `updateHoldingsForPortfolio` derives the holding from those. Violating this breaks AVCO cost-basis for all subsequent trades (ADR-020).
- **AI-Assisted Mapper Pattern** — LLM involvement in CSV import is limited to schema inference: header + 5 sample rows in, `MappingProposal` JSON out. Java parses the full file deterministically via Apache Commons CSV using the user-confirmed mapping. The LLM never touches numeric values, dates, or the commit path. Every non-null column name in the proposal is validated against the real header server-side before use (injection defence). One LLM call per import regardless of file size (ADR-020).
- **Never Drop Data** — SnapTrade ingestion persists first (raw JSONB + `broker_raw_ticker`) and resolves asynchronously. Holdings are usable before pricing resolves.
- **Money = `BigDecimal`, Time = `Instant`/`OffsetDateTime` (UTC)** — never `double`/`float`/`Date`/`LocalDateTime`.
- **FX Fallback Hierarchy (in order):** broker FX → local historical FX (`fx_rate` table) → live FX snapshot. Missing rate degrades gracefully, never breaks the UI.
- **All-or-Nothing USD Normalization** — the USD-normalized cost basis path activates only when BUY transaction quantity ≥ held quantity. Otherwise fall back to live FX. No blending.
- **No Sync External Calls on Hot Path** — EODHD/OpenFIGI/Yahoo only in scheduled jobs, admin endpoints, or sidecars. Reads serve from DB/Redis.
- **Chunked Async Backfills** — event-driven (`@TransactionalEventListener(AFTER_COMMIT) @Async`), batched (100 rows), DB-only inside the loop.
- **Postgres-as-Queue** — `SELECT FOR UPDATE SKIP LOCKED` for FIGI/ticker resolution pollers; no Kafka/RabbitMQ.
- **Module Boundaries Enforced** — `core` = domain only; `api` = HTTP/security; `jobs` = headless scheduled work. `jobs` never imports `api`.
- **LLM Ingestion** — normalize currencies (to reporting currency) before any LLM input.
- **Aggregation Key is Always `security_master_id`** — never listing or symbol; cross-exchange holdings must consolidate.

---

## 5. UI/UX Identity & Styling

- **Full-bleed workspace canvases** — dashboards/holdings use the full viewport width; no framing gutters.
- **Dark, static top-bar** — always-on market indices (S&P, Dow, Nasdaq, NIFTY, ACWI) with currency label; Redis-warmed O(1). Silent 3-minute client poll of `/api/markets/indices/live` (ADR-015); value changes trigger a 500 ms muted-green/red background flash on the changed cell — layout stays frozen via `tabular-nums` + cancelling padding/margin.
- **Tabular-nums for all financial data** — monetary/percentage values use `font-variant-numeric: tabular-nums` and are **right-aligned**.
- **Strict contrast floors** — primary text never lighter than `text-gray-500`; secondary-line reporting-currency rows use smaller, muted weight but stay readable.
- **Stacked multi-currency cells** — native-currency value as primary line, reporting-currency beneath (smaller/lighter). Secondary line hidden when `holding.currency === reportingCurrency` (zero-noise rule).
- **Progressive FX disclosure** — ⓘ icon in Gain/Loss cell, tooltip shows asset return vs. FX impact. Inline cost is zero.
- **Gain/Loss column is reporting-currency only** — enforces tie-out with summary header.
- **Modern Angular control flow only** — `@if`/`@for`/`@switch`; OnPush everywhere; Signals for state, `async` pipe in templates.
- **ECharts for data viz** — declarative `EChartsOption` via Signal; pad-angle donuts, border-radius, emphasis animations. No Chart.js.
- **BEM-inspired SCSS** with design tokens; no repeated raw hex. Use the frontend-design plugin for premium design work (DESIGN.md is deprecated).
- **Hybrid zero-states** — search surfaces preserve the affordance *and* inject actionable live data (e.g., Portfolio Movers) instead of empty icons.

---

## 6. Security & Boundary Constraints

- **Never log PII** — user emails, broker credentials, raw transaction payloads stay out of logs.
- **Sensitive fields AES-256 encrypted** via `SecretEncryptionService` (SnapTrade OAuth creds, API tokens).
- **JWT bearer on every request** — frontend `AuthInterceptor` injects; `authGuard` protects routes.
- **Single-origin deployment** — Caddy path-routes `/api/*` → backend, `/*` → frontend. No CORS; no third-party cookie domains.
- **Container network isolation** — only Caddy exposes 80/443. Postgres/Redis/price-sweeper/backend are reachable only on `app-network`.
- **`price-sweeper /force-fetch` is internal-only** — never route through Caddy.
- **Never share Postgres credentials beyond the compose network** — the sidecar reads the same DB; schema changes require coordinated review.
- **SnapTrade lookups use slugs**, not user-visible identifiers; account IDs stored as JSONB on the connection, not leaked to the client.
- **No client-side financial aggregation** — totals, realized gain, FX conversion, and tie-out math are always server-computed. The frontend renders server-authoritative DTOs.
- **Admin endpoints (FX backfill, reporting-currency rebuild) are superuser-gated** and bounded (e.g., 365-day max per historical-FX call).
- **Flyway owns schema** — Hibernate runs in `validate`; no runtime DDL. Migrations are idempotent (`IF NOT EXISTS`, `ON CONFLICT`) and backward-compatible.
- **No secrets in repo or chat** — credentials come from environment variables (Pydantic Settings on Python, Spring config on Java).
