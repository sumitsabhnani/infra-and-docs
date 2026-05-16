# ADR-036: System-Wide Vendor API Tokens — Encrypted Singleton, Superuser-Captured

**Status:** Accepted
**Date:** 2026-05-07
**Related:** ADR-005 (security & identity model), ADR-002 (per-user SnapTrade credential pattern)

---

## Context

Fyers V3 is the first ingest source for Indian-market intraday/option chain data that authenticates as a single application identity, not as the end user. The vendor's `validate-authcode` exchange returns one access token (≈24h TTL) plus a refresh token; the same token services every backend caller. Two existing patterns were both wrong fits:

- **Per-user SnapTrade pattern (`SnaptradeUser`).** Encrypts credentials per app user. Wrong scope: cloning rows for every user wastes encryption cycles, fans out the same secret across N rows, and creates a stale-row problem on user deletion that has no business meaning for a system identity.
- **OAuth login providers (Google/GitHub/Apple).** Long-lived per-user identities, not system-wide capability tokens. The exchange shape (PKCE, user-info endpoint, multi-tenant) doesn't match a single-row-overwrites-on-resync flow.

The platform also did not have a UI surface for capturing such tokens. Operators had no way to perform the OAuth-style code grant Fyers V3 mandates without dropping into a `psql` shell, and the system had no place to store the result that respected ADR-005's encryption invariant.

A separate frontend bug surfaced during integration: `UserDto` did not carry `isSuperuser`, so `AuthService.getCurrentUser()?.isSuperuser` was always undefined and no client-side role gate worked. That is fixed alongside this ADR but is not the architectural decision; see Consequences.

---

## Decision 1: System-Wide Vendor Tokens Persist as a Singleton Row in a Dedicated Table

Each vendor that authenticates as the application (not as a user) gets its own table with exactly one row at a fixed UUID. For Fyers V3:

