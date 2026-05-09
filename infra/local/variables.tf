variable "profile" {
  description = "Docker Compose profile to deploy on this machine."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "prod"], var.profile)
    error_message = "profile must be either 'dev' or 'prod'."
  }
}

variable "build_images" {
  description = "Whether to run docker compose up with --build."
  type        = bool
  default     = true
}

variable "services" {
  description = "Optional list of compose services to deploy. Leave empty to deploy all services in the profile."
  type        = list(string)
  default     = []
}

variable "remove_volumes_on_destroy" {
  description = "Whether to include --volumes when Terraform destroys the local stack."
  type        = bool
  default     = false
}

variable "force_redeploy_token" {
  description = "Change this string to force a recreate and rerun docker compose even if files did not change."
  type        = string
  default     = ""
}
