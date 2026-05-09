terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ─── Locals ───────────────────────────────────────────────────────────────────
# Valores derivados calculados una sola vez y reutilizados en múltiples recursos.

locals {
  # Prefijo compartido para nombrar todos los recursos AWS de forma consistente.
  # Ejemplo: "youtube-clone-prod"
  name_prefix = "${var.project_name}-${var.environment}"

  # Resolución de VPC en tres pasos (prioridad de mayor a menor):
  #   1. Si el usuario proveyó vpc_id → usarlo directamente.
  #   2. Si el usuario proveyó subnet_id → leer la VPC dueña de esa subnet.
  #   3. Si no se proveyó nada → usar la VPC default de la cuenta AWS.
  vpc_id = (
    var.vpc_id != "" ? var.vpc_id : (
      var.subnet_id != "" ? data.aws_subnet.provided[0].vpc_id : data.aws_vpc.default[0].id
    )
  )

  # Resolución de subnet: si no se especificó, elegir la primera en orden
  # alfabético de la VPC seleccionada. sort() garantiza determinismo.
  subnet_id = var.subnet_id != "" ? var.subnet_id : sort(data.aws_subnets.selected[0].ids)[0]

  # urlencode() es crítico: si la contraseña tiene caracteres reservados en URLs
  # (p.ej. '@', '/', ':') la conexión fallaría sin encodear.
  database_url = format(
    "postgresql+psycopg://%s:%s@postgres:5432/%s",
    urlencode(var.postgres_user),
    urlencode(var.postgres_password),
    urlencode(var.postgres_db)
  )

  # Si no hay contraseña de Redis (desarrollo) la URL no lleva credenciales.
  redis_url = (
    var.redis_password != ""
    ? format("redis://:%s@redis:6379/0", urlencode(var.redis_password))
    : "redis://redis:6379/0"
  )

  # Tags base aplicados a todos los recursos; se mezclan con tags adicionales
  # del usuario vía merge(). Los tags de aquí tienen prioridad sobre var.tags.
  common_tags = merge(
    var.tags,
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  )
}

# ─── Data sources ─────────────────────────────────────────────────────────────
# Los data sources leen información ya existente en AWS (no crean recursos).
# El patrón `count = condición ? 1 : 0` hace el data source opcional:
#   count = 1 → se consulta  |  count = 0 → se ignora

# VPC default de la cuenta. Solo se consulta cuando no se especificó vpc_id ni subnet_id.
data "aws_vpc" "default" {
  count   = var.vpc_id == "" && var.subnet_id == "" ? 1 : 0
  default = true
}

# Datos de la subnet que el usuario indicó explícitamente (para leer su vpc_id).
data "aws_subnet" "provided" {
  count = var.subnet_id != "" ? 1 : 0
  id    = var.subnet_id
}

# Todas las subnets de la VPC seleccionada. Solo cuando el usuario no indicó subnet_id.
data "aws_subnets" "selected" {
  count = var.subnet_id == "" ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [local.vpc_id]
  }
}

# AMI más reciente de Ubuntu 24.04 LTS publicada por Canonical (owner 099720109477).
# Solo se busca si el usuario no indicó un ami_id propio.
data "aws_ami" "ubuntu" {
  count       = var.ami_id == "" ? 1 : 0
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ─── Security Group ───────────────────────────────────────────────────────────
# Firewall a nivel de instancia. Define qué tráfico entra y sale de la EC2.

resource "aws_security_group" "app" {
  name        = "${local.name_prefix}-sg"
  description = "Ingress for the YouTube clone single-node deployment"
  vpc_id      = local.vpc_id

  # Puerto 80: tráfico HTTP público hacia Nginx.
  ingress {
    description = "HTTP via Nginx"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.http_cidr_blocks
  }

  # Puerto 22: SSH para administración. Se crea SOLO si ssh_cidr_blocks no está vacío.
  # dynamic permite omitir el bloque por completo en lugar de crear una regla vacía.
  dynamic "ingress" {
    for_each = length(var.ssh_cidr_blocks) > 0 ? [1] : []

    content {
      description = "SSH administration"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = var.ssh_cidr_blocks
    }
  }

  # Salida irrestricta: necesario para que la EC2 pueda instalar paquetes,
  # clonar el repo y descargar imágenes Docker al arrancar.
  egress {
    description = "Outbound internet for package installs, git clone, and image pulls"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-sg"
  })
}

