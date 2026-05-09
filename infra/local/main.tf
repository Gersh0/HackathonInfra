terraform {
  required_version = ">= 1.5.0"
  # No se declaran providers externos: terraform_data es un recurso built-in
  # disponible desde Terraform 1.4 sin necesidad del provider "null".
}

locals {
  # abspath resuelve la ruta absoluta del directorio raíz del proyecto.
  # path.module apunta a infra/local/, por eso subimos dos niveles (../..).
  project_root = abspath("${path.module}/../..")

  env_file = "${local.project_root}/.env"

  # Huella del .env: si el archivo cambia, triggers_replace detecta el cambio
  # y Terraform vuelve a ejecutar docker compose up para aplicar los nuevos valores.
  # Si el .env no existe aún, usamos "missing" como valor estable.
  env_hash = fileexists(local.env_file) ? filesha256(local.env_file) : "missing"

  # Si se pidieron servicios específicos (ej: ["backend","redis"]), los agregamos
  # al comando. Si la lista está vacía, docker compose levanta todos los servicios.
  services_arg = length(var.services) > 0 ? " ${join(" ", var.services)}" : ""

  # El perfil "dev" requiere dos archivos compose:
  #   docker-compose.yml      → servicios base (postgres, redis, nginx, etc.)
  #   docker-compose.dev.yml  → overrides: hot-reload, bind mounts, puertos expuestos
  # El perfil "prod" solo usa el archivo base.
  compose_files_arg = var.profile == "dev" ? "-f docker-compose.yml -f docker-compose.dev.yml" : "-f docker-compose.yml"
}

# terraform_data es un recurso genérico built-in que no gestiona infraestructura
# real: su único propósito es ejecutar provisioners locales (local-exec).
# Úsalo cuando quieras que Terraform administre un proceso local (docker compose)
# como si fuera un recurso, con estado, triggers y ciclo de vida.
resource "terraform_data" "compose_stack" {

  # `input` guarda valores que el provisioner de destroy necesita leer después.
  # Los provisioners de destroy NO pueden acceder a var.* porque las variables
  # ya no existen en ese punto; sí pueden leer self.input.*.
  input = {
    project_root              = local.project_root
    profile                   = var.profile
    build_images              = var.build_images
    services_arg              = local.services_arg
    remove_volumes_on_destroy = var.remove_volumes_on_destroy
  }

  # triggers_replace: cuando CUALQUIERA de estos valores cambia, Terraform
  # destruye y recrea el recurso (ejecuta destroy + apply de nuevo).
  # Así detectamos cambios en los compose files, el .env, o el perfil.
  triggers_replace = {
    profile       = var.profile
    compose_files = local.compose_files_arg
    build_images  = tostring(var.build_images)
    services      = join(",", var.services)

    # Hashes de los archivos: si el contenido cambia, el hash cambia,
    # y Terraform redespliega automáticamente.
    compose_main_sha = filesha256("${local.project_root}/docker-compose.yml")
    compose_dev_sha  = filesha256("${local.project_root}/docker-compose.dev.yml")
    env_sha          = local.env_hash

    # Token manual: cambia este string en local.tfvars para forzar un redeploy
    # aunque ningún archivo haya cambiado (útil para rollbacks o reinicios).
    force_redeploy = var.force_redeploy_token
  }

  # Se ejecuta al hacer `terraform apply`. Levanta o actualiza el stack.
  # interpreter = bash -lc: "login shell" carga el PATH completo del usuario,
  # lo que garantiza que el binario `docker` se encuentre aunque no esté en
  # el PATH mínimo de Terraform.
  provisioner "local-exec" {
    command     = "docker compose ${local.compose_files_arg} --profile ${self.input.profile} up -d${self.input.build_images ? " --build" : ""}${self.input.services_arg}"
    working_dir = self.input.project_root
    interpreter = ["/usr/bin/env", "bash", "-lc"]
  }

  # Se ejecuta al hacer `terraform destroy`. Baja el stack limpiamente.
  # Nota: aquí usamos self.input (no var.*) porque en destroy las variables
  # ya no son accesibles. self.input fue guardado en el estado de Terraform.
  provisioner "local-exec" {
    when        = destroy
    command     = "docker compose ${self.input.profile == "dev" ? "-f docker-compose.yml -f docker-compose.dev.yml" : "-f docker-compose.yml"} --profile ${self.input.profile} down --remove-orphans${self.input.remove_volumes_on_destroy ? " --volumes" : ""}"
    working_dir = self.input.project_root
    interpreter = ["/usr/bin/env", "bash", "-lc"]
  }
}

output "compose_working_dir" {
  description = "Directory where docker compose commands are executed."
  value       = local.project_root
}

output "active_profile" {
  description = "Compose profile managed by this Terraform stack."
  value       = var.profile
}
