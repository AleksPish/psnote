# Name: remove-certificate
# Tags: certs
# Saved: 2026-03-03T14:10:04.8150978+00:00
function Remove-Certificate {
  <#
  .SYNOPSIS
  Removes a certificate (by thumbprint) from Cert:\LocalMachine\My on one or more computers.

  .DESCRIPTION
  Removes certificates from the LocalMachine\My store on remote computers via PowerShell remoting.
  Supports -WhatIf and -Confirm for safer execution.

  .PARAMETER Thumbprint
  Certificate thumbprint to remove. Spaces are ignored.

  .PARAMETER ComputerName
  One or more target computers. If omitted, uses the local computer.

  .PARAMETER ServerListPath
  Path to a text file containing one computer name per line.

  .PARAMETER UseActiveDirectory
  Queries Active Directory for enabled server OS computer accounts when no explicit targets are supplied.

  .EXAMPLE
  Remove-Certificate -Thumbprint 'ABCD1234...' -ComputerName SRV01,SRV02 -Confirm

  .EXAMPLE
  Remove-Certificate -Thumbprint 'ABCD1234...' -ServerListPath C:\Temp\servers.txt -WhatIf

  .EXAMPLE
  Remove-Certificate -Thumbprint 'ABCD1234...' -UseActiveDirectory

  .OUTPUTS
  PSCustomObject
  #>
  [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
  param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^[A-Fa-f0-9 ]{40,}$')]
    [string]$Thumbprint,

    [Parameter(ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
    [Alias('Server', 'Name')]
    [string[]]$ComputerName,

    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ServerListPath,

    [switch]$UseActiveDirectory
  )

  Set-StrictMode -Version Latest

  begin {
    $normalizedThumbprint = ($Thumbprint -replace '\s', '').ToUpperInvariant()
    if ($normalizedThumbprint.Length -ne 40) {
      throw "Thumbprint must resolve to 40 hexadecimal characters. Received '$normalizedThumbprint' ($($normalizedThumbprint.Length) chars)."
    }

    $targets = New-Object System.Collections.Generic.List[string]
  }

  process {
    if ($ComputerName) {
      foreach ($name in $ComputerName) {
        if (-not [string]::IsNullOrWhiteSpace($name)) {
          $targets.Add($name.Trim())
        }
      }
    }
  }

  end {
    if ($ServerListPath) {
      Get-Content -LiteralPath $ServerListPath -ErrorAction Stop |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $targets.Add($_.Trim()) }
    }

    if ($UseActiveDirectory -and $targets.Count -eq 0) {
      if (-not (Get-Command Get-ADComputer -ErrorAction SilentlyContinue)) {
        throw 'UseActiveDirectory was specified, but Get-ADComputer is unavailable. Install/import the ActiveDirectory module.'
      }

      $adTargets = Get-ADComputer -Filter 'operatingsystem -like "*server*" -and enabled -eq "true"' -ErrorAction Stop |
        Select-Object -ExpandProperty Name

      foreach ($name in $adTargets) {
        if (-not [string]::IsNullOrWhiteSpace($name)) {
          $targets.Add($name.Trim())
        }
      }
    }

    if ($targets.Count -eq 0) {
      $targets.Add($env:COMPUTERNAME)
      Write-Verbose "No targets supplied. Defaulting to local computer '$env:COMPUTERNAME'."
    }

    $uniqueTargets = $targets.ToArray() | Sort-Object -Unique

    foreach ($target in $uniqueTargets) {
      Write-Verbose "Processing '$target'."
      if (-not $PSCmdlet.ShouldProcess($target, "Remove certificate thumbprint $normalizedThumbprint from LocalMachine\\My")) {
        continue
      }

      try {
        $result = Invoke-Command -ComputerName $target -ScriptBlock {
          param([string]$RemoteThumbprint)

          $matches = Get-ChildItem -LiteralPath 'Cert:\LocalMachine\My' -ErrorAction Stop |
            Where-Object { $_.Thumbprint -eq $RemoteThumbprint }

          if (-not $matches) {
            return [PSCustomObject]@{
              ComputerName = $env:COMPUTERNAME
              Thumbprint   = $RemoteThumbprint
              RemovedCount = 0
              Removed      = @()
            }
          }

          $removed = foreach ($cert in $matches) {
            $item = [PSCustomObject]@{
              Subject   = $cert.Subject
              Thumbprint = $cert.Thumbprint
              NotAfter  = $cert.NotAfter
            }

            Remove-Item -LiteralPath $cert.PSPath -Force -ErrorAction Stop
            $item
          }

          [PSCustomObject]@{
            ComputerName = $env:COMPUTERNAME
            Thumbprint   = $RemoteThumbprint
            RemovedCount = @($removed).Count
            Removed      = @($removed)
          }
        } -ArgumentList $normalizedThumbprint -ErrorAction Stop

        $result
      }
      catch {
        Write-Error "[$target] Failed to remove certificate $normalizedThumbprint. $($_.Exception.Message)"
      }
    }
  }
}

# When run directly as a script, execute the function.
# When dot-sourced/imported, only define the function.
if ($MyInvocation.InvocationName -ne ".") {
    Remove-Certificate
}
