function Set-RdsCertificates {
# Name: update-rdscerts
# Tags: windows,remotedesktop,certs
# Saved: 2026-03-03T15:00:16.5346886+00:00
[CmdletBinding()]
param(
  [ValidateNotNullOrEmpty()]
  [string]$Thumbprint,

  [ValidateNotNullOrEmpty()]
  [string]$ConnectionBroker,

  [ValidateSet('RDGateway','RDWebAccess','RDRedirector','RDPublishing')]
  [string[]]$Roles,

  [switch]$Force,

  [switch]$SkipFinalConfirmation
)

Set-StrictMode -Version Latest

<#
.SYNOPSIS
Updates RDS role certificates using Set-RDCertificate.

.DESCRIPTION
Supports both non-interactive parameter-based execution and interactive prompts.
If required values are not provided as parameters, the script prompts for them.
#>

$availableRoles = @(
  [PSCustomObject]@{ Name = 'RDGateway';    Description = 'RD Gateway SSL' }
  [PSCustomObject]@{ Name = 'RDWebAccess';  Description = 'RD Web / HTML5' }
  [PSCustomObject]@{ Name = 'RDRedirector'; Description = 'SSO / redirection' }
  [PSCustomObject]@{ Name = 'RDPublishing'; Description = 'Publishing / feed' }
)

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

function ConvertTo-NormalizedThumbprint {
  param(
    [Parameter(Mandatory=$true)]
    [string]$Value
  )

  $normalized = ($Value -replace '\s', '').ToUpperInvariant()
  if ($normalized -notmatch '^[A-F0-9]{40}$') {
    throw "Invalid thumbprint '$Value'. Expected 40 hexadecimal characters."
  }

  return $normalized
}

function Read-Thumbprint {
  while ($true) {
    $raw = Read-NonEmptyInput -Prompt 'Enter certificate thumbprint (40 hex chars; spaces allowed)'
    try {
      return ConvertTo-NormalizedThumbprint -Value $raw
    }
    catch {
      Write-Warning $_.Exception.Message
    }
  }
}

function Select-RdsRoles {
  param(
    [Parameter(Mandatory=$true)]
    [object[]]$AvailableRoles
  )

  Write-Host ''
  Write-Host 'Available RDS roles:' -ForegroundColor Cyan
  for ($i = 0; $i -lt $AvailableRoles.Count; $i++) {
    $index = $i + 1
    Write-Host ("  {0}. {1} ({2})" -f $index, $AvailableRoles[$i].Name, $AvailableRoles[$i].Description)
  }
  Write-Host '  A. All roles'
  Write-Host ''

  while ($true) {
    $selection = Read-NonEmptyInput -Prompt 'Select roles by number (comma-separated, e.g. 1,3) or A for all'
    if ($selection -match '^[Aa]$') {
      return $AvailableRoles.Name
    }

    $tokens = $selection -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    if (-not $tokens) {
      Write-Warning 'No role selection provided.'
      continue
    }

    $selectedIndices = @()
    $invalidTokens = @()
    foreach ($token in $tokens) {
      $parsed = 0
      if ([int]::TryParse($token, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $AvailableRoles.Count) {
        $selectedIndices += ($parsed - 1)
      }
      else {
        $invalidTokens += $token
      }
    }

    if ($invalidTokens.Count -gt 0) {
      Write-Warning ("Invalid selection value(s): {0}" -f ($invalidTokens -join ', '))
      continue
    }

    if ($selectedIndices.Count -eq 0) {
      Write-Warning 'No valid roles selected.'
      continue
    }

    $uniqueIndices = $selectedIndices | Sort-Object -Unique
    return $uniqueIndices | ForEach-Object { $AvailableRoles[$_].Name }
  }
}

if (-not (Get-Command Set-RDCertificate -ErrorAction SilentlyContinue)) {
  throw 'Set-RDCertificate command not found. Install/import the RemoteDesktop module and run on a host with RDS management tools.'
}

if ($PSBoundParameters.ContainsKey('Thumbprint')) {
  $Thumbprint = ConvertTo-NormalizedThumbprint -Value $Thumbprint
}
else {
  $Thumbprint = Read-Thumbprint
}

if (-not $PSBoundParameters.ContainsKey('ConnectionBroker')) {
  $ConnectionBroker = Read-NonEmptyInput -Prompt 'Enter RD Connection Broker (FQDN or hostname)'
}

if (-not $PSBoundParameters.ContainsKey('Roles') -or -not $Roles -or $Roles.Count -eq 0) {
  $Roles = Select-RdsRoles -AvailableRoles $availableRoles
}
else {
  $Roles = $Roles | Sort-Object -Unique
}

if (-not $PSBoundParameters.ContainsKey('Force')) {
  $forceInput = Read-Host -Prompt 'Force update without per-role confirmation? (Y/N, default Y)'
  if ($forceInput -notmatch '^(N|NO)$') {
    $Force = $true
  }
}

Write-Host ''
Write-Host 'Summary:' -ForegroundColor Cyan
Write-Host ("  Connection Broker: {0}" -f $ConnectionBroker)
Write-Host ("  Thumbprint:        {0}" -f $Thumbprint)
Write-Host ("  Roles:             {0}" -f ($Roles -join ', '))
Write-Host ("  Force:             {0}" -f [bool]$Force)
Write-Host ''

if (-not $SkipFinalConfirmation) {
  $confirm = Read-Host -Prompt 'Proceed with certificate updates? (Y/N)'
  if ($confirm -notmatch '^(Y|YES)$') {
    Write-Host 'Operation cancelled.'
    return
  }
}

foreach ($role in $Roles) {
  try {
    Write-Host ("Applying certificate to role: {0} ..." -f $role) -ForegroundColor Cyan
    Set-RDCertificate -Role $role `
                      -Thumbprint $Thumbprint `
                      -ConnectionBroker $ConnectionBroker `
                      -Force:$Force `
                      -ErrorAction Stop `
                      -Verbose
    Write-Host ("Successfully updated role: {0}" -f $role) -ForegroundColor Green
  }
  catch {
    Write-Error ("Failed to update role '{0}': {1}" -f $role, $_.Exception.Message)
  }
}
}

# When run directly as a script, execute the function.
# When dot-sourced/imported, only define the function.
if ($MyInvocation.InvocationName -ne ".") {
    Set-RdsCertificates
}
