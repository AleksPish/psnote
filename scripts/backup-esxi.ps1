function Invoke-BackupEsxi {
# Name: backup-esxi
# Tags: powercli,vmware
# Saved: 2026-03-03T15:59:51.3016154+00:00
<#
.SYNOPSIS
Backs up ESXi host configuration through vCenter or direct host connection.

.DESCRIPTION
Connects to either a vCenter Server or a single ESXi host and runs
Get-VMHostFirmware -BackupConfiguration for one or more hosts.
If key connection inputs are omitted, interactive prompts are used.

.PARAMETER VCenter
vCenter Server hostname or FQDN used when not running direct-host mode.

.PARAMETER DestinationPath
Directory where host backup bundles are written.

.PARAMETER BackupSingleHost
Restricts backup scope to one host.

.PARAMETER VMHostName
Host name to back up when -BackupSingleHost is used.

.PARAMETER BackupFromHost
Connects directly to a standalone ESXi host instead of vCenter.

.PARAMETER EsxiHost
ESXi host hostname or FQDN used with -BackupFromHost.

.PARAMETER PassThru
Returns detailed per-host backup result objects.

.PARAMETER SkipCertificatePrompt
Sets PowerCLI invalid certificate action to Ignore for the current session.

.EXAMPLE
Invoke-BackupEsxi -VCenter vc01.contoso.com -DestinationPath C:\Backups\ESXi

.EXAMPLE
Invoke-BackupEsxi -BackupFromHost -EsxiHost esx01.contoso.com -PassThru

.OUTPUTS
PSCustomObject
#>
[OutputType([PSCustomObject])]
[CmdletBinding()]
param(
  [Parameter()]
  [ValidateNotNullOrEmpty()]
  [string]$VCenter,

  [Parameter()]
  [ValidateNotNullOrEmpty()]
  [string]$DestinationPath = (Get-Location).Path,

  [Parameter()]
  [switch]$BackupSingleHost,

  [Parameter()]
  [ValidateNotNullOrEmpty()]
  [string]$VMHostName,

  [Parameter()]
  [switch]$BackupFromHost,

  [Parameter()]
  [ValidateNotNullOrEmpty()]
  [string]$EsxiHost,

  [Parameter()]
  [switch]$PassThru,

  [Parameter()]
  [switch]$SkipCertificatePrompt
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-NonEmptyInput {
  param(
    [Parameter(Mandatory=$true)]
    [string]$Prompt
  )

  while ($true) {
    $value = Read-Host -Prompt $Prompt
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      return $value.Trim()
    }
    Write-Warning 'Input is required.'
  }
}

function Read-YesNo {
  param(
    [Parameter(Mandatory=$true)]
    [string]$Prompt,
    [Parameter(Mandatory=$true)]
    [bool]$DefaultValue
  )

  $defaultText = if ($DefaultValue) { 'Y' } else { 'N' }
  while ($true) {
    $answer = Read-Host -Prompt "$Prompt (Y/N, default $defaultText)"
    if ([string]::IsNullOrWhiteSpace($answer)) {
      return $DefaultValue
    }

    if ($answer -match '^(Y|YES)$') { return $true }
    if ($answer -match '^(N|NO)$') { return $false }

    Write-Warning "Invalid response '$answer'. Enter Y or N."
  }
}

function Test-ResolvableHost {
  param(
    [Parameter(Mandatory=$true)]
    [string]$Name
  )

  try {
    [void][System.Net.Dns]::GetHostEntry($Name)
    return $true
  }
  catch {
    return $false
  }
}

if (-not (Get-Command Connect-VIServer -ErrorAction SilentlyContinue)) {
  throw 'PowerCLI command Connect-VIServer was not found. Install/import VMware PowerCLI before running this script.'
}

if (-not (Test-Path -LiteralPath $DestinationPath -PathType Container)) {
  throw "Destination path '$DestinationPath' does not exist or is not a directory."
}

if ($SkipCertificatePrompt) {
  try {
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
  }
  catch {
    Write-Warning "Unable to set PowerCLI certificate behavior for this session: $($_.Exception.Message)"
  }
}

if ($PSBoundParameters.ContainsKey('VMHostName') -and -not $BackupSingleHost) {
  $BackupSingleHost = $true
}

if (-not $PSBoundParameters.ContainsKey('BackupFromHost')) {
  $BackupFromHost = Read-YesNo -Prompt 'Backup directly from a single ESXi host (instead of via vCenter)?' -DefaultValue $false
}

if ($BackupFromHost) {
  if (-not $PSBoundParameters.ContainsKey('EsxiHost')) {
    $EsxiHost = Read-NonEmptyInput -Prompt 'Enter ESXi host (FQDN or hostname) to connect to directly'
  }

  # Direct host mode is always a single-host backup.
  $BackupSingleHost = $true
  if (-not $PSBoundParameters.ContainsKey('VMHostName')) {
    $VMHostName = $EsxiHost
  }
}
else {
  if (-not $PSBoundParameters.ContainsKey('VCenter')) {
    $VCenter = Read-NonEmptyInput -Prompt 'Enter vCenter Server (FQDN or hostname)'
  }

  if (-not $BackupSingleHost) {
    $BackupSingleHost = Read-YesNo -Prompt 'Backup a single ESXi host only?' -DefaultValue $false
  }

  if ($BackupSingleHost -and -not $PSBoundParameters.ContainsKey('VMHostName')) {
    $VMHostName = Read-NonEmptyInput -Prompt 'Enter ESXi host name to back up'
  }
}

$resolvedDestination = (Resolve-Path -LiteralPath $DestinationPath).Path
$connectionTarget = if ($BackupFromHost) { $EsxiHost } else { $VCenter }
$connectionMode = if ($BackupFromHost) { 'DirectHost' } else { 'VCenter' }

if (-not (Test-ResolvableHost -Name $connectionTarget)) {
  throw "Connection target '$connectionTarget' could not be resolved by DNS. Check the hostname/FQDN and try again."
}

Write-Verbose "Connecting to '$connectionTarget' using mode '$connectionMode'."

$connection = $null
try {
  try {
    $connection = Connect-VIServer -Server $connectionTarget -WarningAction SilentlyContinue -ErrorAction Stop
  }
  catch {
    throw "Failed to connect to '$connectionTarget' in mode '$connectionMode'. $($_.Exception.Message)"
  }

  $vmHosts = if ($BackupSingleHost) {
    Get-VMHost -Server $connection -Name $VMHostName -ErrorAction Stop
  }
  else {
    Get-VMHost -Server $connection -ErrorAction Stop
  }

  $vmHosts = $vmHosts | Sort-Object -Property Name
  if (-not $vmHosts) {
    Write-Warning "No matching ESXi hosts found for connection target '$connectionTarget'."
    return
  }

  $results = foreach ($vmHost in $vmHosts) {
    Write-Verbose "Backing up host configuration for '$($vmHost.Name)'."
    try {
      $firmwareResult = Get-VMHostFirmware -VMHost $vmHost -BackupConfiguration -DestinationPath $resolvedDestination -ErrorAction Stop
      [PSCustomObject]@{
        ConnectionMode  = $connectionMode
        ConnectionTo    = $connectionTarget
        VMHost          = $vmHost.Name
        DestinationPath = $resolvedDestination
        Success         = $true
        Result          = $firmwareResult
        Error           = $null
      }
    }
    catch {
      [PSCustomObject]@{
        ConnectionMode  = $connectionMode
        ConnectionTo    = $connectionTarget
        VMHost          = $vmHost.Name
        DestinationPath = $resolvedDestination
        Success         = $false
        Result          = $null
        Error           = $_.Exception.Message
      }
    }
  }

  if ($PassThru) {
    $results
  }
  else {
    $successCount = ($results | Where-Object { $_.Success }).Count
    $failed = $results | Where-Object { -not $_.Success }

    Write-Host "Backup completed. Success: $successCount / $($results.Count). Files saved to: $resolvedDestination" -ForegroundColor Green
    if ($failed) {
      Write-Warning ("Failed hosts: {0}" -f (($failed.VMHost | Sort-Object) -join ', '))
      $failed | Select-Object VMHost, Error | Format-Table -AutoSize
    }
  }
}
finally {
  if ($connection) {
    Disconnect-VIServer -Server $connection -Confirm:$false | Out-Null
  }
}
}

