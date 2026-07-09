# ADR-043: Spin-off BhavKosh Auto-Backfill Restored, Async Paths Use Flat Projections Only

**Status:** Accepted
**Date:** 2026-05-17
**Supersedes:** ADR-027 §Decision 5 (Spin-off Is Manual-Entry Only)
**Related:** ADR-018 (IRS Form 8937 basis contract), ADR-024 (cross-master corporate actions), ADR-028 (EODHD JIT backfill discipline)

---

## Context

ADR-027 §Decision 5 deleted `CorporateActionSpinoffBackfillJob` in favour of manual-entry-only via `CorporateActionSpinoffService.recordManualSpinoff`. That decision was reversed in code after ADR-027 shipped — the job was reintroduced with the BhavKosh-driven design originally described in ADR-024 §Decision 3 (JIT listener on `HistoricalPriceBackfillCompletedEvent`, weekly Sunday 05:30 UTC sweep, plus the manual admin path). The reintroduction was never documented; SYSTEM_SNAPSHOT.md and ADR-027 carried the stale "manual entry only" claim.

In production the auto-backfill was non-functional. Both the sweep and the JIT dereferenced lazy associations (`SecurityListing.exchange`, `SecurityListing.security`, both `FetchType.LAZY`) on the `@Async("backgroundJobExecutor")` thread, which has no Hibernate session. Staging logs on 2026-05-17 05:30 UTC showed ~17 `LazyInitializationException` stacktraces per sweep — one per active Indian master — so `corporate_action_spinoff` was never populated by the job in any environment despite the cron running weekly.

The pattern that the sibling jobs already use (`CorporateActionSplitBackfillJob`, `CorporateActionDividendBackfillJob`) avoids the issue by iterating flat-projection views of `market_data_symbol`: `findActiveBhavKoshSymbolsWithMaster()` for the sweep and `findBhavKoshSymbolWithMasterById(...)` for the JIT — both returning `(providerSymbol, effectiveMasterId, exchangeCode)` as scalars with no JPA proxies. Spinoff was the only outlier.

---

## Decision

1. **`CorporateActionSpinoffBackfillJob` is canonical.** Lives at `jobs/src/main/java/com/portfolio/tracker/jobs/task/marketdata/CorporateActionSpinoffBackfillJob.java`, gated by `app.jobs.corporate-actions-spinoffs.enabled` (effective default `true` per `application.properties`). ADR-027 §Decision 5's deletion claim is superseded. `CorporateActionSpinoffService` continues to own the admin-facing `recordManualSpinoff` / `deleteSpinoff` surface invoked by `CorporateActionSpinoffAdminController` — the two beans coexist by design.

2. **Async paths iterate flat projections, never JPA entities.** The spinoff sweep, JIT, and counterparty resolution all consume scalar projections:
   - Sweep → `MarketDataSymbolRepository.findActiveBhavKoshSymbolsWithMaster()` (returns `ActiveBhavKoshSymbolWithMasterView`).
   - JIT → `MarketDataSymbolRepository.findBhavKoshSymbolWithMasterById(symbolId)`.
   - Counterparty (DEMERGER `toSymbol` → `masterId`) → `SecurityListingRepository.findIndianListingsByTickerWithMaster(ticker)` (new, returns `IndianTickerMasterView` with `effectiveMasterId` + `exchangeCode`, scoped to `WHERE e.exchange_code IN ('NSE', 'BSE')`).
   No path calls `findFirstBySecurityAndIsPrimaryTrue`, `findAllByTickerIgnoreCase`, or `securityListingRepository.findById` — those return entities with lazy `exchange` / `security` and would throw outside a Hibernate session. The previous helpers `resolveIndianListing` and `backfillForSecurity` are deleted.

3. **`basis_allocation_pct` lands NULL on every BhavKosh write.** The IRS Form 8937 contract from ADR-018 §Decision 3 stays load-bearing. Admins curate via `CorporateActionSpinoffService.recordManualSpinoff` (idempotent on `(parent, child, ex_date)`, flips `source` to `MANUAL`). `PortfolioReplayService.applySpinoff` treats null pct as `SPINOFF_MISSING_BASIS` and skips basis transfer.

