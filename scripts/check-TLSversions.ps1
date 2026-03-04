function Get-TlsVersionStatus {
# Name: check-TLSversions
# Tags: windows
# Saved: 2026-03-03T10:57:20.8159408+00:00
<#
.SYNOPSIS
Reports TLS/SSL protocol enablement status on one or more Windows computers.

.DESCRIPTION
Evaluates SCHANNEL protocol registry configuration for client and server roles.
When explicit values are missing, status is inferred from OS build defaults.

.PARAMETER ComputerName
Target computer names. Defaults to the local computer.

.PARAMETER IncludeDeprecatedProtocols
Includes SSL 2.0 and SSL 3.0 in the report.

.PARAMETER ShowOnlyEnabled
Shows only rows where client or server protocol state is enabled.

.PARAMETER PassThru
Returns result objects in addition to formatted table output.

.EXAMPLE
Get-TlsVersionStatus -ComputerName SRV01,SRV02

.EXAMPLE
Get-TlsVersionStatus -ComputerName SRV01 -IncludeDeprecatedProtocols -ShowOnlyEnabled

.OUTPUTS
PSCustomObject
#>
[OutputType([PSCustomObject])]
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$ComputerName = @($env:COMPUTERNAME),

    [Parameter(Mandatory = $false)]
    [switch]$IncludeDeprecatedProtocols,

    [Parameter(Mandatory = $false)]
    [switch]$ShowOnlyEnabled,

    [Parameter(Mandatory = $false)]
    [switch]$PassThru
)

if ($IncludeDeprecatedProtocols) {
    $protocolsToCheck = @("SSL 2.0", "SSL 3.0", "TLS 1.0", "TLS 1.1", "TLS 1.2", "TLS 1.3")
}
else {
    $protocolsToCheck = @("TLS 1.0", "TLS 1.1", "TLS 1.2", "TLS 1.3")
}

