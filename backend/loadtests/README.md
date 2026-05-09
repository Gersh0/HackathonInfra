# Load Testing Suite

Competition metric: **Score = sustained RPS / CPU%** (higher is better)

## Files

| File | Purpose |
|------|---------|
| `Seed.js` | Creates fixture data (20 users, 50 videos, 100 comments). Run once before `Breakpoint.js`. |
| `k6_stress_5k.js` | Extreme ramp to 5 000 VUs — single-endpoint hammer for raw ceiling measurement. |
| `Breakpoint.js` | Weighted traffic mix ramp — finds the performance ceiling across all endpoints. |

---

## Quickstart

### 1. Start the stack

```powershell
docker compose --profile prod up -d
```

### 2. Seed the database

Required before running `Breakpoint.js`. Skip for `k6_stress_5k.js` (it only needs a valid `VIDEO_ID`).

**Linux / macOS:**

```bash
docker run --rm --network host \
  -e BASE_URL=http://localhost/api \
  -v "${PWD}/backend/loadtests:/scripts" \
  grafana/k6 run /scripts/Seed.js
```

**Windows:**

```powershell
docker run --rm --network host `
  -e BASE_URL=http://host.docker.internal/api `
  -v "${PWD}/backend/loadtests:/scripts" `
  grafana/k6 run /scripts/Seed.js
```

**Against a remote host (e.g. AWS):**

```bash
docker run --rm --network host \
  -e BASE_URL=http://<SERVER-IP>/api \
  -v "${PWD}/backend/loadtests:/scripts" \
  grafana/k6 run /scripts/Seed.js
```

Output: `seed_output.json` — contains all created user IDs, tokens, and video IDs consumed by `Breakpoint.js`.

> **Note:** If `seed_output.json` is missing or has empty arrays, `Breakpoint.js` falls back to `id: 1` for users/videos and logs a warning. Run `Seed.js` first to avoid 404s.

### 3. Run the 5k stress test

Hits `GET /api/videos/{VIDEO_ID}` at up to 5 000 concurrent VUs. No seeding required — just supply a valid `VIDEO_ID` that exists in the database.

```bash
docker run --rm -i \
  -e BASE_URL=http://<SERVER-IP>/ \
  -v "$PWD/backend/loadtests:/scripts" \
  grafana/k6:latest \
  run --log-output=none /scripts/k6_stress_5k.js
```

> `--log-output=none` suppresses k6's internal per-request log lines, which would otherwise flood the terminal at 5 000 VUs. The final summary is always printed to stdout.

Override `VIDEO_ID` to target a different video:

```bash
docker run --rm -i \
  -e BASE_URL=http://<SERVER-IP>/ \
  -e VIDEO_ID=5 \
  -v "$PWD/backend/loadtests:/scripts" \
  grafana/k6:latest \
  run --log-output=none /scripts/k6_stress_5k.js
```

### 4. Run the breakpoint test

Run `Breakpoint.js` to find the ceiling across the full traffic mix.

**Linux / macOS:**

```bash
docker run --rm --network host \
  -e BASE_URL=http://localhost/api \
  -e MAX_VUS=300 \
  -v "${PWD}/backend/loadtests:/scripts" \
  grafana/k6 run /scripts/Breakpoint.js
```

**Windows:**

```powershell
docker run --rm --network host `
  -e BASE_URL=http://host.docker.internal/api `
  -e MAX_VUS=300 `
  -v "${PWD}/backend/loadtests:/scripts" `
  grafana/k6 run /scripts/Breakpoint.js
```

**Against a remote host:**

```bash
docker run --rm \
  -e BASE_URL=http://<SERVER-IP>/api \
  -e MAX_VUS=300 \
  -v "${PWD}/backend/loadtests:/scripts" \
  grafana/k6 run /scripts/Breakpoint.js
```

### 5. Isolate a specific scenario (Breakpoint.js)

Runs only one scenario at the full `MAX_VUS` count instead of the weighted split.

```bash
docker run --rm --network host \
  -e BASE_URL=http://localhost/api \
  -e K6_SCENARIO=recommended \
  -v "${PWD}/backend/loadtests:/scripts" \
  grafana/k6 run /scripts/Breakpoint.js
