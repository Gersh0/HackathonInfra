#!/usr/bin/env bash
# =============================================================================
# check.sh — Validate all Terraform modules without deploying
# =============================================================================
# Runs fmt-check, init, and validate against all three modules:
#   infra/local/  infra/aws/  infra/remote/
#
# Usage:
#   ./infra/check.sh [--plan] [--target local|aws|remote] [--var-file FILE]
#
# Options:
#   --plan                  Run terraform plan (read-only, never apply)
#   --target TARGET         Validate only one target (local | aws | remote)
#   --var-file FILE         tfvars file to use for plan (required with --plan)
#   -h, --help              Show this help
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RUN_PLAN=0
TARGET="all"
VAR_FILE=""

usage() {
  cat <<'USAGE'
Usage: ./infra/check.sh [--plan] [--target local|aws|remote] [--var-file FILE]

Options:
  --plan                  Include a read-only terraform plan (no deploy).
  --target TARGET         Validate only one target: local | aws | remote
  --var-file FILE         tfvars file for plan. Required when --plan is set.
  -h, --help              Show this help.

Examples:
  ./infra/check.sh
  ./infra/check.sh --target aws --plan --var-file infra/envs/aws.tfvars
  ./infra/check.sh --target local
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --plan)
      RUN_PLAN=1
      ;;
    --target=*)
      TARGET="${arg#*=}"
      ;;
    --target)
      ;;
    --var-file=*)
      VAR_FILE="${arg#*=}"
      ;;
    --var-file)
      ;;
    -h|--help)
      usage; exit 0
      ;;
  esac
done

# Support space-separated --target and --var-file
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    --target)   TARGET="${args[$((i+1))]}" ;;
    --var-file) VAR_FILE="${args[$((i+1))]}" ;;
  esac
done

if [[ ! "$TARGET" =~ ^(all|local|aws|remote)$ ]]; then
  echo "Error: --target must be 'all', 'local', 'aws', or 'remote'" >&2
  exit 1
fi

if [[ "$RUN_PLAN" -eq 1 && -z "$VAR_FILE" ]]; then
  echo "Error: --var-file is required when using --plan" >&2
  echo "Examples:" >&2
  echo "  --var-file infra/envs/aws.tfvars" >&2
  echo "  --var-file infra/envs/local.tfvars" >&2
  exit 1
fi

# ─── Per-module check ────────────────────────────────────────────────────────

check_module() {
  local name="$1"
  local module_dir="${SCRIPT_DIR}/${name}"

  if [[ ! -d "$module_dir" ]]; then
    echo "Skip ${name}: directory not found"
    return
  fi

  echo ""
  echo "━━━ Module: ${name} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  cd "$module_dir"

  echo "==> terraform fmt -check"
  terraform fmt -check -recursive

  echo "==> terraform init -backend=false"
  terraform init -backend=false -input=false

  echo "==> terraform validate"
  terraform validate

  if [[ "$RUN_PLAN" -eq 1 ]]; then
    local abs_var_file
    abs_var_file="$(cd "${SCRIPT_DIR}/.." && pwd)/${VAR_FILE#infra/}"
    # Also try as-is (absolute or relative to CWD)
    if [[ ! -f "$abs_var_file" ]]; then
      abs_var_file="$VAR_FILE"
    fi

    if [[ ! -f "$abs_var_file" ]]; then
      echo "Skip plan for ${name}: var-file '${VAR_FILE}' not found."
    else
      echo "==> terraform plan -detailed-exitcode"
      set +e
      terraform plan \
        -input=false \
        -lock=false \
        -detailed-exitcode \
        -var-file="$abs_var_file"
      plan_rc=$?
      set -e
      if [[ "$plan_rc" -eq 0 ]]; then
        echo "Plan OK: no changes."
      elif [[ "$plan_rc" -eq 2 ]]; then
        echo "Plan OK: changes detected (nothing was deployed)."
      else
        echo "Plan failed (exit ${plan_rc})" >&2
        exit "$plan_rc"
      fi
    fi
  fi

  echo "OK: ${name}"
}

# ─── Run ─────────────────────────────────────────────────────────────────────

# fmt check is recursive from infra/ root — catches all modules at once
echo "==> terraform fmt -check -recursive (all modules)"
cd "$SCRIPT_DIR"
terraform fmt -check -recursive

if [[ "$TARGET" == "all" ]]; then
  check_module "local"
  check_module "aws"
  check_module "remote"
else
  check_module "$TARGET"
fi

echo ""
echo "All checks passed."
