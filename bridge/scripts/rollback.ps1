param(
  [Parameter(Mandatory=$false)][string]$DataDir = "$env:ProgramData\Thai-Dev\PMIC-Bridge"
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

$statePath = Join-Path $DataDir "install_state.json"
if (-not (Test-Path $statePath)) {
  throw "install_state.json not found at: $statePath"
}

$state = Get-Content $statePath | ConvertFrom-Json

# Stop/delete service
$svc = $state.serviceName
Write-Log "Stopping service: $svc"
try { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue } catch {}
Write-Log "Deleting service: $svc"
try { sc.exe delete $svc | Out-Null } catch {}
Start-Sleep -Seconds 1

# Remove firewall rule
$ruleName = $state.firewallRule
Write-Log "Removing firewall rule: $ruleName"
try {
  $r = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
  if ($r) { Remove-NetFirewallRule -DisplayName $ruleName | Out-Null }
} catch {}

# Remove Defender exclusions if enabled
if ($state.defenderEnabled -eq $true) {
  Write-Log "Removing Defender exclusions..."
  try { Remove-MpPreference -ExclusionPath $state.installDir } catch {}
  try {
    if ($state.exePath) { Remove-MpPreference -ExclusionProcess $state.exePath }
    else { Remove-MpPreference -ExclusionProcess (Get-Command dotnet).Source }
  } catch {}
}

# Remove trusted cert (optional: only remove our specific cert)
Write-Log "Attempting to remove trusted cert by thumbprint (Root + My)..."
try {
  $thumb = $state.certThumbprint
  if ($thumb) {
    Get-ChildItem Cert:\LocalMachine\Root | Where-Object Thumbprint -eq $thumb | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem Cert:\LocalMachine\My   | Where-Object Thumbprint -eq $thumb | Remove-Item -Force -ErrorAction SilentlyContinue
  }
} catch {}

# Keep DataDir by default (contains logs). Comment next lines if you want to wipe.
Write-Log "Rollback complete. DataDir kept: $DataDir"