$scriptBlock = {
    param([string[]]$ProtocolNames)

    function Get-ItemPropertySafe {
        param([string]$Path)
        try {
            if (Test-Path -Path $Path) {
                return Get-ItemProperty -Path $Path -ErrorAction Stop
            }
        }
        catch {
            return $null
        }
        return $null
    }

    function Get-OsInfoSafe {
        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            if ($null -ne $os) {
                return New-Object psobject -Property @{
                    Caption = [string]$os.Caption
                    Version = [string]$os.Version
                    BuildNumber = [int]$os.BuildNumber
                }
            }
        }
        catch {}

        try {
            $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop
            if ($null -ne $os) {
                return New-Object psobject -Property @{
                    Caption = [string]$os.Caption
                    Version = [string]$os.Version
                    BuildNumber = [int]$os.BuildNumber
                }
            }
        }
        catch {}

        return New-Object psobject -Property @{
            Caption = "Unknown OS"
            Version = "0.0"
            BuildNumber = 0
        }
    }

    function Get-DefaultProtocolState {
        param(
            [string]$Protocol,
            [int]$BuildNumber
        )

        # Defaults based on common Windows baselines:
        # - Windows Server 2022 / Windows 11 and later: TLS 1.0/1.1 disabled, TLS 1.2/1.3 enabled
        # - Older supported Windows versions: TLS 1.0/1.1/1.2 enabled, TLS 1.3 disabled
        if ($BuildNumber -ge 20348) {
            switch ($Protocol) {
                "SSL 2.0" { return $false }
                "SSL 3.0" { return $false }
                "TLS 1.0" { return $false }
                "TLS 1.1" { return $false }
                "TLS 1.2" { return $true }
                "TLS 1.3" { return $true }
                default { return $false }
            }
        }
        else {
            switch ($Protocol) {
                "SSL 2.0" { return $false }
                "SSL 3.0" { return $false }
                "TLS 1.0" { return $true }
                "TLS 1.1" { return $true }
                "TLS 1.2" { return $true }
                "TLS 1.3" { return $false }
                default { return $false }
            }
        }
    }

    function Get-ProtocolRoleState {
        param(
            [string]$Path,
            [string]$Protocol,
            [int]$BuildNumber
        )

        $item = Get-ItemPropertySafe -Path $Path
        $enabledValue = $null
        $disabledByDefaultValue = $null
        $source = "Default"
        $details = "Using OS default"
        $isEnabled = $null

        if ($null -ne $item) {
            $source = "Configured"
            if ($null -ne $item.PSObject.Properties["Enabled"]) {
                $enabledValue = [int]$item.Enabled
            }
            if ($null -ne $item.PSObject.Properties["DisabledByDefault"]) {
                $disabledByDefaultValue = [int]$item.DisabledByDefault
            }
        }

        if ($null -ne $enabledValue) {
            $isEnabled = ($enabledValue -eq 1)
            $details = "Enabled=$enabledValue"
        }
        elseif ($null -ne $disabledByDefaultValue) {
            $isEnabled = ($disabledByDefaultValue -ne 1)
            $details = "DisabledByDefault=$disabledByDefaultValue"
        }

        if ($null -eq $isEnabled) {
            $isEnabled = Get-DefaultProtocolState -Protocol $Protocol -BuildNumber $BuildNumber
            $details = "No explicit registry override; inferred from OS build $BuildNumber"
        }

        if ($isEnabled) {
            $status = "Enabled"
        }
        else {
            $status = "Disabled"
        }

        New-Object psobject -Property @{
            Status = $status
            IsEnabled = $isEnabled
            Source = $source
            Details = $details
        }
    }

    $osInfo = Get-OsInfoSafe
    $osCaption = $osInfo.Caption
    $buildNumber = $osInfo.BuildNumber
    $rows = @()
    foreach ($protocol in $ProtocolNames) {
        $base = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$protocol"
        $clientPath = "$base\Client"
        $serverPath = "$base\Server"

        $client = Get-ProtocolRoleState -Path $clientPath -Protocol $protocol -BuildNumber $buildNumber
        $server = Get-ProtocolRoleState -Path $serverPath -Protocol $protocol -BuildNumber $buildNumber

        $rows += (New-Object psobject -Property @{
            ComputerName = $env:COMPUTERNAME
            OS = $osCaption
            Protocol = $protocol
            Client = $client.Status
            Server = $server.Status
            ClientSource = $client.Source
            ServerSource = $server.Source
            ClientDetails = $client.Details
            ServerDetails = $server.Details
        })
    }

    $rows
}

$results = @()
foreach ($computer in $ComputerName) {
    $isLocal = ($computer -eq ".") -or ($computer -eq "localhost") -or ($computer -eq $env:COMPUTERNAME)

    if ($isLocal) {
        $results += (& $scriptBlock -ProtocolNames $protocolsToCheck)
        continue
    }

    try {
        $results += Invoke-Command -ComputerName $computer -ScriptBlock $scriptBlock -ArgumentList (,$protocolsToCheck) -ErrorAction Stop
    }
    catch {
        $results += (New-Object psobject -Property @{
            ComputerName = $computer
            OS = "Unknown OS"
            Protocol = "N/A"
            Client = "Error"
            Server = "Error"
            ClientSource = "Error"
            ServerSource = "Error"
            ClientDetails = $_.Exception.Message
            ServerDetails = $_.Exception.Message
        })
    }
}

if ($ShowOnlyEnabled) {
    $displayRows = $results | Where-Object {
        $_.Protocol -eq "N/A" -or $_.Client -eq "Enabled" -or $_.Server -eq "Enabled"
    }
}
else {
    $displayRows = $results
}

$tableColumns = @("ComputerName", "Protocol", "Client", "Server")
$displayRows | Sort-Object ComputerName, Protocol | Format-Table -Property $tableColumns -AutoSize

if ($PassThru) {
    $displayRows
}
}

