#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Single-command deployment entrypoint (Linux / WSL)
# =============================================================================
#
# Usage:
#   ./infra/scripts/deploy.sh --profile <dev|prod> --target <local|aws|remote>
#   ./infra/scripts/deploy.sh --profile dev  --target local
#   ./infra/scripts/deploy.sh --profile prod --target local
#   ./infra/scripts/deploy.sh --profile prod --target aws
#   ./infra/scripts/deploy.sh --profile prod --target remote
#
# Options:
#   --profile   dev | prod                   (required)
#   --target    local | aws | remote         (required)
#   --action    plan | apply | destroy       (default: apply)
#   --no-build  Skip --build on docker compose (local target only)
#   -h, --help  Show this help
#
# Prerequisites:
#   - Docker + docker compose plugin (local target)
#   - Terraform >= 1.5.0 (all targets)
#   - AWS CLI configured (aws target)
#   - Root .env file filled in (cp .env.template .env)
#   - infra/envs/aws.tfvars    (aws target)
#   - infra/envs/remote.tfvars (remote target)
# =============================================================================
set -euo pipefail

# ─── Platform guard ───────────────────────────────────────────────────────────
# This script uses Bash 4+ features (declare -A associative arrays).
# macOS ships with Bash 3.2 by default, which does not support associative
# arrays. Run this script on Linux or WSL only.
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "Error: this script requires Linux or WSL." >&2
  echo "       macOS ships with Bash 3.2 which does not support 'declare -A'." >&2
  echo "       On macOS, use WSL or a remote Linux host instead." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
INFRA_DIR="${PROJECT_ROOT}/infra"

PROFILE=""
TARGET=""
ACTION="apply"
BUILD_IMAGES="true"
HW_TIER=""

TERRAFORM_MIN="1.5.0"
TERRAFORM_INSTALL="1.9.8"        # pinned fallback; update here if needed
TERRAFORM_BIN="${HOME}/.local/bin"

# ─── Help ────────────────────────────────────────────────────────────────────

usage() {
  cat <<'USAGE'
Usage: ./infra/scripts/deploy.sh [OPTIONS]

Options:
  --profile  PROFILE   dev | prod                            (required)
  --target   TARGET    local | aws | remote                  (required)
  --hw       TIER      tiny | small | medium | large | auto  (optional)
  --action   ACTION    plan | apply | destroy                (default: apply)
  --no-build           Skip --build flag (local target only)
  -h, --help           Show this help

Hardware tiers (--hw):
  tiny    Dev laptop  — 2-4 cores / 4-8 GB   → Docker budget ~4 CPU / ~2 GB
  small   Workstation — 4-8 cores / 8-16 GB  → Docker budget ~8 CPU / ~6 GB
  medium  Server      — 8-32 cores / 32-64 GB → Docker budget ~27 CPU / ~27 GB
  large   c5.24xlarge — 96 cores / 192 GB    → Docker budget ~96 CPU / ~152 GB
  auto    Detect host specs and derive all parameters automatically.
            local  → reads nproc + /proc/meminfo from the current host
            aws    → queries the AWS API for the instance_type in aws.tfvars
            remote → SSHs to the host and reads nproc + /proc/meminfo

  If --hw is omitted the values in your .env file are used as-is.
  IMPORTANT: the docker-compose.yml defaults are sized for large (c5.24xlarge).
  Use --hw auto or an explicit tier when deploying to any other machine.

Examples:
  ./infra/scripts/deploy.sh --profile dev  --target local --hw tiny
  ./infra/scripts/deploy.sh --profile prod --target local --hw auto
  ./infra/scripts/deploy.sh --profile prod --target local --hw small
  ./infra/scripts/deploy.sh --profile prod --target aws   --hw auto
  ./infra/scripts/deploy.sh --profile prod --target aws   --hw large
  ./infra/scripts/deploy.sh --profile prod --target remote --hw auto
  ./infra/scripts/deploy.sh --profile dev  --target local --hw tiny --action destroy
USAGE
}

# ─── Argument parsing ────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)   PROFILE="$2"; shift 2 ;;
    --profile=*) PROFILE="${1#*=}"; shift ;;
    --target)    TARGET="$2"; shift 2 ;;
    --target=*)  TARGET="${1#*=}"; shift ;;
    --action)    ACTION="$2"; shift 2 ;;
    --action=*)  ACTION="${1#*=}"; shift ;;
    --hw)        HW_TIER="$2"; shift 2 ;;
    --hw=*)      HW_TIER="${1#*=}"; shift ;;
    --no-build)  BUILD_IMAGES="false"; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "Error: unknown option '$1'" >&2; usage; exit 1 ;;
  esac
done

# ─── Validation ──────────────────────────────────────────────────────────────

if [[ -z "$PROFILE" ]]; then
  echo "Error: --profile is required (dev|prod)" >&2; usage; exit 1
fi
if [[ -z "$TARGET" ]]; then
  echo "Error: --target is required (local|aws|remote)" >&2; usage; exit 1
fi
if [[ ! "$PROFILE" =~ ^(dev|prod)$ ]]; then
  echo "Error: --profile must be 'dev' or 'prod', got '${PROFILE}'" >&2; exit 1
fi
if [[ ! "$TARGET" =~ ^(local|aws|remote)$ ]]; then
  echo "Error: --target must be 'local', 'aws', or 'remote', got '${TARGET}'" >&2; exit 1
fi
if [[ ! "$ACTION" =~ ^(plan|apply|destroy)$ ]]; then
  echo "Error: --action must be 'plan', 'apply', or 'destroy', got '${ACTION}'" >&2; exit 1
