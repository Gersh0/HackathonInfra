# Hardware Profiles

The application is tuned for a c5.24xlarge by default — 96 vCPUs and 192 GB RAM. Running those defaults on a laptop or a normal workstation will either crash Docker or make the machine unusable.

Hardware profiles solve this: pass `--hw <tier>` to the deploy script and it automatically sets the correct CPU limits, memory limits, worker counts, and PostgreSQL/Redis tuning for your hardware.

---

## Tiers at a glance

| Tier | Target hardware | Cores | RAM | Docker budget |
|------|----------------|-------|-----|---------------|
| `auto` | Any — script detects CPU & RAM | — | — | derived at deploy time |
| `tiny` | Dev laptop | 2–4 | 4–8 GB | ~4 CPU / ~2 GB |
| `small` | Workstation / gaming PC | 4–8 | 8–16 GB | ~8.5 CPU / ~6 GB |
| `medium` | Dedicated server | 8–32 | 32–64 GB | ~27 CPU / ~27 GB |
| `large` | AWS c5.24xlarge | 96 | 192 GB | ~96 CPU / ~152 GB |

> **Rule of thumb:** Docker gets roughly 25–35% of your total RAM. The OS, IDE, and other processes need the rest.

---

## Usage

### Linux / macOS / WSL

```bash
# Let the script detect your hardware automatically (recommended)
./infra/scripts/deploy.sh --profile dev --target local --hw auto

# Development on a laptop
./infra/scripts/deploy.sh --profile dev --target local --hw tiny

# Workstation running prod profile
./infra/scripts/deploy.sh --profile prod --target local --hw small

# Deploy to a rented server
./infra/scripts/deploy.sh --profile prod --target aws --hw medium

# Deploy to c5.24xlarge
./infra/scripts/deploy.sh --profile prod --target aws --hw large
```

### Windows PowerShell

```powershell
# Development on a laptop
.\infra\scripts\deploy.ps1 -Profile dev -Target local -Hw tiny

# Workstation running prod profile
.\infra\scripts\deploy.ps1 -Profile prod -Target local -Hw small

# Deploy to AWS
.\infra\scripts\deploy.ps1 -Profile prod -Target aws -Hw large
```

---

## --hw auto

`--hw auto` replaces manual tier selection by detecting the deployment target's hardware at deploy time:

| Target | Detection method |
|--------|-----------------|
| `local` | `nproc` + `/proc/meminfo` on the local machine |
| `aws` | `aws ec2 describe-instance-types` using the `instance_type` in `aws.tfvars` |
| `remote` | SSH to the host, then `nproc` + `/proc/meminfo` |

Once CPU count and RAM are known, the deploy script applies the same formulas used to produce the preset files — so the result is equivalent to the closest named tier but scaled precisely to your machine.

---

## What each profile controls

The deploy script reads the preset file from `infra/envs/hw-<tier>.env` and exports every variable as:

1. A shell environment variable → read by Docker Compose (takes priority over `.env`)
2. A `TF_VAR_*` variable → read by Terraform → written to the EC2 `.env` at boot

| Variable group | What changes |
|---------------|-------------|
| `BACKEND_WEB_CONCURRENCY` | Gunicorn worker processes |
| `WORKER_CONCURRENCY` | RQ background worker processes |
| `DB_POOL_SIZE` / `DB_MAX_OVERFLOW` | SQLAlchemy connection pool per worker |
| `DB_POOL_TIMEOUT` | Fast-fail timeout (3 s) if the pool is exhausted — avoids 30 s thread blocks |
| `ANYIO_MIN_THREADS` | Minimum anyio thread-pool size per worker; decouples concurrency from DB pool size so cache-hit routes don't consume DB connections |
| `REDIS_MAX_CONNECTIONS` | Async Redis connection pool ceiling; sized to `anyio_total × 2` |
| `VIDEO_DETAIL_CACHE_TTL` | Cache TTL (seconds) for video detail responses; 30 s on `tiny`, 60 s on all other tiers |
| `BACKEND_GUNICORN_MAX_REQUESTS` / `BACKEND_GUNICORN_MAX_REQUESTS_JITTER` | Worker recycle threshold to prevent memory accumulation under sustained load |
| `LOG_LEVEL` | Set to `WARNING` on all tiers to remove I/O overhead on hot paths |
| `POSTGRES_MAX_CONNECTIONS` | PostgreSQL max simultaneous connections |
| `POSTGRES_SHARED_BUFFERS` | PostgreSQL RAM for data page caching |
| `POSTGRES_EFFECTIVE_CACHE_SIZE` | PostgreSQL planner hint |
| `POSTGRES_WORK_MEM` | Memory per sort/hash operation |
| `REDIS_MAXMEMORY` | Redis eviction threshold |
| `*_CPU_LIMIT` / `*_MEMORY_LIMIT` | Docker container hard limits |

