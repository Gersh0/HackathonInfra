# Contributing Guide

## Setup

Follow the [Development Guide](docs/06-development.md) to set up a local development environment.

Quick start:
```bash
cp .env.template .env
# Edit .env with your values
docker compose -f docker-compose.yml -f docker-compose.dev.yml --profile dev up --build
```

---

## Branching Model

| Branch | Purpose |
|--------|---------|
| `main` | Production-ready code only. Protected. |
| `develop` | Integration branch for ongoing work. |
| `feature/<scope>-<name>` | New features |
| `fix/<scope>-<name>` | Bug fixes |
| `perf/<scope>-<name>` | Performance improvements |
| `chore/<scope>-<name>` | Maintenance, config, deps |

Examples:
- `feature/backend-video-comments`
- `fix/frontend-watch-memory-leak`
- `perf/backend-redis-cache-videos`

---

## Commit Messages

Use [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <short description>
```

Types: `feat`, `fix`, `perf`, `refactor`, `chore`, `docs`, `test`, `ci`, `build`

Examples:
- `feat(backend): add Redis cache to video list endpoint`
- `fix(frontend): avoid full stream prefetch on home page`
- `perf(nginx): enable micro-cache on read API endpoints`
- `docs: add troubleshooting guide to wiki`

---

## Before Opening a PR

Run these checks locally:

**Backend:**
```bash
# Lint and format
cd backend
uv run ruff check .
uv run ruff format --check .

# Tests
docker compose exec backend uv run pytest tests/ -v
```

**Frontend:**
```bash
cd frontend
npm run build   # Must succeed with no errors
```

Use the same commands as CI to avoid drift.

---

## Pull Request Rules

1. Target `develop` (except urgent production hotfixes → `main`)
2. Keep PRs small and focused — one concern per PR
3. PR description must include:
   - What changed and why
   - Risk assessment
   - How to test
4. Link the related issue
5. At least 1 approval required
6. All CI checks must pass before merge
7. No secrets, credentials, or API keys in the code

---

## Definition of Done

- CI is green
- No unresolved review comments
- No secrets or credentials added
- Backward compatibility considered (or breaking changes documented)
- Wiki updated if behavior or configuration changed

---

## Code Conventions

- Python: follow the existing repository style (ruff enforces it)
- Type hints on all function signatures
- Repository → Service → Route layering (no business logic in routes)
- No direct DB queries in routes or services — use repositories
- Tests for new business logic

See [Architecture](docs/05-architecture.md) for the full code organization.
