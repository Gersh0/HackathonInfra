# Troubleshooting

Common issues and how to fix them.

---

## Startup Issues

### Backend container keeps restarting

**Symptom:** `docker compose ps` shows the backend container in a restart loop.

**Check logs:**
```bash
docker compose --profile prod logs backend
```

**Common causes:**

1. **Missing or invalid `JWT_SECRET_KEY`**
   ```
   ValueError: JWT_SECRET_KEY must be at least 32 characters
   ```
   Fix: Generate a strong key in `.env`:
   ```bash
   openssl rand -base64 48
   ```

2. **Database not ready yet** — the backend waits for PostgreSQL health check but may time out on slow machines. Wait 30 seconds and retry:
   ```bash
   docker compose --profile prod restart backend
   ```

3. **Invalid `DATABASE_URL`** — if you set `DATABASE_URL` manually, verify the format:
   ```
   postgresql+psycopg://user:password@postgres:5432/youtube_clone
   ```
   Special characters in the password must be URL-encoded. Use `python3 -c "import urllib.parse; print(urllib.parse.quote('your_pass', safe=''))"`.

---

### Nginx returns 502 Bad Gateway

**Cause:** Nginx started before the backend became healthy, or the backend is down.

**Fix:**
```bash
docker compose --profile prod restart nginx
```

If the backend is unhealthy:
```bash
docker compose --profile prod logs backend | tail -50
```

---

### Port 80 already in use

**Symptom:**
```
Error response from daemon: driver failed programming external connectivity: Bind for 0.0.0.0:80 failed: port is already allocated
```

**Find the process:**
```bash
# Linux
sudo ss -tlnp | grep ':80'

# Windows PowerShell
netstat -ano | findstr ":80"
```

**Fix:** Stop the conflicting service (IIS, Apache, another Docker container) or change the Nginx port in `docker-compose.yml`:
```yaml
ports:
  - "8080:80"
```

---

### `POSTGRES_SHARED_BUFFERS` error on startup

**Symptom:**
```
FATAL: could not resize shared memory segment ... : No space left on device
```

**Cause:** Docker's default shared memory (`shm_size`) is too small for the configured `POSTGRES_SHARED_BUFFERS`.

**Fix:** In `.env`, set a smaller shared buffers value:
```env
POSTGRES_SHARED_BUFFERS=256MB
POSTGRES_SHM_SIZE=512m
```
Or increase Docker Desktop's memory limit in Settings → Resources.

---

## Authentication Issues

### `401 Unauthorized` on all requests

1. Verify the `Authorization` header is present and correctly formatted:
   ```
   Authorization: Bearer eyJhbGci...
   ```

2. Check token expiry — default is 120 minutes. Obtain a new token:
   ```bash
   curl -X POST http://localhost/api/auth/token \
     -H "Content-Type: application/json" \
     -d '{"user_id": 1}'
   ```

3. Verify `JWT_SECRET_KEY` has not changed since the token was issued. If the key changed, all existing tokens are invalid.

---

### `403 Forbidden` on video delete

Only the video owner can delete their own video. The user ID in the JWT must match the video's `user_id`.

---

## Database Issues

### Alembic migration fails on startup

**Symptom:**
```
alembic.util.exc.CommandError: Can't locate revision identified by '...'
```

**Cause:** The local migration history is out of sync.

**Fix (development only — destroys all data):**
```bash
docker compose --profile prod down -v   # delete volumes

# Restart via deploy script (includes correct --hw limits)
./infra/scripts/deploy.sh --profile prod --target local --hw small   # adjust tier
# Windows: .\infra\scripts\deploy.ps1 -Profile prod -Target local -Hw small
```

For production, investigate the migration history before taking destructive action:
```bash
docker compose exec backend uv run alembic history
docker compose exec backend uv run alembic current
```

---

### `psycopg.OperationalError: connection refused`

The backend cannot connect to PostgreSQL. Common causes:
1. PostgreSQL container is not running or still starting up
2. `DATABASE_URL` has wrong host (should be `postgres` inside Docker, `localhost` outside)
3. Wrong credentials

