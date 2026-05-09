variable "aws_region" {
  description = "AWS region where the EC2 instance will be created."
  type        = string
  default     = "us-east-2"
}

variable "project_name" {
  description = "Short name used for AWS resource names and tags."
  type        = string
  default     = "youtube-clone"
}

variable "environment" {
  description = "Deployment environment label used for names and tags."
  type        = string
  default     = "prod"
}

variable "vpc_id" {
  description = "Existing VPC ID. Leave empty to use the AWS account default VPC."
  type        = string
  default     = ""
}

variable "subnet_id" {
  description = "Existing public subnet ID. Leave empty to use the first subnet in the selected/default VPC."
  type        = string
  default     = ""
}

variable "ami_id" {
  description = "Optional Ubuntu AMI override. Leave empty to use the latest Ubuntu 24.04 LTS amd64 AMI."
  type        = string
  default     = ""
}

variable "instance_type" {
  description = "EC2 instance type for the single-node stack."
  type        = string
  # c5.24xlarge: 96 vCPU · 192 GB RAM · 25 Gbps network (sin NVMe local)
  default     = "c5.24xlarge"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GiB. Increase this for large media uploads."
  type        = number
  default     = 100

  validation {
    condition     = var.root_volume_size_gb >= 30
    error_message = "root_volume_size_gb must be at least 30."
  }
}

variable "create_eip" {
  description = "Whether to allocate and attach an Elastic IP for a stable public address."
  type        = bool
  default     = false
}

variable "key_name" {
  description = "Existing EC2 key pair name for SSH access. Leave empty to deploy without SSH key access."
  type        = string
  default     = ""
}

variable "http_cidr_blocks" {
  description = "CIDR blocks allowed to reach Nginx over HTTP/80."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ssh_cidr_blocks" {
  description = "CIDR blocks allowed to reach SSH/22. Leave empty to keep SSH closed."
  type        = list(string)
  default     = []
}

variable "repo_url" {
  description = "Git URL that the EC2 instance will clone during boot. Use an HTTPS URL the instance can read."
  type        = string

  validation {
    condition     = length(trimspace(var.repo_url)) > 0
    error_message = "repo_url is required because the EC2 instance must clone the application repository."
  }
}

variable "repo_ref" {
  description = "Git branch or tag to deploy."
  type        = string
  default     = "main"
}

variable "app_env" {
  description = "Application environment injected into the Compose .env file."
  type        = string
  default     = "production"
}

variable "postgres_db" {
  description = "PostgreSQL database name."
  type        = string
  default     = "youtube_clone"
}

variable "postgres_user" {
  description = "PostgreSQL application username."
  type        = string
  sensitive   = true
}

variable "postgres_password" {
  description = "PostgreSQL application password."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.postgres_password) >= 12
    error_message = "postgres_password must be at least 12 characters."
  }
}

variable "redis_password" {
  description = "Redis password. Leave empty only for local/dev-like deployments."
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = var.redis_password == "" || length(var.redis_password) >= 12
    error_message = "redis_password must be empty or at least 12 characters."
  }
}

variable "jwt_secret_key" {
  description = "JWT signing secret."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.jwt_secret_key) >= 32
    error_message = "jwt_secret_key must be at least 32 characters."
  }
}

variable "jwt_access_token_exp_minutes" {
  description = "JWT access token lifetime in minutes."
  type        = number
  default     = 120
}

variable "auth_token_issuer_enabled" {
  description = "Enable POST /auth/token outside development."
  type        = bool
  default     = false
}

variable "cors_allow_origins" {
  description = "Allowed CORS origins for browser clients."
  type        = list(string)
  default = [
    "http://localhost:5173",
    "http://127.0.0.1:5173",
    "http://localhost",
    "http://127.0.0.1",
  ]
}

# ── Gunicorn / worker concurrency ─────────────────────────────────────────────

variable "backend_web_concurrency" {
  description = "Gunicorn worker count. For UvicornWorker (async) use ~vCPU count; formula: 2*vCPU+1."
  type        = number
  # c5d.24xlarge: 96 vCPUs → 2*96+1 = 193; we use 97 (vCPU+1) for async workers.
  default     = 97

  validation {
    condition     = var.backend_web_concurrency >= 2
    error_message = "backend_web_concurrency must be at least 2."
  }
}

variable "worker_concurrency" {
  description = "Number of RQ worker processes launched inside the worker container."
  type        = number
  # c5d.24xlarge: 12 worker CPUs allocated → use 12 processes.
  default     = 12

  validation {
    condition     = var.worker_concurrency >= 1
    error_message = "worker_concurrency must be at least 1."
  }
}