fi
if [[ -n "$HW_TIER" && ! "$HW_TIER" =~ ^(tiny|small|medium|large|auto)$ ]]; then
  echo "Error: --hw must be 'tiny', 'small', 'medium', 'large', or 'auto', got '${HW_TIER}'" >&2; exit 1
fi

# ─── .env → TF_VAR_* loader ──────────────────────────────────────────────────
# Terraform acepta variables de dos formas: --var-file o variables de entorno
# con el prefijo TF_VAR_. Aquí usamos la segunda opción para los secretos:
# leemos el .env y exportamos cada valor como TF_VAR_<nombre>, así Terraform
# los recoge automáticamente SIN que los secretos aparezcan en ningún archivo
# tfvars ni en el historial de comandos.
#
# Ejemplo: POSTGRES_PASSWORD=secret123 → export TF_VAR_postgres_password=secret123

load_env_as_tf_vars() {
  local env_file="${PROJECT_ROOT}/.env"

  if [[ ! -f "$env_file" ]]; then
    echo "Warning: .env not found at ${env_file}" >&2
    echo "Tip:     cp .env.template .env  (then fill in real values)" >&2
    return
  fi

  # Tabla de mapeo: clave del .env → nombre de variable en Terraform.
  # Solo las variables sensibles o que los módulos Terraform necesitan conocer.
  # Las variables de configuración no-secreta (instance_type, region, etc.)
  # van directamente en infra/envs/aws.tfvars.
  declare -A TF_MAP=(
    [POSTGRES_USER]=postgres_user
    [POSTGRES_PASSWORD]=postgres_password
    [POSTGRES_DB]=postgres_db
    [REDIS_PASSWORD]=redis_password
    [JWT_SECRET_KEY]=jwt_secret_key
    [JWT_ACCESS_TOKEN_EXP_MINUTES]=jwt_access_token_exp_minutes
    [BACKEND_WEB_CONCURRENCY]=backend_web_concurrency
    [WORKER_CONCURRENCY]=worker_concurrency
  )

  while IFS= read -r line; do
    # Strip trailing \r to handle CRLF line endings from Windows-edited .env files.
    line="${line%$'\r'}"

    [[ "$line" =~ ^[[:space:]]*# ]] && continue  # ignorar comentarios
    [[ -z "${line// /}" ]] && continue            # ignorar líneas vacías

    # Dividir solo en el primer '=' para soportar contraseñas con '=' dentro.
    key="${line%%=*}"
    value="${line#*=}"

    # Strip leading/trailing whitespace from the key.
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"

    # Strip trailing \r from value (defense in depth for exotic editors).
    value="${value%$'\r'}"

    # Eliminar comillas simples o dobles opcionales alrededor del valor.
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"

    tf_var="${TF_MAP[$key]:-}"
    if [[ -n "$tf_var" ]]; then
      export "TF_VAR_${tf_var}=${value}"
    fi
  done < "$env_file"

  # CORS requiere conversión especial: Terraform espera una lista HCL/JSON,
  # pero en el .env está como string separado por comas.
  # Entrada:  "http://localhost:5173,http://127.0.0.1:5173"
  # Salida:   ["http://localhost:5173","http://127.0.0.1:5173"]
  local cors_raw
  # tr -d $'\r' normalizes CRLF line endings from Windows-edited .env files.
  cors_raw=$(grep -E '^CORS_ALLOW_ORIGINS=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d $'\r')
  if [[ -n "$cors_raw" ]]; then
    local cors_json='['
    local first=1
    IFS=',' read -ra origins <<< "$cors_raw"
    for origin in "${origins[@]}"; do
      origin="${origin//[[:space:]]/}"   # eliminar espacios alrededor de cada origen
      [[ $first -eq 0 ]] && cors_json+=','
      cors_json+="\"${origin}\""
      first=0
    done
    cors_json+=']'
    export TF_VAR_cors_allow_origins="$cors_json"
  fi
}

# ─── Hardware auto-detection ─────────────────────────────────────────────────
# Used by detect_hw_auto(). All helpers are prefixed _hw_ to avoid collisions.

# x100 integer → "3.00" decimal string  (e.g. 350 → "3.50")
_hw_fmt_cpu() {
  printf "%d.%02d" $(( $1 / 100 )) $(( $1 % 100 ))
}

# MB → Docker memory string: round GB when divisible, else MB  (e.g. 2048 → "2G", 768 → "768M")
_hw_fmt_docker_mem() {
  if (( $1 >= 1024 && $1 % 1024 == 0 )); then printf "%dG" $(( $1 / 1024 ))
  else printf "%dM" "$1"; fi
}

# MB → PostgreSQL config string  (e.g. 2048 → "2GB", 512 → "512MB")
_hw_fmt_pg_mem() {
  if (( $1 >= 1024 && $1 % 1024 == 0 )); then printf "%dGB" $(( $1 / 1024 ))
  else printf "%dMB" "$1"; fi
}

# MB → Docker shm_size string (lowercase)  (e.g. 1024 → "1g", 256 → "256m")
_hw_fmt_shm() {
  if (( $1 >= 1024 && $1 % 1024 == 0 )); then printf "%dg" $(( $1 / 1024 ))
  else printf "%dm" "$1"; fi
}

# MB → Redis maxmemory string (lowercase)  (e.g. 4096 → "4gb", 512 → "512mb")
_hw_fmt_redis_mem() {
  if (( $1 >= 1024 && $1 % 1024 == 0 )); then printf "%dgb" $(( $1 / 1024 ))
  else printf "%dmb" "$1"; fi
}

# Outputs "<cpu_total> <mem_total_mb>" by querying the appropriate source for
# the current TARGET. Exits with a clear error message on failure.
_hw_auto_get_specs() {
  local cpu mem_mb

  case "$TARGET" in
    local)
      cpu=$(nproc)
      mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
      ;;

    aws)
      local var_file="${INFRA_DIR}/envs/aws.tfvars"
      local instance_type
      instance_type=$(grep -E 'instance_type' "$var_file" 2>/dev/null \
        | head -1 | grep -oE '"[^"]*"' | tr -d '"')
      if [[ -z "$instance_type" ]]; then
        echo "Error: --hw auto on aws target requires instance_type in ${var_file}" >&2; exit 1
      fi
      echo "==> Querying AWS API for ${instance_type} specs..."
      local result
      result=$(aws ec2 describe-instance-types \
        --instance-types "$instance_type" \
        --query 'InstanceTypes[0].{cpu:VCpuInfo.DefaultVCpus,mem_mib:MemoryInfo.SizeInMiB}' \
        --output text 2>/dev/null)
      cpu=$(awk '{print $1}' <<< "$result")
      mem_mb=$(awk '{print int($2)}' <<< "$result")    # MiB ≈ MB
      ;;

    remote)
      local var_file="${INFRA_DIR}/envs/remote.tfvars"
      local host ssh_user ssh_key
      host=$(grep -E 'host\s*='     "$var_file" 2>/dev/null | head -1 | grep -oE '"[^"]*"' | tr -d '"')
      ssh_user=$(grep -E 'ssh_user\s*=' "$var_file" 2>/dev/null | head -1 | grep -oE '"[^"]*"' | tr -d '"')
      ssh_key=$(grep -E 'ssh_private_key_path\s*=' "$var_file" 2>/dev/null | head -1 | grep -oE '"[^"]*"' | tr -d '"')
      if [[ -z "$host" || -z "$ssh_user" || -z "$ssh_key" ]]; then
        echo "Error: --hw auto on remote target requires host, ssh_user, and ssh_private_key_path in ${var_file}" >&2; exit 1
      fi
      echo "==> Detecting hardware on ${ssh_user}@${host} via SSH..."
      local ssh_opts="-i ${ssh_key} -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10"
      cpu=$(ssh $ssh_opts "${ssh_user}@${host}" nproc 2>/dev/null)
      mem_mb=$(ssh $ssh_opts "${ssh_user}@${host}" \
        "awk '/MemTotal/{print int(\$2/1024)}' /proc/meminfo" 2>/dev/null)
      ;;
  esac

  if [[ -z "$cpu" || -z "$mem_mb" ]] || ! [[ "$cpu" =~ ^[0-9]+$ && "$mem_mb" =~ ^[0-9]+$ ]]; then
    echo "Error: --hw auto could not read hardware specs for target '${TARGET}'." >&2
    echo "       cpu='${cpu:-unset}'  mem_mb='${mem_mb:-unset}'" >&2
    exit 1
  fi

  printf '%s %s\n' "$cpu" "$mem_mb"
}