```

Available scenarios: `recommended`, `watch`, `browse`, `comments`, `auth`.

### 6. Maximize RPS (absolute ceiling)

Set `MAX_VUS` high and `THINK_TIME=0` to remove all sleep. Each VU fires continuously.

```bash
docker run --rm \
  -e BASE_URL=http://<SERVER-IP>/api \
  -e MAX_VUS=1000 \
  -e THINK_TIME=0 \
  -v "${PWD}/backend/loadtests:/scripts" \
  grafana/k6 run /scripts/Breakpoint.js
```

### 7. Quick iteration run (~3 minutes)

`RAMP_SPEED=4` + `THINK_TIME=0` compresses the full ramp to ~3 min for a fast dev-cycle check.

```bash
docker run --rm --network host \
  -e BASE_URL=http://localhost/api \
  -e MAX_VUS=300 \
  -e RAMP_SPEED=4 \
  -e THINK_TIME=0 \
  -v "${PWD}/backend/loadtests:/scripts" \
  grafana/k6 run /scripts/Breakpoint.js
```

> For authoritative before/after scores always run at `RAMP_SPEED=1 THINK_TIME=1` so results are comparable.

---

## 5k stress test (`k6_stress_5k.js`)

Single-scenario extreme load test. Targets one video detail endpoint and ramps until server collapse or the 5 000 VU ceiling is reached.

### Ramp profile

```
  0 →   500 VU  in 1m   (initial load)
500 →  1000 VU  in 1m
1000 → 2000 VU  in 1m
2000 → 3000 VU  in 1m
3000 → 5000 VU  in 1m   (peak)
5000 VU         for 3m  (hold)
5000 → 2000 VU  in 1m   (ramp-down)
2000 →    0 VU  in 30s
```

Total: ~9.5 minutes. Think time is fixed at **200ms** per iteration (not configurable).

### Thresholds

| Metric | Limit |
|--------|-------|
| `http_req_failed` | `rate < 10%` |
| `http_req_duration` p95 | `< 3 000 ms` |
| `http_req_duration` p99 | `< 5 000 ms` |
| `checks` | `rate > 90%` |
| `errors` (custom) | `rate < 10%` |

### Checks per iteration

- Status is 200
- Response has valid JSON with `title`, `views` (number), `id` (number)
- Response time ≤ `RESPONSE_TIME_LIMIT_MS` (default 3 000 ms)

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BASE_URL` | `http://nginx` | App root URL — trailing slash is stripped automatically |
| `VIDEO_ID` | `1` | ID of the video to hit on every request |
| `REQUEST_TIMEOUT` | `60s` | Per-request HTTP timeout |
| `RESPONSE_TIME_LIMIT_MS` | `3000` | Threshold (ms) for the "response time acceptable" check |
| `DEBUG` | `0` | Set to `1` to print per-failure details to the log |

### Teardown

After the ramp-down, a final `GET /api/videos/{VIDEO_ID}` is made and the view count is printed to confirm Redis-buffered view flushes reached the database.

---

## Breakpoint test (`Breakpoint.js`)

Weighted multi-scenario ramp. Designed to find which part of the stack breaks first, not to measure raw throughput.

### Traffic mix

| Scenario | VU share | Endpoints hit |
|----------|:--------:|---------------|
| `browse` | 35% | `GET /health`, `GET /videos`, `GET /users`, `GET /users/{id}/feed` |
| `watch` | 25% | `GET /videos/{id}`, `GET /videos/{id}/thumbnail`, `GET /videos/{id}/stream` |
| `recommended` | 20% | `GET /videos/{id}/recommended` ← known CPU bottleneck |
| `comments` | 12% | `GET /videos/{id}/comments` (70%), `POST /videos/{id}/comments` (30%) |
| `auth` | 8% | `POST /auth/token`, `POST /videos/upload`, `DELETE /videos/{id}` |

