# =============================================================================
# deploy.ps1 — Single-command deployment entrypoint (Windows PowerShell)
# =============================================================================
#
# Usage (from project root):
#   .\infra\scripts\deploy.ps1 -Profile dev  -Target local
#   .\infra\scripts\deploy.ps1 -Profile prod -Target local
#   .\infra\scripts\deploy.ps1 -Profile prod -Target aws
#   .\infra\scripts\deploy.ps1 -Profile prod -Target remote
#
# Parameters:
#   -Profile   dev | prod                              (required)
#   -Target    local | aws | remote                    (required)
#   -Action    plan | apply | destroy                  (default: apply)
#   -NoBuild   Skip --build flag (local target only)
#   -Hw        tiny | small | medium | large | auto    (optional)
#
# Hardware tiers (-Hw):
#   tiny    Dev laptop  — 2-4 cores / 4-8 GB   → Docker budget ~4 CPU / ~2 GB
#   small   Workstation — 4-8 cores / 8-16 GB  → Docker budget ~8 CPU / ~6 GB
#   medium  Server      — 8-32 cores / 32-64 GB → Docker budget ~27 CPU / ~27 GB
#   large   c5.24xlarge — 96 cores / 192 GB    → Docker budget ~96 CPU / ~152 GB
#   auto    Detect host specs and derive all parameters automatically.
#             local  → reads logical CPU count + total RAM from Windows WMI
#             aws    → queries the AWS API for the instance_type in aws.tfvars
#             remote → SSHs to the host and reads nproc + /proc/meminfo
#
#   If -Hw is omitted the values in your .env file are used as-is.
#   IMPORTANT: docker-compose.yml defaults are sized for large (c5.24xlarge).
#   Use -Hw auto or an explicit tier when deploying to any other machine.
#
# Prerequisites:
#   - Docker Desktop with "Use WSL 2 based engine" OR Docker Engine in WSL
#   - Terraform >= 1.5.0 in PATH
#   - AWS CLI configured (aws target)
#   - Root .env file filled in (Copy-Item .env.template .env)
#   - infra\envs\aws.tfvars    (aws target)
#   - infra\envs\remote.tfvars (remote target)
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("dev", "prod")]
    [string]$Profile,

    [Parameter(Mandatory = $true)]
    [ValidateSet("local", "aws", "remote")]
    [string]$Target,

    [ValidateSet("plan", "apply", "destroy")]
    [string]$Action = "apply",

    [switch]$NoBuild,

    [ValidateSet("tiny", "small", "medium", "large", "auto", "")]
    [string]$Hw = ""
)

# -------------------------------------------------------------------
# Ensure deploy.ps1 is stored as UTF-8 with BOM on Windows PowerShell
# This prevents encoding-related parsing issues on some Windows hosts.
# -------------------------------------------------------------------

try {
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        $scriptPath = $MyInvocation.MyCommand.Path

        if ($scriptPath -and (Test-Path $scriptPath)) {
            $content = Get-Content $scriptPath -Raw

            [System.IO.File]::WriteAllText(
                $scriptPath,
                $content,
                [System.Text.UTF8Encoding]::new($true)
            )
        }
    }
}
catch {
    Write-Warning "Failed to normalize deploy.ps1 encoding to UTF-8 with BOM."
}

$ErrorActionPreference = "Stop"

# Ensure consistent UTF-8 behavior in Windows PowerShell
try {
    [Console]::InputEncoding  = [System.Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $OutputEncoding           = [System.Text.UTF8Encoding]::new($false)
} catch {
    Write-Warning "Unable to set UTF-8 console encodings. Continuing with the system defaults."
}
try { cmd /c "chcp 65001 >nul" | Out-Null } catch { }

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Warning "PowerShell 7+ is recommended for consistent UTF-8 behavior."
}

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path
$InfraDir    = Join-Path $ProjectRoot "infra"

$TerraformMin     = [version]"1.5.0"
$TerraformInstall = "1.9.8"          # pinned fallback; update here if needed
$TerraformBinDir  = Join-Path $env:USERPROFILE ".local\bin\terraform"

# ─── Banner ──────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=================================================="
Write-Host " YouTube Clone — Deploy"
Write-Host "  profile : $Profile"
Write-Host "  target  : $Target"
Write-Host "  action  : $Action"
Write-Host "  hw tier : $(if ($Hw) { $Hw } else { '(not set — using .env values)' })"
Write-Host "=================================================="

# ─── Hardware auto-detection helpers ─────────────────────────────────────────

# x100 integer → "N.NN" CPU string  (e.g. 350 → "3.50")
function Format-CpuX100 ([int]$x100) {
    "{0}.{1:D2}" -f [int]($x100 / 100), ($x100 % 100)
}