4. **BhavKosh is the only auto-source.** No EODHD spinoff path exists or is planned — non-Indian spinoffs require admin manual entry until an upstream source materialises. The spinoff job has no EODHD fallback in either iteration path; the sweep's view is `WHERE mdp.name = 'BHAVKOSH'` and the JIT view is the same.

---

## Consequences

- **The Sunday 05:30 UTC error storm stops.** `corporate_action_spinoff` rows now flow from BhavKosh on every active Indian-listing master with a BhavKosh `MarketDataSymbol` mapping. Verified by `CorporateActionSpinoffBackfillJobTest` (Mockito regression guard pinning the new wiring) and `SecurityListingRepositoryIT` (@DataJpaTest + Testcontainers, 6 cases for the new SQL).
- **Sweep iteration narrowed from `securityMasterRepository.findAll()` to active BhavKosh symbols.** Old code iterated all 344+ masters and skipped non-Indian ones via `resolveIndianListing` returning empty; new code skips them at the query level via the view's `WHERE` clause. No spinoff rows are lost — masters without a BhavKosh mapping were a no-op on both paths.
- **Latent JIT bug closed.** The original JIT did `securityListingRepository.findById(symbolId)` against a `MarketDataSymbol.id` (wrong table), then dereferenced lazy `listing.getSecurity()`. The new JIT keys correctly on `MarketDataSymbol.id` via the view and produces scalars only.
- **`SecurityListingRepository.findIndianListingsByTickerWithMaster` is consumed by spinoff today.** The sibling jobs' admin-path bugs (Split/Dividend/Merger `backfillForSecurity(UUID)` still calling `resolveIndianListing` and Merger's `resolveCounterpartyMasterIdByTicker` still calling `findAllByTickerIgnoreCase`) should adopt it during the follow-up tracked in GitHub issue [#373](https://github.com/sumitsabhnani/portfolio-optimizer-backend/issues/373). The Merger fix in particular is direct reuse — same projection shape.
- **ADR-027 §Decision 4 is unaffected.** Merger EODHD `/api/fundamentals` is independent and stays gated off by `app.jobs.corporate-actions-mergers.enabled=false`.
- **Test infrastructure precedent for `jobs` module.** This is the first Spring-Boot/Testcontainers IT in `jobs/src/test/`. `jobs/build.gradle` now declares `spring-boot-testcontainers` + `testcontainers/postgresql` + the Postgres driver as `testImplementation`. The `@DataJpaTest` pattern (own `TestConfig` static class with `@EnableJpaRepositories` / `@EntityScan` on core packages, `@ComponentScan` on `core.converter` for `EncryptedStringConverter`) is the template — booting `JobsApplication` via `@SpringBootTest` transitively requires `RestTemplateConfig` and several `core.service` beans that don't wire standalone.

---

## Alternatives Considered

- **Keep ADR-027 §Decision 5 (revert to manual-only).** Would mean deleting `CorporateActionSpinoffBackfillJob` again and removing the JIT/sweep paths. Loses BhavKosh DEMERGER auto-discovery that's been in place since the job was reintroduced; user-visible regression for Indian spinoffs (RELIANCE → JIOFIN was an instance). Rejected.
- **`@Transactional(readOnly = true)` on the sweep method.** Holds the transaction across `BhavKoshCorporateActionsClient.fetch(...)` — violates the project rule that `@Transactional` boundaries must not span external HTTP. Rejected.
- **Add `JOIN FETCH` variants of `findFirstBySecurityAndIsPrimaryTrue` / `findAllByTickerIgnoreCase`.** Minimal-diff fix but keeps the JPA-entity surface on async paths and doesn't generalise to the BhavKosh-symbol-id lookup the JIT path needs. Inconsistent with the established split/dividend pattern. Rejected.
