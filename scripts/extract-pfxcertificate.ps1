function Export-PfxCertificateMaterial {
# Name: extract-pfxcertificate
# Tags: certs
# Saved: 2026-03-03T19:50:32.8377720+00:00
<#
.SYNOPSIS
Extracts certificate and private key material from a .pfx/.p12 file using OpenSSL.

.DESCRIPTION
Extract-PfxCertificate.ps1 extracts:
1. Public certificate (.crt)
2. Private key (.key)
3. Combined certificate + private key (.pem)

The script validates inputs, creates the output directory if needed, and calculates SHA1/SHA256 thumbprints.
It supports interactive prompts when required parameters are not supplied.

.PARAMETER PfxPath
Path to the source .pfx/.p12 file. If omitted, the script prompts for it.

.PARAMETER OutputDirectory
Directory where extracted files are written. Defaults to the current directory.

.PARAMETER Password
PFX password as a SecureString. If not provided (and -NoPassword is not used), the script prompts for it.

.PARAMETER NoPassword
Indicates the PFX does not require a password.

.PARAMETER IncludeCertificateInfo
Outputs full certificate details (`openssl x509 -text -noout`) after extraction.

.PARAMETER Force
Overwrites existing output files if they already exist.

.EXAMPLE
.\Extract-PfxCertificate.ps1 -PfxPath C:\Certs\site.pfx -OutputDirectory C:\Certs\Out
Prompts for password and writes extracted files to C:\Certs\Out.

.EXAMPLE
.\Extract-PfxCertificate.ps1 -PfxPath C:\Certs\site.pfx -NoPassword -Force
Processes a passwordless PFX and overwrites any existing output files.

.EXAMPLE
$pwd = Read-Host "PFX password" -AsSecureString
.\Extract-PfxCertificate.ps1 -PfxPath C:\Certs\site.pfx -Password $pwd -IncludeCertificateInfo
Runs non-interactively with supplied password and prints certificate details.

.OUTPUTS
PSCustomObject
Returns an object containing source/output paths and SHA1/SHA256 thumbprints.

.NOTES
Requirements:
1. OpenSSL must be installed and available in PATH as `openssl`.
2. Handle extracted private keys securely and restrict filesystem permissions appropriately.
#>
[CmdletBinding()]
param(
  [Parameter()]
  [string]$PfxPath,

  [Parameter()]
  [string]$OutputDirectory = '.',

  [Parameter()]
  [SecureString]$Password,

  [Parameter()]
  [switch]$NoPassword,

  [Parameter()]
  [switch]$IncludeCertificateInfo,

  [Parameter()]
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-NonEmptyInput {
  param(
    [Parameter(Mandatory=$true)]
    [string]$Prompt
  )

  if ([Console]::IsInputRedirected) {
    throw "Interactive input is not available. Provide required parameters instead of prompting for '$Prompt'."
  }

  while ($true) {
    $value = Read-Host -Prompt $Prompt
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      return $value.Trim()
    }
    Write-Warning 'Input is required.'
  }
}

function ConvertFrom-SecureToPlainText {
  param(
    [Parameter(Mandatory=$true)]
    [SecureString]$Secure
  )

  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  }
  finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
}

function Invoke-OpenSsl {
  param(
    [Parameter(Mandatory=$true)]
    [string]$OpenSslExe,

    [Parameter(Mandatory=$true)]
    [string[]]$Arguments,

    [Parameter(Mandatory=$true)]
    [string]$StepName
  )

  $output = & $OpenSslExe @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    $detail = ($output | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($detail)) {
      throw "$StepName failed (exit code $LASTEXITCODE)."
    }
    throw "$StepName failed: $detail"
  }
  return $output
}

if (-not $PfxPath) {
  $PfxPath = Read-NonEmptyInput -Prompt 'Enter full path to .pfx file'
}

$resolvedPfxPath = Resolve-Path -LiteralPath $PfxPath -ErrorAction SilentlyContinue
if (-not $resolvedPfxPath) {
  throw "PFX file not found: $PfxPath"
}
$resolvedPfxPath = $resolvedPfxPath.Path

if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
  New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}
$resolvedOutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

$openSslCommand = Get-Command openssl -ErrorAction SilentlyContinue
if (-not $openSslCommand) {
  throw "OpenSSL executable 'openssl' was not found in PATH."
}
$openSslExe = $openSslCommand.Source

