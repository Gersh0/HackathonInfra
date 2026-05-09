# YouTube Clone — Wiki

Complete documentation for using, developing, and deploying the project.

---

## Table of Contents

### Getting Started
- [01 — Overview & Architecture](01-overview.md) — What the project does, design philosophy, component diagram
- [02 — Quickstart: Windows](02-quickstart-windows.md) — Run on Windows with Docker Desktop (recommended path)
- [03 — Quickstart: Linux](03-quickstart-linux.md) — Run on Linux with Docker Engine

### Configuration
- [04 — Environment Variables](04-environment-variables.md) — Every variable, its purpose, and safe defaults

### Deep Dives
- [05 — Architecture](05-architecture.md) — Backend layers, frontend structure, infrastructure layout
- [06 — Development Guide](06-development.md) — Local dev setup, testing, database migrations, code style
- [07 — AWS EC2 Deployment](07-deployment-aws.md) — Terraform provisioning, production deploy, SSH access
- [08 — Monitoring](08-monitoring.md) — Prometheus metrics, Grafana dashboards, alert rules
- [09 — Load Testing](09-load-testing.md) — k6 scripts, stress scenarios, interpreting results

### Reference
- [10 — API Reference](10-api-reference.md) — All REST endpoints, auth, request/response shapes
- [11 — Troubleshooting](11-troubleshooting.md) — Common errors and how to fix them
- [12 — Hardware Profiles](12-hardware-profiles.md) — `--hw tiny|small|medium|large` — scale to your machine

---

## At a Glance

```
Client
  └─► Nginx (port 80)
        ├─► Frontend (React SPA, served as static files)
        └─► Backend API (FastAPI on port 8000)
              ├─► PostgreSQL (persistent data)
              ├─► Redis (cache + job queues)
              └─► Worker (RQ background jobs)
```

**One command to start everything:**
```bash
# Linux / WSL — pick the tier that matches your machine
./infra/scripts/deploy.sh --profile prod --target local --hw tiny    # laptop  2-4 cores / 4-8 GB
./infra/scripts/deploy.sh --profile prod --target local --hw small   # workstation 4-8 cores / 8-16 GB
./infra/scripts/deploy.sh --profile prod --target local --hw medium  # server  8-32 cores / 32-64 GB

# Windows PowerShell
.\infra\scripts\deploy.ps1 -Profile prod -Target local -Hw small
```

> **Why `--hw`?** The default limits are sized for a 96-core cloud server.
> Without the flag Docker will try to allocate more memory than your machine has and the stack will hang.
> See [Hardware Profiles](12-hardware-profiles.md) to pick your tier.
