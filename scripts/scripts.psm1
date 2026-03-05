$scriptFiles = Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.ps1 -File
foreach ($scriptFile in $scriptFiles) {
    . $scriptFile.FullName
}

$publicFunctions = @(
    'Invoke-BackupEsxi',
    'Invoke-CDriveCleanup',
    'Find-CertificateLocator',
    'Set-DnsClientServerAddressesBulk',
    'Get-TlsVersionStatus',
    'Export-PfxCertificateMaterial',
    'Get-VSphereMountedIso',
    'Get-FreeSpace',
    'Get-GeneratedList',
    'Get-ListeningProcessesReport',
    'Get-SqlOdbcDriverLocationStatus',
    'Get-ServiceAccountsReport',
    'Get-TerminalServerSslCertificate',
    'Get-InstalledUpdatesReport',
    'Search-GpoText',
    'Invoke-IpScanner',
    'New-IsoFile',
    'Invoke-ParallelPortTest',
    'Remove-Certificate',
    'Remove-IdenticalFolders',
    'Reset-SshKeyPermissions',
    'Set-RdsCertificates',
    'Get-VSphereResourceUsage'
)

Export-ModuleMember -Function $publicFunctions
