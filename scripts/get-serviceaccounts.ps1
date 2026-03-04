function Get-ServiceAccountsReport {
# Name: get-serviceaccounts
# Tags: windows,service
# Saved: 2026-03-03T11:58:52.2421771+00:00
<#
.SYNOPSIS
Reports Windows service logon accounts on a target computer.

.DESCRIPTION
Collects service account assignments, supports filtering to domain-style
accounts, optionally includes disabled services, and prints summary statistics.

.PARAMETER ComputerName
Target computer name. Defaults to the local computer.

.PARAMETER OnlyDomainAccounts
Shows only services running as domain or custom accounts.

.PARAMETER IncludeDisabledServices
Includes services with startup type Disabled.

.PARAMETER PassThru
Returns service account detail objects.

.EXAMPLE
Get-ServiceAccountsReport -ComputerName SRV01

.EXAMPLE
Get-ServiceAccountsReport -ComputerName SRV01 -OnlyDomainAccounts -PassThru

.OUTPUTS
PSCustomObject
#>
[OutputType([PSCustomObject])]
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ComputerName = $env:COMPUTERNAME,

    [Parameter(Mandatory = $false)]
    [switch]$OnlyDomainAccounts,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeDisabledServices,

    [Parameter(Mandatory = $false)]
    [switch]$PassThru
)

function Get-ServiceAccounts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [Parameter(Mandatory = $false)]
        [switch]$OnlyDomainAccounts,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeDisabledServices
    )

    try {
        $isLocal = $ComputerName -eq "." -or $ComputerName -eq "localhost" -or $ComputerName -eq $env:COMPUTERNAME
        if ($isLocal) {
            $services = Get-CimInstance -ClassName Win32_Service -ErrorAction Stop
        }
        else {
            $services = Get-CimInstance -ClassName Win32_Service -ComputerName $ComputerName -ErrorAction Stop
        }
    }
    catch {
        try {
            if ($isLocal) {
                $services = Get-WmiObject -Class Win32_Service -ErrorAction Stop
            }
            else {
                $services = Get-WmiObject -Class Win32_Service -ComputerName $ComputerName -ErrorAction Stop
            }
        }
        catch {
            if (-not $isLocal) {
                throw ("Failed to query services from '{0}': {1}" -f $ComputerName, $_.Exception.Message)
            }

            try {
                # Final local fallback for locked-down hosts: read service account data from registry.
                $statusMap = @{}
                Get-Service | ForEach-Object { $statusMap[$_.Name] = $_.Status.ToString() }

                $services = foreach ($key in Get-ChildItem -Path "HKLM:\SYSTEM\CurrentControlSet\Services" -ErrorAction Stop) {
                    $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
                    if ($null -eq $props) { continue }

                    # Service "Type" values with Win32 service bits set: 0x10 (own process), 0x20 (shared process)
                    if (($props.Type -band 0x10) -eq 0 -and ($props.Type -band 0x20) -eq 0) { continue }

                    $startMode = switch ([int]$props.Start) {
                        2 { "Auto" }
                        3 { "Manual" }
                        4 { "Disabled" }
                        default { "Unknown" }
                    }

                    [pscustomobject]@{
                        Name = $key.PSChildName
                        DisplayName = if ($props.DisplayName) { [string]$props.DisplayName } else { [string]$key.PSChildName }
                        StartName = if ($props.ObjectName) { [string]$props.ObjectName } else { "LocalSystem" }
                        State = if ($statusMap.ContainsKey($key.PSChildName)) { $statusMap[$key.PSChildName] } else { "Unknown" }
                        StartMode = $startMode
                    }
                }
            }
            catch {
                throw ("Failed to query services from '{0}': {1}" -f $ComputerName, $_.Exception.Message)
            }
        }
    }

    $results = foreach ($svc in $services) {
        if (-not $IncludeDisabledServices -and $svc.StartMode -eq "Disabled") {
            continue
        }

        $account = [string]$svc.StartName
        if ($OnlyDomainAccounts) {
            if ($account -match "^(LocalSystem|NT AUTHORITY\\|NT SERVICE\\|LocalService|NetworkService)") {
                continue
            }
            if ($account -notmatch "\\") {
                continue
            }
        }

        [pscustomobject]@{
            ComputerName = $ComputerName
            ServiceName = $svc.Name
            DisplayName = $svc.DisplayName
            StartAccount = $account
            State = $svc.State
            StartMode = $svc.StartMode
        }
    }

    $results | Sort-Object StartAccount, ServiceName
}

$output = Get-ServiceAccounts -ComputerName $ComputerName -OnlyDomainAccounts:$OnlyDomainAccounts -IncludeDisabledServices:$IncludeDisabledServices

Write-Host ""
Write-Host ("Service Account Assignments on {0}" -f $ComputerName) -ForegroundColor Cyan
$output | Format-Table -Property StartAccount, ServiceName, State, StartMode -AutoSize

Write-Host ""
Write-Host "Summary by Account" -ForegroundColor Cyan
$output |
    Group-Object -Property StartAccount |
    Sort-Object -Property @{Expression = "Count"; Descending = $true}, @{Expression = "Name"; Descending = $false} |
    Select-Object @{Name = "ServiceCount"; Expression = { $_.Count } }, @{Name = "StartAccount"; Expression = { $_.Name } } |
    Format-Table -AutoSize

if ($PassThru) {
    $output
}
}

