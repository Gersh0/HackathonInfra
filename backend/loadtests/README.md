# Load Testing Suite

Competition metric: **Score = sustained RPS / CPU%** (higher is better)

## Files

| File | Purpose |
|------|---------|
| `Seed.js` | Creates fixture data (users, videos, comments). Run once before `stress.js`. |
| `stress.js` | Weighted multi-scenario ramp — the primary competition tool. |

---

## Quickstart

### 1. Start the stack

```powershell
$env:DATABASE_URL = "postgresql+psycopg://your_db_username:StrongPassword123!@postgres:5432/youtube_clone"
$env:REDIS_URL    = "redis://redis:6379/0"
docker compose --profile prod up -d
```

### 2. Seed the database

Required before running `stress.js`. Creates users, videos, and comments, and writes `seed_output.json`.

**Windows:**

```powershell
docker run --rm --network host `
  -e BASE_URL=http://127.0.0.1/api `
  -v "${PWD}/backend/loadtests:/scripts" `
  grafana/k6 run /scripts/Seed.js
```

**Linux / macOS:**

```bash
docker run --rm --network host \
  -e BASE_URL=http://localhost/api \
  -v "${PWD}/backend/loadtests:/scripts" \
  grafana/k6 run /scripts/Seed.js
```

**Against a remote host (e.g. AWS):**

```bash
docker run --rm --network host \
  -e BASE_URL=http://<SERVER-IP>/api \
  -v "${PWD}/backend/loadtests:/scripts" \
  grafana/k6 run /scripts/Seed.js
```

### 3. Run the stress test

**Windows:**

```powershell
docker run --rm --network host `
  -e BASE_URL=http://127.0.0.1/api `
  -e MAX_VUS=300 `
  -v "${PWD}/backend/loadtests:/scripts" `
  grafana/k6 run /scripts/stress.js
```

**Linux / macOS:**

```bash
docker run --rm --network host \
  -e BASE_URL=http://localhost/api \
  -e MAX_VUS=300 \
  -v "${PWD}/backend/loadtests:/scripts" \
  grafana/k6 run /scripts/stress.js
```

**Against a remote host:**

```bash
docker run --rm \
  -e BASE_URL=http://<SERVER-IP>/api \
  -e MAX_VUS=300 \
  -v "${PWD}/backend/loadtests:/scripts" \
  grafana/k6 run /scripts/stress.js
```

### 4. Isolate a single scenario

Runs only one scenario at the full `MAX_VUS` count instead of the weighted split.

```powershell
docker run --rm --network host `
  -e BASE_URL=http://127.0.0.1/api `
  -e K6_SCENARIO=watch `
  -v "${PWD}/backend/loadtests:/scripts" `
  grafana/k6 run /scripts/stress.js
```

Valid `K6_SCENARIO` values: `browse`, `watch`, `comments`, `social`, `auth`, `system`

---

## Traffic mix

| Scenario | VU share | Endpoints |
|----------|:--------:|-----------|
| `browse` | 30% | `GET /videos`, `GET /videos?q=`, `GET /users` |
| `watch` | 25% | `GET /videos/{id}`, `GET /videos/{id}/recommended`, `GET /videos/{id}/thumbnail` |
| `comments` | 15% | `GET /videos/{id}/comments`, `POST /videos/{id}/comments` (30% of iters) |
| `social` | 15% | `GET /users/{id}/feed`, `GET /users/{id}/subscriptions`, subscribe/unsubscribe (50% of iters) |
| `auth` | 10% | `POST /auth/token`, `POST /videos/upload`, `DELETE /videos/{id}` |
| `system` | 5% | `GET /health`, `GET /health/queues`, `GET /videos/{id}/redis-probe` |

---

## Ramp profile (~4m 30s)

```
20s → 1% of MAX_VUS    (warm-up)
40s → 10% of MAX_VUS   (light)
40s → 33% of MAX_VUS   (moderate)
50s → 66% of MAX_VUS   (heavy)
50s → 100% of MAX_VUS  (ceiling probe)
50s → 100% of MAX_VUS  (hold at peak)
20s → 0                (ramp-down)
```

MAX_VUS=300 example: 3 → 30 → 99 → 198 → 300 → 300 → 0

---

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BASE_URL` | `http://127.0.0.1/api` | App API root URL — no trailing slash |
| `MAX_VUS` | `300` | Peak VU count |
| `K6_SCENARIO` | `all` | Scenario to run, or `all` for weighted mix |
| `SEED_FILE` | `./seed_output.json` | Path to seed output from `Seed.js` |

---

## Output files

| File | Written by | Contents |
|------|-----------|---------|
| `seed_output.json` | `Seed.js` | User IDs, auth tokens, video IDs consumed by `stress.js` |
| `stress_summary.json` | `stress.js` | Per-endpoint p95/p99, error rates, bottleneck list |

Full documentation: [docs/09-load-testing.md](../../docs/09-load-testing.md)
