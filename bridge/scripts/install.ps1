param(
  [Parameter(Mandatory=$false)][string]$InstallDir = "C:\Program Files\Thai-Dev\PMIC-Bridge",
  [Parameter(Mandatory=$false)][int]$Port = 17520,
  [Parameter(Mandatory=$false)][string]$AllowedOrigins = "https://pmic.thai-dev.online",
  [switch]$EnableDefenderExclusions
)

$ErrorActionPreference = "Stop"

function Assert-Admin {
  $id=[Security.Principal.WindowsIdentity]::GetCurrent()
  $p=New-Object Security.Principal.WindowsPrincipal($id)
  if(-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    throw "Run this script as Administrator."
  }
}

function Write-Log($msg) {
  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Write-Host "[$ts] $msg"
}

Assert-Admin

# Data dir in ProgramData (shared)
$DataDir = Join-Path $env:ProgramData "Thai-Dev\PMIC-Bridge"
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $DataDir "logs") | Out-Null

Write-Log "InstallDir: $InstallDir"
Write-Log "DataDir:    $DataDir"

# 1) Generate bridge token (used for write/critical ops once you implement them)
$tokenBytes = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($tokenBytes)
$BridgeToken = [Convert]::ToBase64String($tokenBytes)

# 2) Create and trust localhost cert
Write-Log "Creating localhost TLS cert..."
$certJson = & (Join-Path $PSScriptRoot "create-cert.ps1") -DataDir $DataDir
$certInfo = $certJson | ConvertFrom-Json
Write-Log "Cert thumbprint: $($certInfo.thumbprint)"

# 3) Build/publish (requires .NET 8 SDK)
Write-Log "Publishing bridge (requires .NET SDK)..."
$srcDir = Join-Path $InstallDir "src"
$binDir = Join-Path $InstallDir "bin"
New-Item -ItemType Directory -Force -Path $srcDir | Out-Null
New-Item -ItemType Directory -Force -Path $binDir | Out-Null

# Copy source if running from extracted pack
$packSrc = Resolve-Path (Join-Path $PSScriptRoot "..\src")
Copy-Item -Recurse -Force -Path $packSrc\* -Destination $srcDir

# Publish to bin
$publishDir = Join-Path $binDir "publish"
if (Test-Path $publishDir) { Remove-Item -Recurse -Force $publishDir }

Push-Location $srcDir
try {
  & dotnet --version | Out-Null
  & dotnet publish -c Release -o $publishDir | Out-Null
} finally {
  Pop-Location
}

# Find runnable entry
$exePath = Join-Path $publishDir "pmic-bridge.exe"
$dllPath = Join-Path $publishDir "pmic-bridge.dll"
$useExe = Test-Path $exePath

# Build service command safely (avoid PowerShell quoting pitfalls)
if ($useExe) {
  $svcCmd = "`"$exePath`" --urls https://127.0.0.1:$Port"
  $programPathForFirewall = $exePath
} else {
  $dotnetExe = (Get-Command dotnet).Source
  $svcCmd = "`"$dotnetExe`" `"$dllPath`" --urls https://127.0.0.1:$Port"
  $programPathForFirewall = $dotnetExe
}

# 4) Write secrets/config used by bridge
$secretsPath = Join-Path $DataDir "secrets.json"
$secrets = [ordered]@{
  token = $BridgeToken
  allowedOrigins = ($AllowedOrigins.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
  https = [ordered]@{
    pfxPath = $certInfo.pfxPath
    pfxPassword = $certInfo.pfxPassword
    port = $Port
  }
}
$secrets | ConvertTo-Json -Depth 6 | Set-Content -Path $secretsPath -Encoding UTF8
Write-Log "Wrote secrets: $secretsPath"

# 5) Firewall rule (scoped)
$ruleName = "PMIC-Bridge-Localhost-Allow"
Write-Log "Configuring firewall rule (localhost only)..."
$existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
if (-not $existing) {
  # Program rule (inbound) for localhost
  New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Program $programPathForFirewall -LocalAddress 127.0.0.1 -Protocol TCP -Profile Any | Out-Null
}

# 6) Defender exclusions (opt-in; keep scoped)
if ($EnableDefenderExclusions) {
  Write-Log "Adding scoped Defender exclusions..."
  Add-MpPreference -ExclusionPath $InstallDir
  Add-MpPreference -ExclusionProcess $programPathForFirewall
} else {
  Write-Log "Defender exclusions: skipped (use -EnableDefenderExclusions to opt-in)."
}

# 7) Create Windows Service
$svcName = "PMICBridge"
$svcDisplay = "PMIC Bridge (Localhost HTTPS)"
Write-Log "Creating/Updating service: $svcName"

# Remove existing service if present
$svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
if ($svc) {
  Write-Log "Service exists; stopping and deleting to recreate..."
  try { Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue } catch {}
  sc.exe delete $svcName | Out-Null
  Start-Sleep -Seconds 1
}

# NOTE: sc.exe requires this exact spacing: binPath= <value>
New-Service -Name $svcName -BinaryPathName $svcCmd -DisplayName $svcDisplay -StartupType Automatic | Out-Null
sc.exe description $svcName "Thai-Dev PMIC Bridge headless service (HTTPS localhost)" | Out-Null

# Environment variables for service (read by app)
# Use registry for service environment:
$svcReg = "HKLM:\SYSTEM\CurrentControlSet\Services\$svcName"
New-ItemProperty -Path $svcReg -Name "Environment" -PropertyType MultiString -Value @(
  "PMIC_BRIDGE_DATA_DIR=$DataDir",
  "PMIC_BRIDGE_ALLOWED_ORIGINS=$AllowedOrigins",
  "PMIC_BRIDGE_TOKEN=$BridgeToken",
  "ASPNETCORE_Kestrel__Certificates__Default__Path=$($certInfo.pfxPath)",
  "ASPNETCORE_Kestrel__Certificates__Default__Password=$($certInfo.pfxPassword)"
) -Force | Out-Null

sc.exe start $svcName | Out-Null

# 8) Write install state + rollback helper
$statePath = Join-Path $DataDir "install_state.json"
$state = [ordered]@{
  installedAt = (Get-Date).ToString("o")
  installDir = $InstallDir
  dataDir = $DataDir
  port = $Port
  serviceName = $svcName
  firewallRule = $ruleName
  defenderEnabled = [bool]$EnableDefenderExclusions
  publishDir = $publishDir
  exePath = $exePath
  dllPath = $dllPath
  certThumbprint = $certInfo.thumbprint
  certPfxPath = $certInfo.pfxPath
  allowedOrigins = $secrets.allowedOrigins
}
$state | ConvertTo-Json -Depth 6 | Set-Content -Path $statePath -Encoding UTF8
Write-Log "Saved install state: $statePath"

Copy-Item -Force -Path (Join-Path $PSScriptRoot "rollback.ps1") -Destination (Join-Path $InstallDir "rollback.ps1")

Write-Host ""
Write-Host "================= READY ================="
Write-Host "Bridge URL: https://127.0.0.1:$Port/health"
Write-Host "Allowed Origin(s): $AllowedOrigins"
Write-Host "Bridge Token (store safely; paste into your Web config):"
Write-Host $BridgeToken
Write-Host "Rollback: powershell -ExecutionPolicy Bypass -File `"$InstallDir\rollback.ps1`""
Write-Host "========================================="
