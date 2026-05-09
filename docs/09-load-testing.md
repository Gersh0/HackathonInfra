# Load Testing

All load test scripts live in `backend/loadtests/`. They are run via Docker with the k6 image — no local k6 installation required.

> For the quick-reference command table, see [`backend/loadtests/README.md`](../backend/loadtests/README.md).

---

## Scripts

| Script | When to use |
|--------|-------------|
| [`Seed.js`](#1-seed-the-database) | Once before running `Breakpoint.js`, and after any DB reset |
| [`k6_stress_5k.js`](#2-5k-stress-test) | Measure raw ceiling: one endpoint, up to 5 000 VUs |
| [`Breakpoint.js`](#3-breakpoint-test) | Find which endpoint breaks first across the full traffic mix |

---

## 1. Seed the database

`Seed.js` creates 20 users, 50 videos, and 100 comments in the target database. It outputs `seed_output.json` — the user IDs, auth tokens, and video IDs that `Breakpoint.js` uses to simulate real traffic.

Run this once before any `Breakpoint.js` run, and again after a database reset.

```bash
# Linux / macOS — local stack
docker run --rm --network host \
  -e BASE_URL=http://localhost/api \
  -v "${PWD}/backend/loadtests:/scripts" \
  grafana/k6 run /scripts/Seed.js

# Windows
docker run --rm --network host `
  -e BASE_URL=http://host.docker.internal/api `
  -v "${PWD}/backend/loadtests:/scripts" `
  grafana/k6 run /scripts/Seed.js

# Remote / AWS
docker run --rm --network host \
  -e BASE_URL=http://<SERVER-IP>/api \
  -v "${PWD}/backend/loadtests:/scripts" \
  grafana/k6 run /scripts/Seed.js
```

`Breakpoint.js` will still run without seeding (it falls back to `id: 1` for users and videos), but expect 404s on any endpoint that requires a real record.

---

## 2. 5k stress test

`k6_stress_5k.js` targets a single endpoint — `GET /api/videos/{VIDEO_ID}` — and ramps aggressively to 5 000 VUs. Use this to measure the raw throughput ceiling for the video detail path and to confirm that view-count writes survive extreme concurrency.

### Ramp

```
  0 →   500 VU  in 1m
500 →  1 000 VU  in 1m
1000 → 2 000 VU  in 1m
2000 → 3 000 VU  in 1m
3000 → 5 000 VU  in 1m  (peak)
5 000 VU         for 3m  (hold at ceiling)
5000 → 2 000 VU  in 1m
2000 →     0     in 30s
```

Total: ~9.5 minutes. Fixed 200 ms think time per iteration.

### Run

```bash
docker run --rm -i \
  -e BASE_URL=http://<SERVER-IP>/ \
  -v "$PWD/backend/loadtests:/scripts" \
  grafana/k6:latest \
  run --log-output=none /scripts/k6_stress_5k.js
```

`--log-output=none` suppresses k6's per-request log lines, which would flood the terminal at 5 000 VUs. The summary is always printed at the end.

Override `VIDEO_ID` to target a specific video (default: `1`):

```bash
docker run --rm -i \
  -e BASE_URL=http://<SERVER-IP>/ \
  -e VIDEO_ID=5 \
  -v "$PWD/backend/loadtests:/scripts" \
  grafana/k6:latest \
  run --log-output=none /scripts/k6_stress_5k.js
```

### Thresholds

| Metric | Limit |
|--------|-------|
| `http_req_failed` | rate < 10% |
| `http_req_duration` p95 | < 3 000 ms |
| `http_req_duration` p99 | < 5 000 ms |
| `checks` | rate > 90% |

### Teardown output

After ramp-down the script makes one final request and prints the view count. Use this to verify that Redis-buffered view flushes reached the database after sustained load.

---

## 3. Breakpoint test

`Breakpoint.js` runs five scenarios simultaneously in a weighted mix, ramping to `MAX_VUS` (default 300). Use this to find which part of the stack degrades first — the ramp is intentionally slow enough to observe latency climbing before hard failures appear.

### Traffic mix

| Scenario | VU share | Endpoints hit |
|----------|:--------:|---------------|
| `browse` | 35% | `GET /health`, `GET /videos`, `GET /users`, `GET /users/{id}/feed` |
| `watch` | 25% | `GET /videos/{id}`, `GET /videos/{id}/thumbnail`, `GET /videos/{id}/stream` |
| `recommended` | 20% | `GET /videos/{id}/recommended` ← known CPU bottleneck |
| `comments` | 12% | `GET /videos/{id}/comments` (70%), `POST /videos/{id}/comments` (30%) |
| `auth` | 8% | `POST /auth/token`, `POST /videos/upload`, `DELETE /videos/{id}` |

### Ramp

```
  0 →  20 VU  in 1m   (warmup)
 20 →  60 VU  in 2m   (light)
 60 → 120 VU  in 2m   (moderate)
120 → 200 VU  in 2m   (heavy)
200 → MAX VU  in 2m   (ceiling probe)
MAX VU        for 3m  (hold)
  → 0         in 1m   (ramp-down)
```

Default total: ~13 minutes. Controlled by `RAMP_SPEED` (see below).

### Run

```bash
# Linux / macOS — local stack
docker run --rm --network host \
  -e BASE_URL=http://localhost/api \
  -e MAX_VUS=300 \
  -v "${PWD}/backend/loadtests:/scripts" \
  grafana/k6 run /scripts/Breakpoint.js

# Windows
docker run --rm --network host `
  -e BASE_URL=http://host.docker.internal/api `
  -e MAX_VUS=300 `
  -v "${PWD}/backend/loadtests:/scripts" `
  grafana/k6 run /scripts/Breakpoint.js

# Remote / AWS
docker run --rm \
  -e BASE_URL=http://<SERVER-IP>/api \
  -e MAX_VUS=300 \
  -v "${PWD}/backend/loadtests:/scripts" \
  grafana/k6 run /scripts/Breakpoint.js
```

### Isolate one scenario

Run only one scenario at the full `MAX_VUS` count — useful for finding the ceiling of a specific path:

```bash
docker run --rm --network host \
  -e BASE_URL=http://localhost/api \
  -e K6_SCENARIO=recommended \
  -v "${PWD}/backend/loadtests:/scripts" \
  grafana/k6 run /scripts/Breakpoint.js
```

### Ramp speed

`RAMP_SPEED` divides every stage duration. Higher values compress the ramp for faster iteration during development — shape of the curve is identical.

| `RAMP_SPEED` | Warmup | Each middle stage | Hold | Total |
|:---:|---:|---:|---:|---:|
| 1 (default) | 1m | 2m | 3m | ~13 min |
| 2 | 30s | 1m | 90s | ~6.5 min |
| 4 | 15s | 30s | 45s | ~3.25 min |

### Think time

`THINK_TIME` is a multiplier on the per-iteration sleep. `0` removes all pauses; `1` (default) models realistic browser pacing.

| Scenario | Sleep at `THINK_TIME=1` |
|----------|:-----------------------:|
| `browse` | 300 ms |
| `watch` | 500 ms |
| `recommended` | 200 ms |
| `comments` | 800 ms |
| `auth` | 1 000 ms |

### Quick iteration run (~3 min)

Combine `RAMP_SPEED=4` and `THINK_TIME=0` for a fast dev-cycle check:

```bash
docker run --rm --network host \
  -e BASE_URL=http://localhost/api \
  -e MAX_VUS=300 \
  -e RAMP_SPEED=4 \
  -e THINK_TIME=0 \
  -v "${PWD}/backend/loadtests:/scripts" \
  grafana/k6 run /scripts/Breakpoint.js
```

> For authoritative before/after scores, always run at `RAMP_SPEED=1 THINK_TIME=1` so results are comparable.

### Maximize RPS

Set `THINK_TIME=0` and raise `MAX_VUS` to find the absolute throughput ceiling:

```bash
docker run --rm \
  -e BASE_URL=http://<SERVER-IP>/api \
  -e MAX_VUS=1000 \
  -e THINK_TIME=0 \
  -v "${PWD}/backend/loadtests:/scripts" \
  grafana/k6 run /scripts/Breakpoint.js
```

---

## Environment variables reference

| Variable | Default | Script | Description |
|----------|---------|--------|-------------|
| `BASE_URL` | `http://host.docker.internal:8000` | all | App root URL |
| `VIDEO_ID` | `1` | 5k | Video to hit on every request |
| `REQUEST_TIMEOUT` | `60s` | 5k | Per-request HTTP timeout |
| `RESPONSE_TIME_LIMIT_MS` | `3000` | 5k | ms threshold for the "response time acceptable" check |
| `DEBUG` | `0` | 5k | `1` = print per-failure details |
| `K6_SCENARIO` | `all` | breakpoint | Scenario to isolate, or `all` for weighted mix |
| `MAX_VUS` | `300` | breakpoint | Peak VU count |
| `THINK_TIME` | `1` | breakpoint | Sleep multiplier per iteration |
| `RAMP_SPEED` | `1` | breakpoint | Stage duration divisor |
| `SEED_FILE` | `./seed_output.json` | breakpoint | Path to seed output |

---

## Outputs

| File | Written by | Contents |
|------|-----------|---------|
| `seed_output.json` | `Seed.js` | User IDs, tokens, video IDs (rebuilt from live API) |
| `breakpoint_summary.json` | `Breakpoint.js` | Peak RPS, P95 latency, error rate, breaking-point recommendation |
| `summary.json` | `k6_stress_5k.js` | Full k6 metrics dump |

---

## What to watch during a test

Open the Grafana dashboard ([see Monitoring](08-monitoring.md)) and watch:

| Metric | Healthy | Warning | Critical |
|--------|:-------:|:-------:|:--------:|
| Error rate | < 1% | 1–5% | > 5% |
| P95 latency | < 200 ms | 200–500 ms | > 500 ms |
| P99 latency | < 500 ms | 500–1 000 ms | > 1 000 ms |
| Redis hit rate | > 90% | 80–90% | < 80% |

```bash
# Quick check without Grafana
docker stats
```

---

## Interpreting k6 output

```
✓ status is 200
✓ response has valid JSON

checks.........................: 97.40%  ✓ 184230  ✗ 4892
http_req_duration..............: avg=48ms   p(90)=91ms  p(95)=140ms  p(99)=340ms
http_req_failed................: 2.58%   ✗ 4892
http_reqs......................: 189122  336.8/s
vus............................: 5000    min=1  max=5000
```

| Field | What it means |
|-------|--------------|
| `http_req_duration p(95)` | 95% of requests completed within this time — primary latency target |
| `http_req_duration p(99)` | Tail latency — look here for connection pool exhaustion spikes |
| `http_req_failed` | Percentage of HTTP errors (status ≥ 400, timeouts) |
| `http_reqs rate` | Throughput in requests/second at the reported VU count |
| `checks` | Pass rate of all named assertions in the script |

---

## Reading the results

- **Error rate > 10%** → Breaking point reached. Check Grafana for the exact VU count where errors spiked.
- **P95 > 1s, errors low** → Latency degradation without hard failure. Raise `MAX_VUS` to find collapse point.
- **`recommended` scenario breaks first** → Fix the Python in-memory sort in `GET /videos/{id}/recommended`.
- **`non_200_responses` climbing on 5k test** → Backend is rejecting connections before the pool collapses (check DB pool size and `POSTGRES_MAX_CONNECTIONS`).
- **5k teardown shows stale view count** → The `worker` container may be down. Views are buffered in Redis and flushed every 30s.
- **`watch` scenario fails on stream** → Check Nginx `X-Accel-Redirect` config; the worker container may not have processed the upload.
- **High `http_req_blocked`** → DNS or TCP connection establishment is slow at scale — check Nginx `keepalive` settings.

---

## Before/after comparison workflow

1. Reset DB to a known state — re-run `Seed.js`.
2. Run `Breakpoint.js` at defaults (`RAMP_SPEED=1 THINK_TIME=1`). Save `breakpoint_summary.json` as your baseline.
3. Apply one optimization.
4. Repeat step 2 and compare `peak_rps` and `p95_latency_ms`.
5. Run `k6_stress_5k.js` to confirm the optimization holds at extreme concurrency.
6. Use Grafana to pinpoint the exact VU count where degradation started.

Custom Trend metrics visible in k6 output and Grafana: `recommended_latency`, `watch_latency`, `browse_latency`.

---

[← Monitoring](08-monitoring.md) · [Wiki Index](index.md) · [API Reference →](10-api-reference.md)
