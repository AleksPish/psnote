function Get-VSphereMountedIso {
# Name: find-mounted-ISO-vsphere
# Tags: powercli
# Saved: 2026-03-03T11:13:41.9614418+00:00
<#
.SYNOPSIS
Lists VMs with connected ISO media in a vSphere environment.

.DESCRIPTION
Connects to a vCenter Server, inspects VM CD/DVD devices, and returns mounted
ISO information filtered by an optional wildcard pattern.

.PARAMETER VIServer
vCenter Server name to query.

.PARAMETER IsoPattern
Wildcard pattern applied to ISO path values.

.PARAMETER Credential
Optional credential for Connect-VIServer.

.PARAMETER InvalidCertificateAction
PowerCLI certificate handling for this session.

.PARAMETER PassThru
Returns matching objects in addition to formatted table output.

.EXAMPLE
Get-VSphereMountedIso -VIServer vc01.contoso.com

.EXAMPLE
Get-VSphereMountedIso -VIServer vc01.contoso.com -IsoPattern '*windows*' -PassThru

.OUTPUTS
PSCustomObject
#>
[OutputType([PSCustomObject])]
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$VIServer,

    [Parameter(Mandatory = $false)]
    [string]$IsoPattern = "*",

    [Parameter(Mandatory = $false)]
    [pscredential]$Credential,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Prompt", "Ignore", "Warn", "Fail")]
    [string]$InvalidCertificateAction = "Prompt",

    [Parameter(Mandatory = $false)]
    [switch]$PassThru
)

if (-not (Get-Module -ListAvailable -Name VMware.VimAutomation.Core)) {
    throw "VMware PowerCLI core module is not installed. Install-Module VMware.PowerCLI -Scope CurrentUser"
}

try {
    # Import only the required PowerCLI module to avoid meta-module import issues in some environments.
    Import-Module VMware.VimAutomation.Core -ErrorAction Stop
}
catch {
    throw ("Failed to import VMware.VimAutomation.Core. Try restarting PowerShell and re-running. Error: {0}" -f $_.Exception.Message)
}

# Suppress CEIP prompt in this session only.
Set-PowerCLIConfiguration -ParticipateInCEIP $false -Scope Session -Confirm:$false | Out-Null

# Limit certificate behavior change to the current PowerShell session.
Set-PowerCLIConfiguration -InvalidCertificateAction $InvalidCertificateAction -Scope Session -Confirm:$false | Out-Null

$connectedHere = $false

try {
    $existingConnection = Get-VIServer -Server $VIServer -ErrorAction SilentlyContinue
    if (-not $existingConnection) {
        if ($Credential) {
            Connect-VIServer -Server $VIServer -Credential $Credential -ErrorAction Stop | Out-Null
        }
        else {
            Connect-VIServer -Server $VIServer -ErrorAction Stop | Out-Null
        }
        $connectedHere = $true
    }

    $results = Get-VM -Server $VIServer | Get-CDDrive |
        Where-Object { $_.ConnectionState.Connected -and $_.IsoPath -and $_.IsoPath -like $IsoPattern } |
        Select-Object `
            @{Name = "VIServer"; Expression = { $VIServer } }, `
            @{Name = "VM"; Expression = { $_.Parent.Name } }, `
            @{Name = "CDDrive"; Expression = { $_.Name } }, `
            @{Name = "IsoPath"; Expression = { $_.IsoPath } }, `
            @{Name = "Connected"; Expression = { $_.ConnectionState.Connected } }, `
            @{Name = "StartConnected"; Expression = { $_.StartConnected } }

    if (-not $results) {
        Write-Host ("No mounted ISOs matched pattern '{0}' on '{1}'." -f $IsoPattern, $VIServer) -ForegroundColor Yellow
    }
    else {
        $results | Format-Table -AutoSize
    }

    if ($PassThru) {
        $results
    }
}
finally {
    if ($connectedHere) {
        Disconnect-VIServer -Server $VIServer -Confirm:$false | Out-Null
    }
}
}

# When run directly as a script, execute the function.
# When dot-sourced/imported, only define the function.
if ($MyInvocation.InvocationName -ne ".") {
    Get-VSphereMountedIso
}
