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

$ErrorActionPreference = "Stop"

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
            $cpuTotal   = [Environment]::ProcessorCount
            $cs         = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
            $memTotalMb = [int]($cs.TotalPhysicalMemory / 1MB)
        }
        "aws" {
            $varFile = Join-Path $InfraDir "envs\aws.tfvars"
            $line = Get-Content $varFile -ErrorAction SilentlyContinue |
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
                $l = Get-Content $varFile -ErrorAction SilentlyContinue |
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

    Get-Content $hwFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -match "^#" -or $line -eq "") { return }

        $eqIdx = $line.IndexOf("=")
        if ($eqIdx -lt 0) { return }

        $key   = $line.Substring(0, $eqIdx).Trim()
        $value = $line.Substring($eqIdx + 1).Trim()

        # Export for docker compose
        [System.Environment]::SetEnvironmentVariable($key, $value, "Process")

        # Export as TF_VAR_<lowercase> for Terraform
        $tfKey = "TF_VAR_$($key.ToLower())"
        [System.Environment]::SetEnvironmentVariable($tfKey, $value, "Process")
    }
}


# ─── Hardware requirement validation helpers ─────────────────────────────────

function Read-EnvFileMap {
    param([Parameter(Mandatory = $true)][string]$Path)

    $map = @{}
    if (-not (Test-Path $Path)) { return $map }

    Get-Content $Path -ErrorAction SilentlyContinue | ForEach-Object {
        $line = $_.Trim()
        if (-not $line) { return }
        if ($line.StartsWith('#')) { return }
        if ($line.StartsWith('export ')) { $line = $line.Substring(7).Trim() }

        $eqIdx = $line.IndexOf('=')
        if ($eqIdx -lt 1) { return }

        $key = $line.Substring(0, $eqIdx).Trim()
        $value = $line.Substring($eqIdx + 1).Trim()

        if ($value.Length -ge 2) {
            $startsQuoted = ($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))
            if ($startsQuoted) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }

        $map[$key] = $value
    }

    return $map
}

function ConvertTo-CpuValue {
    param([string]$Raw)

    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }

    $clean = $Raw.Trim().ToLowerInvariant().Replace(',', '.')
    if ($clean -match '^(?<v>\d+(?:\.\d+)?)\s*(?<u>cpu|cpus|vcpu|vcpus|core|cores)?$') {
        return [double]$Matches['v']
    }

    return $null
}

function ConvertTo-MemoryMbValue {
    param([string]$Raw)

    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }

    $clean = $Raw.Trim().ToLowerInvariant().Replace(',', '.')
    if ($clean -match '^(?<v>\d+(?:\.\d+)?)(?<u>tb|t|gb|g|mb|m|kb|k)?$') {
        $v = [double]$Matches['v']
        switch ($Matches['u']) {
            'tb' { return [int]([math]::Round($v * 1024 * 1024)) }
            't'  { return [int]([math]::Round($v * 1024 * 1024)) }
            'gb' { return [int]([math]::Round($v * 1024)) }
            'g'  { return [int]([math]::Round($v * 1024)) }
            'kb' { return [int]([math]::Round($v / 1024)) }
            'k'  { return [int]([math]::Round($v / 1024)) }
            'mb' { return [int]([math]::Round($v)) }
            'm'  { return [int]([math]::Round($v)) }
            default { return [int]([math]::Round($v)) }
        }
    }

    return $null
}

function Get-ResourceSummaryFromMap {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$Map
    )

    $summary = [ordered]@{
        Name         = $Name
        CpuLimits    = @{}
        MemoryLimits = @{}
        TotalCpu     = 0.0
        TotalMemoryMb = 0
        MaxCpu       = 0.0
        MaxMemoryMb  = 0
    }

    $cpuKeys = @($Map.Keys | Where-Object { $_ -match '_CPU_LIMIT$' } | Sort-Object)
    foreach ($cpuKey in $cpuKeys) {
        $cpuVal = ConvertTo-CpuValue $Map[$cpuKey]
        if ($null -ne $cpuVal) {
            $summary.CpuLimits[$cpuKey] = [double]$cpuVal
            $summary.TotalCpu += [double]$cpuVal
            if ([double]$cpuVal -gt [double]$summary.MaxCpu) { $summary.MaxCpu = [double]$cpuVal }
        }

        $memKey = $cpuKey -replace '_CPU_LIMIT$', '_MEMORY_LIMIT'
        if ($Map.ContainsKey($memKey)) {
            $memVal = ConvertTo-MemoryMbValue $Map[$memKey]
            if ($null -ne $memVal) {
                $summary.MemoryLimits[$memKey] = [int]$memVal
                $summary.TotalMemoryMb += [int]$memVal
                if ([int]$memVal -gt [int]$summary.MaxMemoryMb) { $summary.MaxMemoryMb = [int]$memVal }
            }
        }
    }

    return $summary
}

