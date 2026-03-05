function Get-ListeningProcessesReport {
# Name: get-listeningprocesses
# Tags: windows,network
# Saved: 2026-03-03T11:38:42.1963592+00:00
#######################################
#/-----------------------------------\#
#|Aleks Pace - thepace.uk            |#
#\-----------------------------------/#
#######################################
<#
.Synopsis
   Get all TCP ports a server is listening on and display the owning process.

.Example
   .\Get-ListeningProcesses.ps1

.Example
   .\Get-ListeningProcesses.ps1 -IncludeAllLocalAddresses -ExportPath "C:\Temp\ListeningPorts.csv"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$IncludeAllLocalAddresses,

    [Parameter(Mandatory = $false)]
    [string]$ExportPath = "$env:TEMP\$env:COMPUTERNAME-ListeningPorts.csv",

    [Parameter(Mandatory = $false)]
    [switch]$Export
)

function Get-ListeningProcesses {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$IncludeAllLocalAddresses
    )

    $listeningConnections = @()

    if (Get-Command -Name Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        $listeningConnections = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)
    }

    if (-not $listeningConnections -or $listeningConnections.Count -eq 0) {
        # Fallback for systems without NetTCP cmdlets.
        $listeningConnections = @()
        $netstatLines = netstat -ano -p tcp | Select-String -Pattern "LISTENING"
        foreach ($line in $netstatLines) {
            $parts = ($line.ToString() -replace "\s+", " ").Trim().Split(" ")
            if ($parts.Count -lt 5) { continue }

            $local = $parts[1]
            $owningProcessId = [int]$parts[4]
            $localPort = [int]($local.Split(":")[-1])
            $localAddress = $local.Substring(0, $local.LastIndexOf(":"))

            $listeningConnections += [pscustomobject]@{
                LocalAddress = $localAddress
                LocalPort = $localPort
                OwningProcess = $owningProcessId
            }
        }
    }

    if (-not $IncludeAllLocalAddresses) {
        $listeningConnections = $listeningConnections | Where-Object {
            $_.LocalAddress -eq "0.0.0.0" -or $_.LocalAddress -eq "::"
        }
    }

    $results = foreach ($connection in $listeningConnections) {
        $processName = "<exited>"
        try {
            $processName = (Get-Process -Id $connection.OwningProcess -ErrorAction Stop).ProcessName
        }
        catch {}

        [pscustomobject]@{
            LocalAddress = $connection.LocalAddress
            LocalPort = $connection.LocalPort
            ProcessId = $connection.OwningProcess
            ProcessName = $processName
        }
    }

    $results |
        Sort-Object LocalPort, ProcessId -Unique
}

$output = Get-ListeningProcesses -IncludeAllLocalAddresses:$IncludeAllLocalAddresses

if ($Export) {
    $targetDir = Split-Path -Path $ExportPath -Parent
    if ($targetDir -and -not (Test-Path -Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    $output | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
    Write-Host ("Exported listening port report to: {0}" -f $ExportPath)
}

$output
}

# When run directly as a script, execute the function.
# When dot-sourced/imported, only define the function.
if ($MyInvocation.InvocationName -ne ".") {
    Get-ListeningProcessesReport
}
