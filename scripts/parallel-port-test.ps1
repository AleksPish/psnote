# Name: parallel-port-test
# Tags: network
# Saved: 2026-03-04T15:45:44.2029752+00:00
<#
.SYNOPSIS
Tests TCP port connectivity to IPv4 CIDR ranges in parallel.

.DESCRIPTION
This script defines and runs Invoke-ParallelPortTest. It expands one or more IPv4
CIDR ranges into host addresses, tests each host/port combination with parallel
runspaces, optionally exports results to CSV, and returns objects.

.PARAMETER Ports
One or more TCP ports to test.

.PARAMETER IpRanges
One or more IPv4 CIDR ranges to expand and test (for example: 10.10.10.0/24).

.PARAMETER TimeoutMs
TCP connect timeout per test in milliseconds.

.PARAMETER MaxConcurrency
Maximum number of runspaces used for parallel tests.

.PARAMETER OutputPath
CSV output file path. Defaults to a timestamped file in the current directory.

.PARAMETER NoCsvExport
Skips CSV export and only returns result objects.

.EXAMPLE
Get-Help C:\Users\aleks\powershell\HandyTasksScripts\parallel-port-test.ps1 -Detailed

Shows script help, parameter info, and examples.

.EXAMPLE
.\parallel-port-test.ps1 -Ports 80,443 -IpRanges 192.168.1.0/24,10.0.0.0/24 -TimeoutMs 750 -MaxConcurrency 100

Runs custom tests and exports results to a timestamped CSV in the current directory.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [int[]]$Ports = @(3389, 22),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$IpRanges = @('10.10.10.0/24'),

    [Parameter()]
    [ValidateRange(100, 60000)]
    [int]$TimeoutMs = 1000,

    [Parameter()]
    [ValidateRange(1, 500)]
    [int]$MaxConcurrency = 50,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = (Join-Path -Path (Get-Location) -ChildPath ('port-connectivity-results-{0}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))),

    [Parameter()]
    [switch]$NoCsvExport
)

function Get-IPv4HostAddressesFromCidr {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Cidr
    )

    $parts = $Cidr -split '/'
    if ($parts.Count -ne 2) {
        throw "Invalid CIDR format: '$Cidr'. Expected x.x.x.x/nn."
    }

    $ipString = $parts[0]
    $maskBits = 0
    if (-not [int]::TryParse($parts[1], [ref]$maskBits) -or $maskBits -lt 0 -or $maskBits -gt 32) {
        throw "Invalid CIDR mask in '$Cidr'. Mask must be between 0 and 32."
    }

    $parsedIp = $null
    if (-not [System.Net.IPAddress]::TryParse($ipString, [ref]$parsedIp)) {
        throw "Invalid IPv4 address in CIDR: '$Cidr'."
    }

    if ($parsedIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "Only IPv4 CIDR ranges are supported: '$Cidr'."
    }

    # /31 and /32 have no usable host addresses for this scanner.
    if ($maskBits -ge 31) {
        return @()
    }

    $ipBytes = $parsedIp.GetAddressBytes()
    [Array]::Reverse($ipBytes)
    $ipInt = [BitConverter]::ToUInt32($ipBytes, 0)

    $hostBits = 32 - $maskBits
    $maskInt = if ($maskBits -eq 0) {
        [uint32]0
    }
    else {
        [uint32]((((([int64]1) -shl $maskBits) - 1) -shl $hostBits))
    }

    $network = $ipInt -band $maskInt
    $broadcast = $network + [uint32]([math]::Pow(2, $hostBits) - 1)

    $ips = [System.Collections.Generic.List[string]]::new()
    for ($i = $network + 1; $i -lt $broadcast; $i++) {
        $bytes = [BitConverter]::GetBytes($i)
        [Array]::Reverse($bytes)
        $ips.Add(([System.Net.IPAddress]::new($bytes)).IPAddressToString)
    }

    return $ips
}