```bash
# Check PostgreSQL status
docker compose --profile prod ps postgres

# Test connection manually
docker compose exec postgres psql -U $POSTGRES_USER -d $POSTGRES_DB -c "SELECT 1"
```

---

## Media / Upload Issues

### Video upload returns `413 Request Entity Too Large`

The request exceeds the configured size limit. Nginx enforces `client_max_body_size`. The backend also validates `Content-Length`.

Check `nginx/default.conf` for `client_max_body_size`. Default is tuned for large videos but can be increased.

---

### Videos play with errors or thumbnails are broken

Run the media repair utility to detect and fix orphaned records:

```bash
# Audit only (no changes)
docker compose exec backend uv run python -m app.scripts.repair_media

# Fix missing stream files
docker compose exec backend uv run python -m app.scripts.repair_media --delete-orphans

# Fix broken thumbnail references
docker compose exec backend uv run python -m app.scripts.repair_media --null-missing-thumbnails
```

---

### `uploads/` directory permission errors

The `uploads/` directory may be owned by root if created by Docker on Linux.

```bash
# Fix ownership
sudo chown -R $USER:$USER backend/uploads/
```

---

## Redis Issues

### `Connection refused` to Redis

```bash
# Check Redis status
docker compose --profile prod ps redis

# Test manually
docker compose exec redis redis-cli ping
# → PONG

# With password
docker compose exec redis redis-cli -a "$REDIS_PASSWORD" ping
```

---

### Cache not invalidating after video update

The backend invalidates Redis keys after writes. If cached stale data persists:

```bash
# Flush all Redis keys (development only!)
docker compose exec redis redis-cli FLUSHALL
```

---

## CI/CD Issues

### GitHub Actions failing with auth errors

The CI pipeline requires three secrets in GitHub repository settings:
- `CI_POSTGRES_USER`
- `CI_POSTGRES_PASSWORD`
- `CI_JWT_SECRET_KEY`

Go to: **Repository → Settings → Secrets and variables → Actions → New repository secret**

---

## Windows-Specific Issues

### Line endings break shell scripts inside containers

If Git converted line endings (LF → CRLF) on Windows, shell scripts inside containers fail:

```bash
git config core.autocrlf input
git rm --cached -r .
git reset --hard
```

Or fix per-repository with `.gitattributes` (already configured).

---

### Docker Desktop using too much memory / stack hangs on startup

The default limits in `docker-compose.yml` are sized for a c5.24xlarge (96 CPU / 192 GB).
Without `--hw`, Docker tries to allocate those limits on your machine, causing hangs or OOM kills.

**Fix — always pass `--hw` when starting the stack:**

```bash
# Linux / WSL
./infra/scripts/deploy.sh --profile prod --target local --hw tiny    # laptop  ≤8 GB RAM
./infra/scripts/deploy.sh --profile prod --target local --hw small   # workstation 8-16 GB RAM
./infra/scripts/deploy.sh --profile prod --target local --hw medium  # server 32-64 GB RAM

# Windows PowerShell
.\infra\scripts\deploy.ps1 -Profile prod -Target local -Hw tiny
.\infra\scripts\deploy.ps1 -Profile prod -Target local -Hw small
```

See [Hardware Profiles](12-hardware-profiles.md) for the full tier comparison table.

If you need to override a specific value on top of a tier, add it to `.env` — the shell
environment exported by `--hw` takes priority over `.env` values for everything else:

```env
# .env — fine-tune one value on top of --hw small
POSTGRES_SHARED_BUFFERS=1GB
```

---

## Getting More Debug Information

### Enable verbose backend logging

```bash
# In .env
APP_ENV=development
```

Development mode enables more verbose logging.

### Stream all logs

```bash
docker compose --profile prod logs -f
```

### Check container health details

```bash
docker inspect youtube_clone_backend | grep -A 20 '"Health"'
```

### Check queue depths

```bash
curl http://localhost/api/health/queues
```

---

[← API Reference](10-api-reference.md) · [Wiki Index](index.md) · [Hardware Profiles →](12-hardware-profiles.md)