# MB → Docker memory string  (e.g. 2048 → "2G", 768 → "768M")
function Format-DockerMem ([int]$mb) {
    if ($mb -ge 1024 -and $mb % 1024 -eq 0) { "$([int]($mb / 1024))G" } else { "${mb}M" }
}

# MB → PostgreSQL config string  (e.g. 2048 → "2GB", 512 → "512MB")
function Format-PgMem ([int]$mb) {
    if ($mb -ge 1024 -and $mb % 1024 -eq 0) { "$([int]($mb / 1024))GB" } else { "${mb}MB" }
}

# MB → Docker shm_size string (lowercase)  (e.g. 1024 → "1g", 256 → "256m")
function Format-ShmSize ([int]$mb) {
    if ($mb -ge 1024 -and $mb % 1024 -eq 0) { "$([int]($mb / 1024))g" } else { "${mb}m" }
}

# MB → Redis maxmemory string (lowercase)  (e.g. 4096 → "4gb", 512 → "512mb")
function Format-RedisMem ([int]$mb) {
    if ($mb -ge 1024 -and $mb % 1024 -eq 0) { "$([int]($mb / 1024))gb" } else { "${mb}mb" }
}

# Sets both a plain env var and its TF_VAR_<lowercase> counterpart.
function Set-HwEnvVar ([string]$key, [string]$value) {
    [System.Environment]::SetEnvironmentVariable($key, $value, "Process")
    [System.Environment]::SetEnvironmentVariable("TF_VAR_$($key.ToLower())", $value, "Process")
}

