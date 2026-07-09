# ADR-046: Portfolio Last-Synced Read Path — Connection Wall-Clock, Not the Sync Cursor

**Status:** Accepted
**Date:** 2026-05-30
**Extends:** ADR-002 (SnapTrade ledger ingestion — `last_synced_at` semantics), ADR-028 (per-portfolio sync status)

---

## Context

The Holdings Overview header gained a "Sync Portfolio" control that surfaces, per selected portfolio, when it was last synced. `GET /api/portfolios` (`PortfolioController.getUserPortfolios`) carried no sync timestamp — `PortfolioDto` had no such field — so a fresh page load could only render "Not synced yet" until the user triggered a manual sync in-session.

Two columns named `last_synced_at` exist with different meanings, and the obvious one is the wrong one to surface:

- **`portfolios.last_synced_at`** — the incremental recent-sync **cursor**, written by `BrokerSyncService` as `toDate.plusDays(1).atStartOfDay(UTC)` (the day *after* the synced window). It is routinely future-dated relative to wall-clock and is `null` for portfolios never advanced down that path. Rendered as "last synced," it reads as "synced tomorrow."
- **`snaptrade_connection.last_synced_at`** — the real wall-clock sync time, set to `OffsetDateTime.now()` by `SnapTradeService` on every successful sync. This is already the value the manual-sync *response* returns to the client.

## Decision

`GET /api/portfolios` exposes `PortfolioDto.lastSyncedAt` (`OffsetDateTime`, response-only) sourced from **`snaptrade_connection.last_synced_at`**, never from `portfolios.last_synced_at`. The portfolio-table column stays an internal sync cursor with no client read path.

`SnaptradeConnectionRepository.findLastSyncedAtByUserId(userId)` returns `MAX(sc.lastSyncedAt)` **grouped by `sc.portfolio.id`** — exactly one row per portfolio. The `MAX/GROUP BY` is load-bearing, not cosmetic: there is **no unique constraint on `snaptrade_connection.portfolio_id`** (the unique indexes are `id`, `(user_id, authorization_id)`, and a partial `user_id`), so a portfolio with reconnect history can carry multiple connection rows. A plain `SELECT portfolio_id, last_synced_at` would then emit duplicate keys and throw `IllegalStateException` from `Collectors.toMap` in the controller — 500-ing the entire portfolio list and failing the whole Holdings page load. Collapsing to the latest per portfolio is both crash-proof and the correct "last synced" value.

Non-linked (manual/CSV) portfolios have no connection row and resolve to `null` → the UI renders "Not synced yet" and disables the sync button (only broker-linked portfolios sync).

## Consequences

- Load-time and post-sync "last synced" now share one source (connection wall-clock) and stay consistent; the prior in-session-only-timestamp gap is closed.
- The footgun is on record: any future code wanting a portfolio's sync time must read the connection, not `portfolios.last_synced_at`. If a unique constraint on `snaptrade_connection.portfolio_id` is ever added, the `MAX/GROUP BY` may relax to a plain projection — until then it must stay.
- Frontend consumer (UI-only, no contract beyond the new field): `SyncControlComponent` is projected into `PageHeadingComponent` via a new `<ng-content>` slot; with multiple portfolios selected it shows the **oldest** selected time as the headline (the selection is only as fresh as its stalest member) plus a per-portfolio hover breakdown. `syncAllPortfolios()` filters to `isLinked` targets.
- No schema change, no migration, no new event.

## Key Files

| File | Role |
|------|------|
| `api/.../dto/PortfolioDto.java` | `lastSyncedAt` (`OffsetDateTime`, READ_ONLY) |
| `api/.../controller/PortfolioController.java` | `getUserPortfolios` builds the `portfolioId → lastSyncedAt` map |
| `core/.../repository/SnaptradeConnectionRepository.java` | `findLastSyncedAtByUserId` — `MAX(last_synced_at)` GROUP BY `portfolio_id` |
| `frontend/.../portfolio/sync-control/sync-control.component.ts` | Presentational control; oldest headline + per-portfolio breakdown |
