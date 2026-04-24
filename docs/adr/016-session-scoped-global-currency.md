# ADR-016: Session-Scoped Global Reporting Currency

**Status:** Accepted
**Date:** 2026-04-21
**Relates to:** ADR-009 (Multi-Currency Holdings UI), ADR-011 (Unify Valuation Engine and Historical FX)

---

## Context

The reporting-currency dropdown originally lived inside the `/portfolio` page. Any navigation to `/dashboard`, `/portfolio` Detailed view, or `/portfolio/history` dropped the user's chosen currency and fell back to the profile default (`User.reportingCurrency`) — a persistent cross-page context loss for what is clearly a transient view preference.

Two "obvious" ways to fix this were rejected before choosing the current approach:

1. **Persist the toggle to the user's DB profile (`PUT /api/users`) on every flip.** The profile-level reporting currency is not free to change — `UserController` publishes `ReportingCurrencyChangedEvent` on every update, which fans out to `TransactionReportingBackfillService` and forces a full walk of the user's ledger to rewrite the cached `normalized_reporting_*` projection columns on every transaction. That is the correct behaviour when a user deliberately changes their long-term reporting preference (via Settings), but it is pathologically expensive and semantically wrong for a "show me this page in EUR right now" gesture.
2. **Persist the toggle to `localStorage`.** Cross-session persistence implies the user wants the choice to stick beyond this tab, which conflicts with the "right-now" mental model of a header dropdown. It also muddies the source-of-truth story — a signal, a DB column, and a localStorage key all claiming to represent the same preference.

Requirement: a single dropdown visible everywhere, responsive everywhere, that **does not** reach the backend and does **not** outlive the session.

---

## Decision

Extract the dropdown to a global `AppHeaderComponent` mounted in the root `AppComponent` shell, backed by a session-only Angular Signal in `NavbarStateService`.

### Frontend — `NavbarStateService`

- `reportingCurrency = signal<string>('USD')` — the single source of truth for the session.
- `sessionOverridden: boolean` — flipped to `true` the first time the user interacts with the dropdown.
- `setSessionCurrency(next)` — user-driven change. Sets `sessionOverridden = true`, updates the signal. **No HTTP call.** No `localStorage.setItem`.
- `seedFromUserIfUntouched(profileCurrency)` — called from `AppComponent` on every `currentUser$` emission; no-ops once `sessionOverridden === true`. Effect: the signal is seeded from the user profile on authentication and remains re-seedable only while the user has not yet touched the dropdown.
- `resetSession()` — called from the header's logout handler; clears `sessionOverridden` and resets the signal so the next user does not inherit the previous session's choice.

### Backend API surface

Endpoints that render money accept an optional `?reportingCurrency=XXX` query param and fall back to `User.reportingCurrency` when absent (`/api/holdings`, `/api/movers`, `/api/groups/summary`, `/api/history/*`, `/api/asset-allocation`, `/api/holdings/{id}/transactions`). The `ReportingCurrencyResolver` helper centralises the fallback logic. No backend state changes per-toggle — the same stored data is re-rendered through FX conversion at read time.

### What profile-level currency change still does

`PUT /api/users` with a new `reportingCurrency` remains the only path that triggers `ReportingCurrencyChangedEvent` and the normalized-reporting rebuild. That path is reserved for the Settings screen ("change my default reporting currency"), not for the header dropdown.

---

## Consequences

**Positive**
- Zero backend calls and zero cache invalidations per toggle. Dropdown flips are O(1) client-side signal writes that cascade through already-dropdown-aware components via `effect(...)` re-fetches.
- One dropdown, visible on every authenticated route — the header component is mounted by `AppComponent` once and rides along with the router outlet.
- Clean two-layer model: **session preference** (Signal, transient) vs. **profile preference** (DB column, persistent). The two cannot accidentally merge.
- Data-correctness invariants (ADR-011) are preserved: FX conversion still happens server-side through `ExchangeRateService`; the frontend never does financial aggregation across currencies.

**Trade-offs**
- The session currency is not synchronised across browser tabs — each tab owns its own override. Acceptable for a view toggle.
- A page refresh resets to the profile currency (signals are in-memory). Acceptable — a header dropdown is a "right now" gesture, not a saved preference.
- Components that render money must each subscribe to the navbar signal (typically via `effect(...)`) and re-fetch on change. Minor boilerplate, but explicit rather than magical.

---

## Out of scope

- Persisting the session-level choice across refreshes or tabs. If ever needed, add a separate named preference ("remember last used currency") in the Settings screen — do not repurpose this signal.
- Auto-converting the profile default when the user repeatedly picks the same non-default currency. The nudge, if we ever build it, belongs in the Settings screen, not in the dropdown's state machine.
