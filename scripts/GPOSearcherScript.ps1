# Name: GPOSearcherScript
# Tags: windows,activedirectory
# Saved: 2026-03-03T12:29:30.4335967+00:00
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SearchText,

    [Parameter(Mandatory = $false)]
    [string]$DomainName = $env:USERDNSDOMAIN,

    [Parameter(Mandatory = $false)]
    [switch]$UseRegex,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 50)]
    [int]$MaxMatchesPerGpo = 3,

    [Parameter(Mandatory = $false)]
    [ValidateRange(40, 1000)]
    [int]$MaxLineLength = 180,

    [Parameter(Mandatory = $false)]
    [ValidateSet("GpoOnly", "WithText")]
    [string]$DisplayMode,

    [Parameter(Mandatory = $false)]
    [switch]$PassThru
)

if (-not $SearchText) {
    $SearchText = Read-Host -Prompt "What string do you want to search for?"
}

if (-not $SearchText -or [string]::IsNullOrWhiteSpace($SearchText)) {
    throw "Search text cannot be empty."
}

if (-not $DisplayMode) {
    $displayChoice = Read-Host -Prompt "Display mode: type '1' for matching GPOs only, or '2' for matching GPOs with matched text"
    switch ($displayChoice) {
        "1" { $DisplayMode = "GpoOnly" }
        "2" { $DisplayMode = "WithText" }
        default { $DisplayMode = "GpoOnly" }
    }
}

if (-not $DomainName -or [string]::IsNullOrWhiteSpace($DomainName)) {
    throw "Domain name is empty. Pass -DomainName explicitly."
}

if (-not (Get-Module -ListAvailable -Name GroupPolicy)) {
    throw "GroupPolicy module is not available on this system."
}

Import-Module GroupPolicy -ErrorAction Stop

function Test-TextMatch {
    param(
        [string]$InputText,
        [string]$SearchText,
        [bool]$UseRegex
    )

    if ([string]::IsNullOrWhiteSpace($InputText)) {
        return $false
    }

    if ($UseRegex) {
        return ($InputText -match $SearchText)
    }

    return ($InputText.IndexOf($SearchText, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Get-XmlNodePath {
    param([System.Xml.XmlNode]$Node)

    if ($null -eq $Node) { return "" }

    $parts = @()
    $current = $Node
    while ($null -ne $current -and $current.NodeType -ne [System.Xml.XmlNodeType]::Document) {
        $parts += $current.Name
        $current = $current.ParentNode
    }

    [array]::Reverse($parts)
    return "/" + ($parts -join "/")
}

Write-Host ("Finding all GPOs in domain: {0}" -f $DomainName) -ForegroundColor Cyan

try {
    $allGposInDomain = @(Get-GPO -All -Domain $DomainName -ErrorAction Stop)
}
catch {
    throw ("Failed to enumerate GPOs in '{0}': {1}" -f $DomainName, $_.Exception.Message)
}

Write-Host ("Starting search across {0} GPO(s)..." -f $allGposInDomain.Count) -ForegroundColor Cyan

$results = @()
$errors = @()

foreach ($gpo in $allGposInDomain) {
    try {
        $report = Get-GPOReport -Guid $gpo.Id -ReportType Xml -Domain $DomainName -ErrorAction Stop
        $xml = [xml]$report
        $textNodes = $xml.SelectNodes("//*[text()]")

        $addedCount = 0
        foreach ($node in $textNodes) {
            $textValue = [string]$node.InnerText
            if (-not (Test-TextMatch -InputText $textValue -SearchText $SearchText -UseRegex $UseRegex)) {
                continue
            }

            $preview = $textValue.Trim()
            if ($preview.Length -gt $MaxLineLength) {
                $preview = $preview.Substring(0, $MaxLineLength) + "..."
            }

            $results += [pscustomobject]@{
                Domain = $DomainName
                GpoDisplayName = $gpo.DisplayName
                GpoId = $gpo.Id
                SearchText = $SearchText
                MatchType = if ($UseRegex) { "Regex" } else { "Literal" }
                MatchPath = Get-XmlNodePath -Node $node
                MatchPreview = $preview
                MatchText = $textValue
            }

            $addedCount++
            if ($addedCount -ge $MaxMatchesPerGpo) {
                break
            }
        }

        if ($addedCount -gt 0) {
            Write-Verbose ("Match found in: {0}" -f $gpo.DisplayName)
        }
        else {
            Write-Verbose ("No match in: {0}" -f $gpo.DisplayName)
        }
    }
    catch {
        $errors += [pscustomobject]@{
            Domain = $DomainName
            GpoDisplayName = $gpo.DisplayName
            GpoId = $gpo.Id
            Error = $_.Exception.Message
        }
    }
}

Write-Host ""
Write-Host "Matches" -ForegroundColor Yellow
if ($results.Count -eq 0) {
    Write-Host "No GPO matches found." -ForegroundColor Yellow
}
else {
    if ($DisplayMode -eq "GpoOnly") {
        $results |
            Sort-Object GpoDisplayName |
            Select-Object GpoDisplayName, GpoId -Unique |
            Format-Table -AutoSize
    }
    else {
        $results |
            Select-Object GpoDisplayName, GpoId, MatchPath, MatchPreview |
            Sort-Object GpoDisplayName, MatchPath |
            Format-Table -AutoSize
    }

    $uniqueGpoCount = ($results | Select-Object -ExpandProperty GpoId -Unique).Count
    Write-Host ("Total matching GPOs: {0}" -f $uniqueGpoCount) -ForegroundColor Green
    Write-Host ("Total match lines shown: {0}" -f $results.Count) -ForegroundColor Green

    if ($DisplayMode -eq "WithText") {
        Write-Host ""
        Write-Host "Detailed Match Text" -ForegroundColor Yellow
        foreach ($match in ($results | Sort-Object GpoDisplayName, MatchPath)) {
            Write-Host ("[{0}] {1}" -f $match.GpoDisplayName, $match.MatchPath) -ForegroundColor Cyan
            Write-Host $match.MatchText
            Write-Host ""
        }
    }
}

if ($errors.Count -gt 0) {
    Write-Host ""
    Write-Host "GPOs with errors" -ForegroundColor Red
    $errors | Select-Object GpoDisplayName, Error | Format-Table -AutoSize
    Write-Host ("Total errors: {0}" -f $errors.Count) -ForegroundColor Red
}

if ($PassThru) {
    [pscustomobject]@{
        Matches = $results
        Errors = $errors
    }
}