# ─── EC2 Instance ─────────────────────────────────────────────────────────────

resource "aws_instance" "app" {
  ami           = var.ami_id != "" ? var.ami_id : data.aws_ami.ubuntu[0].id
  instance_type = var.instance_type
  subnet_id     = local.subnet_id

  vpc_security_group_ids      = [aws_security_group.app.id]
  associate_public_ip_address = true
  key_name                    = var.key_name != "" ? var.key_name : null

  # Si user_data cambia (nueva versión del script de arranque), Terraform
  # destruye y recrea la instancia automáticamente.
  user_data_replace_on_change = true

  # user_data es el script bash que se ejecuta UNA SOLA VEZ cuando la EC2
  # arranca por primera vez. Terraform inyecta las variables del .env aquí,
  # así que los secretos nunca viajan por SSH ni quedan en el estado visible.
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    # Core application
    app_env                      = var.app_env
    auth_token_issuer_enabled    = var.auth_token_issuer_enabled
    cors_allow_origins           = jsonencode(var.cors_allow_origins)
    database_url                 = local.database_url
    jwt_access_token_exp_minutes = var.jwt_access_token_exp_minutes
    jwt_secret_key               = var.jwt_secret_key
    postgres_db                  = var.postgres_db
    postgres_password            = var.postgres_password
    postgres_user                = var.postgres_user
    project_name                 = var.project_name
    redis_password               = var.redis_password
    redis_url                    = local.redis_url
    repo_ref                     = var.repo_ref
    repo_url                     = var.repo_url
    # Concurrency
    backend_web_concurrency      = var.backend_web_concurrency
    worker_concurrency           = var.worker_concurrency
    # SQLAlchemy pool
    db_pool_size                 = var.db_pool_size
    db_max_overflow              = var.db_max_overflow
    redis_max_connections        = var.redis_max_connections
    # PostgreSQL tuning
    postgres_max_connections     = var.postgres_max_connections
    postgres_shared_buffers      = var.postgres_shared_buffers
    postgres_effective_cache_size = var.postgres_effective_cache_size
    postgres_work_mem            = var.postgres_work_mem
    postgres_maintenance_work_mem = var.postgres_maintenance_work_mem
    postgres_shm_size            = var.postgres_shm_size
    # Redis tuning
    redis_maxmemory              = var.redis_maxmemory
    # Container resource limits
    nginx_cpu_limit              = var.nginx_cpu_limit
    nginx_memory_limit           = var.nginx_memory_limit
    postgres_cpu_limit           = var.postgres_cpu_limit
    postgres_memory_limit        = var.postgres_memory_limit
    redis_cpu_limit              = var.redis_cpu_limit
    redis_memory_limit           = var.redis_memory_limit
    backend_cpu_limit            = var.backend_cpu_limit
    backend_memory_limit         = var.backend_memory_limit
    worker_cpu_limit             = var.worker_cpu_limit
    worker_memory_limit          = var.worker_memory_limit
    frontend_cpu_limit           = var.frontend_cpu_limit
    frontend_memory_limit        = var.frontend_memory_limit
  })

  metadata_options {
    http_endpoint = "enabled"
    # IMDSv2: obliga a usar tokens para acceder a los metadatos de la instancia.
    # Previene ataques SSRF que intenten robar credenciales del metadata service.
    http_tokens = "required"
  }

  root_block_device {
    volume_size = var.root_volume_size_gb
    volume_type = "gp3"
    # Cifrado en reposo para el disco. Protege datos si el volumen es detachado.
    encrypted             = true
    delete_on_termination = true
  }

  timeouts {
    create = "10m"
  }

  tags = merge(local.common_tags, {
    Name = local.name_prefix
  })
}

# ─── Elastic IP (opcional) ────────────────────────────────────────────────────
# Por defecto AWS asigna una IP pública efímera que cambia al parar/iniciar la
# instancia. Un EIP es una IP fija que persiste aunque la instancia se reinicie.
# Costo adicional si la instancia está parada; no recomendado para hackathon.

resource "aws_eip" "app" {
  count    = var.create_eip ? 1 : 0
  domain   = "vpc"
  instance = aws_instance.app.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-eip"
  })
}