function Invoke-ParallelPortTest {
    <#
    .SYNOPSIS
    Tests TCP connectivity to multiple IPv4 CIDR ranges and ports in parallel.

    .DESCRIPTION
    Expands IPv4 CIDR ranges into host IPs, tests each IP/port combination with
    parallel runspaces, optionally exports results to CSV, writes a summary, and
    returns structured result objects.

    .PARAMETER Ports
    One or more TCP ports to test.

    .PARAMETER IpRanges
    One or more IPv4 CIDR ranges to expand and test.

    .PARAMETER TimeoutMs
    TCP connect timeout per test in milliseconds.

    .PARAMETER MaxConcurrency
    Maximum number of concurrent runspaces.

    .PARAMETER OutputPath
    CSV output file path.

    .PARAMETER NoCsvExport
    Skips CSV export.

    .EXAMPLE
    Invoke-ParallelPortTest -Ports 80,443 -IpRanges 10.10.10.0/24 -TimeoutMs 500

    Tests web ports with a 500 ms timeout.

    .EXAMPLE
    Invoke-ParallelPortTest -Ports 445 -IpRanges 10.20.30.0/24 -NoCsvExport

    Runs tests and returns objects without creating a CSV file.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [Alias('Port')]
        [int[]]$Ports,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [Alias('IpRange')]
        [string[]]$IpRanges,

        [Parameter()]
        [ValidateRange(100, 60000)]
        [int]$TimeoutMs = 1000,

        [Parameter()]
        [ValidateRange(1, 500)]
        [int]$MaxConcurrency = 50,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$OutputPath = (Join-Path -Path (Get-Location) -ChildPath ('port-connectivity-results-{0}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))),

        [Parameter()]
        [switch]$NoCsvExport
    )

    $uniqueIps = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($range in $IpRanges) {
        foreach ($ip in (Get-IPv4HostAddressesFromCidr -Cidr $range)) {
            $null = $uniqueIps.Add($ip)
        }
    }

    if ($uniqueIps.Count -eq 0) {
        throw 'No testable host IPs were generated from the provided CIDR ranges.'
    }

    $allIps = @($uniqueIps)
    $totalTests = $allIps.Count * $Ports.Count

    Write-Host "Testing connectivity to $($allIps.Count) IPs across $($Ports.Count) ports..."
    Write-Host "Total tests: $totalTests"

    $runspacePool = [RunspaceFactory]::CreateRunspacePool(1, $MaxConcurrency)
    $runspaces = [System.Collections.Generic.List[object]]::new()
    $results = [System.Collections.Generic.List[object]]::new()

    $testScript = {
        param(
            [string]$Ip,
            [int]$Port,
            [int]$TimeoutMs
        )

        $status = 'Error'

        try {
            $tcpClient = [System.Net.Sockets.TcpClient]::new()
            try {
                $connect = $tcpClient.BeginConnect($Ip, $Port, $null, $null)
                $wait = $connect.AsyncWaitHandle.WaitOne($TimeoutMs, $false)

                if ($wait) {
                    try {
                        $tcpClient.EndConnect($connect)
                        $status = 'Open'
                    }
                    catch {
                        $status = 'Closed'
                    }
                }
                else {
                    $status = 'Timeout'
                }
            }
            finally {
                $tcpClient.Close()
            }
        }
        catch {
            $status = 'Error'
        }

        [PSCustomObject]@{
            IP = $Ip
            Port = $Port
            Status = $status
            Timestamp = Get-Date
        }
    }

    try {
        $runspacePool.Open()

        foreach ($ip in $allIps) {
            foreach ($port in $Ports) {
                $ps = [PowerShell]::Create()
                $ps.RunspacePool = $runspacePool
                $ps.AddScript($testScript).AddArgument($ip).AddArgument($port).AddArgument($TimeoutMs) | Out-Null

                $runspaces.Add([PSCustomObject]@{
                    PowerShell = $ps
                    Handle = $ps.BeginInvoke()
                    IP = $ip
                    Port = $port
                })
            }
        }

        Write-Host "Started $($runspaces.Count) parallel tests using runspaces..."

        $completedTests = 0
        while ($runspaces.Count -gt 0) {
            $completedRunspaces = @($runspaces | Where-Object { $_.Handle.IsCompleted })

            foreach ($runspace in $completedRunspaces) {
                try {
                    $result = $runspace.PowerShell.EndInvoke($runspace.Handle)
                    if ($result -and $result.Count -gt 0) {
                        $resultObject = [PSCustomObject]@{
                            IP = $result[0].IP
                            Port = $result[0].Port
                            Status = $result[0].Status
                            Timestamp = $result[0].Timestamp
                        }
                        $results.Add($resultObject)

                        $statusColor = switch ($resultObject.Status) {
                            'Open' { 'Green' }
                            'Closed' { 'Red' }
                            'Timeout' { 'Yellow' }
                            'Error' { 'Magenta' }
                            default { 'White' }
                        }

                        Write-Host "[$($resultObject.Timestamp.ToString('yyyy-MM-dd HH:mm:ss'))] " -NoNewline -ForegroundColor Gray
                        Write-Host "$($resultObject.IP):$($resultObject.Port) " -NoNewline
                        Write-Host $resultObject.Status -ForegroundColor $statusColor
                    }
                }
                catch {
                    Write-Warning "Runspace failed for $($runspace.IP):$($runspace.Port) - $($_.Exception.Message)"
                }
                finally {
                    $runspace.PowerShell.Dispose()
                }

                $completedTests++
                $percent = [math]::Round(($completedTests / [double]$totalTests) * 100, 2)
                Write-Progress -Activity 'Parallel port test' -Status "$completedTests of $totalTests complete" -PercentComplete $percent
            }

            if ($completedRunspaces.Count -gt 0) {
                $remaining = $runspaces | Where-Object { -not $_.Handle.IsCompleted }
                $runspaces = [System.Collections.Generic.List[object]]::new()
                foreach ($item in $remaining) {
                    $runspaces.Add($item)
                }
            }

            Start-Sleep -Milliseconds 50
        }
    }
    finally {
        Write-Progress -Activity 'Parallel port test' -Completed
        $runspacePool.Close()
        $runspacePool.Dispose()
    }

    $sortedResults = $results | Sort-Object IP, Port

    if (-not $NoCsvExport) {
        $outputDirectory = Split-Path -Path $OutputPath -Parent
        if ($outputDirectory -and -not (Test-Path -Path $outputDirectory)) {
            New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
        }

        $sortedResults | Export-Csv -Path $OutputPath -NoTypeInformation
        Write-Host "Results exported to: $OutputPath"
    }

    Write-Host "Total results: $($results.Count)"

    $openPorts = @($results | Where-Object { $_.Status -eq 'Open' }).Count
    $closedPorts = @($results | Where-Object { $_.Status -eq 'Closed' }).Count
    $timeouts = @($results | Where-Object { $_.Status -eq 'Timeout' }).Count
    $errors = @($results | Where-Object { $_.Status -eq 'Error' }).Count

    Write-Host ''
    Write-Host 'Summary:'
    Write-Host "Open ports: $openPorts"
    Write-Host "Closed ports: $closedPorts"
    Write-Host "Timeouts: $timeouts"
    Write-Host "Errors: $errors"

    if ($openPorts -gt 0) {
        Write-Host ''
        Write-Host 'Open ports found:'
        $sortedResults | Where-Object { $_.Status -eq 'Open' } | Format-Table -AutoSize | Out-Host
    }

    return $sortedResults
}

$null = Invoke-ParallelPortTest @PSBoundParameters

