$scriptFiles = Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.ps1 -File
foreach ($scriptFile in $scriptFiles) {
    . $scriptFile.FullName
}

Export-ModuleMember -Function *
