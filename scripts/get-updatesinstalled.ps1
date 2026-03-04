function Get-InstalledUpdatesReport {
# Name: get-updatesinstalled
# Tags: windows,updates
# Saved: 2026-03-03T12:07:57.7554955+00:00
<#
.SYNOPSIS
Retrieves installed Windows updates from a local or remote computer.

.DESCRIPTION
Collects installed update history using CIM/WMI with local fallback paths,
supports date/result limiting, optional CSV export, and passthrough objects.

.PARAMETER ComputerName
Target computer name. Defaults to the local computer.

.PARAMETER LastDays
Returns only updates installed in the last N days.

.PARAMETER MaxResults
Limits the number of returned updates after sorting newest first.

.PARAMETER ExportCsv
Exports output to CSV.

.PARAMETER ExportPath
CSV path used when -ExportCsv is specified.

.PARAMETER PassThru
Returns update objects.

.EXAMPLE
Get-InstalledUpdatesReport -ComputerName SRV01 -LastDays 30

.EXAMPLE
Get-InstalledUpdatesReport -ComputerName SRV01 -ExportCsv -ExportPath C:\Temp\updates.csv -PassThru

.OUTPUTS
PSCustomObject
#>
[OutputType([PSCustomObject])]
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ComputerName = $env:COMPUTERNAME,

    [Parameter(Mandatory = $false)]
    [int]$LastDays,

    [Parameter(Mandatory = $false)]
    [int]$MaxResults,

    [Parameter(Mandatory = $false)]
    [switch]$ExportCsv,

    [Parameter(Mandatory = $false)]
    [string]$ExportPath = "$env:USERPROFILE\Desktop\Windows-Updates-$($ComputerName).csv",

    [Parameter(Mandatory = $false)]
    [switch]$PassThru
)

function Get-InstalledUpdates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName
    )

    $isLocal = $ComputerName -eq "." -or $ComputerName -eq "localhost" -or $ComputerName -eq $env:COMPUTERNAME

    try {
        if ($isLocal) {
            $raw = Get-CimInstance -ClassName Win32_QuickFixEngineering -ErrorAction Stop
        }
        else {
            $raw = Get-CimInstance -ClassName Win32_QuickFixEngineering -ComputerName $ComputerName -ErrorAction Stop
        }
    }
    catch {
        try {
            if ($isLocal) {
                $raw = Get-WmiObject -Class Win32_QuickFixEngineering -ErrorAction Stop
            }
            else {
                $raw = Get-WmiObject -Class Win32_QuickFixEngineering -ComputerName $ComputerName -ErrorAction Stop
            }
        }
        catch {
            if (-not $isLocal) {
                throw ("Failed to query installed updates on '{0}': {1}" -f $ComputerName, $_.Exception.Message)
            }

            try {
                # Final local fallback for locked-down systems: Windows Update history COM API.
                $session = New-Object -ComObject Microsoft.Update.Session
                $searcher = $session.CreateUpdateSearcher()
                $historyCount = $searcher.GetTotalHistoryCount()
                $history = $searcher.QueryHistory(0, $historyCount)

                $raw = foreach ($entry in $history) {
                    $kb = $null
                    if ($entry.Title -match "(KB\d{4,8})") { $kb = $matches[1] }

                    [pscustomobject]@{
                        InstalledOn = $entry.Date
                        HotFixID = $kb
                        Description = $entry.Title
                        InstalledBy = $null
                    }
                }
            }
            catch {
                try {
                    # Last fallback: parse Windows Update install events.
                    $events = Get-WinEvent -FilterHashtable @{
                        LogName = "System"
                        Id = 19
                        ProviderName = "Microsoft-Windows-WindowsUpdateClient"
                    } -ErrorAction Stop

                    $raw = foreach ($evt in $events) {
                        $kb = $null
                        if ($evt.Message -match "(KB\d{4,8})") { $kb = $matches[1] }

                        [pscustomobject]@{
                            InstalledOn = $evt.TimeCreated
                            HotFixID = $kb
                            Description = ($evt.Message -split "`r?`n")[0]
                            InstalledBy = $null
                        }
                    }
                }
                catch {
                    throw ("Failed to query installed updates on '{0}': {1}. Try running PowerShell as Administrator." -f $ComputerName, $_.Exception.Message)
                }
            }
        }
    }

    foreach ($item in $raw) {
        $installedOn = $null
        if ($item.InstalledOn) {
            try { $installedOn = [datetime]$item.InstalledOn } catch { $installedOn = $null }
        }

        [pscustomobject]@{
            ComputerName = $ComputerName
            InstalledOn = $installedOn
            HotFixID = [string]$item.HotFixID
            Description = [string]$item.Description
            InstalledBy = [string]$item.InstalledBy
        }
    }
}

try {
    $updates = @(Get-InstalledUpdates -ComputerName $ComputerName)
}
catch {
    Write-Warning $_.Exception.Message
    $updates = @()
}

if ($LastDays -gt 0) {
    $cutoff = (Get-Date).AddDays(-$LastDays)
    $updates = $updates | Where-Object { $_.InstalledOn -and $_.InstalledOn -ge $cutoff }
}

$updates = $updates | Sort-Object InstalledOn -Descending

if ($MaxResults -gt 0) {
    $updates = $updates | Select-Object -First $MaxResults
}

Write-Host ""
Write-Host ("Installed Windows Updates on {0}" -f $ComputerName) -ForegroundColor Cyan
if ($LastDays -gt 0) {
    Write-Host ("Showing updates from last {0} days" -f $LastDays) -ForegroundColor DarkCyan
}

if (-not $updates -or $updates.Count -eq 0) {
    Write-Host "No updates found for the selected criteria." -ForegroundColor Yellow
}
else {
    $updates |
        Select-Object InstalledOn, HotFixID, Description, InstalledBy |
        Format-Table -AutoSize

    Write-Host ""
    Write-Host ("Total updates shown: {0}" -f $updates.Count) -ForegroundColor Green
}

if ($ExportCsv) {
    $targetDir = Split-Path -Path $ExportPath -Parent
    if ($targetDir -and -not (Test-Path -Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    $updates |
        Select-Object ComputerName, InstalledOn, HotFixID, Description, InstalledBy |
        Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8

    Write-Host ("Exported CSV: {0}" -f $ExportPath) -ForegroundColor Green
}

if ($PassThru) {
    $updates
}
}

