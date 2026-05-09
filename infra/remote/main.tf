terraform {
  required_version = ">= 1.5.0"

  required_providers {
    # El provider "null" provee null_resource: un recurso que no crea nada en
    # la nube pero permite ejecutar provisioners (SSH en este caso).
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

locals {
  # El perfil "dev" carga los overrides de hot-reload; "prod" solo el base.
  compose_files = var.profile == "dev" ? "-f docker-compose.yml -f docker-compose.dev.yml" : "-f docker-compose.yml"

  # Las contraseñas se URL-encodean por si contienen caracteres especiales (@, /, :).
  # El host "postgres" y "redis" son los nombres de los servicios Docker Compose,
  # resueltos internamente dentro de la red Docker, no son IPs externas.
  database_url = format(
    "postgresql+psycopg://%s:%s@postgres:5432/%s",
    urlencode(var.postgres_user),
    urlencode(var.postgres_password),
    urlencode(var.postgres_db)
  )
  redis_url = (
    var.redis_password != ""
    ? format("redis://:%s@redis:6379/0", urlencode(var.redis_password))
    : "redis://redis:6379/0"
  )

  # Renderizamos el contenido del .env en memoria (en Terraform) usando el
  # template env.tftpl. Este contenido se subirá al servidor remoto vía SSH
  # sin tocar ningún archivo local, manteniendo los secretos fuera del disco.
  env_content = templatefile("${path.module}/env.tftpl", {
    app_env                      = var.app_env
    postgres_user                = var.postgres_user
    postgres_password            = var.postgres_password
    postgres_db                  = var.postgres_db
    database_url                 = local.database_url
    redis_password               = var.redis_password
    redis_url                    = local.redis_url
    jwt_secret_key               = var.jwt_secret_key
    jwt_access_token_exp_minutes = var.jwt_access_token_exp_minutes
    cors_allow_origins           = join(",", var.cors_allow_origins)
    backend_web_concurrency      = var.backend_web_concurrency
    worker_concurrency           = var.worker_concurrency
  })
}

# null_resource no representa ningún recurso real. Su único rol es ser el
# contenedor de los provisioners SSH. Terraform lo "crea" (= ejecuta los
# provisioners) cuando los triggers cambian o en el primer apply.
resource "null_resource" "remote_deploy" {

  # triggers: cuando CUALQUIERA de estos valores cambia, Terraform considera
  # que el recurso cambió y vuelve a ejecutar todos los provisioners.
  # También guardamos project_name y profile aquí porque los provisioners
  # de destroy NO pueden acceder a var.*, solo a self.triggers.*.
  triggers = {
    project_name   = var.project_name
    profile        = var.profile
    repo_ref       = var.repo_ref
    force_redeploy = var.force_redeploy_token
  }

  # Bloque de conexión SSH compartido por todos los provisioners de este recurso.
  # file() lee la clave privada del disco local de quien ejecuta Terraform.
  # pathexpand() permite que rutas como "~/.ssh/id_rsa" funcionen correctamente.
  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = file(pathexpand(var.ssh_private_key_path))
    port        = var.ssh_port
    timeout     = "5m"
  }

  # ── Paso 1: Instalar Docker ────────────────────────────────────────────────
  # remote-exec con inline envía los comandos al servidor vía SSH y los ejecuta
  # como un script bash secuencial. Si Docker ya existe, salimos antes.
  provisioner "remote-exec" {
    inline = [
      "set -euo pipefail",
      # Salida temprana solo si docker, docker compose (plugin v2) y git están disponibles.
      # Verificar únicamente `docker` no es suficiente: hosts con Docker CE sin el
      # plugin de Compose fallarían en pasos posteriores. git es necesario para clonar.
      "if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then echo 'Docker (with Compose plugin) and git already installed'; exit 0; fi",
      "export DEBIAN_FRONTEND=noninteractive",
      "apt-get update -qq",
      "apt-get install -y ca-certificates curl gnupg git",
      # Agregar el repositorio oficial de Docker para obtener la versión más reciente.
      "install -m 0755 -d /etc/apt/keyrings",
      "curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc",
      "chmod a+r /etc/apt/keyrings/docker.asc",
      ". /etc/os-release && echo \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable\" > /etc/apt/sources.list.d/docker.list",
      "apt-get update -qq",
      # docker-compose-plugin instala `docker compose` (v2) como subcomando de Docker.
      "apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin",
      "systemctl enable docker",
      "systemctl start docker",
    ]
  }

  # ── Paso 2: Clonar o actualizar el repositorio ────────────────────────────
  provisioner "remote-exec" {
    inline = [
      "set -euo pipefail",
      "APP=/opt/${var.project_name}",
      # Si el repo ya existe: actualizar ref. Si no: clonar desde cero.
      "if [ -d \"$APP/.git\" ]; then",
      "  cd \"$APP\"",
      "  git fetch --all --prune",
      "  if git show-ref --verify --quiet \"refs/remotes/origin/${var.repo_ref}\"; then",
      "    git checkout -B ${var.repo_ref} origin/${var.repo_ref}",
      "    git pull --ff-only origin ${var.repo_ref}",
      "  else",
      "    git checkout ${var.repo_ref}",
      "  fi",
      "else",
      "  git clone --branch ${var.repo_ref} ${var.repo_url} \"$APP\"",
      "fi",
      # Directorio para archivos subidos por usuarios (videos, thumbnails).
      "mkdir -p /opt/${var.project_name}/backend/uploads",
    ]
  }

  # ── Paso 3: Subir el .env al servidor ─────────────────────────────────────
  # El provisioner "file" con `content` (no `source`) transmite el texto
  # directamente por SSH sin crear ningún archivo temporal en la máquina local.
  # Los secretos nunca tocan el disco local ni el tfstate en texto plano.
  provisioner "file" {
    content     = local.env_content
    destination = "/opt/${var.project_name}/.env"
  }

  # ── Paso 4: Levantar los servicios ────────────────────────────────────────
  provisioner "remote-exec" {
    inline = [
      "set -euo pipefail",
      "cd /opt/${var.project_name}",
      # --build reconstruye imágenes si el código del repo cambió.
      "docker compose ${local.compose_files} --profile ${var.profile} up -d --build",
    ]
  }

  # ── Destroy: bajar los servicios limpiamente ──────────────────────────────
  # `when = destroy` se ejecuta antes de que Terraform elimine el recurso.
  # IMPORTANTE: aquí solo podemos leer self.triggers.*, no var.* ni locals.*
  # porque en el momento del destroy las variables ya no existen en el plan.
  provisioner "remote-exec" {
    when = destroy
    inline = [
      "cd /opt/${self.triggers.project_name} && docker compose --profile ${self.triggers.profile} down --remove-orphans || true",
    ]
  }
}

output "remote_host" {
  description = "Remote server hostname / IP."
  value       = var.host
}

output "app_url" {
  description = "HTTP URL served by Nginx on the remote server."
  value       = "http://${var.host}"
}
