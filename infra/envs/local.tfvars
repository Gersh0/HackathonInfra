# =============================================================================
# LOCAL DEPLOYMENT SETTINGS
# =============================================================================
# Used by deploy.sh / deploy.ps1 when --target local is specified.
# The --profile flag (dev|prod) is passed separately by the deploy script.
#
# This file is safe to commit — it contains no secrets.
# =============================================================================

build_images              = true
remove_volumes_on_destroy = false

# Uncomment to deploy only specific services:
# services = ["postgres", "redis", "backend"]

# Uncomment to force a redeploy without file changes:
# force_redeploy_token = "v2"
