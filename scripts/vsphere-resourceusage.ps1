# Name: vsphere-resourceusage
# Tags: powercli,vmware
# Saved: 2026-03-03T19:34:22.9966380+00:00
[CmdletBinding()]
param(
  [Parameter()]
  [ValidateNotNullOrEmpty()]
  [string]$VCenter,

  [Parameter()]
  [string]$ClusterName,

  [Parameter()]
  [PSCredential]$Credential,

  [Parameter()]
  [switch]$PassThru,

  [Parameter()]
  [string]$SummaryCsvPath,

  [Parameter()]
  [string]$HostCsvPath,

  [Parameter()]
  [ValidateRange(0, 65535)]
  [int]$PlannedVmCpu = 0,

  [Parameter()]
  [ValidateRange(0, 1048576)]
  [double]$PlannedVmMemoryGB = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-NonEmptyInput {
  param(
    [Parameter(Mandatory=$true)]
    [string]$Prompt
  )

  while ($true) {
    $value = Read-Host -Prompt $Prompt
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      return $value.Trim()
    }
    Write-Warning 'Input is required.'
  }
}

function Get-NPlusOneReportForScope {
  param(
    [Parameter(Mandatory=$true)]
    [string]$ScopeName,

    [Parameter(Mandatory=$true)]
    [string]$ScopeType,

    [Parameter(Mandatory=$true)]
    [string]$VCenterName,

    [Parameter(Mandatory=$true)]
    [object[]]$Hosts,

    [Parameter(Mandatory=$true)]
    [object[]]$VMs,

    [Parameter(Mandatory=$true)]
    [int]$PlannedCpu,

    [Parameter(Mandatory=$true)]
    [double]$PlannedMemoryGB
  )

  if (-not $Hosts -or @($Hosts).Count -eq 0) {
    throw "No ESXi hosts were found in scope '$ScopeName'."
  }

  $hosts = @($Hosts) | Sort-Object -Property Name
  $vms = @($VMs)
  $poweredOnVms = $vms | Where-Object { $_.PowerState -eq 'PoweredOn' }

  $hostCount = @($hosts).Count
  $clusterCpuCores = [int](($hosts | Measure-Object -Property NumCpu -Sum).Sum)
  $clusterMemoryGB = [double](($hosts | Measure-Object -Property MemoryTotalGB -Sum).Sum)
  $largestHostByCpu = $hosts | Sort-Object -Property NumCpu -Descending | Select-Object -First 1
  $largestHostByMemory = $hosts | Sort-Object -Property MemoryTotalGB -Descending | Select-Object -First 1

  if ($hostCount -ge 2) {
    $nPlusOneCpuCapacity = $clusterCpuCores - [int]$largestHostByCpu.NumCpu
    $nPlusOneMemoryCapacityGB = $clusterMemoryGB - [double]$largestHostByMemory.MemoryTotalGB
  }
  else {
    $nPlusOneCpuCapacity = 0
    $nPlusOneMemoryCapacityGB = 0.0
  }

  $configuredVcpuAll = [int](($vms | Measure-Object -Property NumCpu -Sum).Sum)
  $configuredVcpuPoweredOn = [int](($poweredOnVms | Measure-Object -Property NumCpu -Sum).Sum)
  $configuredVramAllGB = [double](($vms | Measure-Object -Property MemoryGB -Sum).Sum)
  $configuredVramPoweredOnGB = [double](($poweredOnVms | Measure-Object -Property MemoryGB -Sum).Sum)

  $cpuHeadroomCores = $nPlusOneCpuCapacity - $configuredVcpuPoweredOn
  $memoryHeadroomGB = $nPlusOneMemoryCapacityGB - $configuredVramPoweredOnGB
  $projectedConfiguredVcpuPoweredOn = $configuredVcpuPoweredOn + $PlannedCpu
  $projectedConfiguredVramPoweredOnGB = $configuredVramPoweredOnGB + $PlannedMemoryGB
  $projectedCpuHeadroomCores = $nPlusOneCpuCapacity - $projectedConfiguredVcpuPoweredOn
  $projectedMemoryHeadroomGB = $nPlusOneMemoryCapacityGB - $projectedConfiguredVramPoweredOnGB

  $summary = [PSCustomObject]@{
    VCenter                                  = $VCenterName
    ScopeType                                = $ScopeType
    ClusterName                              = $ScopeName
    HostCount                                = $hostCount
    ClusterTotalCpuCores                     = $clusterCpuCores
    ClusterTotalMemoryGB                     = [math]::Round($clusterMemoryGB, 2)
    LargestHostNameByCpu                     = $largestHostByCpu.Name
    LargestHostCpuCores                      = [int]$largestHostByCpu.NumCpu
    LargestHostNameByMemory                  = $largestHostByMemory.Name
    LargestHostMemoryGB                      = [math]::Round([double]$largestHostByMemory.MemoryTotalGB, 2)
    NPlusOneCpuCapacityCores                 = $nPlusOneCpuCapacity
    NPlusOneMemoryCapacityGB                 = [math]::Round($nPlusOneMemoryCapacityGB, 2)
    PoweredOnVmCount                         = @($poweredOnVms).Count
    TotalVmCount                             = @($vms).Count
    ConfiguredVcpuPoweredOn                  = $configuredVcpuPoweredOn
    ConfiguredVcpuAll                        = $configuredVcpuAll
    ConfiguredVramPoweredOnGB                = [math]::Round($configuredVramPoweredOnGB, 2)
    ConfiguredVramAllGB                      = [math]::Round($configuredVramAllGB, 2)
    NPlusOneCpuHeadroomCores                 = $cpuHeadroomCores
    NPlusOneMemoryHeadroomGB                 = [math]::Round($memoryHeadroomGB, 2)
    NPlusOneCpuCompliantForPoweredOnWorkload = ($hostCount -ge 2 -and $cpuHeadroomCores -ge 0)
    NPlusOneMemoryCompliantForPoweredOnWorkload = ($hostCount -ge 2 -and $memoryHeadroomGB -ge 0)
    PlannedVmCpu                             = $PlannedCpu
    PlannedVmMemoryGB                        = [math]::Round($PlannedMemoryGB, 2)
    ProjectedConfiguredVcpuPoweredOn         = $projectedConfiguredVcpuPoweredOn
    ProjectedConfiguredVramPoweredOnGB       = [math]::Round($projectedConfiguredVramPoweredOnGB, 2)
    ProjectedNPlusOneCpuHeadroomCores        = $projectedCpuHeadroomCores
    ProjectedNPlusOneMemoryHeadroomGB        = [math]::Round($projectedMemoryHeadroomGB, 2)
    ProjectedNPlusOneCpuCompliant            = ($hostCount -ge 2 -and $projectedCpuHeadroomCores -ge 0)
    ProjectedNPlusOneMemoryCompliant         = ($hostCount -ge 2 -and $projectedMemoryHeadroomGB -ge 0)
    NPlusOneEvaluated                        = ($hostCount -ge 2)
    Notes                                    = if ($hostCount -lt 2) { 'N+1 requires at least 2 hosts.' } else { $null }
  }

  $hostDetails = foreach ($esxiHost in $hosts) {
    $hostVms = $vms | Where-Object { $_.VMHost -and $_.VMHost.Name -eq $esxiHost.Name }
    $hostPoweredOnVms = $hostVms | Where-Object { $_.PowerState -eq 'PoweredOn' }
    [PSCustomObject]@{
      VCenter                   = $VCenterName
      ScopeType                 = $ScopeType
      ClusterName               = $ScopeName
      HostName                  = $esxiHost.Name
      CpuCores                  = [int]$esxiHost.NumCpu
      MemoryGB                  = [math]::Round([double]$esxiHost.MemoryTotalGB, 2)
      TotalVmCount              = @($hostVms).Count
      PoweredOnVmCount          = @($hostPoweredOnVms).Count
      ConfiguredVcpuPoweredOn   = [int](($hostPoweredOnVms | Measure-Object -Property NumCpu -Sum).Sum)
      ConfiguredVcpuAll         = [int](($hostVms | Measure-Object -Property NumCpu -Sum).Sum)
      ConfiguredVramPoweredOnGB = [math]::Round([double](($hostPoweredOnVms | Measure-Object -Property MemoryGB -Sum).Sum), 2)
      ConfiguredVramAllGB       = [math]::Round([double](($hostVms | Measure-Object -Property MemoryGB -Sum).Sum), 2)
    }
  }

  [PSCustomObject]@{
    Summary     = $summary
    HostDetails = $hostDetails
  }
}

