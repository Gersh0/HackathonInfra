# Security Policy

## Supported Versions

Only the latest code on `main` is actively supported for security fixes.

---

## What Must Never Be Committed

| File/Pattern | Reason |
|-------------|--------|
| `.env` | Contains passwords and JWT secrets |
| `infra/envs/aws.tfvars` | Contains database credentials for production |
| `infra/envs/remote.tfvars` | Remote backend credentials |
| `terraform.tfstate` / `*.tfstate.backup` | Contains plaintext secrets written by Terraform |
| `*.ppk`, `*.pem`, `*.key` | SSH private keys |
| Any file with real passwords or tokens | Self-evident |

All of the above are in `.gitignore`. Never use `--force` or `-f` to override git's ignoring of these files.

---

## Required Security Configuration

Before running in production:

1. **Generate a strong `JWT_SECRET_KEY`** (min 32 characters):
   ```bash
   openssl rand -base64 48
   ```

2. **Use a strong `POSTGRES_PASSWORD`** (min 12 characters, URL-safe for DATABASE_URL compatibility):
   ```bash
   python3 -c "import secrets; print(secrets.token_urlsafe(24))"
   ```

3. **Set `REDIS_PASSWORD`** for production deployments.

4. **Restrict `CORS_ALLOW_ORIGINS`** to your actual domain(s) in production.

5. **Rotate secrets** if they are ever exposed (leaked to git, shared in chat, etc.).

---

## Reporting a Vulnerability

Do not open a public GitHub issue for security vulnerabilities.

Report privately to the repository maintainers with:
- Summary of the vulnerability
- Estimated impact
- Reproduction steps
- Affected component(s)
- Suggested mitigation (optional)

Keep details private until a fix is released.

---

## Response Targets

| Stage | Target |
|-------|--------|
| Initial acknowledgement | Within 72 hours |
| Triage decision | Within 7 days |
| Fix and disclosure | Depends on severity |

---

## Severity Classification

| Severity | Examples |
|----------|---------|
| Critical | Remote code execution, auth bypass, mass data exposure |
| High | Privilege escalation, major abuse vectors |
| Medium | Constrained impact, requires specific conditions |
| Low | Minor hardening issues, defense in depth |
