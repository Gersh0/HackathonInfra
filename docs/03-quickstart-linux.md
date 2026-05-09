# Quickstart — Linux

This guide covers running the application on Linux using Docker Engine and Docker Compose.

**Estimated time:** 10–15 minutes on first run. Under 1 minute on subsequent runs.

---

## Prerequisites

### Install Docker Engine

**Ubuntu / Debian:**

```bash
# Remove old versions if present
sudo apt remove docker docker-engine docker.io containerd runc 2>/dev/null

# Install dependencies
sudo apt update
sudo apt install -y ca-certificates curl gnupg

# Add Docker's official GPG key and repository
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
```

**Fedora / RHEL / CentOS:**

```bash
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
```

**Arch Linux:**

```bash
sudo pacman -S docker docker-compose
sudo systemctl enable --now docker
```

### Allow running Docker without sudo (optional but recommended)

```bash
sudo usermod -aG docker $USER
newgrp docker
```

Verify:

```bash
docker run --rm hello-world
```

---

## Step 1 — Clone the repository

```bash
git clone <your-repo-url>
cd HackathonChallengeYoutubeClone-main
```

---

## Step 2 — Create the environment file

```bash
cp .env.template .env
```

Edit `.env` and set the three required values:

```bash
nano .env  # or vim, code, etc.
```

```env
POSTGRES_USER=myuser
POSTGRES_PASSWORD=SuperSecure2024!
JWT_SECRET_KEY=REPLACE_WITH_64_CHAR_RANDOM_STRING
```

**Generate a strong JWT secret:**

```bash
openssl rand -base64 48
# or
python3 -c "import secrets; print(secrets.token_urlsafe(48))"
```

> **Security rules:**
> - `POSTGRES_PASSWORD`: minimum 12 characters
> - `JWT_SECRET_KEY`: minimum 32 characters, randomly generated
> - Never commit `.env` — it is in `.gitignore`

---

## Step 3 — Start the stack

Use the deploy script and pick the `--hw` tier that matches your machine:

```bash
# Laptop (2-4 cores / 4-8 GB RAM)
./infra/scripts/deploy.sh --profile dev --target local --hw tiny

# Workstation (4-8 cores / 8-16 GB RAM)
./infra/scripts/deploy.sh --profile dev --target local --hw small

# Powerful workstation or server (8-32 cores / 32-64 GB RAM)
./infra/scripts/deploy.sh --profile prod --target local --hw medium
```

> **Why the `--hw` flag?** The default configuration targets a 96-core cloud server.
> Without the flag, Docker will try to allocate more resources than your machine has and may crash.
> See [Hardware Profiles](12-hardware-profiles.md) for details.

Check that all services are healthy:

```bash
docker compose --profile prod ps
```

Wait until all services show `healthy`. This may take 30–60 seconds on first run while images build.

---

## Step 4 — Open the application

| URL | Description |
|-----|-------------|
| `http://localhost` | The application |
| `http://localhost/api/health` | Backend health endpoint |
| `http://localhost/api/docs` | Swagger UI (interactive API docs) |

---

## Stopping the application

```bash
docker compose --profile prod down
```

Full reset (deletes database data):

```bash
docker compose --profile prod down -v
```

---

## Development mode (hot reload)

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml --profile dev up --build
```

| URL | Service |
|-----|---------|
| `http://localhost:5173` | Frontend (Vite dev server, hot module reload) |
| `http://localhost:8000` | Backend API (direct access, auto-reload on code change) |

Stop with:

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml --profile dev down
```

---

## View logs

```bash
# All services
docker compose --profile prod logs -f

# Specific service
docker compose --profile prod logs -f backend
docker compose --profile prod logs -f worker
docker compose --profile prod logs -f nginx
```

---

## Running without root — port 80 restriction

On Linux, binding to port 80 requires root or a specific capability. If you get a permission error:

**Option A — Use Docker's rootless mode:**
```bash
dockerd-rootless-setuptool.sh install
```

**Option B — Change the port in `docker-compose.yml`:**
```yaml
# Change 80:80 to 8080:80
ports:
  - "8080:80"
```
Then access via `http://localhost:8080`.

---

## Firewall rules (if running on a server)

If running on a remote Linux server and you need external access:

```bash
# UFW (Ubuntu)
sudo ufw allow 80/tcp
sudo ufw allow 22/tcp  # Keep SSH open!

# firewalld (Fedora/RHEL)
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --reload
```

---

## What's next?

- [Environment Variables](04-environment-variables.md) — full reference for all settings
- [Development Guide](06-development.md) — running tests, migrations, code changes
- [AWS EC2 Deployment](07-deployment-aws.md) — deploying to production on AWS
- [Monitoring](08-monitoring.md) — Prometheus + Grafana setup

---

[← Quickstart: Windows](02-quickstart-windows.md) · [Wiki Index](index.md) · [Environment Variables →](04-environment-variables.md)
