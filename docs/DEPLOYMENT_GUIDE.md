# 🚀 Complete Deployment Guide

Choose your deployment method based on your needs:

## 📋 Quick Reference

| Scenario | Command (Linux/WSL) | Access |
|----------|---------------------|--------|
| Local dev — laptop | `./infra/scripts/deploy.sh --profile dev --target local --hw tiny` | http://localhost:5173 |
| Local prod — workstation | `./infra/scripts/deploy.sh --profile prod --target local --hw small` | http://localhost |
| Local prod — server | `./infra/scripts/deploy.sh --profile prod --target local --hw medium` | http://localhost |
| AWS c5.4xlarge | `./infra/scripts/deploy.sh --profile prod --target aws --hw medium` | http://[EC2-IP] |
| AWS c5.24xlarge | `./infra/scripts/deploy.sh --profile prod --target aws --hw large` | http://[EC2-IP] |

> **Windows PowerShell:** replace `./infra/scripts/deploy.sh` with `.\infra\scripts\deploy.ps1`
> and `--profile`/`--target`/`--hw` with `-Profile`/`-Target`/`-Hw`.
>
> **`--hw` is mandatory.** Omitting it applies c5.24xlarge defaults (96 CPU / 192 GB) which
> will hang or crash on any smaller machine. See [Hardware Profiles](12-hardware-profiles.md).

## 🏠 Local Development

**Prerequisites:**
- Docker Desktop (Windows/Mac) or Docker Engine (Linux)
- 8 GB RAM minimum — use `--hw tiny` on a 4-8 GB machine
- 20 GB free disk space

**Quick start:**
```bash
# 1. Clone and configure
git clone <repo-url>
cd hackathon-youtube-clone
cp .env.template .env
# Edit .env: set POSTGRES_PASSWORD and JWT_SECRET_KEY

# 2. Start — pick the tier that matches your machine
#    Linux / WSL:
./infra/scripts/deploy.sh --profile dev --target local --hw tiny    # laptop  2-4 cores / 4-8 GB
./infra/scripts/deploy.sh --profile dev --target local --hw small   # workstation 4-8 cores / 8-16 GB

#    Windows PowerShell:
.\infra\scripts\deploy.ps1 -Profile dev -Target local -Hw tiny
.\infra\scripts\deploy.ps1 -Profile dev -Target local -Hw small

# Access:
# Frontend: http://localhost:5173 (hot reload)
# Backend:  http://localhost:8000 (direct)
# API docs: http://localhost:8000/docs
```

**Development features:**
- Hot reload for frontend and backend
- Direct port access (no nginx)
- Faster startup times
- Debug-friendly logging

## 🎬 Local Production

**When to use:**
- Testing production configuration locally
- Performance testing with k6
- Verifying nginx configuration

```bash
# Linux / WSL — production-like environment
./infra/scripts/deploy.sh --profile prod --target local --hw small   # workstation
./infra/scripts/deploy.sh --profile prod --target local --hw medium  # server

# Windows PowerShell
.\infra\scripts\deploy.ps1 -Profile prod -Target local -Hw small

# Access:
# Frontend: http://localhost        (via nginx)
# API:      http://localhost/api    (via nginx)
```

> **With observability stack (Prometheus + Grafana):**
> Start the prod stack first, then layer the observe profile on top:
> ```bash
> docker compose --profile observe up -d   # adds Prometheus, Grafana, Tempo, cAdvisor
> # Grafana: http://localhost/grafana
> ```

## ☁️ AWS Deployment

**Prerequisites:**
- AWS CLI configured (`aws configure`)
- Terraform >= 1.5 (auto-installed by deploy script if missing)
- Git repo pushed to a remote (EC2 clones from this URL)

**Step by step:**
```bash
# 1. Configure infrastructure settings
cp infra/envs/aws.tfvars.example infra/envs/aws.tfvars
# Edit aws.tfvars: set repo_url, instance_type, postgres_password, jwt_secret_key

# 2. Deploy — match --hw to your instance type (see Hardware Profiles doc)
./infra/scripts/deploy.sh --profile prod --target aws --hw medium   # c5.4xlarge
./infra/scripts/deploy.sh --profile prod --target aws --hw large    # c5.24xlarge

# Windows PowerShell
.\infra\scripts\deploy.ps1 -Profile prod -Target aws -Hw medium

# 3. Get access URL (after apply completes)
cd infra/aws && terraform output app_url

# 4. Cleanup when done
./infra/scripts/deploy.sh --profile prod --target aws --hw large --action destroy
```

See [AWS EC2 Deployment](07-deployment-aws.md) for the complete walkthrough.

## 🧪 Performance Testing

**After deployment:**
```bash
# Navigate to load testing
cd backend/loadtests

# Run smoke test first
docker run --rm -i --network [NETWORK] \
  -v $(pwd):/scripts \
  grafana/k6:latest run /scripts/k6_phase9_smoke.js

# Run stress test
docker run --rm -i --network [NETWORK] \
  -v $(pwd):/scripts \
  grafana/k6:latest run /scripts/k6_hot_row_stress.js
```

See `backend/loadtests/README.md` for detailed instructions.

## 🔧 Troubleshooting

**Service won't start:**
```bash
# Check service status
docker compose ps

# Check logs
docker compose logs [service-name]

# Restart single service
docker compose restart [service-name]
```

**Port conflicts:**
```bash
# Find what's using port 80
sudo netstat -tulpn | grep :80

# Stop conflicting service
sudo systemctl stop apache2  # or nginx
```

**Database connection issues:**
- Verify `POSTGRES_USER` and `POSTGRES_PASSWORD` in `.env`
- Check database logs: `docker compose logs postgres`
- Ensure database is healthy: `docker compose ps postgres`

**AWS deployment issues:**
- Check AWS credentials: `aws sts get-caller-identity`
- Verify security groups allow HTTP traffic
- Check EC2 instance logs via SSH or AWS Console

## 📊 Monitoring and Health Checks

**Health endpoints:**
- Application: `GET /api/health`
- Queue status: `GET /api/health/queues`
- Metrics: `GET /api/metrics`

**Grafana dashboards** (when using `--profile observe`):
- API Overview: Request rates, latency, errors
- Infrastructure: CPU, memory, disk usage

**Log locations:**
- Application: `docker compose logs backend`
- Database: `docker compose logs postgres`
- Queue workers: `docker compose logs worker`
- Nginx: `docker compose logs nginx`