```sql
CREATE TABLE fyers_token (
    id UUID PRIMARY KEY,                         -- always '00000000-0000-0000-0000-000000000001'
    access_token  TEXT NOT NULL,                  -- AES-256-GCM ciphertext (EncryptedStringConverter)
    refresh_token TEXT,                           -- nullable; ciphertext when present
    token_type    VARCHAR(32) NOT NULL DEFAULT 'Bearer',
    expires_at    TIMESTAMPTZ NOT NULL,
    refreshed_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

`FyersToken.SINGLETON_ID = UUID.fromString("00000000-0000-0000-0000-000000000001")` is the only id ever written. `FyersTokenRepository extends JpaRepository<FyersToken, UUID>` — `save()` upserts by primary key, so a successful re-sync overwrites the prior token without a delete/insert dance. `@PrePersist`/`@PreUpdate` stamp `refreshed_at`.

**Invariant:** `SELECT count(*) FROM fyers_token` is 0 or 1. Any future system-identity vendor follows the same shape: one table per vendor, one row per table, one fixed UUID.

## Decision 2: Capture Flow Is a Superuser-Only Admin Endpoint, Token Exchange Stays Server-Side

`POST /api/v1/admin/fyers/exchange` (class-level `@PreAuthorize("hasRole('SUPERUSER')")`) accepts `{ "authCode": "<one-shot from vendor redirect>" }` and returns a `FyersTokenStatusResponse(present, expiresAt, refreshedAt, expired)`. **The response never carries the token.** A companion `GET /api/v1/admin/fyers/status` returns the same shape for the UI to render "last refreshed / expires at" without re-reading the token.

`FyersClient.validateAuthCode(authCode)` computes
`appIdHash = HexFormat.of().formatHex(SHA-256(client_id + ":" + secret_key))` — lowercase hex, exactly Fyers's contract — and POSTs `{grant_type, appIdHash, code}` to `${fyers.validate-authcode-url}` via the shared `RestClient.Builder`. `secret_key` lives in `application.properties` under `fyers.secret-key=${FYERS_SECRET_KEY:}` and is **never** rendered in the frontend, surfaced in any DTO, or logged. The frontend supplies only `fyers.client-id` (public) and a runtime-derived `redirect_uri`; everything else stays on the server. Vendor errors (`s != "ok"`) raise `FyersExchangeException(message, code)` → HTTP 400 with `{message, code}` body.

`FyersTokenExchangeService.exchangeAndStore` is `@Transactional`; it builds a `FyersToken` with `id = SINGLETON_ID` and calls `repository.save(...)` — the JPA upsert is the overwrite. Logs use a SHA-256 fingerprint helper (length + first 12 hex chars) modelled on `SnapTradeAdminController.fingerprintForInfo` — never head/tail, never plaintext.

## Decision 3: Frontend RBAC Is a UX Layer; The Backend `@PreAuthorize` Is the Security Boundary

Two parallel guards:

- **Backend (security):** Class-level `@PreAuthorize("hasRole('SUPERUSER')")` on `FyersAdminController`. `JwtAuthenticationFilter` already maps `User.isSuperuser → ROLE_SUPERUSER` per request from the DB row, so toggling the flag takes effect on the next request — no token re-issue. Existing filter is untouched.
- **Frontend (UX only):** `superuserGuard` on `/admin/settings` and `/admin/fyers/callback` redirects non-superusers to `/dashboard` so they don't see a 403 from a doomed page render. Bypassing the guard cannot grant data access — the backend rejects.

The Admin Settings page (`/admin/settings`) and the Fyers redirect target (`/admin/fyers/callback`) are top-level routes, not nested under `/settings` — admin surfaces have a different audience and a different RBAC story than user settings, and namespacing them under `/admin/...` keeps the boundary visible in URLs and logs. A gated "Admin Settings" entry appears in the existing app-header gear popover when `currentUser?.isSuperuser`.

`crypto.randomUUID()` populates a `state` query param stashed in `localStorage.fyersOAuthState` before opening Fyers in a `window.open` popup; the callback detects popup context via `window.opener`, posts a `{type: 'fyers-callback-success' | 'fyers-callback-error'}` message back to the opener (filtered on `event.origin`), and closes itself — the opener refreshes status inline. Full-page navigation is the popup-blocked fallback. `localStorage` (not `sessionStorage`) is intentional: cross-origin OAuth redirects can drop sessionStorage under browser tracking-protection policies, and the value is still single-use (removed on first read). The callback consumes the state unconditionally on entry (success *or* failure) and aborts on mismatch — CSRF defence on the redirect leg.

---

## Consequences

**Positive**

- One vendor token, one row, one upsert call. `repository.count()` is the integration-test invariant for "previous token is overwritten" — explicit, cheap, and easy to assert.
- `EncryptedStringConverter` is reused unchanged. AES-256-GCM ciphertext at rest is the same path as `SnaptradeUser.snaptradeUserSecret`; no new crypto code, no new key management.
- Adding the next system-identity vendor (Kite, Upstox, Dhan, etc.) is a copy-paste of the entity + migration + client + service + admin endpoint; the architectural shape is locked in.
- `secret_key` lives only on the backend. Even a hostile frontend cannot mint a valid `appIdHash`.

**Negative**

- A second admin surface is now load-bearing. `FyersAdminController` joins `SnapTradeAdminController` as a class that, if its `@PreAuthorize` is ever stripped, gives any authenticated user the ability to overwrite or read a system credential's metadata. The `hasRole('SUPERUSER')` annotation must be treated as security-critical in code review.
- The 24h Fyers TTL means an operator-driven sync remains necessary every day until a refresh-token cron job is built. The schema carries `refresh_token` and `expires_at` so that job can be a pure-backend addition — no UI change, no schema change.
- The `secret_key` env var must be set on every backend deploy. A boot-time misconfiguration produces an `appIdHash` of `SHA-256(<clientId>:)` which Fyers rejects with a clear error; the failure mode is loud, not silent.

**Neutral**

- `UserDto` now carries `isSuperuser`. This is a bug fix, not a contract widening — `User` always had the field; the DTO simply omitted it. Four call sites (`AuthService.buildJwtResponse`, `AuthService.refreshAccessToken`, `UserController.convertToDto`, `PortfolioService.toUserDto`) were updated. Existing localStorage-cached `currentUser` objects from before this fix still have `isSuperuser` undefined; one logout + login refresh resolves it.
- The Admin Settings page exists with one card today (Fyers). Its layout is built around the singleton-token pattern (status grid: last refreshed / expires at / token presence) so additional vendor cards are repetitions of the same shape, not new layouts.

---

## Verification

- `FyersClientTest` (WireMock): asserts the outgoing `appIdHash` is the lowercase SHA-256 hex of `<clientId>:<secretKey>`, the request body shape, and parses both `s:"ok"` success and `s:"error"` paths including missing `access_token`.
- `FyersTokenExchangeServiceTest` (Testcontainers + Postgres): two consecutive exchanges with different fake tokens leave `repository.count() == 1`; the second token's fingerprint differs from the first; the encrypted column round-trips through the converter.
- `FyersAdminControllerIT` (Testcontainers + MockMvc): anonymous → 401; `roles = "USER"` → 403; `roles = "SUPERUSER"` → 200 on both endpoints; blank `authCode` → 400; the response body never contains the token.
- Frontend: `superuserGuard` redirects non-superusers to `/dashboard`; the gear-popover Admin Settings entry is hidden unless `currentUser?.isSuperuser` is true; the callback aborts on `state` mismatch.

## Alternatives Considered

- **Reuse `SnaptradeUser`-style per-user storage.** Rejected: the secret is not per-user. Fan-out across users multiplies the encryption blast radius for one credential and creates orphan-row semantics on user delete that don't model anything real.
- **Store the token in `application.properties` / env var.** Rejected: rotates daily; an operator pasting a 24h credential into config and triggering a redeploy on every sync is the worst possible UX, and writes the token to disk in plaintext.
- **Store all system-identity tokens in one generic `vendor_credentials` table.** Rejected: vendor schemas diverge (some return refresh tokens, some don't; some have multiple scopes; some include account-binding metadata). One table per vendor keeps the columns honest and the migrations independent.
- **Extend `JwtAuthenticationFilter` to embed `isSuperuser` in the JWT claims.** Rejected: the existing per-request DB lookup is already in place and lets superuser toggles take effect immediately. Embedding in the JWT trades a sub-millisecond DB read for a mandatory token re-issue on every privilege change — wrong trade-off for a flag that flips ~once per user, ever.
- **Scope `/admin/settings` under `/settings/admin`.** Rejected: `/settings/*` is the user's own preferences pane and inherits `UserLayoutComponent`'s tab chrome. Admin surfaces are a different audience and a different RBAC story; the URL namespace should reflect that boundary.