# Detects hardware via _hw_auto_get_specs and exports the full set of variables
# that hw-*.env profiles provide, using the same formulas used to author them.
detect_hw_auto() {
  local specs; specs=$(_hw_auto_get_specs)
  local cpu_total mem_total_mb
  cpu_total=$(awk '{print $1}' <<< "$specs")
  mem_total_mb=$(awk '{print $2}' <<< "$specs")

  echo "==> Hardware auto-detected: ${cpu_total} vCPU / $(( mem_total_mb / 1024 )) GB RAM"

  # ── Docker budget: reserve 15% CPU and 25% RAM for the host OS ────────────
  local docker_cpu=$(( cpu_total * 85 / 100 ))
  [[ $docker_cpu -lt 1 ]] && docker_cpu=1
  local docker_mem_mb=$(( mem_total_mb * 75 / 100 ))

  # ── Concurrency ────────────────────────────────────────────────────────────
  # 1 Gunicorn worker per 2 Docker-budget CPUs (conservative for sync model)
  local workers=$(( docker_cpu / 2 ))
  [[ $workers -lt 2 ]] && workers=2

  local worker_concurrency=$(( workers / 2 ))
  [[ $worker_concurrency -lt 1 ]]  && worker_concurrency=1
  [[ $worker_concurrency -gt 12 ]] && worker_concurrency=12

  local db_pool_size=$(( workers / 2 ))
  [[ $db_pool_size -lt 3 ]] && db_pool_size=3
  local db_max_overflow=$db_pool_size

  local anyio_min_threads=$(( db_pool_size + db_max_overflow ))
  [[ $anyio_min_threads -lt 6 ]] && anyio_min_threads=6

  # Redis: anyio_threads × workers × 2 ops/req + 10% headroom
  local redis_max_connections=$(( anyio_min_threads * workers * 2 * 11 / 10 ))
  [[ $redis_max_connections -lt 40 ]] && redis_max_connections=40

  # Postgres: workers × (pool + overflow) × 1.1 headroom
  local postgres_max_connections=$(( workers * (db_pool_size + db_max_overflow) * 11 / 10 + 10 ))

  # ── Container CPU limits (×100 for integer math, formatted by _hw_fmt_cpu) ─
  # Distribution: backend 35%, postgres 24%, worker 12%, redis 12%, nginx 12%, frontend 5%
  local nginx_cpu_x100=$(( docker_cpu * 12 ))
  local postgres_cpu_x100=$(( docker_cpu * 24 ))
  local redis_cpu_x100=$(( docker_cpu * 12 ))
  local backend_cpu_x100=$(( docker_cpu * 35 ))
  local worker_cpu_x100=$(( docker_cpu * 12 ))
  local frontend_cpu_x100=$(( docker_cpu * 5 ))

  [[ $nginx_cpu_x100    -lt  50 ]] && nginx_cpu_x100=50       # min 0.50
  [[ $postgres_cpu_x100 -lt 100 ]] && postgres_cpu_x100=100   # min 1.00
  [[ $redis_cpu_x100    -lt  50 ]] && redis_cpu_x100=50       # min 0.50
  [[ $backend_cpu_x100  -lt 150 ]] && backend_cpu_x100=150    # min 1.50
  [[ $worker_cpu_x100   -lt  50 ]] && worker_cpu_x100=50      # min 0.50
  [[ $frontend_cpu_x100 -lt  25 ]] && frontend_cpu_x100=25    # min 0.25

  # Reservations ≈ 33% of limit (floor)
  local nginx_cpu_res_x100=$(( nginx_cpu_x100 / 3 ))
  [[ $nginx_cpu_res_x100    -lt  25 ]] && nginx_cpu_res_x100=25
  local postgres_cpu_res_x100=$(( postgres_cpu_x100 / 3 ))
  [[ $postgres_cpu_res_x100 -lt  50 ]] && postgres_cpu_res_x100=50
  local redis_cpu_res_x100=$(( redis_cpu_x100 / 3 ))
  [[ $redis_cpu_res_x100    -lt  25 ]] && redis_cpu_res_x100=25
  local backend_cpu_res_x100=$(( backend_cpu_x100 / 6 ))
  [[ $backend_cpu_res_x100  -lt 100 ]] && backend_cpu_res_x100=100
  local worker_cpu_res_x100=$(( worker_cpu_x100 / 3 ))
  [[ $worker_cpu_res_x100   -lt  25 ]] && worker_cpu_res_x100=25
  local frontend_cpu_res_x100=$(( frontend_cpu_x100 / 3 ))
  [[ $frontend_cpu_res_x100 -lt  10 ]] && frontend_cpu_res_x100=10

  # ── Container memory limits (MB) ───────────────────────────────────────────
  # Distribution: postgres 35%, backend 35%, redis 13%, worker 13%, nginx 2%, frontend 2%
  local postgres_mem_mb=$(( docker_mem_mb * 35 / 100 ))
  [[ $postgres_mem_mb -lt 512 ]] && postgres_mem_mb=512
  local redis_mem_mb=$(( docker_mem_mb * 13 / 100 ))
  [[ $redis_mem_mb -lt 256 ]] && redis_mem_mb=256
  local backend_mem_mb=$(( docker_mem_mb * 35 / 100 ))
  [[ $backend_mem_mb -lt 768 ]] && backend_mem_mb=768
  local worker_mem_mb=$(( docker_mem_mb * 13 / 100 ))
  [[ $worker_mem_mb -lt 256 ]] && worker_mem_mb=256
  local nginx_mem_mb=$(( docker_mem_mb * 2 / 100 ))
  [[ $nginx_mem_mb -lt 128 ]] && nginx_mem_mb=128
  local frontend_mem_mb=$(( docker_mem_mb * 2 / 100 ))
  [[ $frontend_mem_mb -lt 128 ]] && frontend_mem_mb=128

  # Reservations ≈ 25% of limit
  local nginx_mem_res_mb=$(( nginx_mem_mb / 4 ))
  [[ $nginx_mem_res_mb    -lt  64 ]] && nginx_mem_res_mb=64
  local postgres_mem_res_mb=$(( postgres_mem_mb / 4 ))
  [[ $postgres_mem_res_mb -lt 256 ]] && postgres_mem_res_mb=256
  local redis_mem_res_mb=$(( redis_mem_mb / 4 ))
  [[ $redis_mem_res_mb    -lt 128 ]] && redis_mem_res_mb=128
  local backend_mem_res_mb=$(( backend_mem_mb / 4 ))
  [[ $backend_mem_res_mb  -lt 256 ]] && backend_mem_res_mb=256
  local worker_mem_res_mb=$(( worker_mem_mb / 4 ))
  [[ $worker_mem_res_mb   -lt 128 ]] && worker_mem_res_mb=128
  local frontend_mem_res_mb=$(( frontend_mem_mb / 4 ))
  [[ $frontend_mem_res_mb -lt  64 ]] && frontend_mem_res_mb=64

  # ── PostgreSQL internal tuning ─────────────────────────────────────────────
  local pg_shared_buffers_mb=$(( postgres_mem_mb / 4 ))
  local pg_effective_cache_mb=$(( postgres_mem_mb * 3 / 4 ))
  local pg_work_mem_mb=$(( db_pool_size > 6 ? 16 : 8 ))
  [[ $pg_work_mem_mb -lt 4 ]] && pg_work_mem_mb=4
  local pg_maintenance_mb=$(( postgres_mem_mb / 16 ))
  [[ $pg_maintenance_mb -lt 32 ]] && pg_maintenance_mb=32
  # shm_size must be ≥ shared_buffers; 2× is safe headroom
  local pg_shm_mb=$(( pg_shared_buffers_mb * 2 ))
  [[ $pg_shm_mb -lt 256 ]] && pg_shm_mb=256

  # Redis maxmemory = 85% of the container memory limit
  local redis_maxmem_mb=$(( redis_mem_mb * 85 / 100 ))

  # ── Export all vars (same names used by hw-*.env and docker-compose.yml) ───
  export BACKEND_WEB_CONCURRENCY=$workers
  export WORKER_CONCURRENCY=$worker_concurrency
  export DB_POOL_SIZE=$db_pool_size
  export DB_MAX_OVERFLOW=$db_max_overflow
  export DB_POOL_TIMEOUT=3
  export REDIS_MAX_CONNECTIONS=$redis_max_connections
  export LOG_LEVEL=WARNING
  export ANYIO_MIN_THREADS=$anyio_min_threads
  export BACKEND_GUNICORN_MAX_REQUESTS=2000
  export BACKEND_GUNICORN_MAX_REQUESTS_JITTER=200
  export VIDEO_DETAIL_CACHE_TTL=60

  export POSTGRES_MAX_CONNECTIONS=$postgres_max_connections
  export POSTGRES_SHARED_BUFFERS="$(_hw_fmt_pg_mem $pg_shared_buffers_mb)"
  export POSTGRES_EFFECTIVE_CACHE_SIZE="$(_hw_fmt_pg_mem $pg_effective_cache_mb)"
  export POSTGRES_WORK_MEM="${pg_work_mem_mb}MB"
  export POSTGRES_MAINTENANCE_WORK_MEM="$(_hw_fmt_pg_mem $pg_maintenance_mb)"
  export POSTGRES_SHM_SIZE="$(_hw_fmt_shm $pg_shm_mb)"
  export REDIS_MAXMEMORY="$(_hw_fmt_redis_mem $redis_maxmem_mb)"

  export NGINX_CPU_LIMIT="$(_hw_fmt_cpu $nginx_cpu_x100)"
  export NGINX_MEMORY_LIMIT="$(_hw_fmt_docker_mem $nginx_mem_mb)"
  export NGINX_CPU_RESERVATION="$(_hw_fmt_cpu $nginx_cpu_res_x100)"
  export NGINX_MEMORY_RESERVATION="$(_hw_fmt_docker_mem $nginx_mem_res_mb)"

  export POSTGRES_CPU_LIMIT="$(_hw_fmt_cpu $postgres_cpu_x100)"
  export POSTGRES_MEMORY_LIMIT="$(_hw_fmt_docker_mem $postgres_mem_mb)"
  export POSTGRES_CPU_RESERVATION="$(_hw_fmt_cpu $postgres_cpu_res_x100)"
  export POSTGRES_MEMORY_RESERVATION="$(_hw_fmt_docker_mem $postgres_mem_res_mb)"

  export REDIS_CPU_LIMIT="$(_hw_fmt_cpu $redis_cpu_x100)"
  export REDIS_MEMORY_LIMIT="$(_hw_fmt_docker_mem $redis_mem_mb)"
  export REDIS_CPU_RESERVATION="$(_hw_fmt_cpu $redis_cpu_res_x100)"
  export REDIS_MEMORY_RESERVATION="$(_hw_fmt_docker_mem $redis_mem_res_mb)"

  export BACKEND_CPU_LIMIT="$(_hw_fmt_cpu $backend_cpu_x100)"
  export BACKEND_MEMORY_LIMIT="$(_hw_fmt_docker_mem $backend_mem_mb)"
  export BACKEND_CPU_RESERVATION="$(_hw_fmt_cpu $backend_cpu_res_x100)"
  export BACKEND_MEMORY_RESERVATION="$(_hw_fmt_docker_mem $backend_mem_res_mb)"

  export WORKER_CPU_LIMIT="$(_hw_fmt_cpu $worker_cpu_x100)"
  export WORKER_MEMORY_LIMIT="$(_hw_fmt_docker_mem $worker_mem_mb)"
  export WORKER_CPU_RESERVATION="$(_hw_fmt_cpu $worker_cpu_res_x100)"
  export WORKER_MEMORY_RESERVATION="$(_hw_fmt_docker_mem $worker_mem_res_mb)"

  export FRONTEND_CPU_LIMIT="$(_hw_fmt_cpu $frontend_cpu_x100)"
  export FRONTEND_MEMORY_LIMIT="$(_hw_fmt_docker_mem $frontend_mem_mb)"
  export FRONTEND_CPU_RESERVATION="$(_hw_fmt_cpu $frontend_cpu_res_x100)"
  export FRONTEND_MEMORY_RESERVATION="$(_hw_fmt_docker_mem $frontend_mem_res_mb)"

  # Mirror to TF_VAR_* so Terraform picks up the computed values too
  local v
  for v in BACKEND_WEB_CONCURRENCY WORKER_CONCURRENCY DB_POOL_SIZE DB_MAX_OVERFLOW \
            ANYIO_MIN_THREADS REDIS_MAX_CONNECTIONS \
            NGINX_CPU_LIMIT NGINX_MEMORY_LIMIT NGINX_CPU_RESERVATION NGINX_MEMORY_RESERVATION \
            POSTGRES_CPU_LIMIT POSTGRES_MEMORY_LIMIT POSTGRES_CPU_RESERVATION POSTGRES_MEMORY_RESERVATION \
            REDIS_CPU_LIMIT REDIS_MEMORY_LIMIT REDIS_CPU_RESERVATION REDIS_MEMORY_RESERVATION \
            BACKEND_CPU_LIMIT BACKEND_MEMORY_LIMIT BACKEND_CPU_RESERVATION BACKEND_MEMORY_RESERVATION \
            WORKER_CPU_LIMIT WORKER_MEMORY_LIMIT WORKER_CPU_RESERVATION WORKER_MEMORY_RESERVATION \
            FRONTEND_CPU_LIMIT FRONTEND_MEMORY_LIMIT FRONTEND_CPU_RESERVATION FRONTEND_MEMORY_RESERVATION \
            POSTGRES_MAX_CONNECTIONS POSTGRES_SHARED_BUFFERS POSTGRES_EFFECTIVE_CACHE_SIZE \
            POSTGRES_WORK_MEM POSTGRES_MAINTENANCE_WORK_MEM POSTGRES_SHM_SIZE REDIS_MAXMEMORY; do
    export "TF_VAR_${v,,}=${!v}"
  done

  echo "==> Auto-configured: ${workers} workers · pool=${db_pool_size}+${db_max_overflow} · anyio=${anyio_min_threads} · redis_conns=${redis_max_connections} · postgres_conns=${postgres_max_connections}"
}