function Get-ProcessEnvMap {
    $map = @{}
    [System.Environment]::GetEnvironmentVariables('Process').GetEnumerator() | ForEach-Object {
        $map[[string]$_.Key] = [string]$_.Value
    }
    return $map
}

function Get-DockerCapacity {
    $hostCpu = [double][Environment]::ProcessorCount
    $hostMemMb = [int]((Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1MB)

    $dockerCpu = $null
    $dockerMemMb = $null

    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $dockerInfo = & cmd /c 'docker info --format "{{.NCPU}} {{.MemTotal}}" 2>nul'
        if ($LASTEXITCODE -eq 0 -and $dockerInfo) {
            $parts = $dockerInfo.Trim() -split '\s+'
            if ($parts.Count -ge 2) {
                try { $dockerCpu = [double]$parts[0] } catch { $dockerCpu = $null }
                try { $dockerMemMb = [int]([double]$parts[1] / 1MB) } catch { $dockerMemMb = $null }
            }
        }
    }

    return [ordered]@{
        HostCpu       = $hostCpu
        HostMemoryMb  = $hostMemMb
        DockerCpu     = $dockerCpu
        DockerMemoryMb = $dockerMemMb
    }
}

function Get-HwTierCatalog {
    $catalog = @()
    foreach ($tier in @('tiny', 'small', 'medium', 'large')) {
        $path = Join-Path $InfraDir "envs\hw-$tier.env"
        if (Test-Path $path) {
            $catalog += (Get-ResourceSummaryFromMap -Name $tier -Map (Read-EnvFileMap -Path $path))
        }
    }
    return $catalog
}

function Get-BestFittingTier {
    param(
        [Parameter(Mandatory = $true)]$Capacity,
        [Parameter(Mandatory = $true)][object[]]$Catalog
    )

    $fits = @()
    foreach ($tier in $Catalog) {
        if ($null -eq $tier) { continue }
        if ($tier.TotalCpu -le $Capacity.DockerCpu -and $tier.TotalCpu -le $Capacity.HostCpu -and
            $tier.TotalMemoryMb -le $Capacity.DockerMemoryMb -and $tier.TotalMemoryMb -le $Capacity.HostMemoryMb) {
            $score = [double]$tier.TotalCpu + ([double]$tier.TotalMemoryMb / 1024)
            $fits += [pscustomobject]@{ Tier = $tier; Score = $score }
        }
    }

    if ($fits.Count -eq 0) { return $null }
    return ($fits | Sort-Object Score -Descending | Select-Object -First 1).Tier
}

