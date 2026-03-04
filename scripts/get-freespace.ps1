# Name: get-freespace
# Tags: windows
# Saved: 2026-03-04T16:42:06.4935749+00:00
param(
    [Parameter()]
    [Alias("CN", "Server", "Name")]
    [string[]]$ComputerName = @($env:COMPUTERNAME),

    [Parameter()]
    [ValidateRange(0, 100)]
    [int]$BelowPercentFree,

    [Parameter()]
    [switch]$PassThru
)

function Get-FreeSpace {
    <#
    .SYNOPSIS
    Reports fixed-disk free space on local or remote Windows computers.

    .DESCRIPTION
    Queries logical disks (DriveType=3) using CIM/WMI with local fallbacks and
    returns size and utilization details per drive.

    .PARAMETER ComputerName
    One or more target computer names. Defaults to the local computer.

    .PARAMETER BelowPercentFree
    Optional threshold to return only drives with free space below this percent.

    .EXAMPLE
    Get-FreeSpace -ComputerName SRV01,SRV02

    .EXAMPLE
    Get-FreeSpace -ComputerName SRV01 -BelowPercentFree 15

    .OUTPUTS
    PSCustomObject
    #>
    [OutputType([PSCustomObject])]
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias("CN", "Server", "Name")]
        [string[]]$ComputerName = @($env:COMPUTERNAME),

        [Parameter()]
        [ValidateRange(0, 100)]
        [int]$BelowPercentFree
    )

    begin {
        $allResults = @()
    }

    process {
        foreach ($computer in $ComputerName) {
            $isLocal = $computer -eq "." -or $computer -eq "localhost" -or $computer -eq $env:COMPUTERNAME
            $allDisks = $null

            try {
                if ($isLocal) {
                    $allDisks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop
                }
                else {
                    $allDisks = Get-CimInstance -ComputerName $computer -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop
                }
            }
            catch {
                try {
                    # Fallback for systems without WSMan/WinRM connectivity.
                    if ($isLocal) {
                        $allDisks = Get-WmiObject -Class Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop
                    }
                    else {
                        $allDisks = Get-WmiObject -ComputerName $computer -Class Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop
                    }
                }
                catch {
                    if ($isLocal) {
                        try {
                            # Final local fallback that avoids CIM/WMI permissions/remoting.
                            $allDisks = [System.IO.DriveInfo]::GetDrives() | Where-Object {
                                $_.DriveType -eq [System.IO.DriveType]::Fixed -and $_.IsReady
                            }
                        }
                        catch {
                            Write-Error ("Failed to query '{0}': {1}" -f $computer, $_.Exception.Message)
                            continue
                        }
                    }
                    else {
                        Write-Error ("Failed to query '{0}': {1}" -f $computer, $_.Exception.Message)
                        continue
                    }
                }
            }

            foreach ($disk in $allDisks) {
                $sizeBytes = $null
                $freeBytes = $null
                $driveId = $null
                $label = $null

                if ($disk -is [System.IO.DriveInfo]) {
                    $sizeBytes = $disk.TotalSize
                    $freeBytes = $disk.AvailableFreeSpace
                    $driveId = $disk.Name.TrimEnd('\')
                    $label = $disk.VolumeLabel
                }
                else {
                    $sizeBytes = $disk.Size
                    $freeBytes = $disk.FreeSpace
                    $driveId = $disk.DeviceID
                    $label = $disk.VolumeName
                }

                if (-not $sizeBytes -or $sizeBytes -le 0) {
                    continue
                }

                $sizeGb = [math]::Round(($sizeBytes / 1GB), 2)
                $freeGb = [math]::Round(($freeBytes / 1GB), 2)
                $usedGb = [math]::Round((($sizeBytes - $freeBytes) / 1GB), 2)
                $percentFree = [math]::Round((($freeBytes / $sizeBytes) * 100), 2)

                $row = [pscustomobject]@{
                    ComputerName = $computer
                    Drive = $driveId
                    Label = $label
                    SizeGB = $sizeGb
                    UsedGB = $usedGb
                    FreeGB = $freeGb
                    PercentFree = $percentFree
                }

                if ($PSBoundParameters.ContainsKey("BelowPercentFree")) {
                    if ($percentFree -lt $BelowPercentFree) {
                        $allResults += $row
                    }
                }
                else {
                    $allResults += $row
                }
            }
        }
    }

    end {
        $allResults
    }
}

if ($MyInvocation.InvocationName -ne ".") {
    $invokeParams = @{
        ComputerName = $ComputerName
    }

    if ($PSBoundParameters.ContainsKey("BelowPercentFree")) {
        $invokeParams.BelowPercentFree = $BelowPercentFree
    }

    $results = @(Get-FreeSpace @invokeParams)

    if (-not $results -or $results.Count -eq 0) {
        Write-Warning "No fixed drives found, or no drives matched the selected filter."
    }
    else {
        $results |
            Sort-Object ComputerName, Drive |
            Format-Table ComputerName, Drive, Label, SizeGB, UsedGB, FreeGB, PercentFree -AutoSize
    }

    if ($PassThru) {
        $results
    }
}