# ─── Hardware profile loader ─────────────────────────────────────────────────
# Lee infra/envs/hw-<tier>.env y exporta cada variable de dos formas:
#   1. Como variable de entorno normal (para que docker compose la recoja)
#   2. Como TF_VAR_<nombre_en_minúsculas> (para que Terraform la recoja)
# Las variables de entorno del shell tienen prioridad sobre el .env en Docker Compose.
# Los TF_VAR_* sobreescriben los defaults de variables.tf en Terraform.
#
# El mapeo funciona porque los nombres son idénticos salvo el case:
#   BACKEND_WEB_CONCURRENCY → TF_VAR_backend_web_concurrency   ✓
#   POSTGRES_SHARED_BUFFERS  → TF_VAR_postgres_shared_buffers  ✓
#   NGINX_CPU_LIMIT          → TF_VAR_nginx_cpu_limit          ✓

load_hw_profile() {
  [[ -z "$HW_TIER" ]] && return

  if [[ "$HW_TIER" == "auto" ]]; then
    detect_hw_auto
    return
  fi

  local hw_file="${INFRA_DIR}/envs/hw-${HW_TIER}.env"
  if [[ ! -f "$hw_file" ]]; then
    echo "Error: hardware profile file not found: ${hw_file}" >&2
    exit 1
  fi

  echo "==> Loading hardware profile: ${HW_TIER} (${hw_file})"

  while IFS= read -r line; do
    line="${line%$'\r'}"                         # strip Windows CRLF
    [[ "$line" =~ ^[[:space:]]*# ]] && continue # skip comments
    [[ -z "${line// /}" ]] && continue           # skip blank lines

    key="${line%%=*}"
    value="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"

    export "${key}=${value}"                     # for docker compose
    export "TF_VAR_${key,,}=${value}"            # for Terraform (lowercase key)
  done < "$hw_file"
}

# ─── Dependency checker ──────────────────────────────────────────────────────

# Returns 0 if semver $1 >= $2 (uses sort -V).
_ver_ge() { printf '%s\n%s\n' "$2" "$1" | sort -V -C; }

_install_terraform() {
  local arch
  case "$(uname -m)" in
    x86_64)  arch="amd64" ;;
    aarch64) arch="arm64" ;;
    armv7l)  arch="arm"   ;;
    *) echo "Error: unsupported architecture $(uname -m)" >&2; exit 1 ;;
  esac

  local zip="terraform_${TERRAFORM_INSTALL}_linux_${arch}.zip"
  local url="https://releases.hashicorp.com/terraform/${TERRAFORM_INSTALL}/${zip}"
  local tmp; tmp=$(mktemp -d)

  echo "==> Installing Terraform ${TERRAFORM_INSTALL} to ${TERRAFORM_BIN}..."
  mkdir -p "${TERRAFORM_BIN}"

  if command -v curl &>/dev/null; then
    curl -fsSL -o "${tmp}/${zip}" "${url}"
  elif command -v wget &>/dev/null; then
    wget -q -O "${tmp}/${zip}" "${url}"
  else
    echo "Error: neither curl nor wget found. Install terraform manually:" >&2
    echo "       https://developer.hashicorp.com/terraform/install" >&2
    rm -rf "${tmp}"; exit 1
  fi

  if ! command -v unzip &>/dev/null; then
    echo "Error: unzip not found (apt install unzip / yum install unzip)." >&2
    rm -rf "${tmp}"; exit 1
  fi

  unzip -q "${tmp}/${zip}" -d "${tmp}"
  mv "${tmp}/terraform" "${TERRAFORM_BIN}/terraform"
  chmod +x "${TERRAFORM_BIN}/terraform"
  rm -rf "${tmp}"

  export PATH="${TERRAFORM_BIN}:${PATH}"
  echo "==> Terraform ${TERRAFORM_INSTALL} ready at ${TERRAFORM_BIN}/terraform"
  echo "    To persist: add 'export PATH=\"${TERRAFORM_BIN}:\$PATH\"' to your shell profile."
}

