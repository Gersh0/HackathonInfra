# Local Terraform

Manages your local Docker Compose deployment via Terraform state — without touching any cloud infrastructure.

On `apply` it runs `docker compose ... up -d`. On `destroy` it runs `docker compose ... down`.

---

## Prerequisites

- Docker Engine running locally
- `cp .env.template .env` at the project root (filled in)
- Terraform ≥ 1.5.0

---

## Usage

```bash
cd infra/local

# Development stack (hot reload)
terraform init
terraform apply -var='profile=dev'

# Production stack
terraform apply -var='profile=prod'

# Tear down
terraform destroy -var='profile=dev'
```

---

## Key variables

| Variable | Default | Description |
|----------|---------|-------------|
| `profile` | `dev` | `dev` or `prod` |
| `build_images` | `true` | Add `--build` on apply |
| `services` | *(all)* | Subset of services, e.g. `["backend","worker"]` |
| `remove_volumes_on_destroy` | `false` | Run `down --volumes` on destroy |
| `force_redeploy_token` | `""` | Change this value to force a redeploy |

```bash
# Target specific services only
terraform apply \
  -var='profile=dev' \
  -var='services=["postgres","redis","backend"]'
```

---

> Prefer running Docker Compose directly? See [Quickstart — Linux](../../docs/03-quickstart-linux.md) or [Quickstart — Windows](../../docs/02-quickstart-windows.md).
