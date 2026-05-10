# Quickstart — Windows

This guide gets the application running on Windows using **Docker Desktop** (recommended).

**Estimated time:** 10–15 minutes on first run (image builds). Under 1 minute on subsequent runs.

---

## Prerequisites

| Requirement | Version | Download |
|-------------|---------|----------|
| Docker Desktop | 4.x or later | [docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/) |
| Git | Any recent | [git-scm.com](https://git-scm.com/download/win) |

> **Note:** Docker Desktop includes Docker Compose. No separate install needed.
>
> If you have WSL2 enabled, Docker Desktop works with it automatically. Enable "Use the WSL 2 based engine" in Docker Desktop → Settings → General.

---

## Step 1 — Clone the repository

Open **PowerShell** or **Git Bash** and run:

```powershell
git clone https://github.com/Gersh0/HackathonInfra.git
cd HackathonInfra
```

---

## Step 2 — Create the environment file

```powershell
Copy-Item .env.template .env
```

Now open `.env` in any text editor and set the three required values:

```env
POSTGRES_USER=myuser
POSTGRES_PASSWORD=SuperSecure2024!
JWT_SECRET_KEY=REPLACE_WITH_64_CHAR_RANDOM_STRING
```

**Generate a strong JWT secret (run in PowerShell):**

```powershell
python -c "import secrets; print(secrets.token_urlsafe(48))"
```

Or use Git Bash:

```bash
openssl rand -base64 48
```

> **Security rules:**
> - `POSTGRES_PASSWORD`: minimum 12 characters, mixed case + numbers + symbols
> - `JWT_SECRET_KEY`: minimum 32 characters, randomly generated
> - Never commit `.env` to git — it is already in `.gitignore`

---

## Step 3 — Start the stack

> **Before running docker compose**, export the database and Redis URLs so the backend can connect. Replace the values with the credentials you set in `.env`:
>
> ```powershell
> $env:DATABASE_URL = "postgresql+psycopg://your_db_username:StrongPassword123!@postgres:5432/youtube_clone"
> $env:REDIS_URL    = "redis://redis:6379/0"
> ```

Use the deploy script and pick the `--hw` tier that matches your machine:

```powershell
# Laptop (2-4 cores / 4-8 GB RAM)
.\infra\scripts\deploy.ps1 -Profile dev -Target local -Hw tiny

# Workstation (4-8 cores / 8-16 GB RAM)
.\infra\scripts\deploy.ps1 -Profile dev -Target local -Hw small

# Powerful workstation or server (8-32 cores / 32-64 GB RAM)
.\infra\scripts\deploy.ps1 -Profile prod -Target local -Hw medium
```

> **Why the `--hw` flag?** The default configuration targets a 96-core cloud server.
> Without the flag, Docker will try to allocate more resources than your machine has and may crash.
> See [Hardware Profiles](12-hardware-profiles.md) for details.

The script starts six services:
- `nginx` — reverse proxy (port 80)
- `postgres` — database
- `redis` — cache and queues
- `backend` — FastAPI API
- `worker` — background job processor
- `frontend` — React app (served by Nginx)

**Check that all services are healthy (30–60 seconds on first run):**

```powershell
docker compose --profile prod ps
```

All services should show `healthy` or `running`.

---

## Step 4 — Open the application

| URL | What it opens |
|-----|--------------|
| `http://localhost` | The application (via Nginx) |
| `http://localhost/api/health` | Backend health check |
| `http://localhost/api/docs` | Interactive API docs (Swagger UI) |

---

## Stopping the application

```powershell
docker compose --profile prod down
```

To also delete the database volumes (full reset):

```powershell
docker compose --profile prod down -v
```

---

## Development mode (hot reload)

Use the dev profile for live code reloading without rebuilding images:

```powershell
docker compose -f docker-compose.yml -f docker-compose.dev.yml --profile dev up --build
```

| URL | Service |
|-----|---------|
| `http://localhost:5173` | Frontend (Vite dev server with HMR) |
| `http://localhost:8000` | Backend API (direct, with reload) |
| `http://localhost:8000/health` | Backend health |

Stop with:

```powershell
docker compose -f docker-compose.yml -f docker-compose.dev.yml --profile dev down
```

---

## Common issues on Windows

### Docker Desktop not starting
- Ensure virtualization is enabled in BIOS (Intel VT-x / AMD-V)
- For WSL2: run `wsl --update` in PowerShell as Administrator

### Port 80 already in use
Check what is using port 80:
```powershell
netstat -ano | findstr ":80"
```
Common culprits: IIS, Skype, another web server. Stop the conflicting service or change the Nginx port in `docker-compose.yml`.

### Backend container keeps restarting
The backend requires `JWT_SECRET_KEY` with at least 32 characters. Check your `.env` file.

### Line ending issues with scripts
If you clone on Windows, Git may convert LF to CRLF. Run:
```powershell
git config core.autocrlf input
```

---

## What's next?

- [Environment Variables](04-environment-variables.md) — full reference for all settings
- [Development Guide](06-development.md) — running tests, migrations, code changes
- [AWS EC2 Deployment](07-deployment-aws.md) — deploying to production

---

[← Overview & Architecture](01-overview.md) · [Wiki Index](index.md) · [Quickstart: Linux →](03-quickstart-linux.md)