# Mirrors detect_hw_auto() from deploy.sh — queries the appropriate source for
# the current -Target, applies the same resource formulas, and exports all vars.
function Invoke-HwAutoDetect {
    $cpuTotal   = 0
    $memTotalMb = 0

    switch ($Target) {
        "local" {
            $cpuTotal = [Environment]::ProcessorCount

            try {
                if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
                    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
                    $memTotalMb = [int]($cs.TotalPhysicalMemory / 1MB)
                }
                else {
                    $cs = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop
                    $memTotalMb = [int]($cs.TotalPhysicalMemory / 1MB)
                }
            }
            catch {
                Write-Error "Unable to determine local physical memory."
                exit 1
            }
        }
        "aws" {
            $varFile = Join-Path $InfraDir "envs\aws.tfvars"
            $line = Get-Content -Path $varFile -Encoding UTF8 -ErrorAction SilentlyContinue |
                    Where-Object { $_ -match 'instance_type' } |
                    Select-Object -First 1
            $instanceType = if ($line) {
                [regex]::Match($line, '"([^"]*)"').Groups[1].Value
            } else { "" }

            if (-not $instanceType) {
                Write-Error "--hw auto on aws target requires instance_type in $varFile"
                exit 1
            }

            Write-Host "==> Querying AWS API for $instanceType specs..."
            $result = aws ec2 describe-instance-types `
                --instance-types $instanceType `
                --query 'InstanceTypes[0].{cpu:VCpuInfo.DefaultVCpus,mem_mib:MemoryInfo.SizeInMiB}' `
                --output text 2>$null

            if ($LASTEXITCODE -ne 0 -or -not $result) {
                Write-Error "--hw auto: AWS API query failed for '$instanceType'. Ensure credentials and ec2:DescribeInstanceTypes permission are configured."
                exit 1
            }

            $parts      = ($result.Trim() -split '\s+')
            $cpuTotal   = [int]$parts[0]
            $memTotalMb = [int]$parts[1]   # MiB ≈ MB
        }
        "remote" {
            $varFile = Join-Path $InfraDir "envs\remote.tfvars"
            $getField = {
                param([string]$pattern)
                $l = Get-Content -Path $varFile -Encoding UTF8 -ErrorAction SilentlyContinue |
                     Where-Object { $_ -match $pattern } | Select-Object -First 1
                if ($l) { [regex]::Match($l, '"([^"]*)"').Groups[1].Value } else { "" }
            }
            $remoteHost = & $getField 'host\s*='
            $sshUser    = & $getField 'ssh_user\s*='
            $sshKey     = & $getField 'ssh_private_key_path\s*='

            if (-not $remoteHost -or -not $sshUser -or -not $sshKey) {
                Write-Error "--hw auto on remote target requires host, ssh_user, and ssh_private_key_path in $varFile"
                exit 1
            }

            Write-Host "==> Detecting hardware on ${sshUser}@${remoteHost} via SSH..."
            $sshArgs = @("-i", $sshKey, "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
                         "-o", "ConnectTimeout=10", "${sshUser}@${remoteHost}")
            $cpuTotal   = [int](ssh @sshArgs "nproc" 2>$null)
            $memTotalMb = [int](ssh @sshArgs "awk '/MemTotal/{print int(`$2/1024)}' /proc/meminfo" 2>$null)
        }
    }

    if ($cpuTotal -le 0 -or $memTotalMb -le 0) {
        Write-Error "--hw auto could not determine hardware specs for target '$Target' (cpu=$cpuTotal mem_mb=$memTotalMb)."
        exit 1
    }

    Write-Host "==> Hardware auto-detected: $cpuTotal vCPU / $([int]($memTotalMb / 1024)) GB RAM"

    # ── Docker budget: reserve 15% CPU and 25% RAM for host OS ────────────────
    $dockerCpu   = [Math]::Max(1, [int]($cpuTotal * 85 / 100))
    $dockerMemMb = [int]($memTotalMb * 75 / 100)

    # ── Concurrency ────────────────────────────────────────────────────────────
    $workers           = [Math]::Max(2,  [int]($dockerCpu / 2))
    $workerConcurrency = [Math]::Min(12, [Math]::Max(1, [int]($workers / 2)))
    $dbPoolSize        = [Math]::Max(3,  [int]($workers / 2))
    $dbMaxOverflow     = $dbPoolSize
    $anyioMinThreads   = [Math]::Max(6,  $dbPoolSize + $dbMaxOverflow)
    $redisMaxConns     = [Math]::Max(40, [int]($anyioMinThreads * $workers * 2 * 11 / 10))
    $pgMaxConns        = [int]($workers * ($dbPoolSize + $dbMaxOverflow) * 11 / 10) + 10

    # ── CPU limits (×100 for integer math, formatted by Format-CpuX100) ───────
    # Distribution: backend 35%, postgres 24%, worker 12%, redis 12%, nginx 12%, frontend 5%
    $nginxCpuX100    = [Math]::Max(50,  $dockerCpu * 12)
    $postgresCpuX100 = [Math]::Max(100, $dockerCpu * 24)
    $redisCpuX100    = [Math]::Max(50,  $dockerCpu * 12)
    $backendCpuX100  = [Math]::Max(150, $dockerCpu * 35)
    $workerCpuX100   = [Math]::Max(50,  $dockerCpu * 12)
    $frontendCpuX100 = [Math]::Max(25,  $dockerCpu * 5)

    # Reservations ≈ 33% of limit (floor)
    $nginxCpuResX100    = [Math]::Max(25,  [int]($nginxCpuX100 / 3))
    $postgresCpuResX100 = [Math]::Max(50,  [int]($postgresCpuX100 / 3))
    $redisCpuResX100    = [Math]::Max(25,  [int]($redisCpuX100 / 3))
    $backendCpuResX100  = [Math]::Max(100, [int]($backendCpuX100 / 6))
    $workerCpuResX100   = [Math]::Max(25,  [int]($workerCpuX100 / 3))
    $frontendCpuResX100 = [Math]::Max(10,  [int]($frontendCpuX100 / 3))

    # ── Memory limits (MB) ─────────────────────────────────────────────────────
    # Distribution: postgres 35%, backend 35%, redis 13%, worker 13%, nginx 2%, frontend 2%
    $postgresMemMb = [Math]::Max(512, [int]($dockerMemMb * 35 / 100))
    $redisMemMb    = [Math]::Max(256, [int]($dockerMemMb * 13 / 100))
    $backendMemMb  = [Math]::Max(768, [int]($dockerMemMb * 35 / 100))
    $workerMemMb   = [Math]::Max(256, [int]($dockerMemMb * 13 / 100))
    $nginxMemMb    = [Math]::Max(128, [int]($dockerMemMb * 2  / 100))
    $frontendMemMb = [Math]::Max(128, [int]($dockerMemMb * 2  / 100))

    # Reservations ≈ 25% of limit
    $nginxMemResMb    = [Math]::Max(64,  [int]($nginxMemMb / 4))
    $postgresMemResMb = [Math]::Max(256, [int]($postgresMemMb / 4))
    $redisMemResMb    = [Math]::Max(128, [int]($redisMemMb / 4))
    $backendMemResMb  = [Math]::Max(256, [int]($backendMemMb / 4))
    $workerMemResMb   = [Math]::Max(128, [int]($workerMemMb / 4))
    $frontendMemResMb = [Math]::Max(64,  [int]($frontendMemMb / 4))

    # ── PostgreSQL internal tuning ─────────────────────────────────────────────
    $pgSharedBuffersMb  = [int]($postgresMemMb / 4)
    $pgEffectiveCacheMb = [int]($postgresMemMb * 3 / 4)
    $pgWorkMemMb        = if ($dbPoolSize -gt 6) { 16 } else { 8 }
    $pgMaintenanceMb    = [Math]::Max(32, [int]($postgresMemMb / 16))
    $pgShmMb            = [Math]::Max(256, $pgSharedBuffersMb * 2)
    $redisMaxmemMb      = [int]($redisMemMb * 85 / 100)

    # ── Export all vars (same names used by hw-*.env and docker-compose.yml) ───
    Set-HwEnvVar "BACKEND_WEB_CONCURRENCY"              "$workers"
    Set-HwEnvVar "WORKER_CONCURRENCY"                   "$workerConcurrency"
    Set-HwEnvVar "DB_POOL_SIZE"                         "$dbPoolSize"
    Set-HwEnvVar "DB_MAX_OVERFLOW"                      "$dbMaxOverflow"
    Set-HwEnvVar "DB_POOL_TIMEOUT"                      "3"
    Set-HwEnvVar "REDIS_MAX_CONNECTIONS"                "$redisMaxConns"
    Set-HwEnvVar "LOG_LEVEL"                            "WARNING"
    Set-HwEnvVar "ANYIO_MIN_THREADS"                    "$anyioMinThreads"
    Set-HwEnvVar "BACKEND_GUNICORN_MAX_REQUESTS"        "2000"
    Set-HwEnvVar "BACKEND_GUNICORN_MAX_REQUESTS_JITTER" "200"
    Set-HwEnvVar "VIDEO_DETAIL_CACHE_TTL"               "60"

    Set-HwEnvVar "POSTGRES_MAX_CONNECTIONS"             "$pgMaxConns"
    Set-HwEnvVar "POSTGRES_SHARED_BUFFERS"              (Format-PgMem $pgSharedBuffersMb)
    Set-HwEnvVar "POSTGRES_EFFECTIVE_CACHE_SIZE"        (Format-PgMem $pgEffectiveCacheMb)
    Set-HwEnvVar "POSTGRES_WORK_MEM"                    "${pgWorkMemMb}MB"
    Set-HwEnvVar "POSTGRES_MAINTENANCE_WORK_MEM"        (Format-PgMem $pgMaintenanceMb)
    Set-HwEnvVar "POSTGRES_SHM_SIZE"                    (Format-ShmSize $pgShmMb)
    Set-HwEnvVar "REDIS_MAXMEMORY"                      (Format-RedisMem $redisMaxmemMb)

    Set-HwEnvVar "NGINX_CPU_LIMIT"                      (Format-CpuX100 $nginxCpuX100)
    Set-HwEnvVar "NGINX_MEMORY_LIMIT"                   (Format-DockerMem $nginxMemMb)
    Set-HwEnvVar "NGINX_CPU_RESERVATION"                (Format-CpuX100 $nginxCpuResX100)
    Set-HwEnvVar "NGINX_MEMORY_RESERVATION"             (Format-DockerMem $nginxMemResMb)

    Set-HwEnvVar "POSTGRES_CPU_LIMIT"                   (Format-CpuX100 $postgresCpuX100)
    Set-HwEnvVar "POSTGRES_MEMORY_LIMIT"                (Format-DockerMem $postgresMemMb)
    Set-HwEnvVar "POSTGRES_CPU_RESERVATION"             (Format-CpuX100 $postgresCpuResX100)
    Set-HwEnvVar "POSTGRES_MEMORY_RESERVATION"          (Format-DockerMem $postgresMemResMb)

    Set-HwEnvVar "REDIS_CPU_LIMIT"                      (Format-CpuX100 $redisCpuX100)
    Set-HwEnvVar "REDIS_MEMORY_LIMIT"                   (Format-DockerMem $redisMemMb)
    Set-HwEnvVar "REDIS_CPU_RESERVATION"                (Format-CpuX100 $redisCpuResX100)
    Set-HwEnvVar "REDIS_MEMORY_RESERVATION"             (Format-DockerMem $redisMemResMb)

    Set-HwEnvVar "BACKEND_CPU_LIMIT"                    (Format-CpuX100 $backendCpuX100)
    Set-HwEnvVar "BACKEND_MEMORY_LIMIT"                 (Format-DockerMem $backendMemMb)
    Set-HwEnvVar "BACKEND_CPU_RESERVATION"              (Format-CpuX100 $backendCpuResX100)
    Set-HwEnvVar "BACKEND_MEMORY_RESERVATION"           (Format-DockerMem $backendMemResMb)

    Set-HwEnvVar "WORKER_CPU_LIMIT"                     (Format-CpuX100 $workerCpuX100)
    Set-HwEnvVar "WORKER_MEMORY_LIMIT"                  (Format-DockerMem $workerMemMb)
    Set-HwEnvVar "WORKER_CPU_RESERVATION"               (Format-CpuX100 $workerCpuResX100)
    Set-HwEnvVar "WORKER_MEMORY_RESERVATION"            (Format-DockerMem $workerMemResMb)

    Set-HwEnvVar "FRONTEND_CPU_LIMIT"                   (Format-CpuX100 $frontendCpuX100)
    Set-HwEnvVar "FRONTEND_MEMORY_LIMIT"                (Format-DockerMem $frontendMemMb)
    Set-HwEnvVar "FRONTEND_CPU_RESERVATION"             (Format-CpuX100 $frontendCpuResX100)
    Set-HwEnvVar "FRONTEND_MEMORY_RESERVATION"          (Format-DockerMem $frontendMemResMb)

    Write-Host "==> Auto-configured: $workers workers · pool=${dbPoolSize}+${dbMaxOverflow} · anyio=$anyioMinThreads · redis_conns=$redisMaxConns · postgres_conns=$pgMaxConns"
}

