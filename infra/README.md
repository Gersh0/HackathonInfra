# Infrastructure - Terraform for AWS EC2

This module provisions one AWS EC2 instance for the production-like single-node stack. Terraform creates the host, security group, and optional Elastic IP. EC2 cloud-init then installs Docker/Compose, clones this repo, writes the application `.env`, and starts:

```bash
docker compose --profile prod up -d
```

Terraform variables are separate from the application `.env` file:

- Local PC runtime config: copy root `.env.template` to root `.env`
- AWS infrastructure config: copy `infra/envs/aws.tfvars.example` to `infra/envs/aws.tfvars`

If you want to run Docker containers on this same development PC using Terraform (no AWS resources), use [`infra/local/README.md`](./local/README.md).

## Prerequisites

- Terraform >= 1.5.0
- AWS credentials configured in your shell, environment, or AWS CLI profile
- A pushed Git repository URL that the EC2 instance can clone
- Optional: an existing AWS EC2 key pair if you want SSH access

## Quick Start - Linux/macOS/WSL (recommended)

Use the deploy script, which loads the root `.env` for secrets and the env-specific tfvars for infrastructure settings:

```bash
cp infra/envs/aws.tfvars.example infra/envs/aws.tfvars
# Edit infra/envs/aws.tfvars with your values (repo_url, instance type, etc.)
./infra/scripts/deploy.sh --profile prod --target aws
```

## Quick Start - Terraform directly (Linux/macOS/Git Bash)

```bash
cp envs/aws.tfvars.example envs/aws.tfvars
# Edit envs/aws.tfvars with your values
cd aws
terraform init
terraform plan -var-file=../envs/aws.tfvars
terraform apply -var-file=../envs/aws.tfvars
```

## Quick Start - Windows PowerShell

```powershell
Copy-Item envs\aws.tfvars.example envs\aws.tfvars
# Edit envs\aws.tfvars with your values
Set-Location aws
terraform init
terraform plan -var-file="..\envs\aws.tfvars"
terraform apply -var-file="..\envs\aws.tfvars"
```

After apply completes, use the `app_url` output. First boot can take several minutes because EC2 installs Docker and builds the backend/frontend images.

## Required Values

At minimum, edit these in `infra/envs/aws.tfvars`:

- `repo_url`: HTTPS Git URL for this project
- `repo_ref`: branch or tag to deploy, default `main`
- `postgres_user`: database username
- `postgres_password`: database password, minimum 12 characters
- `jwt_secret_key`: JWT secret, minimum 32 characters
- `redis_password`: set a strong value for production, or empty only for dev-like use

Prefer URL-safe generated secrets, for example `python -c "import secrets; print(secrets.token_urlsafe(24))"`, because the EC2 boot script writes them into a Compose `.env` file.

## AWS Networking

By default Terraform uses the account default VPC and first subnet in that VPC. Override these if your AWS account has no default VPC:

```hcl
vpc_id    = "vpc-..."
subnet_id = "subnet-..."
```

HTTP is open to the internet by default:

```hcl
http_cidr_blocks = ["0.0.0.0/0"]
```

SSH is closed by default. To enable it, set an existing EC2 key pair and restrict SSH to your public IP:

```hcl
key_name        = "my-existing-keypair"
ssh_cidr_blocks = ["203.0.113.10/32"]
```

## Useful Commands

```bash
terraform output app_url
terraform output public_ip
terraform destroy
```

## Check Without Deploying

Use the local helper script to run safe checks without `terraform apply`:

```bash
cd infra
./check.sh
```

This runs:

- `terraform fmt -check -recursive`
- `terraform init -backend=false -input=false`
- `terraform validate`

To include a read-only plan (still no deploy):

```bash
cd infra/aws
cp ../envs/aws.tfvars.example ../envs/aws.tfvars
# Edit ../envs/aws.tfvars with your values
cd ..
./check.sh --plan
```

`--plan` uses `terraform plan -detailed-exitcode -lock=false` and never runs apply.

If SSH is enabled:

```bash
ssh ubuntu@$(terraform output -raw public_ip)
sudo tail -f /var/log/youtube-clone-provision.log
cd /opt/youtube-clone
sudo docker compose --profile prod ps
```

## State File Security

Terraform state contains sensitive data. In this module, user-data writes the application `.env` on EC2, so Terraform state can contain `POSTGRES_PASSWORD`, `JWT_SECRET_KEY`, `REDIS_PASSWORD`, and generated connection URLs.

Do not commit these files:

- `infra/envs/aws.tfvars`
- `infra/envs/remote.tfvars`
- `terraform.tfstate`
- `terraform.tfstate.backup`
- `.terraform/`

For shared or production use, move state to an encrypted remote backend such as S3 with SSE-KMS and restrict state access with IAM. Rotate secrets immediately if a state file is exposed.

## Troubleshooting AWS Deployment

### Common Issues

**❌ "Error creating EC2 instance"**
- Check AWS credentials: `aws sts get-caller-identity`
- Verify region has available capacity for instance type
- Check VPC/subnet configuration in `aws.tfvars`
- Ensure AWS quotas allow the instance type

**❌ "Application not accessible after deployment"**
- Wait 5-10 minutes for Docker installation and image builds
- Check security group allows HTTP (port 80) from your IP
- Verify `http_cidr_blocks = ["0.0.0.0/0"]` in `aws.tfvars` 
- SSH into instance and check logs: `sudo tail -f /var/log/youtube-clone-provision.log`

**❌ "SSH connection refused"**
- Verify `key_name` is set to an existing EC2 keypair in `aws.tfvars`
- Check `ssh_cidr_blocks` includes your current public IP
- Confirm security group SSH rule was created: check AWS Console
- Use correct SSH key: `ssh -i ~/.ssh/your-keypair.pem ubuntu@$(terraform output -raw public_ip)`

**❌ "Docker build failing on EC2"**
- SSH into instance: `ssh ubuntu@$(terraform output -raw public_ip)`
- Check build logs: `sudo journalctl -u cloud-final.service`
- Manually retry build: `cd /opt/youtube-clone && sudo docker compose --profile prod up --build`

### Monitoring Deployment Progress

```bash
# Get instance IP
terraform output public_ip

# SSH into instance (if SSH enabled)
ssh -i ~/.ssh/your-keypair.pem ubuntu@$(terraform output -raw public_ip)

# Check cloud-init progress
sudo tail -f /var/log/cloud-init-output.log

# Check application specific logs
sudo tail -f /var/log/youtube-clone-provision.log

# Check application status
cd /opt/youtube-clone
sudo docker compose --profile prod ps
sudo docker compose --profile prod logs -f
```

### Cost Optimization

**Instance sizing guidelines:**
- **t3.small** (2 vCPU, 2 GB): Development/testing (≤1000 users)
- **t3.medium** (2 vCPU, 4 GB): Light production (≤2000 users)  
- **c6i.large** (2 vCPU, 4 GB): Performance testing (≤3000 users)
- **c6i.xlarge** (4 vCPU, 8 GB): High-performance production (3000+ users)

**Monthly cost estimates (US-East-1):**
- t3.small: ~$15-20
- t3.medium: ~$30-40
- c6i.large: ~$60-80
- c6i.xlarge: ~$120-160

*Estimates exclude data transfer, storage, and Elastic IP costs.*

**Cost optimization tips:**
- Use `terraform destroy` when not needed
- Consider Spot instances for development (`spot_instance = true`)
- Set up CloudWatch alarms for unexpected usage
- Use smaller instance types for initial testing