# ── SQLAlchemy connection pool ─────────────────────────────────────────────────
# Total Postgres connections ≤ backend_web_concurrency × (db_pool_size + db_max_overflow)
# With defaults: 97 × (5+5) = 970 → set postgres_max_connections ≥ 1000.

variable "db_pool_size" {
  description = "SQLAlchemy pool_size per Gunicorn worker process."
  type        = number
  default     = 5

  validation {
    condition     = var.db_pool_size >= 1
    error_message = "db_pool_size must be at least 1."
  }
}

variable "db_max_overflow" {
  description = "SQLAlchemy max_overflow per Gunicorn worker process."
  type        = number
  default     = 5

  validation {
    condition     = var.db_max_overflow >= 0
    error_message = "db_max_overflow must be non-negative."
  }
}

# ── PostgreSQL tuning ──────────────────────────────────────────────────────────

variable "postgres_max_connections" {
  description = "PostgreSQL max_connections. Must be > backend_web_concurrency × (db_pool_size + db_max_overflow)."
  type        = number
  default     = 1000
}

variable "postgres_shared_buffers" {
  description = "PostgreSQL shared_buffers. Use ~25% of RAM allocated to the postgres container."
  type        = string
  # postgres container gets 64 GB → 25% = 16 GB
  default     = "16GB"
}

variable "postgres_effective_cache_size" {
  description = "PostgreSQL effective_cache_size. Use ~75% of RAM allocated to the postgres container."
  type        = string
  # 75% of 64 GB = 48 GB
  default     = "48GB"
}

variable "postgres_work_mem" {
  description = "PostgreSQL work_mem per sort/hash operation (not per connection)."
  type        = string
  default     = "16MB"
}

variable "postgres_maintenance_work_mem" {
  description = "PostgreSQL maintenance_work_mem for VACUUM, CREATE INDEX, etc."
  type        = string
  default     = "2GB"
}

variable "postgres_shm_size" {
  description = "Shared memory for the postgres Docker container (Docker format, e.g. '20g'). Must be >= shared_buffers."
  type        = string
  # 20 GB covers 16 GB shared_buffers with headroom.
  default     = "20g"
}

# ── Redis tuning ───────────────────────────────────────────────────────────────

variable "redis_maxmemory" {
  description = "Redis maxmemory limit (Redis format, e.g. '16gb'). Triggers allkeys-lru eviction."
  type        = string
  default     = "16gb"
}

variable "redis_max_connections" {
  description = "Max Redis connections per backend/worker instance (Redis connection pool size)."
  type        = number
  default     = 50
}

# ── Docker container resource limits ──────────────────────────────────────────
# Sized for c5d.24xlarge (96 vCPU / 192 GB RAM).
# Total: nginx(4)+postgres(24)+redis(4)+backend(48)+worker(12)+frontend(4) = 96 CPUs
#        2G+64G+18G+48G+16G+4G = 152 GB RAM (40 GB headroom for OS + Docker)

variable "nginx_cpu_limit" {
  description = "CPU limit for the nginx container."
  type        = string
  default     = "4.00"
}

variable "nginx_memory_limit" {
  description = "Memory limit for the nginx container (Docker format)."
  type        = string
  default     = "2G"
}

variable "postgres_cpu_limit" {
  description = "CPU limit for the postgres container."
  type        = string
  default     = "24.00"
}

variable "postgres_memory_limit" {
  description = "Memory limit for the postgres container (Docker format)."
  type        = string
  default     = "64G"
}

variable "redis_cpu_limit" {
  description = "CPU limit for the redis container."
  type        = string
  default     = "4.00"
}

variable "redis_memory_limit" {
  description = "Memory limit for the redis container (Docker format). Must be > redis_maxmemory."
  type        = string
  default     = "18G"
}

variable "backend_cpu_limit" {
  description = "CPU limit for the backend container."
  type        = string
  default     = "48.00"
}

variable "backend_memory_limit" {
  description = "Memory limit for the backend container (Docker format)."
  type        = string
  default     = "48G"
}

variable "worker_cpu_limit" {
  description = "CPU limit for the worker container."
  type        = string
  default     = "12.00"
}

variable "worker_memory_limit" {
  description = "Memory limit for the worker container (Docker format)."
  type        = string
  default     = "16G"
}

variable "frontend_cpu_limit" {
  description = "CPU limit for the frontend container."
  type        = string
  default     = "4.00"
}

variable "frontend_memory_limit" {
  description = "Memory limit for the frontend container (Docker format)."
  type        = string
  default     = "4G"
}

variable "tags" {
  description = "Additional tags to apply to AWS resources."
  type        = map(string)
  default     = {}
}
