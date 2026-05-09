# Environment Variables

Configuration is split into **two independent layers**. Understanding this split avoids confusion and prevents accidental overrides.

---

## Two-layer configuration

```
┌─────────────────────────────────────────────────────────┐
│  Layer 1 — .env (credentials & app config)              │
│                                                         │
│  POSTGRES_PASSWORD, JWT_SECRET_KEY, REDIS_PASSWORD,     │
│  APP_ENV, CORS_ALLOW_ORIGINS, Gunicorn timeouts         │
│                                                         │
│  Set once per deployment. Stays on disk. Never commit.  │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  Layer 2 — --hw tiny|small|medium|large (hw presets)    │
│                                                         │
│  BACKEND_WEB_CONCURRENCY, WORKER_CONCURRENCY,           │
│  DB_POOL_SIZE, REDIS_MAX_CONNECTIONS,                   │
│  POSTGRES_SHARED_BUFFERS, REDIS_MAXMEMORY,              │
│  *_CPU_LIMIT, *_MEMORY_LIMIT, *_RESERVATION             │
│                                                         │
│  Set by deploy.sh from infra/envs/hw-<tier>.env.        │
│  Exported as shell env vars → override .env at runtime. │
└─────────────────────────────────────────────────────────┘
```

**Rule:** if a variable appears in an `hw-*.env` file, do not set it in `.env`. It will be silently overridden and the value in `.env` will have no effect.

See [Hardware Profiles](12-hardware-profiles.md) for the full list of hw-managed variables and their values per tier.

---

## Setup

```bash
# Linux / macOS / Git Bash
cp .env.template .env

# Windows PowerShell
Copy-Item .env.template .env
```

**Never commit `.env`** — it is already in `.gitignore`.

---

## Required variables

These must be set before the application will start:

| Variable | Description | Example |
|----------|-------------|---------|
| `POSTGRES_USER` | Database username | `myapp_user` |
| `POSTGRES_PASSWORD` | Database password (min 12 chars) | `S3cur3P@ss2024!` |
| `JWT_SECRET_KEY` | JWT signing secret (min 32 chars) | *(generate, see below)* |

**Generate secrets:**

```bash
# JWT_SECRET_KEY
openssl rand -base64 48

# POSTGRES_PASSWORD (URL-safe, no special chars that break connection strings)
python3 -c "import secrets; print(secrets.token_urlsafe(24))"
```

---

## Application environment

| Variable | Default | Description |
|----------|---------|-------------|
| `APP_ENV` | `production` | Runtime mode. Use `development` for the dev profile. |

---

## Database credentials

| Variable | Default | Description |
|----------|---------|-------------|
| `POSTGRES_DB` | `youtube_clone` | Database name |
| `POSTGRES_USER` | *(required)* | Database username |
| `POSTGRES_PASSWORD` | *(required)* | Database password |
| `DATABASE_URL` | *(auto-built)* | Full connection URL. Leave blank; Docker Compose builds it from `POSTGRES_*`. Set explicitly when running outside Compose or when the password contains URL-reserved characters. Format: `postgresql+psycopg://user:password@postgres:5432/dbname` |

> PostgreSQL performance tuning (`POSTGRES_MAX_CONNECTIONS`, `POSTGRES_SHARED_BUFFERS`, etc.) is managed by the `--hw` profile, not `.env`. See [Hardware Profiles](12-hardware-profiles.md).

---

## Redis

| Variable | Default | Description |
|----------|---------|-------------|
| `REDIS_PASSWORD` | *(empty)* | Redis auth password. Empty = no auth (dev only). Always set in production. |
| `REDIS_URL` | *(auto-built)* | Full Redis URL. Leave blank; Compose builds it from `REDIS_PASSWORD`. Format: `redis://:password@redis:6379/0` |

> `REDIS_MAXMEMORY` is managed by the `--hw` profile.

---

## JWT / Authentication

| Variable | Default | Description |
|----------|---------|-------------|
| `JWT_SECRET_KEY` | *(required)* | Signing secret, min 32 characters |
| `JWT_ALGORITHM` | `HS256` | Signing algorithm |
| `JWT_ACCESS_TOKEN_EXP_MINUTES` | `120` | Token lifetime in minutes |
| `AUTH_TOKEN_ISSUER_ENABLED` | `false` | Allow `POST /auth/token` outside development |

---

## CORS

| Variable | Default | Description |
|----------|---------|-------------|
| `CORS_ALLOW_ORIGINS` | `http://localhost:5173,...` | Comma-separated or JSON array of allowed origins. Add your domain in production: `https://yourdomain.com` |

---

## Gunicorn timeouts

These control connection behaviour; worker count is set by `--hw`.

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKEND_GUNICORN_TIMEOUT` | `120` | Request timeout in seconds |
| `BACKEND_GUNICORN_GRACEFUL_TIMEOUT` | `30` | Graceful shutdown timeout |
| `BACKEND_GUNICORN_KEEPALIVE` | `75` | Keep-alive seconds for persistent connections |

> `BACKEND_WEB_CONCURRENCY` and `WORKER_CONCURRENCY` are managed by the `--hw` profile.

---

## Minimal `.env` for local development

```env
APP_ENV=development
POSTGRES_USER=devuser
POSTGRES_PASSWORD=devpassword1234
POSTGRES_DB=youtube_clone
JWT_SECRET_KEY=dev_jwt_secret_key_min_32_chars_here_ok
REDIS_PASSWORD=
CORS_ALLOW_ORIGINS=http://localhost:5173,http://localhost
```

Then start with `--hw tiny` to get safe resource limits for a laptop:

```bash
./infra/scripts/deploy.sh --profile dev --target local --hw tiny
```

---

[← Quickstart: Linux](03-quickstart-linux.md) · [Wiki Index](index.md) · [Architecture →](05-architecture.md)
