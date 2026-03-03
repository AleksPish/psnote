# Name: get-odbcdriverlocation
# Tags: SQL
# Saved: 2026-03-03T14:22:15.6247953+00:00
Set-StrictMode -Version Latest

function Get-SqlOdbcDriverLocationStatus {
  <#
  .SYNOPSIS
  Checks whether the SQL ODBC Client SDK folder exists on one or more computers.

  .DESCRIPTION
  Tests the UNC path:
  \\<ComputerName>\C$\Program Files\Microsoft SQL Server\Client SDK\ODBC
  and returns structured status data per target computer.

  .PARAMETER ComputerName
  One or more target computer names.

  .PARAMETER ServerListPath
  Text file containing one computer name per line.

  .PARAMETER UseActiveDirectory
  Queries Active Directory for enabled server OS computer accounts when no explicit targets are provided.

  .PARAMETER SkipConnectivityTest
  Skips the initial ICMP reachability check (Test-Connection).

  .EXAMPLE
  Get-SqlOdbcDriverLocationStatus -UseActiveDirectory

  .EXAMPLE
  Get-SqlOdbcDriverLocationStatus -ComputerName SQL01,SQL02 -Verbose

  .EXAMPLE
  Get-SqlOdbcDriverLocationStatus -ServerListPath C:\Temp\servers.txt | Export-Csv C:\Temp\odbc-status.csv -NoTypeInformation

  .OUTPUTS
  PSCustomObject
  #>
  [CmdletBinding()]
  param(
    [Parameter(ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
    [Alias('Server', 'Name')]
    [string[]]$ComputerName,

    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ServerListPath,

    [switch]$UseActiveDirectory,

    [switch]$SkipConnectivityTest
  )

  begin {
    $targets = New-Object System.Collections.Generic.List[string]
    $odbcSubPath = 'C$\Program Files\Microsoft SQL Server\Client SDK\ODBC'
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

    foreach ($server in $uniqueTargets) {
      Write-Verbose "Processing '$server'."

      $uncPath = "\\$server\$odbcSubPath"
      $isReachable = $null
      $exists = $null
      $errorMessage = $null

      try {
        if (-not $SkipConnectivityTest) {
          $isReachable = Test-Connection -ComputerName $server -Count 1 -Quiet -ErrorAction Stop
          if (-not $isReachable) {
            $errorMessage = 'Host did not respond to ICMP ping.'
          }
        }

        if ($SkipConnectivityTest -or $isReachable) {
          $exists = Test-Path -LiteralPath $uncPath -PathType Container -ErrorAction Stop
        }
      }
      catch {
        $errorMessage = $_.Exception.Message
      }

      [PSCustomObject]@{
        ComputerName = $server
        Path         = $uncPath
        Reachable    = $isReachable
        Exists       = $exists
        Error        = $errorMessage
      }
    }
  }
}

$isDotSourced = $MyInvocation.InvocationName -eq '.'
if (-not $isDotSourced) {
  Get-SqlOdbcDriverLocationStatus -UseActiveDirectory
}