# ─── Hardware profile loader ─────────────────────────────────────────────────
# Reads infra/envs/hw-<tier>.env and exports each variable two ways:
#   1. As a process environment variable (docker compose reads these)
#   2. As TF_VAR_<lowercase_name> (Terraform reads these)
# Variable naming is consistent: NGINX_CPU_LIMIT → TF_VAR_nginx_cpu_limit ✓

function Import-HwProfile {
    if (-not $Hw) { return }

    if ($Hw -eq "auto") {
        Invoke-HwAutoDetect
        return
    }

    $hwFile = Join-Path $InfraDir "envs\hw-$Hw.env"
    if (-not (Test-Path $hwFile)) {
        Write-Error "Hardware profile file not found: $hwFile"
        exit 1
    }

    Write-Host "==> Loading hardware profile: $Hw ($hwFile)"

    foreach ($rawLine in Get-Content -Path $hwFile -Encoding UTF8) {
        $line = $rawLine.Trim()
        if ($line -match "^#" -or $line -eq "") { continue }

        $eqIdx = $line.IndexOf("=")
        if ($eqIdx -lt 0) { continue }

        $key   = $line.Substring(0, $eqIdx).Trim()
        $value = $line.Substring($eqIdx + 1).Trim()

        # Export for docker compose
        [System.Environment]::SetEnvironmentVariable($key, $value, "Process")

        # Export as TF_VAR_<lowercase> for Terraform
        $tfKey = "TF_VAR_$($key.ToLower())"
        [System.Environment]::SetEnvironmentVariable($tfKey, $value, "Process")
    }
}