_install_docker() {
  echo "==> Installing Docker Engine + Compose plugin via get.docker.com (sudo required)..."

  if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
    echo "Error: neither curl nor wget found. Install Docker manually:" >&2
    echo "       https://docs.docker.com/engine/install/" >&2
    exit 1
  fi

  local tmp; tmp=$(mktemp)
  if command -v curl &>/dev/null; then
    curl -fsSL https://get.docker.com -o "$tmp"
  else
    wget -q -O "$tmp" https://get.docker.com
  fi

  sudo sh "$tmp"
  rm -f "$tmp"

  if command -v systemctl &>/dev/null; then
    sudo systemctl enable --now docker 2>/dev/null || true
  elif command -v service &>/dev/null; then
    sudo service docker start 2>/dev/null || true
  fi

  sudo usermod -aG docker "$USER"

  if docker info &>/dev/null 2>&1; then
    echo "==> Docker installed and operational."
    return 0
  fi

  echo ""
  echo "==> Docker installed. Your user was added to the 'docker' group."
  echo "    Apply the group change without logging out:"
  echo "      newgrp docker"
  echo "    Then re-run this script."
  exit 0
}

_install_docker_compose() {
  echo "==> Installing docker compose plugin..."
  if command -v apt-get &>/dev/null; then
    sudo apt-get update -qq && sudo apt-get install -y docker-compose-plugin
  elif command -v dnf &>/dev/null; then
    sudo dnf install -y docker-compose-plugin
  elif command -v yum &>/dev/null; then
    sudo yum install -y docker-compose-plugin
  else
    echo "Error: cannot auto-install docker compose on this distro." >&2
    echo "       https://docs.docker.com/compose/install/" >&2
    exit 1
  fi
}

