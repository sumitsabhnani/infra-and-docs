# ADR-042: Fyers `/quotes` Runtime Failure Classification — Tri-State Outcomes, Negative Cache

**Status:** Accepted
**Date:** 2026-05-10
**Extends:** ADR-006 (price-sweeper sidecar), ADR-036 (system-identity vendor tokens)
**Composes with:** ADR-040 (Fyers symbol master + `symbol_kind` classification) — ADR-040 is the *upstream* mechanism that filters known-bad categories (e.g. `RIGHTS_ENTITLEMENT`) out of the active universe at SQL and resolves correct Fyers symbols at the boundary. This ADR specifies the *runtime* classification that remains necessary for the residual per-call rejections (delistings, halted symbols, transient mid-day data gaps) that the SQL filter cannot pre-empt.

---

## Context

The price-sweeper's upstream live-price source for the `BHAVKOSH` provider has moved from `yahooquery` to Fyers V3 `/quotes`. The capture of the daily access token was already specified in ADR-036; the symbol resolution path was hardened in ADR-040; this ADR specifies the runtime failure classification that callers reason over when an individual `/quotes` call rejects a symbol or the whole call fails.

The switch surfaced two correctness gaps that did not exist on the yahooquery path:

1. **Negative-cache poisoning.** Fyers `/quotes` returns three distinct failure shapes — per-symbol rejection (`s == "ok"` top-level but `s == "error"` on the entry, or a malformed entry with no `n`/`lp`), top-level service error (`s == "error"`, including token-expired codes `{-15, -16, -17, -300}`), and transport exceptions (network down, timeout). The original implementation collapsed all three into "absent from the result dict," so a token expiry on a single poll could mark every symbol in the batch as Fyers-rejected and suppress them for 24h. `984IFSL26.BO` was the production canary: Fyers returns `s == "ok"` top-level but the data entry has `s == "error"` with no `n`/`lp` payload — a real per-symbol rejection that the old logic could not distinguish from a transient failure.

2. **Cross-language token decryption contract.** The sweeper is Python; the token was written by Java's `EncryptedStringConverter` (AES-256-GCM, `Base64(IV || ciphertext || tag)`). The decryption shape, key length, and IV layout are an implicit ABI between the two services — must be specified, not implied.

---

## Decision 1: Three Outcomes — FOUND, REJECTED, FAILED — Returned to the Caller

`price-sweeper/app/fetcher.py` exposes:

```python
class FetchOutcome(Enum):
    FOUND     # price returned successfully
    REJECTED  # Fyers explicitly refused this specific symbol (per-entry error,
              # missing n/lp, non-positive price, or unmappable Yahoo symbol)
    FAILED    # service-wide failure: network exception, top-level Fyers error,
              # token expiry. The symbol's status is *unknown*; do not negative-cache.

@dataclass
class BulkFetchResult:
    prices: Dict[str, dict]       # FOUND
    rejected: Set[str]            # REJECTED
    # symbol in neither           # FAILED — caller infers by elimination
```

Bulk callers reason over the two sets explicitly. Single-symbol callers receive a `SingleFetchResult(outcome, data)` so the JIT path can branch cleanly.

**Invariant:** a symbol is REJECTED **only** when Fyers gave a successful top-level response and either explicitly rejected the entry or omitted a parseable price for it. Network errors, token-error codes, and top-level `s == "error"` responses are FAILED — the bulk caller leaves those symbols out of *both* sets.

The pivot point is `_parse_quote_payload`, which now returns `(prices, top_level_ok)`. When `top_level_ok` is False the bulk caller `continue`s without marking any symbol in the batch as rejected.

## Decision 2: Negative Cache at a Separate Redis Key Prefix, 24h TTL, Auto-Clearing

REJECTED symbols are negative-cached so the JIT `/force-fetch` path does not re-call Fyers for known-bad symbols every time the Java backend retries on cache miss.

| Property | Value |
|---|---|
| Key prefix | `market_data:yahoo:invalid:` (separate from the price prefix `market_data:yahoo:`) |
| TTL | 86400 s (24h) — long enough to absorb steady backend retries, short enough that a re-listed symbol self-recovers next trading day |
| Auto-clear | `write_price` / `write_prices_bulk` `DELETE` the matching invalid marker in the same Redis pipeline as the SETEX of the price; a successful price clears the negative cache implicitly |
| Probe | `is_invalid(symbol)` is the single source of truth; `/force-fetch` short-circuits on it before any Fyers call |
| Marker | Mark on REJECTED only. Never on FAILED. |

The separate key prefix is non-negotiable: the price prefix `market_data:yahoo:` is an external contract with the Java backend's `YahooPriceCacheReader.java` (`jobs` module, `KEY_PREFIX = "market_data:yahoo:"`). Any non-price payload at a `market_data:yahoo:<symbol>` key would corrupt the Java reader's deserialisation.

## Decision 3: `/force-fetch` Branches on Outcome, Caches Read-Through, Returns Distinct HTTP Codes

```
GET /force-fetch?symbol=X
  1. read_price(X) hit                        → 200, source="redis"
  2. is_invalid(X)                            → 404, "in negative cache"
  3. fetch_single_price(X):
       FetchOutcome.FOUND                     → 200, source="fyers", write Redis + upsert Postgres
       FetchOutcome.REJECTED                  → 404, mark_invalid(X)
       FetchOutcome.FAILED                    → 503, NO negative-cache write
```

