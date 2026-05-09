# Overview & Architecture

## What is this project?

A YouTube-like video platform designed to handle **thousands of concurrent users on a single server**. The focus is on performance engineering: every design decision prioritizes minimizing work per request, reducing database load, and serving media efficiently.

This is not a feature-complete consumer product. It is a demonstration of production-grade architecture and performance practices.

---

## Core Philosophy

> Performance is not an afterthought. It is the system.

Design principles:
- **Minimize work per request** — cache aggressively, avoid redundant queries
- **Offload heavy operations** — video processing runs in background workers, never blocking the API
- **Serve media efficiently** — Nginx serves bytes directly via `X-Accel-Redirect`, the backend only authorizes
- **Stateless API** — every instance is identical; scale horizontally if needed
- **Single-node capable** — tuned to run well on one large machine (e.g., AWS c5.24xlarge)

---

## System Components

```
Browser / Client
      │
      ▼
┌──────────────┐
│    Nginx     │  ← Reverse proxy, static file server (port 80)
└──────┬───────┘
       │
   ┌───┴──────────────┐
   │                  │
   ▼                  ▼
┌────────┐     ┌──────────────┐
│Frontend│     │  Backend API │  ← FastAPI + Gunicorn/Uvicorn (port 8000)
│(React) │     └──────┬───────┘
└────────┘            │
                 ┌────┴────────────────┐
                 │                     │
                 ▼                     ▼
          ┌──────────┐         ┌──────────────┐
          │PostgreSQL│         │    Redis     │
          │   (16)   │         │(cache+queues)│
          └──────────┘         └──────┬───────┘
                                      │
                               ┌──────▼───────┐
                               │   Workers    │  ← RQ background jobs
                               └──────────────┘
```

### Nginx
- Terminates HTTP connections
- Routes `/api/*` to the backend, everything else to the frontend
- Authorizes and serves video/thumbnail bytes via `X-Accel-Redirect` (zero backend copying)
- Buffers responses and manages connection limits

### Backend (FastAPI)
- Stateless REST API, JSON over HTTP
- Authentication via JWT (HS256)
- SQLAlchemy ORM with connection pooling
- Redis cache on read-heavy endpoints (video detail, listings)
- Enqueues background jobs for video processing
- Exposes `/metrics` in Prometheus format

### PostgreSQL
- Normalized schema: users, user_identities, videos, subscriptions, comments
- Indexes tuned for query patterns (no full scans)
- Connection pool managed by SQLAlchemy (`DB_POOL_SIZE`, `DB_MAX_OVERFLOW`)

### Redis
- Cache layer: frequently read data (video metadata, listings)
- Job queue: RQ queues for video processing (`video_processing`) and analytics (`analytics`)
- Configured with `allkeys-lru` eviction policy

### Workers (RQ)
- One or more processes (`WORKER_CONCURRENCY`) consuming the job queues
- Handles: video transcoding/processing after upload
- Isolated from the web process; shares the same Docker image

### Frontend (React)
- Single Page Application built with Vite and Bun
- TypeScript throughout
- Served as static files from Nginx in production
- Communicates with backend exclusively via `/api/*`

---

## Request Flow — Read (Video Page)

```
1. Browser → GET /api/videos/42
2. Nginx forwards the request to the backend
3. Backend increments the view buffer and checks Redis → HIT: return cached JSON
              → MISS: query PostgreSQL, populate Redis, return JSON
4. Browser → GET /api/videos/42/stream
5. Backend verifies auth → responds with X-Accel-Redirect header
6. Nginx reads bytes from internal /_protected_uploads/ location → streams to client
```

## Request Flow — Write (Video Upload)

```
1. Browser → POST /api/videos/upload (multipart, video + thumbnail)
2. Backend validates request size, saves files to disk
3. Backend inserts video record
4. Backend enqueues job → Redis queue
5. Worker picks job → processes video
6. Browser polls or re-fetches to see updated result
```

---

## Performance Highlights

| Technique | Where | Effect |
|-----------|-------|--------|
| Redis cache | Video detail, listings | Eliminates repeated DB queries |
| `X-Accel-Redirect` | Video/thumbnail serving | Zero-copy media delivery |
| Connection pooling | SQLAlchemy → PostgreSQL | Reduces connection overhead |
| Background workers | Video processing | Unblocks the API immediately |
| Batch analytics | View counting | Reduces write load via Redis aggregation |
| Pagination | All list endpoints | Prevents memory exhaustion |

---

## Project Structure

```
/
├── backend/            Python FastAPI backend
│   ├── app/
│   │   ├── api/routes/ REST route handlers (auth, users, videos)
│   │   ├── auth/       JWT authentication
│   │   ├── core/       Settings, DB, Redis, logging, metrics, tracing
│   │   ├── models/     SQLAlchemy ORM models
│   │   ├── repositories/ Data access layer
│   │   ├── schemas/    Pydantic request/response schemas
│   │   ├── services/   Business logic
│   │   └── async_jobs/ RQ job dispatcher and job definitions
│   ├── alembic/        Database migrations
│   ├── tests/          Integration tests
│   └── loadtests/      k6 load test scripts
├── frontend/           React + TypeScript SPA
├── nginx/              Nginx configuration files
├── infra/              Terraform for local and AWS EC2 deployment
├── observability/      Prometheus config and Grafana dashboards
└── docs/               This wiki
```

---

[Wiki Index](index.md) · [Quickstart: Windows →](02-quickstart-windows.md)
