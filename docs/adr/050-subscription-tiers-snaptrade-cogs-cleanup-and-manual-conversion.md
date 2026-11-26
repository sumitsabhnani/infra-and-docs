# ADR-050: Subscription Tiers, `SnaptradeUser` COGS Cleanup & Zero-Data-Loss Linked-to-Manual Portfolio Conversion

**Status:** Accepted
**Date:** 2026-11-16
**Extends:** [ADR-002](002-snaptrade-ledger-ingestion.md) (SnapTrade ledger ingestion), [ADR-021](021-strict-csv-deduplication-partial-fills.md) (strict CSV deduplication & naive-UTC timestamp parsing), [ADR-046](046-portfolio-last-synced-read-path.md) (`snaptrade_connection.last_synced_at` wall-clock authority)

---

## Context

Ahead of public user acquisition, live SnapTrade broker connectivity introduces recurring per-user USD cost of goods sold (COGS) and two domain integrity hazards when users leave live sync:

1. **Per-`SnaptradeUser` monthly billing:** SnapTrade bills monthly per registered `SnaptradeUser` rather than per brokerage connection. Registering a `SnaptradeUser` on `POST /api/brokers/snaptrade/connect/start` for ineligible users, leaving abandoned OAuth popups registered, or deleting a user's last `SnaptradeConnection` without calling `deleteSnapTradeUser` leaks monthly USD COGS indefinitely.
2. **Data-loss trap on disconnect/expiry:** Deleting a linked portfolio destroys the user's ledger history, whereas leaving `SnaptradeConnection` rows attached after a 90-day trial expires continues polling and billing.
3. **Cross-pipeline duplicate hazard (`BROKER_SYNCED` vs `CSV_IMPORT`):** Existing SnapTrade transactions carry provider `externalId`s, while subsequent CSV uploads into a converted portfolio compute `csv:v2:` / `csv:cf:v1:` SHA-256 hashes (ADR-021). Without a conversion cutoff, uploading a full-history broker CSV into a converted portfolio duplicates every previously synced trade and cash flow. Furthermore, `portfolios.last_synced_at` is an internal cursor that is `NULL` on SnapTrade portfolios (ADR-046), and CSV import attaches `UTC` verbatim to naive local timestamps (e.g., Zerodha IST `"2026-06-15T15:15:00"` $\to$ `15:15:00Z` even when the trade executed at `09:45:00Z` before an `11:00:00Z` sync).

---

## Decisions

### Decision 1: O(1) Subscription Tier State on `users` & Pre-Registration Gate

