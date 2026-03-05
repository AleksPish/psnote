function Invoke-IpScanner {
# Name: ip-scanner
# Tags: network
# Saved: 2026-03-03T12:36:57.9202333+00:00
<#
.SYNOPSIS
  Scan IP addresses and report reachable hosts.

.DESCRIPTION
  Uses runspaces for concurrent ping checks. Optional DNS and MAC lookups can
  be enabled when needed.

.EXAMPLE
  .\IP-Scanner.ps1 -SubnetPrefix 10.0.0 -StartHost 1 -EndHost 254

.EXAMPLE
  .\IP-Scanner.ps1 -IPList 10.0.0.5,10.0.0.10 -ResolveDns -ResolveMac
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 2048)]
    [int]$Threads = 256,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$SubnetPrefix,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 254)]
    [int]$StartHost = 1,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 254)]
    [int]$EndHost = 254,

    [Parameter(Mandatory = $false)]
    [string[]]$IPList,

    [Parameter(Mandatory = $false)]
    [ValidateRange(100, 5000)]
    [int]$TimeoutMs = 800,

    [Parameter(Mandatory = $false)]
    [switch]$ResolveDns,

    [Parameter(Mandatory = $false)]
    [switch]$ResolveMac,

    [Parameter(Mandatory = $false)]
    [switch]$ShowDeadHosts,

    [Parameter(Mandatory = $false)]
    [switch]$NoProgress
)

if (-not $IPList -or $IPList.Count -eq 0) {
    if (-not $SubnetPrefix -or [string]::IsNullOrWhiteSpace($SubnetPrefix)) {
        $SubnetPrefix = Read-Host -Prompt "Enter subnet prefix to scan (example: 10.0.0 for /24)"
    }

    if (-not $SubnetPrefix -or [string]::IsNullOrWhiteSpace($SubnetPrefix)) {
        throw "SubnetPrefix cannot be empty when -IPList is not provided."
    }

    if ($StartHost -gt $EndHost) {
        throw "StartHost cannot be greater than EndHost."
    }

    $IPList = for ($i = $StartHost; $i -le $EndHost; $i++) {
        "{0}.{1}" -f $SubnetPrefix, $i
    }
}
$IPList = @($IPList)
if ($IPList.Count -eq 1 -and $IPList[0] -is [string] -and $IPList[0].Contains(",")) {
    $IPList = @($IPList[0].Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

Write-Host ""
Write-Host ("IP Scanner - Targets: {0} | Threads: {1} | Timeout: {2}ms" -f $IPList.Count, $Threads, $TimeoutMs) -ForegroundColor Cyan
Write-Host ("DNS Lookup: {0} | MAC Lookup: {1}" -f $ResolveDns.IsPresent, $ResolveMac.IsPresent) -ForegroundColor DarkCyan

$pool = $null
$runspaces = New-Object System.Collections.ArrayList
$results = New-Object System.Collections.Generic.List[object]

$scriptBlock = {
    param(
        [string]$IpAddress,
        [int]$TimeoutMs,
        [bool]$ResolveDns,
        [bool]$ResolveMac
    )

    $isAlive = $false
    $dnsName = $null
    $macAddress = $null
    $roundTripMs = $null
    $errorText = $null

    try {
        $pinger = New-Object System.Net.NetworkInformation.Ping
        $reply = $pinger.Send($IpAddress, $TimeoutMs)
        if ($reply -and $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
            $isAlive = $true
            $roundTripMs = [int]$reply.RoundtripTime
        }
    }
    catch {
        $errorText = $_.Exception.Message
    }

    if ($isAlive -and $ResolveDns) {
        try {
            $dnsName = ([System.Net.Dns]::GetHostEntry($IpAddress)).HostName
        }
        catch {}
    }

    if ($isAlive -and $ResolveMac) {
        try {
            if (Get-Command -Name Get-NetNeighbor -ErrorAction SilentlyContinue) {
                $neighbor = Get-NetNeighbor -IPAddress $IpAddress -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($neighbor) {
                    $macAddress = $neighbor.LinkLayerAddress
                }
            }
        }
        catch {}
    }

    [pscustomobject]@{
        IP = $IpAddress
        Alive = $isAlive
        RoundTripMs = $roundTripMs
        DNS = $dnsName
        MAC = $macAddress
        Error = $errorText
    }
}

try {
    $pool = [RunspaceFactory]::CreateRunspacePool(1, $Threads)
    $pool.ApartmentState = "MTA"
    $pool.Open()

    foreach ($ip in $IPList) {
        $ps = [PowerShell]::Create()
        $null = $ps.AddScript($scriptBlock).AddArgument($ip).AddArgument($TimeoutMs).AddArgument($ResolveDns.IsPresent).AddArgument($ResolveMac.IsPresent)
        $ps.RunspacePool = $pool

        $handle = $ps.BeginInvoke()
        $null = $runspaces.Add([pscustomobject]@{
            PowerShell = $ps
            Handle = $handle
        })
    }

    $completed = 0
    $total = $runspaces.Count

    foreach ($job in $runspaces) {
        try {
            $output = $job.PowerShell.EndInvoke($job.Handle)
            foreach ($item in $output) {
                $results.Add($item) | Out-Null
            }
        }
        finally {
            $job.PowerShell.Dispose()
            $completed++
            if (-not $NoProgress) {
                $pct = [int](($completed / $total) * 100)
                Write-Progress -Activity "Scanning IP range" -Status ("Processed {0}/{1}" -f $completed, $total) -PercentComplete $pct
            }
        }
    }
}
finally {
    if ($pool) {
        $pool.Close()
        $pool.Dispose()
    }
    if (-not $NoProgress) {
        Write-Progress -Activity "Scanning IP range" -Completed
    }
}

$allResults = @($results | Sort-Object IP)
$aliveResults = @($allResults | Where-Object { $_.Alive })
$deadResults = @($allResults | Where-Object { -not $_.Alive })

Write-Host ""
Write-Host ("Total Hosts: {0}" -f $allResults.Count) -ForegroundColor Cyan
Write-Host ("Alive Hosts: {0}" -f $aliveResults.Count) -ForegroundColor Green
Write-Host ("Dead Hosts:  {0}" -f $deadResults.Count) -ForegroundColor Red
Write-Host ""

if ($ShowDeadHosts) {
    $allResults |
        Select-Object IP, Alive, RoundTripMs, DNS, MAC, Error |
        Format-Table -AutoSize
}
else {
    if ($aliveResults.Count -eq 0) {
        Write-Host "No reachable hosts found." -ForegroundColor Yellow
    }
    else {
        $aliveResults |
            Select-Object IP, RoundTripMs, DNS, MAC |
            Format-Table -AutoSize
    }
}
}

# When run directly as a script, execute the function.
# When dot-sourced/imported, only define the function.
if ($MyInvocation.InvocationName -ne ".") {
    Invoke-IpScanner
}