# ─── Dependency checker ──────────────────────────────────────────────────────

function Install-Terraform {
    $arch = switch ($env:PROCESSOR_ARCHITECTURE) {
        "AMD64" { "amd64" }
        "ARM64" { "arm64" }
        default { Write-Error "Unsupported CPU architecture: $env:PROCESSOR_ARCHITECTURE"; exit 1 }
    }

    $zip    = "terraform_${TerraformInstall}_windows_${arch}.zip"
    $url    = "https://releases.hashicorp.com/terraform/${TerraformInstall}/${zip}"
    $tmpDir = Join-Path $env:TEMP "tf_install_$(Get-Random)"

    Write-Host "==> Installing Terraform $TerraformInstall to $TerraformBinDir..."
    New-Item -ItemType Directory -Force -Path $TerraformBinDir | Out-Null
    New-Item -ItemType Directory -Force -Path $tmpDir          | Out-Null

    $zipPath = Join-Path $tmpDir $zip
    try {
        Write-Host "==> Downloading $url"
        Invoke-WebRequest -Uri $url -OutFile $zipPath
        Expand-Archive -Path $zipPath -DestinationPath $tmpDir -Force
        Move-Item -Force (Join-Path $tmpDir "terraform.exe") (Join-Path $TerraformBinDir "terraform.exe")
    } finally {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
    }

    $env:PATH = "$TerraformBinDir;$env:PATH"
    Write-Host "==> Terraform $TerraformInstall ready at $TerraformBinDir\terraform.exe"
    Write-Host "    To persist: add '$TerraformBinDir' to your user PATH via System Properties."
}

function Install-Docker {
    Write-Host "==> Installing Docker Desktop via winget (this may take a few minutes)..."
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Warning "winget not available. Install Docker Desktop manually: https://www.docker.com/products/docker-desktop/"
        exit 1
    }
    winget install -e --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Docker Desktop installation failed. Install manually: https://www.docker.com/products/docker-desktop/"
        exit 1
    }
    Write-Host "==> Docker Desktop installed."
    Write-Host "    A system restart or WSL2 setup may be required."
    Write-Host "    After Docker Desktop is running, re-run this script."
    exit 0
}