if (-not $NoPassword -and -not $Password) {
  $Password = Read-Host -Prompt 'Enter PFX password (leave blank and press Enter for none)' -AsSecureString
}

$baseName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedPfxPath)
$certFile = Join-Path $resolvedOutputDirectory "$baseName.crt"
$keyFile = Join-Path $resolvedOutputDirectory "$baseName.key"
$combinedFile = Join-Path $resolvedOutputDirectory "$baseName-combined.pem"

if (-not $Force) {
  $existing = @($certFile, $keyFile, $combinedFile) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
  if ($existing.Count -gt 0) {
    throw "Output file(s) already exist. Use -Force to overwrite: $($existing -join ', ')"
  }
}

$plainPassword = $null
$setPasswordEnv = $false
try {
  $passwordArgs = @()
  if (-not $NoPassword -and $Password) {
    $plainPassword = ConvertFrom-SecureToPlainText -Secure $Password
    if (-not [string]::IsNullOrEmpty($plainPassword)) {
      $env:OPENSSL_PFX_PASS = $plainPassword
      $setPasswordEnv = $true
      $passwordArgs = @('-passin', 'env:OPENSSL_PFX_PASS')
    }
  }

  Write-Host "Processing PFX file: $resolvedPfxPath" -ForegroundColor Green
  Write-Host "Output directory: $resolvedOutputDirectory" -ForegroundColor Green

  Write-Host "`nExtracting public certificate..." -ForegroundColor Yellow
  Invoke-OpenSsl -OpenSslExe $openSslExe -StepName 'Extract certificate' -Arguments @(
    'pkcs12','-in',$resolvedPfxPath,'-nokeys','-out',$certFile
  ) + $passwordArgs | Out-Null

  Write-Host "Extracting private key..." -ForegroundColor Yellow
  Invoke-OpenSsl -OpenSslExe $openSslExe -StepName 'Extract private key' -Arguments @(
    'pkcs12','-in',$resolvedPfxPath,'-nocerts','-out',$keyFile
  ) + $passwordArgs | Out-Null

  Write-Host "Extracting combined certificate and key..." -ForegroundColor Yellow
  Invoke-OpenSsl -OpenSslExe $openSslExe -StepName 'Extract combined PEM' -Arguments @(
    'pkcs12','-in',$resolvedPfxPath,'-out',$combinedFile
  ) + $passwordArgs | Out-Null

  $sha1Output = Invoke-OpenSsl -OpenSslExe $openSslExe -StepName 'Get SHA1 thumbprint' -Arguments @(
    'x509','-in',$certFile,'-fingerprint','-noout','-sha1'
  )
  $sha256Output = Invoke-OpenSsl -OpenSslExe $openSslExe -StepName 'Get SHA256 thumbprint' -Arguments @(
    'x509','-in',$certFile,'-fingerprint','-noout','-sha256'
  )

  $sha1Thumbprint = (($sha1Output | Select-Object -First 1) -replace '^.*=', '').Trim()
  $sha256Thumbprint = (($sha256Output | Select-Object -First 1) -replace '^.*=', '').Trim()

  if ($IncludeCertificateInfo) {
    Write-Host "`nCertificate information:" -ForegroundColor Yellow
    Invoke-OpenSsl -OpenSslExe $openSslExe -StepName 'Read certificate info' -Arguments @(
      'x509','-in',$certFile,'-text','-noout'
    )
  }

  $result = [PSCustomObject]@{
    PfxPath           = $resolvedPfxPath
    OutputDirectory   = $resolvedOutputDirectory
    CertificateFile   = $certFile
    PrivateKeyFile    = $keyFile
    CombinedPemFile   = $combinedFile
    SHA1Thumbprint    = $sha1Thumbprint
    SHA256Thumbprint  = $sha256Thumbprint
  }

  Write-Host "`nExtraction completed successfully." -ForegroundColor Green
  $result | Format-List
  $result
}
finally {
  if ($setPasswordEnv) {
    Remove-Item Env:OPENSSL_PFX_PASS -ErrorAction SilentlyContinue
  }
  $plainPassword = $null
}
}

# When run directly as a script, execute the function.
# When dot-sourced/imported, only define the function.
if ($MyInvocation.InvocationName -ne ".") {
    Export-PfxCertificateMaterial
}
