# Load Testing

All load test scripts live in `backend/loadtests/`. They are run via Docker with the k6 image — no local k6 installation required.

> For the quick-reference command table, see [`backend/loadtests/README.md`](../backend/loadtests/README.md).

---

## Scripts

| Script | Purpose |
|--------|---------|
| [`Seed.js`](#1-seed-the-database) | Creates fixture data (users, videos, comments). Run once before `stress.js`. |
| [`stress.js`](#2-run-the-stress-test) | Weighted multi-scenario ramp across all endpoints. The primary competition tool. |

---

## 1. Seed the database

`Seed.js` creates fixture users, videos, and comments in the target database. It writes `seed_output.json` — the user IDs, auth tokens, and video IDs that `stress.js` uses to simulate real traffic.

Run this once before any `stress.js` run, and again after a database reset.

```powershell
# Windows — local stack
docker run --rm --network host `
  -e BASE_URL=http://127.0.0.1/api `
  -v "${PWD}/backend/loadtests:/scripts" `
  grafana/k6 run /scripts/Seed.js
```

```bash
# Linux / macOS — local stack
docker run --rm --network host \
  -e BASE_URL=http://localhost/api \
  -v "${PWD}/backend/loadtests:/scripts" \
  grafana/k6 run /scripts/Seed.js
```

```bash
# Remote / AWS
docker run --rm --network host \
  -e BASE_URL=http://<SERVER-IP>/api \
  -v "${PWD}/backend/loadtests:/scripts" \
  grafana/k6 run /scripts/Seed.js
```

Output: `backend/loadtests/seed_output.json`. If this file is missing, `stress.js` falls back to `id: 1` for users and videos and logs a warning — expect 404s on auth-guarded endpoints.

---

## 2. Run the stress test

`stress.js` runs six scenarios simultaneously in a weighted mix, ramping to `MAX_VUS` (default: 300). Use it to:

- Measure per-endpoint p95/p99 latency and error rates
- Find which endpoint or code path degrades first
- Compare before/after numbers for optimizations
- Produce a machine-readable `stress_summary.json` for archiving

### Traffic mix

| Scenario | VU share | Endpoints hit |
|----------|:--------:|---------------|
| `browse` | 30% | `GET /videos`, `GET /videos?q=`, `GET /users` |
| `watch` | 25% | `GET /videos/{id}`, `GET /videos/{id}/recommended`, `GET /videos/{id}/thumbnail` |
| `comments` | 15% | `GET /videos/{id}/comments`, `POST /videos/{id}/comments` (30% of iters) |
| `social` | 15% | `GET /users/{id}/feed`, `GET /users/{id}/subscriptions`, subscribe/unsubscribe (50% of iters) |
| `auth` | 10% | `POST /auth/token`, `POST /videos/upload`, `DELETE /videos/{id}` |
| `system` | 5% | `GET /health`, `GET /health/queues`, `GET /videos/{id}/redis-probe` |

### Ramp profile

```
Stage 1: 20s → 1% of MAX_VUS    (warm-up)
Stage 2: 40s → 10% of MAX_VUS   (light)
Stage 3: 40s → 33% of MAX_VUS   (moderate)
Stage 4: 50s → 66% of MAX_VUS   (heavy)
Stage 5: 50s → 100% of MAX_VUS  (ceiling probe)
Stage 6: 50s → 100% of MAX_VUS  (hold at peak)
Stage 7: 20s → 0                (ramp-down)

Total: ~4m 30s
Example (MAX_VUS=300): 3 → 30 → 99 → 198 → 300 → 300 → 0
```

Each stage target is `Math.max(floor, Math.floor(MAX_VUS × fraction))` — the floor ensures a meaningful ramp even at low VU counts.

### Run

```powershell
# Windows — local stack
docker run --rm --network host `
  -e BASE_URL=http://127.0.0.1/api `
  -e MAX_VUS=300 `
  -v "${PWD}/backend/loadtests:/scripts" `
  grafana/k6 run /scripts/stress.js
```

```bash
# Linux / macOS — local stack
docker run --rm --network host \
  -e BASE_URL=http://localhost/api \
  -e MAX_VUS=300 \
  -v "${PWD}/backend/loadtests:/scripts" \
  grafana/k6 run /scripts/stress.js
```

```bash
# Remote / AWS
docker run --rm \
  -e BASE_URL=http://<SERVER-IP>/api \
  -e MAX_VUS=300 \
  -v "${PWD}/backend/loadtests:/scripts" \
  grafana/k6 run /scripts/stress.js
```

### Isolate one scenario

Run only one scenario at the full `MAX_VUS` count — useful for measuring a specific endpoint's ceiling:

```powershell
docker run --rm --network host `
  -e BASE_URL=http://127.0.0.1/api `
  -e K6_SCENARIO=watch `
  -v "${PWD}/backend/loadtests:/scripts" `
  grafana/k6 run /scripts/stress.js
```

Valid values for `K6_SCENARIO`: `browse`, `watch`, `comments`, `social`, `auth`, `system`, `all` (default).

---

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BASE_URL` | `http://127.0.0.1/api` | App API root URL — no trailing slash |
| `MAX_VUS` | `300` | Peak VU count (total across all scenarios in weighted mode) |
| `K6_SCENARIO` | `all` | Scenario to run, or `all` for the weighted mix |
| `SEED_FILE` | `./seed_output.json` | Path to seed output from `Seed.js` |

---

## Outputs

| File | Written by | Contents |
|------|-----------|---------|
| `seed_output.json` | `Seed.js` | User IDs, auth tokens, video IDs used by `stress.js` |
| `stress_summary.json` | `stress.js` | Per-endpoint p95/p99, error rates, bottleneck list |

---

## Reading the summary output

At the end of each run, `stress.js` prints a formatted table to stdout and writes `stress_summary.json`:

```
════════════════════════════════════════════════════════════════════════════════
  STRESS TEST SUMMARY
════════════════════════════════════════════════════════════════════════════════

  OVERALL
────────────────────────────────────────────────────────────────────────────────
  Total requests   : 45,832
  Throughput       : 169.4 req/s
  Global error rate: 0.43%
  Global p95       : 284ms
  Global p99       : 612ms
  Upstream timeouts: 0
  Max VUs          : 300
  Mode             : weighted mix

  PER-ENDPOINT BREAKDOWN
────────────────────────────────────────────────────────────────────────────────
  Endpoint                               p95        p99        err%       Top status codes             Flag
  GET /videos (list)                     88ms       134ms      0.0%       200×12840                    ✅
  GET /videos/{id}/recommended           1420ms     2300ms     0.8%       200×8102                     ⚠️
  ...

  BOTTLENECK ANALYSIS
────────────────────────────────────────────────────────────────────────────────
  ⚠️   WARNINGS (approaching limits):
     • GET /videos/{id}/recommended — p95 1420ms
```

| Column | Meaning |
|--------|---------|
| `p95` / `p99` | Latency at the 95th / 99th percentile across all requests to that endpoint |
| `err%` | Fraction of requests that returned an unexpected status code or timed out |
| `Top status codes` | Most-seen HTTP status codes during the test (`code×count`) |
| `Flag` | ✅ healthy · ⚠️ approaching limits (p95 > 1s or err > 2%) · ❌ bottleneck (p95 > 2s or err > 5%) |

---

## What to watch during a test

Open the Grafana dashboard ([see Monitoring](08-monitoring.md)) and watch:

| Metric | Healthy | Warning | Critical |
|--------|:-------:|:-------:|:--------:|
| Error rate | < 1% | 1–5% | > 5% |
| P95 latency | < 200 ms | 200–500 ms | > 500 ms |
| P99 latency | < 500 ms | 500–1 000 ms | > 1 000 ms |
| Redis hit rate | > 90% | 80–90% | < 80% |

```powershell
# Quick resource check without Grafana
docker stats
```

---

## Interpreting results

- **Error rate > 10%** → Breaking point reached. Check Grafana for the exact VU count where errors spiked.
- **P95 > 1s on `recommended`** → `GET /videos/{id}/recommended` is the known CPU bottleneck — cache miss rate is too high.
- **Auth scenario errors consistently** → `AUTH_TOKEN_ISSUER_ENABLED` may be `false`, or file upload is blocking the event loop.
- **High `upstream_timeouts`** → Nginx `proxy_read_timeout` or Gunicorn worker saturation — check `BACKEND_REPLICAS` and `BACKEND_WEB_CONCURRENCY`.
- **Broad read latency across all endpoints** → CPU saturation. Raise `BACKEND_REPLICAS` for the machine tier.
- **`watch_thumbnail` shows 404×N** → Expected for stub data; thumbnails are optional and not created by `Seed.js`. Not an error.

---

## Before/after comparison workflow

1. Reset DB to a known state — re-run `Seed.js`.
2. Run `stress.js` at defaults. Save `stress_summary.json` as baseline.
3. Apply one optimization.
4. Re-run and compare `throughput_rps` and `global_p95_ms` in the two JSON files.
5. To isolate a specific path, re-run with `K6_SCENARIO=<name>` and compare the relevant endpoint row.

> **Note:** Docker Desktop on Windows adds VM overhead not present on a bare-metal Linux server. A local Windows run will understate the RPS you'll see on the competition server. Always compare within the same environment — don't mix Windows baseline with AWS after-run.

---

[← Monitoring](08-monitoring.md) · [Wiki Index](index.md) · [API Reference →](10-api-reference.md)
