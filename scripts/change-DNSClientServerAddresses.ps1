function Set-DnsClientServerAddressesBulk {
# Name: change-DNSClientServerAddresses
# Tags: windows
# Saved: 2026-03-03T10:42:40.3859605+00:00
#######################################
#/-----------------------------------\#
#|Aleks Piszczynski - piszczynski.com|#
#\-----------------------------------/#
#######################################
<#
.SYNOPSIS
Changes DNS server addresses on active network adapters across multiple servers.

.DESCRIPTION
Prompts for DNS server IPs, validates input, and updates active hardware
network adapters on each target server via PowerShell remoting.

.PARAMETER Servers
Target server names. If omitted, values from $scriptServers are used.

.EXAMPLE
Set-DnsClientServerAddressesBulk -Servers @('Server01','Server02')

.OUTPUTS
PSCustomObject
#>
[OutputType([PSCustomObject])]
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
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
    if (-not $PSCmdlet.ShouldProcess($server, "Set DNS client server addresses")) {
        continue
    }

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

    [pscustomobject]@{
        ComputerName = $server
        DnsServers   = ($dnsServers -join ", ")
        Updated      = $true
    }
}
}

# When run directly as a script, execute the function.
# When dot-sourced/imported, only define the function.
if ($MyInvocation.InvocationName -ne ".") {
    Set-DnsClientServerAddressesBulk
}