function Install-AwsCli {
    Write-Host "==> Installing AWS CLI..."

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install -e --id Amazon.AWSCLI --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) {
            Write-Error "AWS CLI installation via winget failed."
            exit 1
        }
    } else {
        Write-Host "==> winget not found — falling back to MSI installer..."
        $msiUrl = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
            "https://awscli.amazonaws.com/AWSCLIV2-arm64.msi"
        } else {
            "https://awscli.amazonaws.com/AWSCLIV2.msi"
        }
        $msiPath = Join-Path $env:TEMP "AWSCLIV2.msi"
        Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath
        Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /qn" -Wait
        Remove-Item $msiPath -ErrorAction SilentlyContinue
    }

    # Refresh PATH so aws is callable in this session
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")

    Write-Host "==> AWS CLI installed."
    Write-Host "    Run 'aws configure' to set up your credentials."
}

function Test-Dependencies {
    Write-Host ""
    Write-Host "==> Checking dependencies..."
    $errors = 0

    # ── Docker + Compose (local target only) ─────────────────────────────────
    if ($Target -eq "local") {
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
            Write-Host "[MISSING] docker — auto-installing..."
            Install-Docker  # exits after install; user must restart/re-run
        }

        cmd /c "docker info >nul 2>nul"
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[STOPPED] Docker daemon is not running — attempting to start Docker Desktop..."
            $dockerExe = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
            if (Test-Path $dockerExe) {
                Start-Process $dockerExe
                Write-Host "          Waiting up to 30 seconds for Docker to become ready..."
                $deadline = (Get-Date).AddSeconds(30)
                while ((Get-Date) -lt $deadline) {
                    Start-Sleep -Seconds 3
                    cmd /c "docker info >nul 2>nul"
                    if ($LASTEXITCODE -eq 0) { break }
                }
            }
            cmd /c "docker info >nul 2>nul"
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "[ERROR]   Docker daemon still not reachable. Start Docker Desktop manually and retry."
                $errors++
            } else {
                Write-Host "[OK]      Docker daemon started"
            }
        } else {
            Write-Host "[OK]      $(docker --version)"
        }

        cmd /c "docker compose version >nul 2>nul"
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "[MISSING] docker compose plugin — included with Docker Desktop; ensure it is up to date."
            $errors++
        } else {
            Write-Host "[OK]      $(docker compose version)"
        }
    }

    # ── Terraform (all targets) ───────────────────────────────────────────────
    if (Get-Command terraform -ErrorAction SilentlyContinue) {
        $tfVerRaw = $null
        try {
            $tfJson   = terraform version -json 2>$null | ConvertFrom-Json -ErrorAction Stop
            $tfVerRaw = $tfJson.terraform_version
        } catch {
            $m = (terraform version 2>$null | Select-String -Pattern '\d+\.\d+\.\d+').Matches
            if ($m.Count -gt 0) { $tfVerRaw = $m[0].Value }
        }

        if ($tfVerRaw -and ([version]$tfVerRaw -ge $TerraformMin)) {
            Write-Host "[OK]      terraform $tfVerRaw"
        } else {
            Write-Warning "[OLD]     terraform $tfVerRaw < $TerraformMin — auto-installing $TerraformInstall..."
            Install-Terraform
        }
    } else {
        Write-Host "[MISSING] terraform — auto-installing $TerraformInstall..."
        Install-Terraform
    }

    # ── .env file and required values (all targets) ─────────────────────────
    $envFile = Join-Path $ProjectRoot ".env"
    if (-not (Test-Path $envFile)) {
        Write-Warning "[MISSING] .env — copy the template and fill in your values:"
        Write-Warning "          Copy-Item .env.template .env"
        $errors++
    } else {
        $jwtLine = Get-Content -Path $envFile -Encoding UTF8 | Where-Object { $_ -match "^JWT_SECRET_KEY=" } | Select-Object -First 1
        $jwtKey  = if ($jwtLine) { ($jwtLine -split "=", 2)[1].Trim().Trim('"').Trim("'") } else { "" }
        if (-not $jwtKey -or $jwtKey -eq "REPLACE_WITH_STRONG_SECRET_MIN_32_CHARS" -or $jwtKey.Length -lt 32) {
            Write-Warning "[INVALID] .env: JWT_SECRET_KEY is missing, too short (< 32 chars), or still the template placeholder."
            Write-Warning "          Generate: python -c `"import secrets; print(secrets.token_urlsafe(48))`""
            $errors++
        } else {
            Write-Host "[OK]      .env (JWT_SECRET_KEY set)"
        }

        $pgLine = Get-Content -Path $envFile -Encoding UTF8 | Where-Object { $_ -match "^POSTGRES_PASSWORD=" } | Select-Object -First 1
        $pgPass = if ($pgLine) { ($pgLine -split "=", 2)[1].Trim().Trim('"').Trim("'") } else { "" }
        if (-not $pgPass -or $pgPass -eq "StrongPassword12!") {
            Write-Warning "[INVALID] .env: POSTGRES_PASSWORD is empty or still the template default (StrongPassword12!)."
            $errors++
        }
    }

    # ── AWS CLI + credentials (aws target) ───────────────────────────────────
    if ($Target -eq "aws") {
        if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
            Write-Host "[MISSING] aws CLI — auto-installing..."
            Install-AwsCli
        }
        if (Get-Command aws -ErrorAction SilentlyContinue) {
            Write-Host "[OK]      $(aws --version 2>&1)"
            aws sts get-caller-identity 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "[INVALID] AWS credentials not configured or expired."
                Write-Warning "          Run: aws configure   (or set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY)"
                $errors++
            } else {
                $acct = (aws sts get-caller-identity --query Account --output text 2>$null)
                Write-Host "[OK]      AWS account $acct"
            }
        } else {
            Write-Warning "[ERROR]   aws CLI still not found after install attempt."
            $errors++
        }
    }

    # ── SSH client (remote target) ────────────────────────────────────────────
    if ($Target -eq "remote") {
        if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
            Write-Warning "[MISSING] ssh — enable via: Settings > System > Optional features > OpenSSH Client"
            $errors++
        } else {
            Write-Host "[OK]      ssh"
        }
    }

    if ($errors -gt 0) {
        Write-Error "$errors dependency check(s) failed. Resolve the issues above and retry."
        exit 1
    }

    Write-Host "==> All dependencies satisfied."
}

# ─── .env → TF_VAR_* loader ──────────────────────────────────────────────────

function Import-EnvAsTfVars {
    $envFile = Join-Path $ProjectRoot ".env"

    if (-not (Test-Path $envFile)) {
        Write-Warning ".env not found at $envFile"
        Write-Warning "Tip: Copy-Item .env.template .env  (then fill in real values)"
        return
    }

    # Mapping: .env key → Terraform variable name
    $tfMap = @{
        "POSTGRES_USER"                  = "postgres_user"
        "POSTGRES_PASSWORD"              = "postgres_password"
        "POSTGRES_DB"                    = "postgres_db"
        "REDIS_PASSWORD"                 = "redis_password"
        "JWT_SECRET_KEY"                 = "jwt_secret_key"
        "JWT_ACCESS_TOKEN_EXP_MINUTES"   = "jwt_access_token_exp_minutes"
        "BACKEND_WEB_CONCURRENCY"        = "backend_web_concurrency"
        "WORKER_CONCURRENCY"             = "worker_concurrency"
    }

    $corsRaw = $null

    foreach ($rawLine in Get-Content -Path $envFile -Encoding UTF8) {
        $line = $rawLine.Trim()
        # Skip comments and blank lines
        if ($line -match "^#" -or $line -eq "") { continue }

        # Split on first '=' only
        $eqIdx = $line.IndexOf("=")
        if ($eqIdx -lt 0) { continue }

        $key   = $line.Substring(0, $eqIdx).Trim()
        $value = $line.Substring($eqIdx + 1).Trim().Trim('"').Trim("'")

        if ($tfMap.ContainsKey($key)) {
            $varName = "TF_VAR_$($tfMap[$key])"
            [System.Environment]::SetEnvironmentVariable($varName, $value, "Process")
        }

        if ($key -eq "CORS_ALLOW_ORIGINS") {
            $corsRaw = $value
        }
    }

    # CORS: comma-separated string → Terraform list JSON
    # Input:  "http://localhost:5173,http://127.0.0.1"
    # Output: ["http://localhost:5173","http://127.0.0.1"]
    if ($corsRaw) {
        $origins = $corsRaw -split "," | ForEach-Object { "`"$($_.Trim())`"" }
        $corsJson = "[" + ($origins -join ",") + "]"
        [System.Environment]::SetEnvironmentVariable("TF_VAR_cors_allow_origins", $corsJson, "Process")
    }
}

