function Get-TerminalServerSslCertificate {
# Name: get-terminalserver-ssl-cert
# Tags: remotedesktop
# Saved: 2026-03-03T09:38:05.9797951+00:00
<#
.SYNOPSIS
Gets the RDP listener SSL certificate thumbprint from terminal servers.

.DESCRIPTION
Queries Win32_TSGeneralSetting (RDP-tcp listener) and returns the configured
SSLCertificateSHA1Hash value for each target computer.

.PARAMETER ComputerName
One or more target computer names. Defaults to local computer.

.PARAMETER PassThru
Returns result objects.

.EXAMPLE
Get-TerminalServerSslCertificate -ComputerName RDS01,RDS02

.OUTPUTS
PSCustomObject
#>
[OutputType([PSCustomObject])]
[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
    [Alias('Server', 'Name')]
    [string[]]$ComputerName = @($env:COMPUTERNAME),

    [Parameter()]
    [switch]$PassThru
)

$results = foreach ($computer in $ComputerName) {
    try {
        $setting = Get-WmiObject -Class 'Win32_TSGeneralSetting' `
            -Namespace 'root\cimv2\terminalservices' `
            -ComputerName $computer `
            -Filter "TerminalName='RDP-tcp'" `
            -ErrorAction Stop

        [pscustomobject]@{
            ComputerName              = $computer
            SSLCertificateSHA1Hash    = $setting.SSLCertificateSHA1Hash
        }
    }
    catch {
        [pscustomobject]@{
            ComputerName              = $computer
            SSLCertificateSHA1Hash    = $null
            Error                     = $_.Exception.Message
        }
    }
}

$results | Format-Table -AutoSize

if ($PassThru) {
    $results
}
}
