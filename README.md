# YouTube Clone — High Performance Edition

> A production-grade video platform built to handle **thousands of concurrent users on a single server.**

---

## What it does

Upload, stream, and discover videos — just like YouTube. The interesting part is what's under the hood: every layer is tuned for high concurrency, low latency, and efficient media delivery on commodity hardware.

```
Browser → Nginx → FastAPI → Redis (cache)
                           ↓
                        PostgreSQL (fallback)
```

Videos stream via `X-Accel-Redirect` — Nginx reads bytes off disk while the backend only handles auth. Zero copying through Python.

---

## Quick start — Local

**Requires:** [Docker Desktop](https://www.docker.com/products/docker-desktop/) (Windows/macOS) or Docker Engine (Linux)

```bash
# 1. Configure secrets
cp .env.template .env
#    Edit .env → set POSTGRES_PASSWORD and JWT_SECRET_KEY

# 2. Launch — pick the tier that matches your machine, or let the script detect it
./infra/scripts/deploy.sh --profile dev --target local --hw auto    # auto-detect (recommended)
./infra/scripts/deploy.sh --profile dev --target local --hw tiny    # laptop  (2-4 cores / 4-8 GB)
./infra/scripts/deploy.sh --profile dev --target local --hw small   # workstation (4-8 cores / 8-16 GB)
./infra/scripts/deploy.sh --profile prod --target local --hw medium # server (8-32 cores / 32-64 GB)
./infra/scripts/deploy.sh --profile prod --target aws --hw large    # server (96 cores / 192 GB)
```

```powershell
# Windows PowerShell
.\infra\scripts\deploy.ps1 -Profile dev -Target local -Hw tiny
.\infra\scripts\deploy.ps1 -Profile dev -Target local -Hw small
```

```bash
# 3. Open
open http://localhost   # macOS
# http://localhost       # Windows / Linux
```

The first run builds images (~3 minutes). Subsequent starts take under 10 seconds.

> The `--hw` flag sets CPU limits, memory limits, worker counts, and database tuning
> to match your hardware. Use `--hw auto` to let the script detect your CPU and RAM
> automatically. Skipping it applies c5.24xlarge defaults (96 CPU / 192 GB)
> which will crash a normal machine. See [Hardware Profiles](docs/12-hardware-profiles.md).

> Step-by-step guides: [Windows](docs/02-quickstart-windows.md) · [Linux](docs/03-quickstart-linux.md)

---

## Quick start — AWS EC2

**Requires:** [Terraform ≥ 1.5](https://developer.hashicorp.com/terraform/downloads) · AWS CLI configured with credentials

```bash
# 1. Configure secrets (if not done yet)
cp .env.template .env
#    Edit .env → set POSTGRES_PASSWORD, JWT_SECRET_KEY, REDIS_PASSWORD

# 2. Configure AWS deployment variables
cp infra/envs/aws.tfvars.example infra/envs/aws.tfvars
#    Edit infra/envs/aws.tfvars → set repo_url, instance_type, credentials

# 3. Deploy — Terraform provisions the EC2 instance and starts the stack
./infra/scripts/deploy.sh --profile prod --target aws --hw auto     # auto-detect from instance_type in aws.tfvars
./infra/scripts/deploy.sh --profile prod --target aws --hw large    # c5.24xlarge (96 cores / 192 GB)
./infra/scripts/deploy.sh --profile prod --target aws --hw medium   # c5.4xlarge  (16 cores / 32 GB)
```

```powershell
# Windows PowerShell
.\infra\scripts\deploy.ps1 -Profile prod -Target aws -Hw large
.\infra\scripts\deploy.ps1 -Profile prod -Target aws -Hw medium
```

After `apply`, Terraform prints the public IP. First boot takes ~5–10 minutes (Docker install + image build on EC2).

> Full AWS guide with SSH access, HTTPS, and state management: [AWS EC2 Deployment](docs/07-deployment-aws.md)

---

## Stack

| Layer | Technology |
|-------|-----------|
| API | Python 3.12 · FastAPI · Gunicorn + Uvicorn |
| Database | PostgreSQL 16 |
| Cache & Queues | Redis 7 |
| Workers | RQ (Redis Queue) |
| Frontend | React 18 · TypeScript · Vite |
| Proxy | Nginx 1.27 (reverse proxy + X-Accel-Redirect) |
| Deploy | Docker Compose · Terraform · AWS EC2 |
| Observability | Prometheus · Grafana · OpenTelemetry · Tempo |
| CI | GitHub Actions |

---

## Documentation

| | |
|--|--|
| [Overview & Architecture](docs/01-overview.md) | How the system is designed and why |
| [Quickstart — Windows](docs/02-quickstart-windows.md) | Step-by-step for Windows with Docker Desktop |
| [Quickstart — Linux](docs/03-quickstart-linux.md) | Step-by-step for Linux |
| [Environment Variables](docs/04-environment-variables.md) | Every config option explained |
| [Architecture Deep Dive](docs/05-architecture.md) | Backend layers, DB schema, Nginx internals |
| [Development Guide](docs/06-development.md) | Local dev, tests, migrations, scripts |
| [AWS EC2 Deployment](docs/07-deployment-aws.md) | Terraform → production in one command |
| [Monitoring](docs/08-monitoring.md) | Prometheus metrics · Grafana dashboards |
| [Load Testing](docs/09-load-testing.md) | k6 stress tests and how to read them |
| [API Reference](docs/10-api-reference.md) | All REST endpoints |
| [Troubleshooting](docs/11-troubleshooting.md) | Common errors and fixes |
| [Hardware Profiles](docs/12-hardware-profiles.md) | `--hw tiny\|small\|medium\|large` — scale to your machine |

---

## Performance philosophy

> Performance is not an afterthought. It is the system.

- **Redis cache** on every hot read path — database is the fallback, not the default
- **Async Redis client** — all cache operations use `redis.asyncio`, eliminating blocking I/O on hot paths
- **Single-roundtrip view counter** — `INCR` return value replaces two sequential Redis calls per video request
- **Configurable cache TTL** — `VIDEO_DETAIL_CACHE_TTL` (60 s in prod) cuts cache-miss DB hits by ~6× versus the previous 10 s default
- **Buffered view and analytics writes** keep hot video pages off synchronous database updates
- **X-Accel-Redirect** for media — zero bytes of video ever touch Python
- **Connection pooling** — SQLAlchemy pool shared across Gunicorn workers; `DB_POOL_TIMEOUT=3s` fails fast instead of blocking for 30 s
- **anyio thread budget** — `ANYIO_MIN_THREADS` decouples the thread pool from the DB pool so cache-hit routes don't consume DB connections
- **Worker recycling** — `BACKEND_GUNICORN_MAX_REQUESTS` recycles workers periodically to prevent memory bloat under sustained load
- **Background workers** — video processing is async, uploads return immediately
- **Pagination everywhere** — no endpoint loads an unbounded result set

---

## Contributing · Security

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).