# ─── Terraform execution helper ──────────────────────────────────────────────

function Invoke-Terraform {
    param(
        [string]$ModuleDir,
        [string]$VarFile
    )

    Write-Host ""
    Write-Host "==> Working dir: $ModuleDir"
    Push-Location $ModuleDir

    try {
        Write-Host "==> terraform init"
        $terraformArgs = @("init", "-input=false")
        & terraform @terraformArgs
        if ($LASTEXITCODE -ne 0) { throw "terraform init failed" }

        switch ($Action) {
            "plan" {
                Write-Host "==> terraform plan"
                $terraformArgs = @("plan", "-input=false", "-var-file=$VarFile")
            }
            "apply" {
                Write-Host "==> terraform apply"
                $terraformArgs = @("apply", "-input=false", "-auto-approve", "-var-file=$VarFile")
            }
            "destroy" {
                Write-Host "==> terraform destroy"
                $terraformArgs = @("destroy", "-input=false", "-auto-approve", "-var-file=$VarFile")
            }
        }

        if ($terraformArgs.Count -gt 0 -and $terraformArgs[0] -ne "init") {
            & terraform @terraformArgs
        }

        if ($LASTEXITCODE -ne 0) { throw "terraform $Action failed" }
    }
    finally {
        Pop-Location
    }
}