if (-not (Get-Command Connect-VIServer -ErrorAction SilentlyContinue)) {
  throw 'PowerCLI command Connect-VIServer was not found. Install/import VMware PowerCLI before running this script.'
}

if (-not $VCenter) {
  $VCenter = Read-NonEmptyInput -Prompt 'Enter vCenter Server (FQDN or hostname)'
}

$connection = $null
try {
  if ($Credential) {
    $connection = Connect-VIServer -Server $VCenter -Credential $Credential -WarningAction SilentlyContinue -ErrorAction Stop
  }
  else {
    $connection = Connect-VIServer -Server $VCenter -WarningAction SilentlyContinue -ErrorAction Stop
  }

  $allClusters = @(Get-Cluster -Server $connection -ErrorAction SilentlyContinue | Sort-Object -Property Name)
  $summaryResults = @()
  $hostResults = @()

  if (@($allClusters).Count -gt 0) {
    $targetClusters = @()
    if ($ClusterName) {
      $targetClusters = $allClusters | Where-Object { $_.Name -eq $ClusterName }
      if (-not $targetClusters) {
        $available = $allClusters | Select-Object -ExpandProperty Name
        throw "Cluster '$ClusterName' was not found in vCenter '$VCenter'. Available clusters: $($available -join ', ')"
      }
    }
    else {
      $targetClusters = $allClusters
      Write-Verbose "Cluster name not specified. Running report for all clusters ($(@($targetClusters).Count))."
    }

    foreach ($cluster in $targetClusters) {
      $clusterHosts = @(Get-VMHost -Location $cluster -ErrorAction Stop)
      $clusterVms = @(Get-VM -Location $cluster -ErrorAction Stop)
      $report = Get-NPlusOneReportForScope `
        -ScopeName $cluster.Name `
        -ScopeType 'Cluster' `
        -VCenterName $VCenter `
        -Hosts $clusterHosts `
        -VMs $clusterVms `
        -PlannedCpu $PlannedVmCpu `
        -PlannedMemoryGB $PlannedVmMemoryGB

      $summaryResults += $report.Summary
      $hostResults += $report.HostDetails
    }
  }
  else {
    Write-Warning "No clusters found in vCenter '$VCenter'. Running a vCenter-wide report across all visible ESXi hosts."
    if ($ClusterName) {
      Write-Warning "ClusterName '$ClusterName' was ignored because no clusters exist in this vCenter."
    }

    $scopeHosts = @(Get-VMHost -Server $connection -ErrorAction Stop)
    if (-not $scopeHosts -or @($scopeHosts).Count -eq 0) {
      throw "No ESXi hosts were found in vCenter '$VCenter'."
    }

    $scopeVms = @(Get-VM -Server $connection -ErrorAction Stop)
    $scopeName = '__NO_CLUSTERS_VCENTER_SCOPE__'
    $report = Get-NPlusOneReportForScope `
      -ScopeName $scopeName `
      -ScopeType 'VCenter' `
      -VCenterName $VCenter `
      -Hosts $scopeHosts `
      -VMs $scopeVms `
      -PlannedCpu $PlannedVmCpu `
      -PlannedMemoryGB $PlannedVmMemoryGB

    $summaryResults += $report.Summary
    $hostResults += $report.HostDetails
  }

  if ($SummaryCsvPath) {
    $summaryResults | Export-Csv -Path $SummaryCsvPath -NoTypeInformation -Encoding UTF8
  }

  if ($HostCsvPath) {
    $hostResults | Export-Csv -Path $HostCsvPath -NoTypeInformation -Encoding UTF8
  }

  if ($PassThru) {
    [PSCustomObject]@{
      Summaries   = $summaryResults
      HostDetails = $hostResults
    }
  }
  else {
    Write-Host "N+1 Capacity Summary on '$VCenter'" -ForegroundColor Cyan
    $summaryResults | Sort-Object -Property ClusterName | Format-Table -AutoSize
    Write-Host ''
    Write-Host 'Per-host capacity and assigned VM configuration:' -ForegroundColor Cyan
    $hostResults | Sort-Object -Property ClusterName, HostName | Format-Table -AutoSize
  }
}
finally {
  if ($connection) {
    Disconnect-VIServer -Server $connection -Confirm:$false | Out-Null
  }
}