function Assert-HardwareRequirements {
    if ($Target -ne 'local') { return }

    $sourceMap = if ($Hw) {
        Get-ProcessEnvMap
    } else {
        Read-EnvFileMap -Path (Join-Path $ProjectRoot '.env')
    }

    $activeProfile = Get-ResourceSummaryFromMap -Name ($(if ($Hw) { $Hw } else { '.env' })) -Map $sourceMap
    if ($activeProfile.CpuLimits.Count -eq 0 -and $activeProfile.MemoryLimits.Count -eq 0) {
        Write-Host "[INFO]    No *_CPU_LIMIT / *_MEMORY_LIMIT values found for validation. Skipping hardware preflight."
        return
    }

    $capacity = Get-DockerCapacity
    if ($null -eq $capacity.DockerCpu -or $null -eq $capacity.DockerMemoryMb) {
        throw "Unable to detect Docker CPU/memory capacity. Verify Docker Desktop is running and `docker info` is available."
    }

    $violations = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $activeProfile.CpuLimits.GetEnumerator()) {
        $name = [string]$entry.Key
        $req  = [double]$entry.Value
        if ($req -gt [double]$capacity.HostCpu) {
            [void]$violations.Add("$name requires $req CPUs, but the host only has $([int]$capacity.HostCpu) available.")
        }
        if ($req -gt [double]$capacity.DockerCpu) {
            [void]$violations.Add("$name requires $req CPUs, but Docker exposes only $([string]::Format('{0:0.##}', $capacity.DockerCpu)) CPUs.")
        }
    }

    foreach ($entry in $activeProfile.MemoryLimits.GetEnumerator()) {
        $name = [string]$entry.Key
        $req  = [int]$entry.Value
        if ($req -gt [int]$capacity.HostMemoryMb) {
            [void]$violations.Add("$name requires ${req}MB RAM, but the host only has $($capacity.HostMemoryMb)MB available.")
        }
        if ($req -gt [int]$capacity.DockerMemoryMb) {
            [void]$violations.Add("$name requires ${req}MB RAM, but Docker exposes only $($capacity.DockerMemoryMb)MB.")
        }
    }

    if ($violations.Count -gt 0) {
        $catalog = Get-HwTierCatalog
        $recommended = Get-BestFittingTier -Capacity $capacity -Catalog $catalog
        $recommendedText = if ($recommended) { "Recommended tier: -Hw $($recommended.Name)." } else { "Recommended tier: use -Hw auto or a smaller tier such as -Hw tiny." }

        $details = ($violations | Sort-Object -Unique) -join "`n- "
        throw @"
Selected hardware profile '$($(if ($Hw) { $Hw } else { '.env' }))' cannot be deployed with the current hardware.

Detected hardware:
- Host:   $([int]$capacity.HostCpu) vCPU / $($capacity.HostMemoryMb) MB RAM
- Docker: $([string]::Format('{0:0.##}', $capacity.DockerCpu)) vCPU / $($capacity.DockerMemoryMb) MB RAM

Violations:
- $details

How to fix it:
- Increase Docker Desktop CPU and memory limits, or adjust `.wslconfig` if you are using WSL2.
- Choose a smaller tier or use -Hw auto.
- $recommendedText
"@
    }

    if ($Hw -and $Hw -ne 'auto') {
        $tierPath = Join-Path $InfraDir "envs\hw-$Hw.env"
        if (Test-Path $tierPath) {
            $tierProfile = Get-ResourceSummaryFromMap -Name $Hw -Map (Read-EnvFileMap -Path $tierPath)
            $hostBigger = ($capacity.HostCpu -ge ($tierProfile.TotalCpu * 1.15)) -and ($capacity.HostMemoryMb -ge ($tierProfile.TotalMemoryMb * 1.15))
            $dockerBigger = ($capacity.DockerCpu -ge ($tierProfile.TotalCpu * 1.15)) -and ($capacity.DockerMemoryMb -ge ($tierProfile.TotalMemoryMb * 1.15))

            if ($hostBigger -and $dockerBigger) {
                $catalog = Get-HwTierCatalog
                $recommended = Get-BestFittingTier -Capacity $capacity -Catalog $catalog
                $recommendedText = if ($recommended) { "-Hw $($recommended.Name)" } else { '-Hw auto' }

                Write-Warning "The selected tier '$Hw' is smaller than the available hardware."
                Write-Warning "Recommended option: $recommendedText"
                $answer = Read-Host "Proceed anyway with tier '$Hw'? [y/N]"
                if ($answer -notmatch '^(?i:y|yes)$') {
                    throw 'Deployment cancelled by user.'
                }
            }
        }
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
        Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
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
        Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing
        Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /qn" -Wait
        Remove-Item $msiPath -ErrorAction SilentlyContinue
    }

    # Refresh PATH so aws is callable in this session
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH", "User")

    Write-Host "==> AWS CLI installed."
    Write-Host "    Run 'aws configure' to set up your credentials."
}