- `users` stores `subscription_tier` (`FREE | EARLY_ACCESS_TRIAL | PRO`, `CHECK`-constrained, default `EARLY_ACCESS_TRIAL`), `trial_started_at`, and `trial_ends_at` (initialized to `now() + 90 days` on signup and migration). `User.effectiveTier(now)` resolves expired `EARLY_ACCESS_TRIAL` rows to `FREE` at read time even before the nightly batch job runs.
- **Tier & anti-abuse enforcement:**
  - `FREE` and expired-trial users allow unlimited Manual & CSV portfolios (`0` live broker connections).
  - Active `EARLY_ACCESS_TRIAL` and `PRO` users have **unlimited live broker connections** in product UX (matching SnapTrade's per-user billing), bounded server-side only by a configurable anti-abuse ceiling `snaptrade.max-connections-per-user = 20` (`SnapTradeProperties`).
  - `SnapTradeService.start(...)` enforces `SubscriptionTierLimitException` (`403 FORBIDDEN` with `{ code, message, tier }`) **before** `createSnaptradeUser` runs so ineligible users never register a billable `SnaptradeUser`. The check re-runs under `UserRepository.findByIdForUpdate` (`PESSIMISTIC_WRITE`) inside `persistPendingConnection`, `prepareComplete`, and `prepareRetry`. Pre-OAuth placeholder rows (`brokerage = 'PENDING'` with null `authorizationId` and `connectionId`) are excluded from `countClaimedConnectionsByUserId`.

### Decision 2: `SnaptradeUser` Billing Teardown & Orphan Reaper Retry

- Whenever a user drops to `0` remaining `snaptrade_connection` rows (via `convertToManual`, trial-expiry downgrade, portfolio deletion, or connection deletion), `SnapTradeService.disconnectConnection` invokes `SnapTradeClient.deleteSnapTradeUser(snaptradeUserId)` **outside** `@Transactional` (`§4.4`).
- `deleteSnapTradeUser` returns `true` on HTTP 2xx or `404` (idempotent), after which the local `snaptrade_user` row is deleted under the per-user lock if `existsByUserId` is still `false`. On upstream 5xx or transport failure, `deleteSnapTradeUser` logs the stack at `WARN` and returns `false` without failing the user flow, retaining the local `snaptrade_user` row so `AbandonedConnectionReaperJob` (`02:00 UTC` daily, via `SnapTradeLifecycleRunner.cleanupOrphanedSnaptradeUsers`) retries deregistration alongside abandoned-popup users (`snaptrade_user` older than 24h with `NOT EXISTS` connection).

### Decision 3: Zero-Data-Loss Linked-to-Manual Conversion & UTC `LocalDate` CSV Cutoff

- Triggered either manually (`POST /api/portfolios/{portfolioId}/convert-to-manual`, ownership-gated via `findByIdAndUserId`) or automatically for expired trials by `TrialExpiryDowngradeJob` (`02:15 UTC` daily — 15 minutes before `BrokerSyncScheduler` at `02:30 UTC` — routed through `SnapTradeLifecycleRunner` in `core` so `jobs` never imports `api`).
- **Conversion sequence (`PortfolioService.convertToManual`):**
  1. Resolve cutoff from `MAX(snaptrade_connection.last_synced_at)` (ADR-046), falling back to `MAX(AccountSyncState.lastSyncedAt)`, then `MAX(transactions.transaction_date)` where `source = 'BROKER_SYNCED'` (or `NULL` if zero broker data ever synced).
  2. Disconnect all portfolio `SnaptradeConnection`s (revoking authorizations and deregistering `SnaptradeUser` if last).
  3. Preserve `Portfolio`, `Transaction`, `CashFlow` (`raw_payload_ref` auto-nulls via `ON DELETE SET NULL`), and derived `Holding` rows intact; set `broker = 99`, strip `snaptradeConnectionId` / `connectionId` / `accountIds` / `accounts` from `broker_metadata`, stamp `portfolios.converted_from_broker_sync_at` (`maxTimestamp(existing, cutoff)`), and stamp `holdings.broker_snapshot_quantity = quantity` on every `Holding` row in the portfolio (backfilled on migration `V20261123203000` on a best-effort basis from current quantities).
- **Cutoff-anchored holdings projection (`HoldingService`):** On converted portfolios (`convertedFromBrokerSyncAt != null` and no active `SnaptradeConnection`), broker-anchored masters project `projectedQty = brokerSnapshotQuantity * postCutoffSplits + (replayAll - replayPreCutoff)` at the same UTC `LocalDate` cutoff. Backdated manual `BUY` fixes (`<= cutoff`) close the unledgered gap (`snapshotToday - replayPreCutoff`) without double-counting shares, pre-cutoff oversold ledgers (`replayAll < 0`) never delete positive broker holdings, and post-cutoff trades (`> cutoff`) adjust `projectedQty` normally.
- **CSV sync-window enforcement (`CsvImportService`):** When `portfolio.convertedFromBrokerSyncAt != null`, both `preview()` (`buildPreviewResponse`) and `commit()` bound the SnapTrade-synced skip interval to **`[earliestBrokerSyncedDate, cutoffDate]`** at **UTC `LocalDate` granularity** across all CSV modes (`TRANSACTIONS`, `AI_FLEXIBLE`, deterministic `CsvRowInterpreter`s, and `CASH_FLOW` rows), where `earliestBrokerSyncedDate` is derived from `MIN(transactions.transaction_date)` (`source = 'BROKER_SYNCED'`, scoped separately for non-dividend trades vs. `DIVIDEND`s, and `MIN(cash_flows.occurred_at)` excluding `csv:cf:%` for cash flows). Pre-SnapTrade historical CSV rows (`rowDate < earliestBrokerSyncedDate`) and post-conversion rows (`rowDate > cutoffDate`) import normally (deduped via `csv:v2:` / `csv:cf:v1:`), while rows inside `[earliestBrokerSyncedDate, cutoffDate]` surface as `RowStatus.DUPLICATE` in preview and are skipped on commit. When zero `BROKER_SYNCED` rows exist (positions-only broker), no pre-cutoff CSV rows are blocked.

---

## Consequences

- **Bounded COGS:** `FREE` and expired-trial users incur zero SnapTrade monthly charges; abandoned OAuth popups and transient 5xx user-deletions self-heal within 24 hours.
- **Zero lock-in:** Users downgrading or leaving a broker connection retain 100% of historical trades, dividends, cash flows, and AVCO cost basis, and can seamlessly continue via CSV imports from the day after their last broker sync.
- **Same-day boundary trade-off:** Comparing UTC `LocalDate` eliminates intra-day duplicate trades caused by naive local CSV timestamps (ADR-021); if a user executes a new trade *later on the exact conversion day* after converting, that single post-disconnect same-day trade must be entered manually or dated after cutoff.

---

## Alternatives Considered

- **Cap `EARLY_ACCESS_TRIAL` / `PRO` at 3 connections:** Rejected — SnapTrade bills per `SnaptradeUser`, not per connection, so capping paying/trial users at 3 brokers degrades multi-broker UX without saving COGS; a server-side `max-connections-per-user = 20` ceiling suffices against script abuse.
- **Separate `user_subscriptions` table on Day 1:** Rejected — adds join overhead on auth/connect paths before payment-gateway webhook history exists in Phase 2.
- **Compare raw `OffsetDateTime` instants for CSV cutoff:** Rejected — date-only CSVs parse to `00:00Z` and naive IST afternoon timestamps parse to `>10:00Z` UTC, causing false duplicates for same-day pre-conversion trades.
