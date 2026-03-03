# Name: change-DNSClientServerAddresses
# Tags: windows
# Saved: 2026-03-03T10:42:40.3859605+00:00
#######################################
#/-----------------------------------\#
#|Aleks Piszczynski - piszczynski.com|#
#\-----------------------------------/#
#######################################
<#
.Synopsis
   Script to change DNS of multiple servers
.EXAMPLE
   .\Change-DNSClientServerAddresses.ps1 -Servers @("Server01","Server02")
#>
param(
    [Parameter(Mandatory = $false)]
    [string[]]$Servers
)

$scriptServers = @()

function Test-ValidIpAddress {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Address
    )

    $parsed = $null
    $null = [System.Net.IPAddress]::TryParse($Address, [ref]$parsed)
    return ($parsed -and $parsed.AddressFamily -in @(
        [System.Net.Sockets.AddressFamily]::InterNetwork,
        [System.Net.Sockets.AddressFamily]::InterNetworkV6
    ))
}

if (-not $Servers -or $Servers.Count -eq 0) {
    $Servers = $scriptServers
}

if (-not $Servers -or $Servers.Count -eq 0) {
    throw "No servers were provided. Pass -Servers or populate `$scriptServers in the script."
}

$dnsInput = Read-Host "Enter DNS server IP addresses (comma-separated, e.g. 1.1.1.1,8.8.8.8)"
$dnsServers = $dnsInput -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" } | Select-Object -Unique

if (-not $dnsServers -or $dnsServers.Count -eq 0) {
    throw "No DNS server IP addresses were provided."
}

$invalidDnsEntries = $dnsServers | Where-Object { -not (Test-ValidIpAddress -Address $_) }
if ($invalidDnsEntries) {
    throw ("Invalid DNS IP address(es): {0}" -f ($invalidDnsEntries -join ", "))
}

foreach ($server in $Servers) {
    Invoke-Command -ComputerName $server -ScriptBlock {
        param([string[]]$DnsServerAddresses)

        $adapterIndexes = Get-NetAdapter |
            Where-Object { $_.Status -eq "Up" -and $_.HardwareInterface } |
            Select-Object -ExpandProperty ifIndex

        if (-not $adapterIndexes) {
            throw "No active hardware network adapters found on $env:COMPUTERNAME."
        }

        foreach ($adapterIndex in $adapterIndexes) {
            Set-DnsClientServerAddress -InterfaceIndex $adapterIndex -ServerAddresses $DnsServerAddresses -ErrorAction Stop
        }
    } -ArgumentList (,$dnsServers) -ErrorAction Stop

    Write-Host ("Updated DNS settings on {0} to: {1}" -f $server, ($dnsServers -join ", "))
}

