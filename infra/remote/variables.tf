variable "host" {
  description = "Hostname or IP address of the remote Linux server."
  type        = string

  validation {
    condition     = length(trimspace(var.host)) > 0
    error_message = "host is required."
  }
}

variable "ssh_user" {
  description = "SSH username on the remote server. Must have sudo/root privileges."
  type        = string
  default     = "ubuntu"
}

variable "ssh_private_key_path" {
  description = "Absolute path to the SSH private key file on the machine running Terraform. Terraform does not expand '~' in variable values."
  type        = string

  validation {
    condition     = length(trimspace(var.ssh_private_key_path)) > 0 && startswith(var.ssh_private_key_path, "/")
    error_message = "ssh_private_key_path must be set to a non-empty absolute path (for example, /home/user/.ssh/id_rsa). Do not use '~'."
  }
}

variable "ssh_port" {
  description = "SSH port on the remote server."
  type        = number
  default     = 22
}

variable "project_name" {
  description = "Short project name. Used as the remote deployment directory name under /opt/."
  type        = string
  default     = "youtube-clone"
}

variable "profile" {
  description = "Docker Compose profile to activate on the remote server."
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "prod"], var.profile)
    error_message = "profile must be 'dev' or 'prod'."
  }
}

variable "repo_url" {
  description = "Git HTTPS URL the remote server will clone."
  type        = string

  validation {
    condition     = length(trimspace(var.repo_url)) > 0
    error_message = "repo_url is required."
  }
}

variable "repo_ref" {
  description = "Git branch or tag to deploy."
  type        = string
  default     = "main"
}

variable "app_env" {
  description = "Value for APP_ENV written into the remote .env file."
  type        = string
  default     = "production"
}

variable "postgres_db" {
  description = "PostgreSQL database name."
  type        = string
  default     = "youtube_clone"
}

variable "postgres_user" {
  description = "PostgreSQL username."
  type        = string
  sensitive   = true
}

variable "postgres_password" {
  description = "PostgreSQL password."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.postgres_password) >= 12
    error_message = "postgres_password must be at least 12 characters."
  }
}

variable "redis_password" {
  description = "Redis password. Leave empty to disable Redis authentication."
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = var.redis_password == "" || length(var.redis_password) >= 12
    error_message = "redis_password must be empty or at least 12 characters."
  }
}

variable "jwt_secret_key" {
  description = "JWT signing secret (minimum 32 characters)."
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

variable "cors_allow_origins" {
  description = "Allowed CORS origins."
  type        = list(string)
  default = [
    "http://localhost:5173",
    "http://127.0.0.1:5173",
    "http://localhost",
    "http://127.0.0.1",
  ]
}

variable "backend_web_concurrency" {
  description = "Gunicorn worker count."
  type        = number
  default     = 4

  validation {
    condition     = var.backend_web_concurrency >= 2
    error_message = "backend_web_concurrency must be at least 2."
  }
}

variable "worker_concurrency" {
  description = "RQ worker process count."
  type        = number
  default     = 2

  validation {
    condition     = var.worker_concurrency >= 1
    error_message = "worker_concurrency must be at least 1."
  }
}

variable "force_redeploy_token" {
  description = "Change this string to force a full redeploy even if no other variables changed."
  type        = string
  default     = ""
}
