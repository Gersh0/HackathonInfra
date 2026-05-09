# Architecture Deep Dive

---

## Backend (Python / FastAPI)

### Stack

| Component | Technology |
|-----------|-----------|
| Framework | FastAPI 0.115+ |
| ASGI server | Uvicorn (workers managed by Gunicorn) |
| ORM | SQLAlchemy 2.x (sync sessions) |
| Migrations | Alembic |
| Background jobs | RQ (Redis Queue) |
| Validation | Pydantic v2 |
| Auth | python-jose (JWT HS256) |
| Package manager | uv |

### Directory layout

```
backend/app/
├── api/
│   └── routes/
│       ├── auth.py       Login, register, token refresh
│       ├── users.py      User profile, avatar upload
│       └── videos.py     Upload, list, detail, stream, thumbnail
├── auth/
│   └── jwt.py            Token creation and verification
├── async_jobs/
│   ├── contracts.py      Queue names and job payload schemas
│   ├── dispatcher.py     JobDispatcher — enqueues jobs with retry
│   └── jobs.py           Job handler functions (run by workers)
├── core/
│   ├── cache.py          Redis cache helpers (get/set/invalidate)
│   ├── database.py       SQLAlchemy engine, session factory
│   ├── logging.py        JSON structured logging
│   ├── metrics.py        Prometheus counters/histograms
│   ├── migrate.py        Run Alembic migrations on startup
│   ├── settings.py       Pydantic settings (reads from env)
│   └── tracing.py        OpenTelemetry SQL tracing
├── models/
│   ├── user.py           User ORM model
│   ├── user_identity.py  Provider identity (OAuth/local) linked to a user
│   ├── video.py          Video ORM model
│   ├── subscription.py   Follower ↔ creator relationship
│   └── comment.py        Video comment
├── repositories/
│   ├── interfaces.py       Abstract repository ports
│   ├── user_repository.py  DB queries for users and identities
│   ├── video_repository.py DB queries for videos
│   ├── subscription_repository.py DB queries for subscriptions
│   └── comment_repository.py DB queries for comments
├── schemas/
│   ├── auth.py           Login/register request + token response
│   ├── user.py           User read/update schemas
│   ├── video.py          Video create/update/read schemas
│   ├── comment.py        Comment create/read schemas
│   ├── subscription.py   Subscription response schemas
│   └── pagination.py     Generic paginated response wrapper
├── services/
│   ├── interfaces.py        Abstract service ports
│   ├── auth_service.py      Auth business logic (hash, verify, issue tokens)
│   ├── user_service.py      User business logic
│   ├── video_service.py     Video business logic (upload, cache invalidation)
│   ├── subscription_service.py  Subscribe/unsubscribe, feed generation
│   ├── comment_service.py   Comment creation and listing
│   └── cache_payloads.py    Serialization helpers for Redis cache objects
├── scripts/
│   ├── repair_media.py   Fixes orphaned video records after file migration
│   └── *_acceptance.py  Acceptance test scripts (run manually)
└── main.py               FastAPI app factory, middleware, health endpoints
```

### Request lifecycle

```
HTTP Request
    │
    ▼
[Middleware: request_size_guard]  — reject oversized bodies early
    │
    ▼
[Middleware: request_logging]     — structured JSON log per request
    │
    ▼
[Middleware: metrics_middleware]  — Prometheus observe_request()
    │
    ▼
[Route handler]
    ├── Auth dependency (verify JWT, load user)
    ├── Repository (SQLAlchemy query, with Redis cache check)
    └── Return response
    │
    ▼
[Response] — includes x-request-id header
```

### Caching strategy

The backend uses an application-level read cache:

1. **Redis** — application-level cache with explicit TTLs. Keys: `cache:videos:detail:{id}`, `cache:videos:list:{limit}:{offset}:{query}`, etc.
2. **Nginx** — forwards API reads to the backend so request side effects such as view counting and analytics still run on every video detail request.

Cache invalidation happens explicitly in `video_service.py` when a video is updated or deleted.

### Background jobs

Two queues exist in Redis:

| Queue | Purpose |
|-------|---------|
| `default` | View count flush, analytics aggregation, and video processing jobs |

Two self-scheduling periodic jobs run every 30 seconds via `Queue.enqueue_in()`:

| Job | Purpose |
|-----|---------|
| `flush_view_counts_to_db` | Drains Redis view-count buffers into PostgreSQL |
| `process_analytics_batch` | Aggregates Redis analytics events into totals |

Jobs are enqueued via `JobDispatcher` with exponential backoff retry (`ENQUEUE_RETRY_ATTEMPTS`, `ENQUEUE_RETRY_BASE_DELAY_SECONDS`).

---

## Frontend (React / TypeScript)

### Stack

| Component | Technology |
|-----------|-----------|
| Framework | React 18 |
| Language | TypeScript |
| Build tool | Vite + Bun |
| HTTP client | Fetch API (custom wrapper in `src/api/`) |

### Directory layout

