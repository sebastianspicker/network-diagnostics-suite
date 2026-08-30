[CmdletBinding()]
param(
  [ValidateSet('Triage', 'Path', 'Throughput', 'Baseline', 'WindowsTuning')][string]$Workflow = 'Triage',
  [string]$ProfilePath,
  [string[]]$HostsIPv4,
  [string[]]$HostsIPv6,
  [ValidateSet('IPv4', 'IPv6')][string[]]$Protocols,
  [string[]]$Rounds,
  [string]$IperfTarget,
  [ValidateRange(1, 65535)][int]$IperfPort = 5201,
  [ValidateSet('TCP', 'UDP', 'Both')][string]$ThroughputProtocol = 'Both',
  [ValidateSet('Apply', 'Backup', 'Restore', 'Verify')][string]$TuningAction = 'Apply',
  [ValidateSet('Safe', 'Measured')][string]$TuningProfile = 'Safe',
  [uint16[]]$UdpPorts,
  [switch]$IncludeAppPolicies,
  [string[]]$AppPaths,
  [string]$OutRoot,
  [switch]$SkipPathping,
  [switch]$DryRun,
  [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$workflowModule = Join-Path $PSScriptRoot 'src/powershell/workflow/NetworkLantern.Workflow/NetworkLantern.Workflow.psd1'
$applicationSupport = Join-Path $PSScriptRoot 'apps/workflow/Private/WorkflowApplication.ps1'

try {
  Import-Module -Name $workflowModule -Force -ErrorAction Stop
  . $applicationSupport

  $planParameters = @{}
  foreach ($parameterName in @($PSBoundParameters.Keys)) {
    $planParameters[$parameterName] = $PSBoundParameters[$parameterName]
  }
  $planParameters['OutRoot'] = if ([string]::IsNullOrWhiteSpace($OutRoot)) {
    Join-Path $PSScriptRoot 'artifacts'
  } else {
    [System.IO.Path]::GetFullPath($OutRoot)
  }
  $planParameters['ExplicitParameters'] = $PSBoundParameters

  $workflowPlan = New-NetworkLanternWorkflowPlan @planParameters
  foreach ($step in @($workflowPlan.Steps)) {
    $childStatus = Invoke-NetworkLanternCapabilityChild -Step $step -RepositoryRoot $PSScriptRoot
    if ($childStatus -ne 0) {
      exit ([int]$childStatus)
    }
  }
  exit 0
} catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 1
}
