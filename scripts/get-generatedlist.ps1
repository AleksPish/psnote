# Name: get-generatedlist
# Tags: tools
# Saved: 2026-03-03T20:01:28.1090882+00:00
function Get-GeneratedList {
  <#
  .SYNOPSIS
  Generates common admin lists such as server name ranges, IPv4 ranges, and number ranges.

  .DESCRIPTION
  Supports three modes via parameter sets:
  1. NameRange: values like server-01, server-02, server-03
  2. IpRange: IPv4 ranges like 10.0.0.1 to 10.0.0.254
  3. NumberRange: generic numeric sequences with optional prefix/suffix

  Results are written to the pipeline and can optionally be exported to a text/CSV file
  or copied to clipboard.

  .EXAMPLE
  Get-GeneratedList -Prefix 'server-' -StartNumber 1 -EndNumber 20 -PadWidth 2

  .EXAMPLE
  Get-GeneratedList -StartIp 192.168.1.10 -EndIp 192.168.1.30

  .EXAMPLE
  Get-GeneratedList -Start 100 -End 120 -NumberPrefix 'vm-' -PadWidth 3 -OutputPath C:\Temp\vms.txt

  .OUTPUTS
  System.String or PSCustomObject
  #>
  [CmdletBinding(DefaultParameterSetName='NameRange')]
  param(
    [Parameter(ParameterSetName='NameRange')]
    [string]$Prefix = 'server-',

    [Parameter(ParameterSetName='NameRange')]
    [string]$Suffix = '',

    [Parameter()]
    [ValidateRange(0, 12)]
    [int]$PadWidth = 2,

    [Parameter(ParameterSetName='NameRange')]
    [int]$StartNumber = 1,

    [Parameter(ParameterSetName='NameRange')]
    [int]$EndNumber = 10,

    [Parameter(Mandatory=$true, ParameterSetName='IpRange')]
    [string]$StartIp,

    [Parameter(Mandatory=$true, ParameterSetName='IpRange')]
    [string]$EndIp,

    [Parameter(Mandatory=$true, ParameterSetName='NumberRange')]
    [int]$Start,

    [Parameter(Mandatory=$true, ParameterSetName='NumberRange')]
    [int]$End,

    [Parameter(ParameterSetName='NumberRange')]
    [string]$NumberPrefix = '',

    [Parameter(ParameterSetName='NumberRange')]
    [string]$NumberSuffix = '',

    [Parameter()]
    [ValidateRange(1, 1000000)]
    [int]$Step = 1,

    [Parameter()]
    [switch]$AsObject,

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [ValidateSet('Text', 'Csv')]
    [string]$OutputFormat = 'Text',

    [Parameter()]
    [switch]$CopyToClipboard
  )

  Set-StrictMode -Version Latest

  function Get-NumericRange {
    param(
      [Parameter(Mandatory=$true)][int64]$From,
      [Parameter(Mandatory=$true)][int64]$To,
      [Parameter(Mandatory=$true)][int]$StepSize
    )

    if ($From -le $To) {
      for ($n = $From; $n -le $To; $n += $StepSize) {
        $n
      }
    }
    else {
      for ($n = $From; $n -ge $To; $n -= $StepSize) {
        $n
      }
    }
  }

  function ConvertTo-IpUInt32 {
    param([Parameter(Mandatory=$true)][string]$IpAddress)

    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($IpAddress, [ref]$parsed)) {
      throw "Invalid IPv4 address: $IpAddress"
    }

    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
      throw "Only IPv4 is supported. Invalid value: $IpAddress"
    }

    $bytes = $parsed.GetAddressBytes()
    [array]::Reverse($bytes)
    return [System.BitConverter]::ToUInt32($bytes, 0)
  }

  function ConvertFrom-IpUInt32 {
    param([Parameter(Mandatory=$true)][uint32]$Value)

    $bytes = [System.BitConverter]::GetBytes($Value)
    [array]::Reverse($bytes)
    return ([System.Net.IPAddress]::new($bytes)).ToString()
  }

  $values = switch ($PSCmdlet.ParameterSetName) {
    'NameRange' {
      Get-NumericRange -From $StartNumber -To $EndNumber -StepSize $Step | ForEach-Object {
        $numberText = if ($PadWidth -gt 0) { $_.ToString("D$PadWidth") } else { "$_" }
        '{0}{1}{2}' -f $Prefix, $numberText, $Suffix
      }
      break
    }
    'IpRange' {
      $startValue = ConvertTo-IpUInt32 -IpAddress $StartIp
      $endValue = ConvertTo-IpUInt32 -IpAddress $EndIp
      Get-NumericRange -From $startValue -To $endValue -StepSize $Step | ForEach-Object {
        ConvertFrom-IpUInt32 -Value ([uint32]$_)
      }
      break
    }
    'NumberRange' {
      Get-NumericRange -From $Start -To $End -StepSize $Step | ForEach-Object {
        $numberText = if ($PadWidth -gt 0) { $_.ToString("D$PadWidth") } else { "$_" }
        '{0}{1}{2}' -f $NumberPrefix, $numberText, $NumberSuffix
      }
      break
    }
    default {
      throw "Unsupported mode '$($PSCmdlet.ParameterSetName)'."
    }
  }

  $output = @()
  $index = 1
  foreach ($value in $values) {
    if ($AsObject) {
      $output += [PSCustomObject]@{
        Index = $index
        Value = $value
      }
    }
    else {
      $output += $value
    }
    $index++
  }

  if ($OutputPath) {
    $parent = Split-Path -Path $OutputPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
      New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }

    if ($OutputFormat -eq 'Csv') {
      $csvRows = if ($AsObject) { $output } else { $output | ForEach-Object { [PSCustomObject]@{ Value = $_ } } }
      $csvRows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    }
    else {
      $textRows = if ($AsObject) { $output | ForEach-Object { $_.Value } } else { $output }
      $textRows | Set-Content -Path $OutputPath -Encoding UTF8
    }

    Write-Verbose "Saved $($output.Count) item(s) to '$OutputPath' as $OutputFormat."
  }

  if ($CopyToClipboard) {
    if (-not (Get-Command Set-Clipboard -ErrorAction SilentlyContinue)) {
      Write-Warning 'Set-Clipboard is not available in this PowerShell session.'
    }
    else {
      $clipboardText = if ($AsObject) { ($output | ForEach-Object { $_.Value }) -join [Environment]::NewLine } else { $output -join [Environment]::NewLine }
      Set-Clipboard -Value $clipboardText
      Write-Verbose 'List copied to clipboard.'
    }
  }

  $output
}

# When run directly as a script, execute the function.
# When dot-sourced/imported, only define the function.
if ($MyInvocation.InvocationName -ne ".") {
    Get-GeneratedList
}
