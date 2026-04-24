# ADR-001: Core Tech Stack and Deployment

**Status:** Accepted  
**Date:** 2026-04-12  
**Context:** Foundational technology choices for a production-grade financial portfolio optimizer.

---

## Decision

### Backend: Spring Boot 3.3 + Java 21 (Gradle Multi-Module)

Three Gradle modules enforce strict dependency boundaries:

| Module | Responsibility | May Depend On |
|--------|---------------|---------------|
| **core** | Domain entities, JPA repositories, DTOs, pure domain services | — |
| **api** | REST controllers, JWT/OAuth security, orchestration services | core, jobs |
| **jobs** | Scheduled background tasks (`@EnableScheduling`, `WebApplicationType.NONE`) | core |

`jobs` runs headless — no HTTP server, no Spring Security filter chain. It processes market data ingestion, FIGI resolution, and broker sync on its own schedule.

### Database: PostgreSQL 15 + Flyway 11

- All schema changes tracked via Flyway migrations in `api/src/main/resources/db/migration/`.
- Naming convention: `V{YYYYMMDDHHMMSS}__PascalCaseDescription.sql`.
- All migrations use idempotent SQL (`IF NOT EXISTS`, `ON CONFLICT`).
- Hibernate runs in `validate` mode — Flyway is the sole owner of the schema.

### Cache: Redis 7

Redis serves as a read-through cache layer with purpose-tuned TTLs:

| Cache Name | TTL | Why |
|-----------|-----|-----|
| `latestPrices` | 20 min | Job refreshes every 15 min; buffer avoids stale reads |
| `historicalPrices` | 24 hr | Immutable once written (EOD bars don't change) |
| `portfolioValuations` | 10 min | Depends on latestPrices; short-lived |
| `fxRates` | 1 hr | Exchange rates update daily |
| `brokers` | 24 hr | Static metadata |

Values are JSON-serialized via Jackson with `@class` type metadata enabled. This prevents `BigDecimal` → `Double` coercion during deserialization — critical for a financial application where precision loss is a data integrity bug.

### Frontend: Angular 17 SPA

- Standalone components only (no NgModules).
- Angular Signals for component state; RxJS reserved for service/API boundaries.
- All HTTP calls route through a single `ApiService` using `environment.apiUrl`.
- `AuthInterceptor` injects JWT bearer tokens on every request.
- Modern control flow (`@if`, `@for`, `@switch`), OnPush change detection everywhere.

### Reverse Proxy: Caddy 2

Path-based routing on a single domain eliminates CORS entirely:

```
{$DOMAIN} {
  /api/*    → backend:8080   (strip /api prefix)
  /logs/*   → dozzle:8080    (basic-auth protected)
  /*        → frontend:80    (SPA catch-all)
}
```

### Deployment: Docker Compose on Hetzner VPS

All services run in a single `docker-compose.yml` on one machine:

```
┌─────────────────────────────────────────────────────┐
│  Hetzner VPS                                        │
│                                                     │
│  ┌──────────┐                                       │
│  │  Caddy   │ :80/:443 (public)                     │
│  └────┬─────┘                                       │
│       ├── /api/*  ──→  backend:8080                  │
│       ├── /logs/* ──→  dozzle:8080                   │
│       └── /*      ──→  frontend:80                   │
│                                                     │
│  ┌──────────┐  ┌───────┐  ┌───────────────┐        │
│  │ Postgres │  │ Redis │  │ price-sweeper │        │
│  │  :5432   │  │ :6379 │  │    :8000      │        │
│  └──────────┘  └───────┘  └───────────────┘        │
│                                                     │
│  All on bridge network: app-network                 │
│  No ports exposed except Caddy 80/443               │
└─────────────────────────────────────────────────────┘
```

Postgres data persists via a named Docker volume (`postgres-data`). Caddy manages TLS certificates automatically via Let's Encrypt.

## Why This Stack

1. **Java 21 + Spring Boot 3.3** — Virtual threads, Records for DTOs, `BigDecimal` as a first-class citizen for financial math. The Gradle multi-module split prevents accidental coupling (e.g., a domain service importing an HTTP annotation).

2. **PostgreSQL over NoSQL** — Relational integrity matters when tracking money. Foreign keys, unique constraints, and `NUMERIC` types enforce correctness at the storage layer. Flyway gives us auditable, version-controlled schema evolution.

3. **Redis as cache, not source of truth** — Postgres is authoritative. Redis absorbs read traffic for frequently-accessed data (latest prices, FX rates). If Redis is flushed, the system rebuilds from Postgres on next access.

4. **Single-domain Caddy** — Eliminates CORS preflight overhead and cookie/token domain issues. The SPA and API share one origin, simplifying auth and deployment.

5. **Docker Compose on a single VPS** — Right-sized for a solo-operated product. No Kubernetes overhead, no multi-region complexity. Horizontal scaling is a future concern, not a current one.

## Consequences

- All inter-service communication is container-to-container on `app-network`. No service is directly reachable from the internet except Caddy.
- Flyway migrations must be backward-compatible — the backend and database deploy together, but a failed migration blocks startup.
- Redis cache invalidation is manual (application events, not TTL-only). Adding a new cached entity requires wiring up invalidation logic.
- Single-VPS deployment means downtime during `docker-compose up -d` redeploys. Acceptable for current scale.