# ─── Target: local ───────────────────────────────────────────────────────────
# On Windows, docker compose is called directly to avoid the Terraform
# local-exec bash interpreter dependency. This is equivalent to what
# deploy.sh does via Terraform on Linux/WSL.

function Deploy-Local {
    Write-Host "==> Target: local | Profile: $Profile | Action: $Action"

    $envFile = Join-Path $ProjectRoot ".env"
    if (-not (Test-Path $envFile)) {
        Write-Error ".env not found. Run: Copy-Item .env.template .env"
        exit 1
    }

    $composeBaseArgs = @("compose")
    if ($Profile -eq "dev") {
        $composeBaseArgs += @("-f", "docker-compose.yml", "-f", "docker-compose.dev.yml")
    } else {
        $composeBaseArgs += @("-f", "docker-compose.yml")
    }
    $composeBaseArgs += @("--profile", $Profile)

    Push-Location $ProjectRoot
    try {
        switch ($Action) {
            "apply" {
                $dockerArgs = $composeBaseArgs + @("up", "-d")
                if (-not $NoBuild) { $dockerArgs += "--build" }
                Write-Host "==> docker $($dockerArgs -join ' ')"
                & docker @dockerArgs
            }
            "destroy" {
                $dockerArgs = $composeBaseArgs + @("down", "--remove-orphans")
                Write-Host "==> docker $($dockerArgs -join ' ')"
                & docker @dockerArgs
            }
            "plan" {
                # Show resolved compose config without starting anything
                $dockerArgs = $composeBaseArgs + @("config")
                Write-Host "==> docker $($dockerArgs -join ' ')  (dry-run: shows resolved config)"
                & docker @dockerArgs
            }
        }
        if ($LASTEXITCODE -ne 0) { throw "docker compose $Action failed" }
    }
    finally {
        Pop-Location
    }
}

# ─── Target: aws ─────────────────────────────────────────────────────────────

function Deploy-Aws {
    Write-Host "==> Target: aws | Profile: $Profile | Action: $Action"

    $varFile = Join-Path $InfraDir "envs\aws.tfvars"
    if (-not (Test-Path $varFile)) {
        Write-Error @"
$varFile not found.
Tip: Copy-Item $InfraDir\envs\aws.tfvars.example $varFile
     then fill in repo_url, instance_type, etc.
"@
        exit 1
    }

    Import-EnvAsTfVars
    Invoke-Terraform -ModuleDir (Join-Path $InfraDir "aws") -VarFile $varFile
}

# ─── Target: remote ──────────────────────────────────────────────────────────

function Deploy-Remote {
    Write-Host "==> Target: remote | Profile: $Profile | Action: $Action"

    $varFile = Join-Path $InfraDir "envs\remote.tfvars"
    if (-not (Test-Path $varFile)) {
        Write-Error @"
$varFile not found.
Tip: Copy-Item $InfraDir\envs\remote.tfvars.example $varFile
     then fill in host, ssh_user, ssh_private_key_path, repo_url.
"@
        exit 1
    }

    [System.Environment]::SetEnvironmentVariable("TF_VAR_profile", $Profile, "Process")
    Import-EnvAsTfVars
    Invoke-Terraform -ModuleDir (Join-Path $InfraDir "remote") -VarFile $varFile
}

# ─── Dispatch ────────────────────────────────────────────────────────────────

Test-Dependencies
Import-HwProfile

switch ($Target) {
    "local"  { Deploy-Local }
    "aws"    { Deploy-Aws }
    "remote" { Deploy-Remote }
}

Write-Host ""
Write-Host "=================================================="
Write-Host " Done: target=$Target profile=$Profile action=$Action"
Write-Host "=================================================="