_install_awscli() {
  local arch
  case "$(uname -m)" in
    x86_64)  arch="x86_64"  ;;
    aarch64) arch="aarch64" ;;
    *) echo "Error: AWS CLI auto-install only supports x86_64 and aarch64." >&2; exit 1 ;;
  esac

  local tmp; tmp=$(mktemp -d)
  local url="https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip"

  echo "==> Downloading AWS CLI from ${url}..."
  if command -v curl &>/dev/null; then
    curl -fsSL -o "${tmp}/awscliv2.zip" "${url}"
  else
    wget -q -O "${tmp}/awscliv2.zip" "${url}"
  fi

  unzip -q "${tmp}/awscliv2.zip" -d "${tmp}"
  "${tmp}/aws/install" \
    --install-dir "${HOME}/.local/aws-cli" \
    --bin-dir "${TERRAFORM_BIN}" \
    --update
  rm -rf "${tmp}"

  export PATH="${TERRAFORM_BIN}:${PATH}"
  echo "==> AWS CLI installed to ${TERRAFORM_BIN}/aws"
  echo "    Run 'aws configure' to set up your credentials."
}

check_deps() {
  echo ""
  echo "==> Checking dependencies..."
  local errors=0

  # ── Docker + Compose (local target only) ─────────────────────────────────
  if [[ "$TARGET" == "local" ]]; then
    if ! command -v docker &>/dev/null; then
      echo "[MISSING] docker — auto-installing..."
      _install_docker
    fi

    if ! docker info &>/dev/null 2>&1; then
      echo "[STOPPED] Docker daemon is not running — starting..."
      if command -v systemctl &>/dev/null; then
        sudo systemctl start docker
      elif command -v service &>/dev/null; then
        sudo service docker start
      else
        echo "[ERROR]   Cannot start Docker daemon automatically. Start it manually and retry." >&2
        errors=$((errors + 1))
      fi
      sleep 2
      if docker info &>/dev/null 2>&1; then
        echo "[OK]      Docker daemon started"
      else
        echo "[ERROR]   Docker daemon still not reachable after start attempt." >&2
        errors=$((errors + 1))
      fi
    else
      echo "[OK]      $(docker --version)"
    fi

    if ! docker compose version &>/dev/null 2>&1; then
      echo "[MISSING] docker compose plugin — auto-installing..."
      _install_docker_compose
      if docker compose version &>/dev/null 2>&1; then
        echo "[OK]      $(docker compose version)"
      else
        echo "[ERROR]   docker compose still not available after install." >&2
        errors=$((errors + 1))
      fi
    else
      echo "[OK]      $(docker compose version)"
    fi
  fi

  # ── Terraform (all targets) ───────────────────────────────────────────────
  if command -v terraform &>/dev/null; then
    local tf_ver
    tf_ver=$(terraform version -json 2>/dev/null \
      | grep -oE '"terraform_version": *"[0-9]+\.[0-9]+\.[0-9]+"' \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    if [[ -z "$tf_ver" ]]; then
      tf_ver=$(terraform version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    fi
    if [[ -n "$tf_ver" ]] && _ver_ge "$tf_ver" "${TERRAFORM_MIN}"; then
      echo "[OK]      terraform ${tf_ver}"
    else
      echo "[OLD]     terraform ${tf_ver:-unknown} < ${TERRAFORM_MIN} — auto-installing ${TERRAFORM_INSTALL}..." >&2
      _install_terraform
    fi
  else
    echo "[MISSING] terraform — auto-installing ${TERRAFORM_INSTALL}..."
    _install_terraform
  fi

  # ── .env file and required values (all targets) ─────────────────────────
  local env_file="${PROJECT_ROOT}/.env"
  if [[ ! -f "$env_file" ]]; then
    echo "[MISSING] .env — copy the template and fill in your values:" >&2
    echo "          cp .env.template .env" >&2
    errors=$((errors + 1))
  else
    local jwt_key
    jwt_key=$(grep -E '^JWT_SECRET_KEY=' "$env_file" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d $'\r')
    if [[ -z "$jwt_key" \
       || "$jwt_key" == "REPLACE_WITH_STRONG_SECRET_MIN_32_CHARS" \
       || ${#jwt_key} -lt 32 ]]; then
      echo "[INVALID] .env: JWT_SECRET_KEY is missing, too short (< 32 chars), or still the template placeholder." >&2
      echo "          Generate: openssl rand -base64 48" >&2
      errors=$((errors + 1))
    else
      echo "[OK]      .env (JWT_SECRET_KEY set)"
    fi

    local pg_pass
    pg_pass=$(grep -E '^POSTGRES_PASSWORD=' "$env_file" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d $'\r')
    if [[ -z "$pg_pass" || "$pg_pass" == "StrongPassword12!" ]]; then
      echo "[INVALID] .env: POSTGRES_PASSWORD is empty or still the template default (StrongPassword12!)." >&2
      errors=$((errors + 1))
    fi
  fi

  # ── AWS CLI + credentials (aws target) ───────────────────────────────────
  if [[ "$TARGET" == "aws" ]]; then
    if ! command -v aws &>/dev/null; then
      echo "[MISSING] aws CLI — auto-installing..."
      _install_awscli
    fi
    if command -v aws &>/dev/null; then
      echo "[OK]      $(aws --version 2>&1 | head -1)"
      if ! aws sts get-caller-identity &>/dev/null 2>&1; then
        echo "[INVALID] AWS credentials not configured or expired." >&2
        echo "          Run: aws configure   (or export AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY)" >&2
        errors=$((errors + 1))
      else
        echo "[OK]      AWS account $(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
      fi
    else
      echo "[ERROR]   aws CLI still not found after install attempt." >&2
      errors=$((errors + 1))
    fi
  fi

  # ── SSH client (remote target) ────────────────────────────────────────────
  if [[ "$TARGET" == "remote" ]]; then
    if ! command -v ssh &>/dev/null; then
      echo "[MISSING] ssh — install openssh-client (apt install openssh-client)" >&2
      errors=$((errors + 1))
    else
      echo "[OK]      ssh"
    fi
  fi

  if (( errors > 0 )); then
    echo "" >&2
    echo "Error: ${errors} dependency check(s) failed. Resolve the issues above and retry." >&2
    exit 1
  fi

  echo "==> All dependencies satisfied."
}

# ─── Terraform execution helper ──────────────────────────────────────────────
# Centraliza init + plan/apply/destroy para que cada función de target
# no repita la misma lógica. Se ejecuta siempre desde el directorio del módulo
# para que Terraform encuentre los archivos .tf sin rutas absolutas.

tf_exec() {
  local module_dir="$1"
  local var_file="$2"

  echo ""
  echo "==> Working dir: ${module_dir}"
  cd "$module_dir"

  # init descarga los providers declarados en required_providers.
  # Es seguro ejecutarlo múltiples veces; si ya está inicializado es un no-op.
  echo "==> terraform init"
  terraform init -input=false

  case "$ACTION" in
    plan)
      # plan muestra qué cambiaría sin modificar nada. Útil para revisar antes de aplicar.
      echo "==> terraform plan"
      terraform plan -input=false -var-file="$var_file"
      ;;
    apply)
      # -auto-approve omite la confirmación interactiva. El script ya preguntó al usuario.
      echo "==> terraform apply"
      terraform apply -input=false -auto-approve -var-file="$var_file"
      ;;
    destroy)
      # Elimina todos los recursos del módulo. Para local: baja docker compose.
      # Para aws: termina la instancia EC2 y borra el security group.
      echo "==> terraform destroy"
      terraform destroy -input=false -auto-approve -var-file="$var_file"
      ;;
  esac
}

# ─── Target: local ───────────────────────────────────────────────────────────

deploy_local() {
  echo "==> Target: local | Profile: ${PROFILE} | Action: ${ACTION}"

  # El módulo local no maneja secretos directamente (docker compose lee el .env
  # por sí solo), así que solo necesitamos pasar el perfil y si compilar imágenes.
  export TF_VAR_profile="$PROFILE"
  export TF_VAR_build_images="$BUILD_IMAGES"

  tf_exec "${INFRA_DIR}/local" "${INFRA_DIR}/envs/local.tfvars"
}

# ─── Target: aws ─────────────────────────────────────────────────────────────

deploy_aws() {
  echo "==> Target: aws | Profile: ${PROFILE} | Action: ${ACTION}"

  # aws.tfvars contiene configuración no-secreta (region, instance_type, repo_url...).
  # Los secretos vienen del .env vía load_env_as_tf_vars (TF_VAR_*).
  local var_file="${INFRA_DIR}/envs/aws.tfvars"
  if [[ ! -f "$var_file" ]]; then
    echo ""
    echo "Error: ${var_file} not found." >&2
    echo "Tip:   cp ${INFRA_DIR}/envs/aws.tfvars.example ${var_file}" >&2
    echo "       then fill in repo_url, instance_type, etc." >&2
    exit 1
  fi

  load_env_as_tf_vars
  tf_exec "${INFRA_DIR}/aws" "$var_file"
}

# ─── Target: remote ──────────────────────────────────────────────────────────

deploy_remote() {
  echo "==> Target: remote | Profile: ${PROFILE} | Action: ${ACTION}"

  # remote.tfvars contiene host, ssh_user, ssh_private_key_path, repo_url...
  # Los secretos de la app (contraseñas, JWT) vienen del .env.
  local var_file="${INFRA_DIR}/envs/remote.tfvars"
  if [[ ! -f "$var_file" ]]; then
    echo ""
    echo "Error: ${var_file} not found." >&2
    echo "Tip:   cp ${INFRA_DIR}/envs/remote.tfvars.example ${var_file}" >&2
    echo "       then fill in host, ssh_user, ssh_private_key_path, repo_url." >&2
    exit 1
  fi

  # El módulo remote usa var.profile para elegir el compose file correcto.
  export TF_VAR_profile="$PROFILE"
  load_env_as_tf_vars
  tf_exec "${INFRA_DIR}/remote" "$var_file"
}

# ─── Dispatch ────────────────────────────────────────────────────────────────

echo ""
echo "=================================================="
echo " YouTube Clone — Deploy"
echo "  profile : ${PROFILE}"
echo "  target  : ${TARGET}"
echo "  action  : ${ACTION}"
echo "  hw tier : ${HW_TIER:-"(not set — using .env values)"}"
echo "=================================================="

check_deps
load_hw_profile

case "$TARGET" in
  local)  deploy_local ;;
  aws)    deploy_aws ;;
  remote) deploy_remote ;;
esac

echo ""
echo "=================================================="
echo " Done: target=${TARGET} profile=${PROFILE} action=${ACTION}"
echo "=================================================="
