param(
  [Parameter(Mandatory=$true)][string]$DataDir
)

$ErrorActionPreference = "Stop"

function Assert-Admin {
  $id=[Security.Principal.WindowsIdentity]::GetCurrent()
  $p=New-Object Security.Principal.WindowsPrincipal($id)
  if(-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    throw "Run this script as Administrator."
  }
}

Assert-Admin

$certDir = Join-Path $DataDir "certs"
New-Item -ItemType Directory -Force -Path $certDir | Out-Null

$pfxPath = Join-Path $certDir "bridge.pfx"
$cerPath = Join-Path $certDir "bridge.cer"

# Generate random password for PFX
$pwBytes = New-Object byte[] 24
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($pwBytes)
$pfxPasswordPlain = [Convert]::ToBase64String($pwBytes)
$pfxPassword = ConvertTo-SecureString -String $pfxPasswordPlain -Force -AsPlainText

# Subject + SAN
$subject = "CN=PMIC-Bridge Localhost"
$san = "dns=localhost&dns=pmic-bridge.local&ipaddress=127.0.0.1"

# Create cert in LocalMachine\My
$cert = New-SelfSignedCertificate \
  -Subject $subject \
  -KeyAlgorithm RSA \
  -KeyLength 2048 \
  -HashAlgorithm SHA256 \
  -KeyExportPolicy Exportable \
  -KeyUsage DigitalSignature, KeyEncipherment \
  -FriendlyName "PMIC-Bridge Localhost" \
  -CertStoreLocation "Cert:\\LocalMachine\\My" \
  -NotAfter (Get-Date).AddYears(5) \
  -TextExtension @("2.5.29.17={text}$san")

# Export cert + PFX
Export-Certificate -Cert $cert -FilePath $cerPath | Out-Null
Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $pfxPassword | Out-Null

# Trust it (LocalMachine Root)
Import-Certificate -FilePath $cerPath -CertStoreLocation "Cert:\\LocalMachine\\Root" | Out-Null

# Return info
@{
  pfxPath = $pfxPath
  pfxPassword = $pfxPasswordPlain
  thumbprint = $cert.Thumbprint
  cerPath = $cerPath
} | ConvertTo-Json -Depth 5
