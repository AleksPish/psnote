function Invoke-CDriveCleanup {
# Name: c-drive-cleanup
# Tags: windows
# Saved: 2026-03-03T10:27:05.4680641+00:00
<#
.SYNOPSIS
Performs common C: drive cleanup tasks and reports space reclaimed.

.DESCRIPTION
Runs a curated set of cleanup actions for temporary folders and update cache
locations, writes a transcript and CSV audit output, and supports WhatIf/Confirm.

.PARAMETER DaysToDelete
Age threshold in days for tasks that remove only older files.

.PARAMETER TranscriptPath
Path for transcript logging.

.PARAMETER AuditCsvPath
Path for audit CSV output containing cleanup results.

.PARAMETER IncludeCleanMgr
Runs legacy CleanMgr (if available) as part of cleanup.

.PARAMETER IncludeSccmCacheShrink
Attempts to reduce Configuration Manager client cache size.

.EXAMPLE
Invoke-CDriveCleanup -DaysToDelete 30 -WhatIf

.EXAMPLE
Invoke-CDriveCleanup -IncludeCleanMgr -IncludeSccmCacheShrink

.OUTPUTS
PSCustomObject
#>
[OutputType([PSCustomObject])]
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 3650)]
    [int]$DaysToDelete = 60,

    [Parameter(Mandatory = $false)]
    [string]$TranscriptPath = (Join-Path $env:TEMP ("CDriveCleanup-Transcript-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))),

    [Parameter(Mandatory = $false)]
    [string]$AuditCsvPath = (Join-Path $env:TEMP ("CDriveCleanup-Audit-{0}.csv" -f (Get-Date -Format "yyyyMMdd-HHmmss"))),

    [Parameter(Mandatory = $false)]
    [switch]$IncludeCleanMgr,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeSccmCacheShrink
)

function Start-CleanupV2 {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 3650)]
        [int]$DaysToDelete = 60,

        [Parameter(Mandatory = $false)]
        [string]$TranscriptPath = (Join-Path $env:TEMP ("CDriveCleanup-Transcript-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))),

        [Parameter(Mandatory = $false)]
        [string]$AuditCsvPath = (Join-Path $env:TEMP ("CDriveCleanup-Audit-{0}.csv" -f (Get-Date -Format "yyyyMMdd-HHmmss"))),

        [Parameter(Mandatory = $false)]
        [switch]$IncludeCleanMgr,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeSccmCacheShrink
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    function Test-IsAdministrator {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    function Write-Info {
        param([string]$Message)
        Write-Host $Message -ForegroundColor Green
    }

    function Write-Warn {
        param([string]$Message)
        Write-Warning $Message
    }

    function Get-LogicalDiskState {
        param([string]$DriveLetter = 'C:')
        $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID = '$DriveLetter'"
        if (-not $disk) {
            return $null
        }

        [pscustomobject]@{
            Drive          = $disk.DeviceID
            SizeGB         = [math]::Round($disk.Size / 1GB, 2)
            FreeSpaceGB    = [math]::Round($disk.FreeSpace / 1GB, 2)
            PercentFree    = [math]::Round(($disk.FreeSpace / $disk.Size) * 100, 2)
            Timestamp      = Get-Date
        }
    }

    function Get-SizeBytesFromPattern {
        param([Parameter(Mandatory = $true)][string]$PathPattern)

        $total = 0L
        $roots = @(Get-Item -Path $PathPattern -Force -ErrorAction SilentlyContinue)
        foreach ($root in $roots) {
            if ($root -is [System.IO.FileInfo]) {
                $total += $root.Length
                continue
            }

            $measure = Get-ChildItem -LiteralPath $root.FullName -Recurse -Force -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum
            if ($measure -and $null -ne $measure.Sum) {
                $total += [int64]$measure.Sum
            }
        }
        return $total
    }

    function Get-SizeBytesOlderThanDays {
        param(
            [Parameter(Mandatory = $true)][string]$PathPattern,
            [Parameter(Mandatory = $true)][int]$OlderThanDays
        )

        $cutoff = (Get-Date).AddDays(-$OlderThanDays)
        $measure = Get-ChildItem -Path $PathPattern -Recurse -Force -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            Measure-Object -Property Length -Sum

        if (-not $measure -or $null -eq $measure.Sum) {
            return 0L
        }
        return [int64]$measure.Sum
    }

    function Remove-PathPatternContents {
        param(
            [Parameter(Mandatory = $true)][string]$PathPattern,
            [switch]$OnlyOlderThanDays,
            [int]$OlderThanDays = 0
        )

        $removedCount = 0
        $errors = New-Object System.Collections.Generic.List[string]
        $cutoff = (Get-Date).AddDays(-$OlderThanDays)

        if ($OnlyOlderThanDays.IsPresent) {
            $targets = @(Get-ChildItem -Path $PathPattern -Recurse -Force -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $cutoff })
        }
        else {
            $targets = @(Get-ChildItem -Path $PathPattern -Force -ErrorAction SilentlyContinue)
        }

        foreach ($target in $targets) {
            if ($PSCmdlet.ShouldProcess($target.FullName, "Remove item")) {
                try {
                    Remove-Item -LiteralPath $target.FullName -Recurse -Force -ErrorAction Stop
                    $removedCount++
                }
                catch {
                    $errors.Add(("{0}: {1}" -f $target.FullName, $_.Exception.Message))
                }
            }
        }

        [pscustomobject]@{
            RemovedCount = $removedCount
            Errors       = $errors
        }
    }

    function Invoke-CleanupTask {
        param(
            [Parameter(Mandatory = $true)][string]$TaskName,
            [Parameter(Mandatory = $true)][string]$PathPattern,
            [switch]$OnlyOlderThanDays,
            [int]$OlderThanDays = 0
        )

        $started = Get-Date
        Write-Info ("Starting: {0}" -f $TaskName)

        $before = if ($OnlyOlderThanDays.IsPresent) {
            Get-SizeBytesOlderThanDays -PathPattern $PathPattern -OlderThanDays $OlderThanDays
        }
        else {
            Get-SizeBytesFromPattern -PathPattern $PathPattern
        }

        $result = Remove-PathPatternContents -PathPattern $PathPattern -OnlyOlderThanDays:$OnlyOlderThanDays -OlderThanDays $OlderThanDays

        $after = if ($OnlyOlderThanDays.IsPresent) {
            Get-SizeBytesOlderThanDays -PathPattern $PathPattern -OlderThanDays $OlderThanDays
        }
        else {
            Get-SizeBytesFromPattern -PathPattern $PathPattern
        }

        $freed = [math]::Max(($before - $after), 0)
        $status = if ($result.Errors.Count -gt 0) { 'CompletedWithWarnings' } else { 'Completed' }

        if ($result.Errors.Count -gt 0) {
            Write-Warn ("{0}: {1} warning(s)." -f $TaskName, $result.Errors.Count)
        }
        else {
            Write-Info ("Completed: {0}" -f $TaskName)
        }

        [pscustomobject]@{
            TaskName         = $TaskName
            PathPattern      = $PathPattern
            OlderThanDays    = if ($OnlyOlderThanDays.IsPresent) { $OlderThanDays } else { 0 }
            RemovedCount     = $result.RemovedCount
            BeforeMB         = [math]::Round($before / 1MB, 2)
            AfterMB          = [math]::Round($after / 1MB, 2)
            FreedMB          = [math]::Round($freed / 1MB, 2)
            Status           = $status
            ErrorCount       = $result.Errors.Count
            ErrorSummary     = ($result.Errors -join ' || ')
            StartedAt        = $started
            FinishedAt       = Get-Date
        }
    }

    if (-not (Test-IsAdministrator)) {
        throw "Run this script from an elevated PowerShell session (Run as Administrator)."
    }

    $scriptStart = Get-Date
    $transcriptStarted = $false
    $auditRows = New-Object System.Collections.Generic.List[object]
    $wuService = $null
    $wuWasRunning = $false

    try {
        $transcriptResult = Start-Transcript -Path $TranscriptPath -Force
        if ($transcriptResult -and (Test-Path -Path $TranscriptPath -ErrorAction SilentlyContinue)) {
            $transcriptStarted = $true
        }

        Write-Info ("Cleanup started at: {0}" -f $scriptStart)
        Write-Info ("Transcript: {0}" -f $TranscriptPath)
        Write-Info ("Audit CSV: {0}" -f $AuditCsvPath)

        $beforeDisk = Get-LogicalDiskState -DriveLetter 'C:'
        if ($beforeDisk) {
            Write-Info ("Before cleanup free space on C:: {0} GB ({1}%)" -f $beforeDisk.FreeSpaceGB, $beforeDisk.PercentFree)
        }

        $wuService = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
        if ($wuService) {
            $wuWasRunning = ($wuService.Status -eq 'Running')
            if ($wuWasRunning -and $PSCmdlet.ShouldProcess('wuauserv', 'Stop service')) {
                Stop-Service -Name wuauserv -Force -ErrorAction Stop
                Write-Info "Stopped service: wuauserv"
            }
        }

        if ($IncludeSccmCacheShrink.IsPresent) {
            try {
                $cache = Get-CimInstance -Namespace root\ccm\SoftMgmtAgent -ClassName CacheConfig -ErrorAction Stop
                if ($cache -and $PSCmdlet.ShouldProcess('SCCM Cache', 'Set cache size to 1024 MB')) {
                    Invoke-CimMethod -InputObject $cache -MethodName SetSize -Arguments @{ Size = 1024 } -ErrorAction Stop | Out-Null
                    Restart-Service -Name ccmexec -ErrorAction SilentlyContinue
                    Write-Info "SCCM cache reduced to 1024 MB and ccmexec restarted."
                }
            }
            catch {
                Write-Warn ("SCCM cache step skipped: {0}" -f $_.Exception.Message)
            }
        }

        $taskDefinitions = @(
            @{ Name = 'Windows SoftwareDistribution'; Pattern = 'C:\Windows\SoftwareDistribution\*'; Older = $false; Days = 0 },
            @{ Name = 'Windows Temp'; Pattern = 'C:\Windows\Temp\*'; Older = $false; Days = 0 },
            @{ Name = 'All User Temp'; Pattern = 'C:\Users\*\AppData\Local\Temp\*'; Older = $false; Days = 0 },
            @{ Name = 'WER ProgramData'; Pattern = 'C:\ProgramData\Microsoft\Windows\WER\*'; Older = $false; Days = 0 },
            @{ Name = 'All User WER'; Pattern = 'C:\Users\*\AppData\Local\Microsoft\Windows\WER\*'; Older = $false; Days = 0 },
            @{ Name = 'Temporary Internet Files'; Pattern = 'C:\Users\*\AppData\Local\Microsoft\Windows\Temporary Internet Files\*'; Older = $false; Days = 0 },
            @{ Name = 'INetCache'; Pattern = 'C:\Users\*\AppData\Local\Microsoft\Windows\INetCache\*'; Older = $false; Days = 0 },
            @{ Name = 'INetCookies'; Pattern = 'C:\Users\*\AppData\Local\Microsoft\Windows\INetCookies\*'; Older = $false; Days = 0 },
            @{ Name = 'IECompatCache'; Pattern = 'C:\Users\*\AppData\Local\Microsoft\Windows\IECompatCache\*'; Older = $false; Days = 0 },
            @{ Name = 'IECompatUaCache'; Pattern = 'C:\Users\*\AppData\Local\Microsoft\Windows\IECompatUaCache\*'; Older = $false; Days = 0 },
            @{ Name = 'IEDownloadHistory'; Pattern = 'C:\Users\*\AppData\Local\Microsoft\Windows\IEDownloadHistory\*'; Older = $false; Days = 0 },
            @{ Name = 'Terminal Server Cache'; Pattern = 'C:\Users\*\AppData\Local\Microsoft\Terminal Server Client\Cache\*'; Older = $false; Days = 0 },
            @{ Name = 'Windows Minidump'; Pattern = "$env:windir\Minidump\*"; Older = $false; Days = 0 },
            @{ Name = 'Windows Memory Dump'; Pattern = "$env:windir\Memory.dmp"; Older = $false; Days = 0 },
            @{ Name = 'CBS Logs (age-based)'; Pattern = 'C:\Windows\Logs\CBS\*.log'; Older = $true; Days = $DaysToDelete },
            @{ Name = 'IIS Logs (age-based)'; Pattern = 'C:\inetpub\logs\LogFiles\*'; Older = $true; Days = $DaysToDelete }
        )

        foreach ($task in $taskDefinitions) {
            $row = Invoke-CleanupTask -TaskName $task.Name -PathPattern $task.Pattern -OnlyOlderThanDays:([bool]$task.Older) -OlderThanDays ([int]$task.Days)
            $auditRows.Add($row)
        }

        if ($PSCmdlet.ShouldProcess('Recycle Bin', 'Clear on C drive')) {
            try {
                Clear-RecycleBin -DriveLetter C -Force -ErrorAction Stop | Out-Null
                $auditRows.Add([pscustomobject]@{
                        TaskName      = 'Recycle Bin'
                        PathPattern   = 'C:\$Recycle.Bin'
                        OlderThanDays = 0
                        RemovedCount  = 0
                        BeforeMB      = 0
                        AfterMB       = 0
                        FreedMB       = 0
                        Status        = 'Completed'
                        ErrorCount    = 0
                        ErrorSummary  = ''
                        StartedAt     = Get-Date
                        FinishedAt    = Get-Date
                    })
                Write-Info "Recycle Bin cleared."
            }
            catch {
                Write-Warn ("Recycle Bin clear failed: {0}" -f $_.Exception.Message)
                $auditRows.Add([pscustomobject]@{
                        TaskName      = 'Recycle Bin'
                        PathPattern   = 'C:\$Recycle.Bin'
                        OlderThanDays = 0
                        RemovedCount  = 0
                        BeforeMB      = 0
                        AfterMB       = 0
                        FreedMB       = 0
                        Status        = 'Failed'
                        ErrorCount    = 1
                        ErrorSummary  = $_.Exception.Message
                        StartedAt     = Get-Date
                        FinishedAt    = Get-Date
                    })
            }
        }

        if ($IncludeCleanMgr.IsPresent -and $PSCmdlet.ShouldProcess('Disk Cleanup', 'Run cleanmgr /sagerun:1')) {
            try {
                Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\*' -Name StateFlags0001 -ErrorAction SilentlyContinue |
                    Remove-ItemProperty -Name StateFlags0001 -ErrorAction SilentlyContinue
                New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Update Cleanup' -Name StateFlags0001 -Value 2 -PropertyType DWord -Force | Out-Null
                New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Temporary Files' -Name StateFlags0001 -Value 2 -PropertyType DWord -Force | Out-Null
                Start-Process -FilePath 'cleanmgr.exe' -ArgumentList '/sagerun:1' -Wait -ErrorAction Stop
                Write-Info "cleanmgr completed."
            }
            catch {
                Write-Warn ("cleanmgr step failed: {0}" -f $_.Exception.Message)
            }
        }

        $afterDisk = Get-LogicalDiskState -DriveLetter 'C:'
        if ($afterDisk) {
            Write-Info ("After cleanup free space on C:: {0} GB ({1}%)" -f $afterDisk.FreeSpaceGB, $afterDisk.PercentFree)
            if ($beforeDisk) {
                $gain = [math]::Round(($afterDisk.FreeSpaceGB - $beforeDisk.FreeSpaceGB), 2)
                Write-Info ("Net free-space change: {0} GB" -f $gain)
            }
        }
    }
    finally {
        if ($wuService -and $wuWasRunning) {
            try {
                if ($PSCmdlet.ShouldProcess('wuauserv', 'Start service')) {
                    Start-Service -Name wuauserv -ErrorAction Stop
                    Write-Info "Restored service: wuauserv"
                }
            }
            catch {
                Write-Warn ("Failed to restore wuauserv: {0}" -f $_.Exception.Message)
            }
        }

        if ($auditRows.Count -gt 0) {
            $auditRows | Export-Csv -Path $AuditCsvPath -NoTypeInformation -Encoding UTF8 -Force
            Write-Info ("Audit CSV written: {0}" -f $AuditCsvPath)
        }

        if ($transcriptStarted) {
            Stop-Transcript | Out-Null
        }
    }

    $scriptEnd = Get-Date
    $elapsedSeconds = [math]::Round(($scriptEnd - $scriptStart).TotalSeconds, 2)
    Write-Info ("Cleanup finished at: {0}" -f $scriptEnd)
    Write-Info ("Elapsed seconds: {0}" -f $elapsedSeconds)
}

$invokeParams = @{
    DaysToDelete          = $DaysToDelete
    TranscriptPath        = $TranscriptPath
    AuditCsvPath          = $AuditCsvPath
    IncludeCleanMgr       = $IncludeCleanMgr
    IncludeSccmCacheShrink = $IncludeSccmCacheShrink
}

if ($PSBoundParameters.ContainsKey('WhatIf')) {
    $invokeParams['WhatIf'] = $PSBoundParameters['WhatIf']
}
if ($PSBoundParameters.ContainsKey('Confirm')) {
    $invokeParams['Confirm'] = $PSBoundParameters['Confirm']
}

Start-CleanupV2 @invokeParams
}

