function Find-CertificateLocator {
# Name: cert-locator
# Tags: certs
# Saved: 2026-03-02T18:45:14.9905172+00:00
<#
.SYNOPSIS
Finds certificates by subject text across one or more Windows servers.

.DESCRIPTION
Queries Cert:\LocalMachine\My remotely and matches certificate Subject values.
Targets can be provided directly, from a text file, or discovered from Active
Directory enabled server objects.

.PARAMETER CertificateName
Text fragment to match in certificate Subject.

.PARAMETER Servers
Target servers to query.

.PARAMETER ServerListPath
Path to a text file containing one server name per line.

.PARAMETER UseActiveDirectory
When no explicit server list is supplied, query AD for enabled servers.

.PARAMETER OutputPath
CSV output path for matching certificates.

.PARAMETER PassThru
Returns match objects in addition to CSV export.

.EXAMPLE
Find-CertificateLocator -CertificateName 'domain.co.uk' -Servers SRV01,SRV02

.EXAMPLE
Find-CertificateLocator -CertificateName 'api.contoso.com' -ServerListPath C:\Temp\servers.txt -OutputPath C:\Temp\results.csv -PassThru

.OUTPUTS
PSCustomObject
#>
[OutputType([PSCustomObject])]
[CmdletBinding()]
param(
    [Parameter()]
    [string]$CertificateName,

    [Parameter(ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
    [Alias('ComputerName', 'Name')]
    [string[]]$Servers,

    [Parameter()]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ServerListPath,

    [Parameter()]
    [switch]$UseActiveDirectory,

    [Parameter()]
    [string]$OutputPath = 'C:\temp\results.csv',

    [Parameter()]
    [switch]$PassThru
)

begin {
    $ErrorActionPreference = 'Stop'
    $targetList = New-Object System.Collections.Generic.List[string]
}

process {
    foreach ($server in $Servers) {
        if (-not [string]::IsNullOrWhiteSpace($server)) {
            $targetList.Add($server.Trim())
        }
    }
}

end {
    if (-not $CertificateName) {
        $CertificateName = Read-Host "Enter in the certificate name you need to find (e.g. domain.co.uk)"
    }

    if ([string]::IsNullOrWhiteSpace($CertificateName)) {
        throw 'CertificateName cannot be empty.'
    }

    if ($ServerListPath) {
        Get-Content -LiteralPath $ServerListPath -ErrorAction Stop |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $targetList.Add($_.Trim()) }
    }

    if ($UseActiveDirectory -or $targetList.Count -eq 0) {
        if (-not (Get-Command Get-ADComputer -ErrorAction SilentlyContinue)) {
            throw 'Get-ADComputer not found. Install/import ActiveDirectory module or provide -Servers.'
        }

        $adServers = Get-ADComputer -Filter 'operatingsystem -like "*server*" -and enabled -eq "true"' |
            Select-Object -ExpandProperty Name

        foreach ($server in $adServers) {
            if (-not [string]::IsNullOrWhiteSpace($server)) {
                $targetList.Add($server.Trim())
            }
        }
    }

    $serversToQuery = $targetList.ToArray() | Sort-Object -Unique
    if (-not $serversToQuery -or $serversToQuery.Count -eq 0) {
        throw 'No servers were found to query.'
    }

    $outputDir = Split-Path -Path $OutputPath -Parent
    if ($outputDir -and -not (Test-Path -LiteralPath $outputDir)) {
        New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
    }

    $results = foreach ($server in $serversToQuery) {
        Write-Host ("Processing {0}" -f $server) -ForegroundColor Yellow
        try {
            $certs = Invoke-Command -ComputerName $server -ScriptBlock { Get-ChildItem -Path Cert:\LocalMachine\My }
        }
        catch {
            Write-Warning ("Failed to query '{0}': {1}" -f $server, $_.Exception.Message)
            continue
        }

        foreach ($cert in $certs) {
            if ($cert.Subject -notlike "*$CertificateName*") {
                continue
            }

            [pscustomobject]@{
                Subject      = $cert.Subject
                PSComputerName = $server
                Issuer       = $cert.Issuer
                NotAfter     = $cert.NotAfter
                Thumbprint   = $cert.Thumbprint
            }
        }
    }

    if ($results) {
        $results | Export-Csv -Path $OutputPath -Append -NoTypeInformation
        $results | Format-Table -AutoSize
    }
    else {
        Write-Host "No matching certificates were found." -ForegroundColor Yellow
    }

    if ($PassThru) {
        $results
    }
}
}

# When run directly as a script, execute the function.
# When dot-sourced/imported, only define the function.
if ($MyInvocation.InvocationName -ne ".") {
    Find-CertificateLocator
}