### Ramp profile

```
  0 →  20 VU  in 1m   (warmup)
 20 →  60 VU  in 2m   (light)
 60 → 120 VU  in 2m   (moderate)
120 → 200 VU  in 2m   (heavy)
200 → MAX VU  in 2m   (ceiling probe)
MAX VU        for 3m  (hold)
  → 0         in 1m   (ramp-down)
```

`RAMP_SPEED` divides every stage duration:

| `RAMP_SPEED` | Warmup | Each middle stage | Hold | Total |
|:---:|---:|---:|---:|---:|
| 1 (default) | 1m | 2m | 3m | ~13 min |
| 2 | 30s | 1m | 90s | ~6.5 min |
| 4 | 15s | 30s | 45s | ~3.25 min |

> Minimum stage duration is 1 second regardless of `RAMP_SPEED`.

### Think time (`THINK_TIME`)

`THINK_TIME` is a multiplier on the sleep at the end of each scenario iteration. `0` removes all pauses; `1` (default) models realistic browser pacing.

| Scenario | Sleep at `THINK_TIME=1` |
|----------|:-----------------------:|
| `browse` | 300 ms |
| `watch` | 500 ms |
| `recommended` | 200 ms |
| `comments` | 800 ms |
| `auth` | 1 000 ms |

### Thresholds

Thresholds are intentionally set to **not abort** the test — the goal is to observe degradation, not stop early.

| Metric | Limit |
|--------|-------|
| `http_req_failed` | `rate < 15%` (no abort) |
| `http_req_duration` p95 | `< 3 000 ms` (no abort) |
| `error_rate` (custom) | `rate < 15%` (no abort) |

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BASE_URL` | `http://host.docker.internal:8000` | App base URL |
| `K6_SCENARIO` | `all` | Scenario to isolate, or `all` for weighted mix |
| `MAX_VUS` | `300` | Peak VU count — raise to 1 000+ for ceiling tests |
| `THINK_TIME` | `1` | Sleep multiplier. `0` = max RPS; `1` = realistic pacing |
| `RAMP_SPEED` | `1` | Stage duration divisor. `2` = half speed; `4` = quarter speed |
| `SEED_FILE` | `./seed_output.json` | Path to seed output from `Seed.js` |

---

## Outputs

| File | Written by | Contents |
|------|-----------|---------|
| `seed_output.json` | `Seed.js` | User IDs, tokens, video IDs (rebuilt from API at end of run) |
| `breakpoint_summary.json` | `Breakpoint.js` | Peak RPS, P95 latency, error rate, breaking-point recommendation |
| `summary.json` | `k6_stress_5k.js` | Full k6 metrics dump for the 5k run |

---

## Methodology: before/after comparison

1. Reset DB to a known state — re-run `Seed.js`
2. Run `Breakpoint.js` at default settings (`RAMP_SPEED=1 THINK_TIME=1`) — save `breakpoint_summary.json` as baseline
3. Apply one optimization
4. Repeat step 2 and compare `peak_rps` and `p95_latency_ms`
5. Use the 5k test to confirm the optimization holds under extreme concurrency
6. Use Grafana to pinpoint the exact VU count where degradation started

---

## Reading the results

- **Error rate > 10%** → breaking point reached — check Grafana for the VU count where it spiked
- **P95 > 1s but errors low** → latency degradation without hard failure — raise `MAX_VUS` to find collapse
- **`recommended` scenario breaks first** → fix the Python in-memory sort (`GET /videos/{id}/recommended`)
- **DB pool exhaustion** → increase `pool_size` or switch to async SQLAlchemy
- **5k test: `non_200_responses` counter climbing** → backend is rejecting requests before the connection pool collapses
- **5k teardown shows stale view count** → the `worker` container may be down; views are buffered in Redis and flushed every 30s
- **Breakpoint: efficiency score flat** → the optimization didn't improve throughput per CPU unit

Custom Trend metrics available in k6 output for `Breakpoint.js`: `recommended_latency`, `watch_latency`, `browse_latency`.