The 503-on-FAILED is the load-bearing distinction. A Java backend retry on 404 means "give up on this symbol" (the negative cache will short-circuit the next call cheaply); a retry on 503 means "Fyers is sick, my symbol is still valid, try again later" — and the backend should back off rather than poison its own state.

## Decision 4: Token Decryption Is a Cross-Language Contract

`price-sweeper/app/fyers_token.py` reads the singleton row written by the Java backend's `FyersAdminController` (ADR-036) and decrypts the `access_token` in-process. The contract:

| Concern | Value |
|---|---|
| Key source | `ENCRYPTION_KEY` env var, byte-identical to the Java backend's `encryption.key` property |
| Key format | Base64-encoded 32 bytes (256-bit AES key) |
| Ciphertext format | `Base64( IV(12 bytes) ‖ ciphertext ‖ GCM_tag(16 bytes) )` |
| Algorithm | AES-256-GCM, no associated data, 128-bit auth tag |
| Library | Python `cryptography.hazmat.primitives.ciphers.aead.AESGCM` (matches Java `Cipher.getInstance("AES/GCM/NoPadding")`) |
| In-process cache | Plaintext cached until `fyers_token.expires_at` passes; thread-locked re-read on miss |
| Token-error invalidation | Fyers response codes in `{-15, -16, -17, -300}` invalidate the in-process cache so the next call re-reads the (potentially re-synced) row |

Any change to the Java-side ciphertext layout — different IV length, associated data, different tag length — must be co-released with a sweeper update. There is no protocol-level versioning today; both sides assume the layout above.

---

## Consequences

**Positive**

- A token-expiry hiccup no longer poisons the negative cache for arbitrary symbols. The `test_top_level_error_does_NOT_mark_rejected` and `test_quotes_exception_does_NOT_mark_rejected` cases are the burn-in.
- `984IFSL26.BO`-shaped per-symbol rejections are now correctly classified and negative-cached.
- The Java backend gains a typed retry signal: 404 → done, 503 → back off and retry. Cache-miss storms during Fyers outages no longer fan out into Fyers itself.
- One ABI contract for the encrypted singleton row lets either side be replaced without touching the other, provided the AES-GCM layout is preserved.

**Negative**

- `ENCRYPTION_KEY` is now a sweeper deploy concern, not just a backend concern. A drift between the two values is silent until the first decrypt fails. The sweeper logs the failure with a non-reversible fingerprint of the key (length + first 12 hex of SHA-256) on startup so operators can compare against the backend's `SnapTradeAdminController.encryptionKeyFingerprint()` output without echoing plaintext.
- The negative-cache TTL is a fixed 24h. A symbol that Fyers rejects today but accepts tomorrow stays in the negative cache for up to a day even after Fyers starts honouring it — the auto-clear only fires on a successful price write, which won't happen if `/force-fetch` is the only path hitting that symbol. Acceptable because the scheduler's 5-min poll cycle covers the entire BHAVKOSH universe anyway.
- Yahoo-format ticker strings (`RELIANCE.NS`, `TCS.BO`) remain the canonical internal symbol type even though Yahoo is no longer the upstream — translated to Fyers form (`NSE:RELIANCE-EQ`, `BSE:TCS-A`) at the fetch boundary only. The naming is honest about the type's shape; renaming through the call graph would not change behaviour.

**Neutral**

- ADR-006's architecture diagram, scheduling, market window, and shared-DB access remain unchanged. The provider swap does not affect the sidecar's deployment topology.
- The Redis key prefix `market_data:yahoo:` is preserved verbatim. The `yahoo` segment is now historical; renaming it would force a coordinated Java-side change for zero correctness gain.

---

## Verification

`pytest price-sweeper/tests/` — 11 passed. Load-bearing cases:

- `test_top_level_error_does_NOT_mark_rejected` — token expiry leaves symbols in neither set.
- `test_quotes_exception_does_NOT_mark_rejected` — network exception leaves symbols in neither set.
- `test_per_symbol_error_marks_rejected` — explicit `s == "error"` on an entry marks the symbol.
- `test_missing_n_lp_marks_symbol_rejected` — `984IFSL26.BO`-shape (top-level ok, entry missing `n`/`lp`) is inferred as REJECTED by elimination.
- `test_fetch_single_price_classifies_failed_on_token_error` — single-call FAILED on token expiry, not REJECTED.

## Alternatives Considered

- **Mark on FAILED and rely on TTL.** Rejected: a 24h penalty for a network blip is the exact failure mode this ADR exists to prevent.
- **Single key prefix with a discriminator field.** Rejected: would couple the Java backend's `YahooPriceCacheReader` to a payload schema change. Two key namespaces with a literal `:invalid:` segment is cheaper and leaves the Java contract untouched.
- **Use `requests` directly instead of `fyers-apiv3`.** Rejected: the SDK handles auth header formatting and the `/quotes` payload envelope. Direct HTTP would be a second drift surface.
- **Cache Fyers tokens at process start only.** Rejected: the daily-rotation cycle plus the 1–2 hour gap between an expired token and the operator clicking "Sync Fyers" again means the sweeper must re-read mid-process. The thread-locked re-read on expiry handles this without a restart.
