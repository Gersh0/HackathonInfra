# AWS EC2 Deployment

This guide deploys the application to a single AWS EC2 instance using Terraform.

Terraform provisions the instance, security group, and optional Elastic IP. A `user_data` boot script installs Docker, clones the repo, writes the `.env`, and starts the stack automatically.

---

## Prerequisites

| Requirement | Install |
|-------------|---------|
| Terraform >= 1.5.0 | [terraform.io/downloads](https://developer.hashicorp.com/terraform/downloads) |
| AWS CLI v2 | [aws.amazon.com/cli](https://aws.amazon.com/cli/) |
| AWS credentials configured | `aws configure` or environment variables |
| Git repo pushed to a remote (GitHub, etc.) | The EC2 instance clones from this URL |

### Configure AWS credentials

```bash
# Option A: AWS CLI interactive setup
aws configure

# Option B: Environment variables
export AWS_ACCESS_KEY_ID=your_key_id
export AWS_SECRET_ACCESS_KEY=your_secret_key
export AWS_DEFAULT_REGION=us-east-1
```

Verify:

```bash
aws sts get-caller-identity
```

---

## Step 1 — Configure infrastructure variables

```bash
# Linux / macOS / WSL
cp infra/envs/aws.tfvars.example infra/envs/aws.tfvars

# Windows PowerShell
Copy-Item infra\envs\aws.tfvars.example infra\envs\aws.tfvars
```

Edit `infra/envs/aws.tfvars` and fill in the required values:

```hcl
# The HTTPS URL of your Git repository (EC2 will clone this)
repo_url = "https://github.com/your-org/your-repo.git"

# Branch or tag to deploy
repo_ref = "main"

# AWS region
aws_region = "us-east-1"

# EC2 instance type
# Recommended for production: c5.4xlarge (16 vCPU, 32 GB)
# For testing: t3.medium
instance_type = "c5.4xlarge"

# Database credentials (written to .env on EC2)
postgres_user     = "your_db_user"
postgres_password = "YourStrongPassword123!"

# JWT secret (min 32 characters, randomly generated)
jwt_secret_key = "your_generated_jwt_secret_here"

# Redis password (set a strong value for production; empty = no auth)
redis_password = "YourRedisPassword456!"

# Optional: restrict SSH access (set key_name to enable SSH)
# key_name        = "my-existing-keypair"
# ssh_cidr_blocks = ["YOUR.IP.ADDRESS/32"]
```

> **Security:** `infra/envs/aws.tfvars` is in `.gitignore`. Never commit it.

---

## Step 2 — Choose a hardware tier

The deploy script accepts a `--hw` flag that sets CPU limits, memory limits, worker counts, and PostgreSQL/Redis tuning for the target machine. **Always pass `--hw` — omitting it applies the `large` defaults (96 CPU / 192 GB) which will crash or hang on anything smaller.**

| Instance type | vCPU | RAM | `--hw` tier |
|--------------|------|-----|-------------|
| `t3.medium` | 2 | 4 GB | `tiny` |
| `t3.xlarge` / `c5.xlarge` | 4 | 8–16 GB | `small` |
| `c5.4xlarge` | 16 | 32 GB | `medium` |
| `c5.9xlarge` | 36 | 72 GB | `medium` |
| `c5.24xlarge` / `c5d.24xlarge` | 96 | 192 GB | `large` |

> For full details on what each tier controls see [Hardware Profiles](12-hardware-profiles.md).

---

## Step 3 — Configure application environment

The secrets in `infra/envs/aws.tfvars` (`postgres_password`, `jwt_secret_key`, `redis_password`) are read by Terraform and written to the EC2 instance's `.env` file at boot time.

The root `.env` is for **local Docker Compose** only. It is not used by Terraform.

---

## Step 4 — Deploy

### Linux / macOS / WSL (recommended — uses the deploy script)

```bash
# c5.24xlarge (96 vCPU / 192 GB)
./infra/scripts/deploy.sh --profile prod --target aws --hw large

# c5.4xlarge / c5.9xlarge (16–36 vCPU / 32–72 GB)
./infra/scripts/deploy.sh --profile prod --target aws --hw medium

# t3.xlarge / c5.xlarge (4 vCPU / 8–16 GB)
./infra/scripts/deploy.sh --profile prod --target aws --hw small
```

The deploy script:
1. Validates `.env` exists and required secrets are set
2. Loads the hardware profile (CPU/memory limits, concurrency)
3. Runs `terraform init` if needed
4. Runs `terraform apply`
5. Prints the application URL

### Linux / macOS / WSL (Terraform directly — advanced)

> The deploy script is the recommended path. Use Terraform directly only if you need
> fine-grained control. You must load the hw variables manually before running Terraform.

```bash
# Load hw variables so Terraform passes correct limits to EC2
source infra/envs/hw-large.env    # adjust tier: tiny / small / medium / large

cd infra/aws
terraform init
terraform plan  -var-file=../envs/aws.tfvars
terraform apply -var-file=../envs/aws.tfvars
```

### Windows PowerShell

```powershell
# c5.24xlarge
.\infra\scripts\deploy.ps1 -Profile prod -Target aws -Hw large

# c5.4xlarge / c5.9xlarge
.\infra\scripts\deploy.ps1 -Profile prod -Target aws -Hw medium

# t3.xlarge / c5.xlarge
.\infra\scripts\deploy.ps1 -Profile prod -Target aws -Hw small
```

---

## Step 5 — Wait for EC2 boot

After `terraform apply` completes, the EC2 instance starts the boot script:
1. Installs Docker and Docker Compose (~2 minutes)
2. Clones the repository
3. Writes `.env`
4. Runs `docker compose --profile prod up -d` (builds images, ~5–10 minutes)

**Monitor boot progress (requires SSH key configured):**

```bash
ssh ubuntu@$(terraform output -raw public_ip) \
  "sudo tail -f /var/log/youtube-clone-provision.log"
```

**Check application status:**

```bash
# Get the URL
terraform output app_url

# Check all containers are running
ssh ubuntu@$(terraform output -raw public_ip) \
  "cd /opt/youtube-clone && sudo docker compose --profile prod ps"
```

---

## Step 6 — Access the application

```bash
terraform output app_url
```

Open the URL in a browser. The application is ready when the health check responds:

```bash
curl http://$(terraform output -raw public_ip)/api/health
# {"status": "ok"}
```

---

## Useful Terraform commands

```bash
# Show outputs (URLs, IPs)
terraform output

# Show just the public IP
terraform output -raw public_ip

# Show just the app URL
terraform output app_url

# SSH to the instance (requires key_name set)
ssh ubuntu@$(terraform output -raw public_ip)

# Destroy all resources (terminates EC2, deletes security group)
terraform destroy -var-file=../envs/aws.tfvars
```

---

## Validate without deploying

Run checks without applying:

```bash
cd infra
./check.sh            # fmt, validate
./check.sh --plan     # fmt, validate, plan (read-only)
```

---

## Networking

By default:
- HTTP port 80 is open to the internet (`http_cidr_blocks = ["0.0.0.0/0"]`)
- SSH port 22 is **closed** (no key pair set)
- Uses the AWS account's default VPC and first subnet

To restrict access or use a custom VPC, set in `aws.tfvars`:

```hcl
# Custom VPC
vpc_id    = "vpc-xxxxxxxxxxxxxxxxx"
subnet_id = "subnet-xxxxxxxxxxxxxxxxx"

# Restrict HTTP to specific IPs
http_cidr_blocks = ["203.0.113.0/24"]

# Enable SSH
key_name        = "my-keypair-name"
ssh_cidr_blocks = ["203.0.113.10/32"]
```

---

## HTTPS / SSL

Terraform currently provisions HTTP only. To add HTTPS:

1. Register a domain and point it to the EC2 Elastic IP
2. Install Certbot on the EC2 instance:
   ```bash
   sudo apt install certbot python3-certbot-nginx
   sudo certbot --nginx -d yourdomain.com
   ```
3. Update `CORS_ALLOW_ORIGINS` in the `.env` on EC2 to include `https://yourdomain.com`
4. Restart the backend: `sudo docker compose --profile prod restart backend`

---

## Updating a running deployment

**Option A — re-run the deploy script from your workstation (recommended):**

```bash
# This re-runs terraform apply → triggers docker compose up --build on EC2
./infra/scripts/deploy.sh --profile prod --target aws --hw large   # match your instance tier

# Windows PowerShell
.\infra\scripts\deploy.ps1 -Profile prod -Target aws -Hw large
```

**Option B — SSH directly into EC2 and rebuild manually:**

```bash
ssh ubuntu@$(terraform output -raw public_ip)
cd /opt/youtube-clone
git pull

# Load the hw preset that matches your instance type BEFORE running compose
source infra/envs/hw-large.env   # adjust: tiny / small / medium / large
sudo -E docker compose --profile prod up -d --build
```

> Without `source infra/envs/hw-large.env`, Docker will fall back to the bare `.env` defaults
> which are sized for a 96-core c5.24xlarge and will crash or hang on smaller instances.

---

## State file security

Terraform state (`terraform.tfstate`) contains plaintext secrets. It is in `.gitignore` and must never be committed.

For team use, move state to an encrypted S3 backend:

```hcl
# infra/aws/main.tf — add backend block
terraform {
  backend "s3" {
    bucket         = "your-terraform-state-bucket"
    key            = "youtube-clone/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-lock"  # optional: state locking
  }
}
```

---

[← Development Guide](06-development.md) · [Wiki Index](index.md) · [Monitoring →](08-monitoring.md)