function Test-Dependencies {
    Write-Host ""
    Write-Host "==> Checking dependencies..."

    $issues = New-Object System.Collections.Generic.List[string]

    function Add-Issue {
        param([string]$Message)
        [void]$issues.Add($Message)
    }

    switch ($Target) {
        "local" {
            if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
                Add-Issue "Docker is required for target 'local'. Install Docker Desktop and try again."
            } else {
                cmd /c "docker info >nul 2>nul"
                if ($LASTEXITCODE -ne 0) {
                    Add-Issue "Docker Desktop is installed but the daemon is not ready. Start Docker Desktop and retry."
                }

                cmd /c "docker compose version >nul 2>nul"
                if ($LASTEXITCODE -ne 0) {
                    Add-Issue "Docker Compose plugin is missing or unavailable. Update Docker Desktop."
                }
            }

            $envFile = Join-Path $ProjectRoot ".env"
            if (-not (Test-Path $envFile)) {
                Add-Issue ".env is missing. Copy .env.template to .env and fill in the required values."
            } else {
                $jwtLine = Get-Content $envFile | Where-Object { $_ -match "^JWT_SECRET_KEY=" } | Select-Object -First 1
                $jwtKey  = if ($jwtLine) { ($jwtLine -split "=", 2)[1].Trim().Trim('"').Trim("'") } else { "" }
                if (-not $jwtKey -or $jwtKey -eq "REPLACE_WITH_STRONG_SECRET_MIN_32_CHARS" -or $jwtKey.Length -lt 32) {
                    Add-Issue ".env: JWT_SECRET_KEY is missing, too short, or still using the template placeholder."
                }

                $pgLine = Get-Content $envFile | Where-Object { $_ -match "^POSTGRES_PASSWORD=" } | Select-Object -First 1
                $pgPass = if ($pgLine) { ($pgLine -split "=", 2)[1].Trim().Trim('"').Trim("'") } else { "" }
                if (-not $pgPass -or $pgPass -eq "StrongPassword12!") {
                    Add-Issue ".env: POSTGRES_PASSWORD is empty or still using the template default."
                }
            }

            # Target-specific hardware checks for local should happen here only.
            # Do not read AWS files, AWS CLI, or AWS credentials in this branch.
        }

        "aws" {
            if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
                Add-Issue "AWS CLI is required for target 'aws'. Install it and run 'aws configure'."
            } else {
                cmd /c "aws sts get-caller-identity >nul 2>nul"
                if ($LASTEXITCODE -ne 0) {
                    Add-Issue "AWS credentials are missing, invalid, or expired. Run 'aws configure' or set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY."
                }
            }

            $varFile = Join-Path $InfraDir "envs\aws.tfvars"
            if (-not (Test-Path $varFile)) {
                Add-Issue "$varFile not found. Copy aws.tfvars.example and fill in the required values."
            }
        }

        "remote" {
            if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
                Add-Issue "SSH client is required for target 'remote'. Enable OpenSSH Client on Windows."
            }

            $varFile = Join-Path $InfraDir "envs\remote.tfvars"
            if (-not (Test-Path $varFile)) {
                Add-Issue "$varFile not found. Copy remote.tfvars.example and fill in the required values."
            }
        }

        default {
            Add-Issue "Unsupported target: $Target"
        }
    }

    if ($issues.Count -gt 0) {
        throw ($issues -join "`n")
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

    Get-Content $envFile | ForEach-Object {
        $line = $_.Trim()
        # Skip comments and blank lines
        if ($line -match "^#" -or $line -eq "") { return }

        # Split on first '=' only
        $eqIdx = $line.IndexOf("=")
        if ($eqIdx -lt 0) { return }

        $key   = $line.Substring(0, $eqIdx).Trim()
        $value = $line.Substring($eqIdx + 1).Trim().Trim('"').Trim("'")

        if ($tfMap.ContainsKey($key)) {
            $varName = "TF_VAR_$($tfMap[$key])"
            [System.Environment]::SetEnvironmentVariable($varName, $value, "Process")
        }
    }

    # CORS: comma-separated string → Terraform list JSON
    # Input:  "http://localhost:5173,http://127.0.0.1"
    # Output: ["http://localhost:5173","http://127.0.0.1"]
    $corsLine = Get-Content $envFile | Where-Object { $_ -match "^CORS_ALLOW_ORIGINS=" } | Select-Object -First 1
    if ($corsLine) {
        $corsRaw = ($corsLine -split "=", 2)[1].Trim().Trim('"').Trim("'")
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
        terraform init -input=false
        if ($LASTEXITCODE -ne 0) { throw "terraform init failed" }

        switch ($Action) {
            "plan" {
                Write-Host "==> terraform plan"
                terraform plan -input=false -var-file=$VarFile
            }
            "apply" {
                Write-Host "==> terraform apply"
                terraform apply -input=false -auto-approve -var-file=$VarFile
            }
            "destroy" {
                Write-Host "==> terraform destroy"
                terraform destroy -input=false -auto-approve -var-file=$VarFile
            }
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

    Assert-HardwareRequirements

    $composeFiles = if ($Profile -eq "dev") {
        "-f docker-compose.yml -f docker-compose.dev.yml"
    } else {
        "-f docker-compose.yml"
    }
    $buildFlag = if ($NoBuild) { "" } else { "--build" }

    Push-Location $ProjectRoot
    try {
        switch ($Action) {
            "apply" {
                $cmd = "docker compose $composeFiles --profile $Profile up -d $buildFlag".Trim()
                Write-Host "==> $cmd"
                Invoke-Expression $cmd
            }
            "destroy" {
                $cmd = "docker compose $composeFiles --profile $Profile down --remove-orphans"
                Write-Host "==> $cmd"
                Invoke-Expression $cmd
            }
            "plan" {
                # Show resolved compose config without starting anything
                $cmd = "docker compose $composeFiles --profile $Profile config"
                Write-Host "==> $cmd  (dry-run: shows resolved config)"
                Invoke-Expression $cmd
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