---

## Detailed preset values

### tiny — Dev laptop

```
Workers:        backend=2, rq=1
DB pool:        pool=3, overflow=3, timeout=3s → 2×(3+3)=12 max connections
anyio threads:  6 per worker
Redis conns:    40
Cache TTL:      30s
Gunicorn:       max_requests=2000, jitter=200
Postgres:       max_connections=50, shared_buffers=128MB
Redis:          maxmemory=128mb
Limits:         nginx=0.5CPU/128M  postgres=1CPU/512M  redis=0.5CPU/256M
                backend=1.5CPU/768M  worker=0.5CPU/256M  frontend=0.25CPU/128M
```

### small — Workstation

```
Workers:        backend=4, rq=2
DB pool:        pool=8, overflow=12, timeout=3s → 4×(8+12)=80 max connections
anyio threads:  20 per worker
Redis conns:    200
Cache TTL:      60s
Gunicorn:       max_requests=2000, jitter=200
Postgres:       max_connections=100, shared_buffers=512MB
Redis:          maxmemory=512mb
Limits:         nginx=1CPU/256M  postgres=2CPU/2G  redis=1CPU/768M
                backend=3CPU/2G  worker=1CPU/768M  frontend=0.5CPU/256M
```

### medium — Server

```
Workers:        backend=16, rq=8
DB pool:        pool=8, overflow=12, timeout=3s → 16×(8+12)=320 max connections
anyio threads:  20 per worker
Redis conns:    500
Cache TTL:      60s
Gunicorn:       max_requests=2000, jitter=200
Postgres:       max_connections=400, shared_buffers=2GB
Redis:          maxmemory=4gb
Limits:         nginx=2CPU/512M  postgres=6CPU/8G  redis=2CPU/6G
                backend=12CPU/8G  worker=4CPU/4G  frontend=1CPU/512M
```

### large — c5.24xlarge

```
Workers:        backend=97, rq=12
DB pool:        pool=12, overflow=12, timeout=3s → 97×(12+12)=2,328 max connections
anyio threads:  24 per worker
Redis conns:    2500
Cache TTL:      60s
Gunicorn:       max_requests=2000, jitter=200
Postgres:       max_connections=2500, shared_buffers=16GB
Redis:          maxmemory=16gb
Limits:         nginx=4CPU/2G  postgres=24CPU/64G  redis=4CPU/18G
                backend=48CPU/48G  worker=12CPU/16G  frontend=4CPU/4G
```

---

## Custom tuning

The preset files are the starting point — not a hard constraint. If your machine sits between tiers (e.g., 12 cores / 24GB RAM), start with `medium` and adjust specific variables in your `.env`:

```env
# .env — override specific values on top of the hw-medium preset
BACKEND_WEB_CONCURRENCY=8
POSTGRES_SHARED_BUFFERS=3GB
POSTGRES_MEMORY_LIMIT=12G
```

The `--hw` flag exports its values into the environment. Variables already in `.env` are **not** overridden — the shell environment takes priority, so the hw profile wins over `.env`.

If you want your `.env` to take precedence for specific variables, set them in `.env` and omit them from the hw override (or don't use `--hw` for that deployment).

---

## AWS instance type → recommended tier

| Instance type | vCPU | RAM | Recommended tier |
|--------------|------|-----|-----------------|
| `t3.medium` | 2 | 4 GB | `tiny` |
| `t3.xlarge` | 4 | 16 GB | `small` |
| `c5.xlarge` | 4 | 8 GB | `small` |
| `c5.4xlarge` | 16 | 32 GB | `medium` |
| `c5.9xlarge` | 36 | 72 GB | `medium` |
| `c5.24xlarge` | 96 | 192 GB | `large` |
| `c5d.24xlarge` | 96 | 192 GB + NVMe | `large` |

For AWS deploys, `--hw large` is equivalent to the values in `aws.tfvars.example` (the production defaults). Using `--hw medium` or smaller on AWS is useful for cost testing before scaling up.

---

[← Troubleshooting](11-troubleshooting.md) · [Wiki Index](index.md)