```
frontend/src/
├── api/          HTTP client, base URL config, auth header injection
├── components/   Reusable UI components
├── context/      React contexts (AuthContext, etc.)
├── hooks/        Custom hooks (useAuth, useVideo, etc.)
├── pages/        Page-level components (Home, VideoPage, Upload, Profile)
├── App.tsx       Router and top-level layout
├── main.tsx      React entry point
├── types.ts      Shared TypeScript types
└── styles.css    Global styles
```

### Production build

In production (`--profile prod`), Vite builds the frontend as static HTML/CSS/JS. Nginx serves these files directly from the `frontend` container's build output. The frontend never runs a Node.js server in production.

In development (`--profile dev`), the Vite dev server runs on port 5173 with hot module replacement.

---

## Database Schema

```sql
-- Core user record (display only, no auth credentials here)
users
  id            SERIAL PRIMARY KEY
  display_name  TEXT(255) NOT NULL CHECK (not blank)
  avatar_path   TEXT(500) NULL
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
  [index: ix_users_created_at]

-- Provider identity linked to a user (local or OAuth)
user_identities
  id               SERIAL PRIMARY KEY
  user_id          INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE
  provider         TEXT(64) NOT NULL        -- e.g. "local", "google"
  provider_subject TEXT(255) NOT NULL       -- provider's unique user ID / email
  email            TEXT(255) NULL
  [unique: (provider, provider_subject)]

-- Video metadata (files stored on disk, served via Nginx)
videos
  id             SERIAL PRIMARY KEY
  title          TEXT(255) NOT NULL CHECK (not blank)
  description    TEXT NOT NULL DEFAULT ''
  file_path      TEXT(500) NOT NULL CHECK (not blank)
  thumbnail_path TEXT(500) NULL
  uploader_id    INTEGER NULL REFERENCES users(id)
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
  views          INTEGER NOT NULL DEFAULT 0 CHECK (views >= 0)

-- Follower ↔ creator subscription
subscriptions
  id          SERIAL PRIMARY KEY
  follower_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE
  creator_id  INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
  [unique: (follower_id, creator_id)]
  [check: follower_id != creator_id]

-- Video comments (author stored as display_name snapshot)
comments
  id         SERIAL PRIMARY KEY
  video_id   INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE
  author     TEXT(255) NOT NULL CHECK (not blank)
  content    TEXT NOT NULL CHECK (not blank)
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
```

### Indexes

| Table | Index | Purpose |
|-------|-------|---------|
| `users` | `ix_users_created_at` | Pagination by creation time |
| `user_identities` | `uq_provider_subject` (unique) | Fast auth lookup by provider + subject |

### Migrations

Alembic manages schema versions in `backend/alembic/versions/`. The backend runs `alembic upgrade head` automatically on startup before accepting requests.

---

## Nginx Configuration

`nginx/nginx.conf` and `nginx/default.conf` define:

### Routing

```
GET /api/*          → proxy_pass http://backend:8000
GET /uploads/*      → internal only (X-Accel-Redirect target)
GET /*              → proxy_pass http://frontend:5173 (prod: static files)
```

### Media delivery via X-Accel-Redirect

Video streams and thumbnails are served through a protected internal location:

```nginx
location /_protected_uploads/ {
    internal;
    alias /var/www/uploads/;
}
```

When a client requests `/api/videos/42/stream`, the backend:
1. Verifies the JWT token
2. Returns a response with header `X-Accel-Redirect: /_protected_uploads/videos/42.mp4`
3. Nginx intercepts, reads the file directly from disk, streams to client

The backend never reads the file bytes — Nginx does all I/O.

### API Proxying

```nginx
location /api/ {
    proxy_pass http://backend/;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```

API responses are not cached at Nginx because video detail requests increment view counters and analytics buffers. Redis handles repeated backend reads while preserving those request side effects.

---

## Infrastructure (Terraform)

Three Terraform configurations exist:

| Path | Purpose |
|------|---------|
| `infra/aws/` | AWS EC2 single-node production deploy |
| `infra/local/` | Run Docker containers via Terraform locally |
| `infra/remote/` | Remote backend config (S3 state, etc.) |

### AWS layout

`infra/aws/main.tf` creates:
- 1 EC2 instance (instance type from `aws.tfvars`)
- Security group: HTTP (80) open, SSH restricted to `ssh_cidr_blocks`
- Optional Elastic IP
- `user_data` script (`user_data.sh.tftpl`) that:
  - Installs Docker and Docker Compose
  - Clones the repo
  - Writes `.env` from Terraform variables
  - Runs `docker compose --profile prod up -d`

Variables flow:
```
infra/envs/aws.tfvars       → Terraform variables
root .env (POSTGRES_*, JWT_SECRET_KEY, REDIS_PASSWORD)
    → written to EC2 /opt/youtube-clone/.env
    → read by Docker Compose at container start
```

Full deploy guide: [AWS EC2 Deployment](07-deployment-aws.md)

---

[← Environment Variables](04-environment-variables.md) · [Wiki Index](index.md) · [Development Guide →](06-development.md)
