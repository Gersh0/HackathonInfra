# Development Guide

This guide covers setting up a local development environment, running tests, making code changes, and working with the database.

---

## Local Development Setup

### Requirements

| Tool | Version | Install |
|------|---------|---------|
| Docker + Docker Compose | Latest | [docker.com](https://docs.docker.com/get-docker/) |
| Python | 3.12+ | [python.org](https://python.org) |
| uv | Latest | `pip install uv` or [docs.astral.sh/uv](https://docs.astral.sh/uv/) |
| Node.js | 18+ | [nodejs.org](https://nodejs.org) (optional, for frontend outside Docker) |

### Start the dev stack

```bash
# Clone and configure
git clone <repo-url>
cd HackathonChallengeYoutubeClone-main
cp .env.template .env
# Edit .env with your values

# Start with hot reload
docker compose -f docker-compose.yml -f docker-compose.dev.yml --profile dev up --build
```

The dev compose override mounts local source directories as volumes, so code changes reflect immediately without rebuilding.

### Backend without Docker (optional)

If you want to run the backend directly on your machine for faster iteration:

```bash
cd backend

# Install dependencies
uv sync

# Set environment variables (use your local values)
export DATABASE_URL=postgresql+psycopg://devuser:devpass@localhost:5432/youtube_clone
export REDIS_URL=redis://localhost:6379/0
export JWT_SECRET_KEY=dev_jwt_secret_32_chars_minimum_here
export APP_ENV=development

# Run migrations
uv run python -m app.core.migrate

# Start the API
uv run uvicorn app.main:app --reload --port 8000
```

> PostgreSQL and Redis still need to be running. Start them via Docker:
> ```bash
> docker compose up postgres redis -d
> ```

---

## Running Tests

### Integration tests

```bash
# Run all integration tests (requires running database)
docker compose exec backend uv run pytest tests/ -v

# Or, with services already running locally:
cd backend
uv run pytest tests/ -v
```

Test files are in `backend/tests/integration/`:
- `test_auth_mutation_boundaries.py` — auth edge cases (duplicate users, bad passwords, token limits)
- `test_core_flow_regression.py` — full user journey (register → upload → view → delete)

### Acceptance scripts

These scripts validate specific subsystems against a running stack. Run them inside the backend container:

```bash
# Cache behavior
docker compose exec backend uv run python -m app.scripts.cache_acceptance

# Security checks
docker compose exec backend uv run python -m app.scripts.security_acceptance

# Worker queue health
docker compose exec backend uv run python -m app.scripts.worker_acceptance

# Media storage
docker compose exec backend uv run python -m app.scripts.media_acceptance

# Database query plans
docker compose exec backend uv run python -m app.scripts.query_plan_verification

# Frontend integration
docker compose exec backend uv run python -m app.scripts.frontend_acceptance
```

---

## Database Migrations

Migrations are managed with Alembic. The backend runs `alembic upgrade head` automatically on startup.

### Create a new migration

```bash
# Auto-generate from model changes
docker compose exec backend uv run alembic revision --autogenerate -m "add_column_x_to_table_y"

# Or manually
docker compose exec backend uv run alembic revision -m "describe_the_change"
```

Migration files go in `backend/alembic/versions/`. Name format: `YYYYMMDD_NNNN_description.py`.

### Apply migrations manually

```bash
# Upgrade to latest
docker compose exec backend uv run alembic upgrade head

# Downgrade one step
docker compose exec backend uv run alembic downgrade -1

# Show current revision
docker compose exec backend uv run alembic current

# Show migration history
docker compose exec backend uv run alembic history
```

---

## Code Style and Linting

The project uses pre-commit hooks for consistency. Install them once:

```bash
pip install pre-commit
pre-commit install
```

Hooks run automatically on `git commit`. Run manually on all files:

```bash
pre-commit run --all-files
```

Configured checks (see `.pre-commit-config.yaml`):
- **ruff** — Python linting and formatting
- **mypy** — type checking (if configured)

---

## Media Repair Utility

If you have video records in the database pointing to files that no longer exist on disk (e.g., after moving the `uploads/` directory):

```bash
# Dry run — shows what would be affected
docker compose exec backend uv run python -m app.scripts.repair_media

# Delete video records whose stream files are missing
docker compose exec backend uv run python -m app.scripts.repair_media --delete-orphans

# Clear thumbnail references for videos with missing thumbnails
docker compose exec backend uv run python -m app.scripts.repair_media --null-missing-thumbnails
```

---

## Adding a New API Endpoint

1. **Add the route** in `backend/app/api/routes/` (auth, users, or videos, or a new file)
2. **Add request/response schemas** in `backend/app/schemas/`
3. **Add business logic** in `backend/app/services/`
4. **Add DB queries** in `backend/app/repositories/`
5. **Register the router** in `backend/app/main.py` if it's a new file
6. **Add a migration** if the schema changes
7. **Write a test** in `backend/tests/integration/`

---

## Frontend Development

The frontend connects to the backend via `/api/*` proxied through Nginx (prod) or Vite's dev proxy (dev mode).

```bash
# Run frontend independently (requires backend running)
cd frontend
npm install  # or: bun install
npm run dev  # or: bun dev
```

The Vite dev server proxies `/api/*` to `http://localhost:8000` (configured in `vite.config.ts`).

**Build for production:**

```bash
cd frontend
npm run build
```

Output goes to `frontend/dist/`. In the Docker prod build, Nginx serves these files.

---

## Environment Variables in Development

A minimal `.env` for local development:

```env
APP_ENV=development
POSTGRES_USER=devuser
POSTGRES_PASSWORD=devpassword1234
POSTGRES_DB=youtube_clone
JWT_SECRET_KEY=dev_jwt_secret_key_32_chars_minimum_ok
REDIS_PASSWORD=
BACKEND_WEB_CONCURRENCY=2
WORKER_CONCURRENCY=2
CORS_ALLOW_ORIGINS=http://localhost:5173,http://localhost
```

See [Environment Variables](04-environment-variables.md) for the full reference.

---

## Branch and Commit Conventions

- Branch naming: `feature/short-description`, `fix/bug-name`, `perf/what-improves`
- Commit messages: imperative mood, present tense. Example: `add Redis cache to video list endpoint`
- Keep PRs focused — one concern per PR
- Run tests before pushing

---

[← Architecture](05-architecture.md) · [Wiki Index](index.md) · [AWS EC2 Deployment →](07-deployment-aws.md)
