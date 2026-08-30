<#
.SYNOPSIS
Measures TCP and UDP throughput with iperf3, DSCP marking, optional MTU probes, and reporting.

.DESCRIPTION
This script is the CLI entry point for the NetworkLantern.Throughput module. It runs a DSCP-marked TCP and
UDP test matrix against an iperf3 server, producing CSV, JSON, summary, and Markdown report artifacts.

Features:
- ICMP reachability (IPv4/IPv6) and TCP port checks
- Optional MTU payload probe (IPv4 DF-bit, IPv6 payload)
- TCP/UDP matrix with configurable DSCP classes, stream counts, and window sizes
- UDP saturation ramp with automatic loss-threshold stopping
- Profile management (save/load/delete named parameter sets)
- Threshold-based CI pass/fail for throughput, loss, and jitter
- Run history tracking and regression comparison
- Structured exit codes (0=success, 11=input, 12=prereq, 13=connectivity, 14-15=test failures, 16=internal)

Run as script (pwsh -File). Do not dot-source to avoid leaking StrictMode/ErrorActionPreference.

.PARAMETER Target
Hostname or IP address of the iperf3 server. Required for test runs.

.PARAMETER Port
iperf3 server port. Range: 1-65535. Default: 5201.

.PARAMETER Duration
Test duration in seconds per individual test. Range: 1-3600. Default: 10.

.PARAMETER Omit
Seconds to omit from the start of each test (warm-up exclusion). Range: 0-60. Default: 1.

.PARAMETER OutDir
Output directory for CSV, JSON, summary, and report artifacts. Default: ./logs.

.PARAMETER Quiet
Suppress all informational output. Only errors are shown.

.PARAMETER Progress
Show per-test progress messages during the run (e.g., "Running test 3/45").

.PARAMETER Summary
Print a summary table to the console after the run completes.

.PARAMETER DisableMtuProbe
Skip the MTU payload probe. Required on Linux/macOS where raw sockets are unavailable.

.PARAMETER SkipReachabilityCheck
Skip the ICMP reachability pre-check. The TCP server-port check still runs. Required on Linux/macOS or when ICMP is blocked.

.PARAMETER MtuSizes
Array of MTU payload sizes (bytes) to probe. Default is platform-specific.

.PARAMETER ConnectTimeoutMs
Timeout in milliseconds for the iperf3 TCP connection. Range: 1000-300000. Default: 60000.

.PARAMETER UdpStart
Starting bandwidth for the UDP saturation ramp (e.g., "1M"). Default: 1M.

.PARAMETER UdpMax
Maximum bandwidth for the UDP saturation ramp (e.g., "1G"). Default: 1G.

.PARAMETER UdpStep
Bandwidth step increment for the UDP saturation ramp (e.g., "10M"). Default: 10M.

.PARAMETER UdpLossThreshold
Stop the UDP ramp when packet loss exceeds this percentage. Range: 0-100. Default: 5.

.PARAMETER TcpStreams
Array of parallel TCP stream counts to test (e.g., 1,4,8). Default: 1,4,8.

.PARAMETER TcpWindows
Array of TCP window sizes to test (e.g., "default","128K","256K"). Default: default,128K,256K.

.PARAMETER DscpClasses
Array of DSCP class names to test (e.g., "CS0","EF","AF41"). Default: CS0,AF11,CS5,EF,AF41.

.PARAMETER IpVersion
IP stack selection: Auto, IPv4, or IPv6. Default: Auto.

.PARAMETER Force
Overwrite existing output files instead of failing on collision.

.PARAMETER WhatIf
Preview mode: shows how many tests would run and the effective parameters without executing them.

.PARAMETER Protocol
Which protocols to test: TCP, UDP, or Both. Default: Both.

.PARAMETER SingleTest
Run a single quick TCP test only, useful for verifying basic connectivity.

.PARAMETER RetryCount
Number of retries per test on transient iperf3 failure. Range: 0-5. Default: 0.

.PARAMETER ThresholdMinThroughputMbps
Fail the run (exit code 14) if any test's throughput falls below this value in Mbps. Not set by default.

.PARAMETER ThresholdMaxLossPct
Fail the run (exit code 14) if any UDP test's packet loss exceeds this percentage. Range: 0-100. Not set by default.

.PARAMETER ThresholdMaxJitterMs
Fail the run (exit code 14) if any UDP test's jitter exceeds this value in milliseconds. Not set by default.

.PARAMETER ConfigurationPath
Path to a JSON configuration file. Keys override defaults; explicitly passed CLI parameters override config values.

.PARAMETER ProfileName
Name of a saved profile to load. When combined with -SaveProfile, saves current parameters under this name.

.PARAMETER ProfilesFile
Path to the profiles storage file. Default: .iperf3/profiles.json in the current directory.

.PARAMETER SaveProfile
Save the current parameter set as a named profile (requires -ProfileName).

.PARAMETER ListProfiles
List all saved profiles and exit (exit code 0).

.PARAMETER DeleteProfile
Remove the named profile from the profiles file and exit.

.PARAMETER StrictConfiguration
Error on unknown keys in the configuration file or profile instead of ignoring them with a warning.

.PARAMETER PassThru
Return the run summary object on the pipeline for programmatic consumption.

.PARAMETER OpenOutputFolder
Open the output folder in the system file explorer after the run completes.

.EXAMPLE
pwsh -File Measure-NetworkThroughput.ps1 -Target 10.0.0.1 -SingleTest
Runs a single TCP TX test to verify basic connectivity.

.EXAMPLE
pwsh -File Measure-NetworkThroughput.ps1 -Target 10.0.0.1 -Protocol TCP -DscpClasses CS0,EF -Progress
Runs a TCP-only matrix for CS0 and EF with progress output.

.EXAMPLE
pwsh -File Measure-NetworkThroughput.ps1 -Target 10.0.0.1 -ThresholdMinThroughputMbps 100 -ThresholdMaxLossPct 2
Runs the full matrix and fails (exit 14) if throughput drops below 100 Mbps or loss exceeds 2%.

.EXAMPLE
pwsh -File Measure-NetworkThroughput.ps1 -Target 10.0.0.1 -SaveProfile -ProfileName lab
Saves current parameters as the 'lab' profile for reuse.

.EXAMPLE
pwsh -File Measure-NetworkThroughput.ps1 -Target 10.0.0.1 -WhatIf
Previews the test plan (count, parameters) without running any tests.

.EXAMPLE
pwsh -File Measure-NetworkThroughput.ps1 -Target 10.0.0.1 -SkipReachabilityCheck -DisableMtuProbe
Runs on Linux/macOS by skipping the ICMP and MTU probes while retaining the TCP server-port check.

.OUTPUTS
When -PassThru is specified, outputs a PSCustomObject with Status, ExitCode, and Supplemental paths.

.NOTES
Exit codes:
  0  - Success (or WhatIf/ListProfiles)
  11 - Input/config validation error
  12 - Prerequisite/environment error (iperf3 not found, wrong PowerShell version)
  13 - Connectivity precheck error (target unreachable, port closed)
  14 - Partial failures or threshold breaches
  15 - Total failure (all tests failed)
  16 - Internal/unclassified error

Requires PowerShell 7+ and iperf3 3.7+ on PATH.
#>
[CmdletBinding()]
param(
  [string]$Target,

  [ValidateRange(1, 65535)]
  [int]$Port,

  [ValidateRange(1, 3600)]
  [int]$Duration,

  [ValidateRange(0, 60)]
  [int]$Omit,

  [ValidateNotNullOrEmpty()]
  [string]$OutDir,

  [switch]$Quiet,

  [switch]$Progress,

  [switch]$Summary,

  [switch]$DisableMtuProbe,

  [switch]$SkipReachabilityCheck,

  [ValidateNotNullOrEmpty()]
  [int[]]$MtuSizes,

  [ValidateRange(1000, 300000)]
  [int]$ConnectTimeoutMs,

  [ValidateNotNullOrEmpty()]
  [string]$UdpStart,

  [ValidateNotNullOrEmpty()]
  [string]$UdpMax,

  [ValidateNotNullOrEmpty()]
  [string]$UdpStep,

  [ValidateRange(0, 100)]
  [double]$UdpLossThreshold,

  [ValidateNotNullOrEmpty()]
  [int[]]$TcpStreams,

  [ValidateNotNullOrEmpty()]
  [string[]]$TcpWindows,

  [ValidateNotNullOrEmpty()]
  [string[]]$DscpClasses,

  [ValidateSet('IPv4', 'IPv6', 'Auto')]
  [string]$IpVersion,

  [switch]$Force,

  [switch]$WhatIf,

  [ValidateSet('TCP', 'UDP', 'Both')]
  [string]$Protocol,

  [switch]$SingleTest,

  [ValidateRange(0, 5)]
  [int]$RetryCount,

  [nullable[double]]$ThresholdMinThroughputMbps,

  [ValidateRange(0, 100)]
  [nullable[double]]$ThresholdMaxLossPct,

  [nullable[double]]$ThresholdMaxJitterMs,

  [string]$ConfigurationPath,

  [string]$ProfileName,

  [string]$ProfilesFile,

  [switch]$SaveProfile,

  [switch]$ListProfiles,

  [string]$DeleteProfile,

  [switch]$StrictConfiguration,

  [switch]$PassThru,

  [switch]$OpenOutputFolder
)

if ($MyInvocation.InvocationName -eq '.') {
  Write-Error "This script should not be dot-sourced. Please run it as a script file (e.g., pwsh -File Measure-NetworkThroughput.ps1)."
  return
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Exit codes mirror the throughput module's canonical definitions.
$EC_InputValidation = 11
$EC_Prerequisite    = 12
$EC_Connectivity    = 13
$EC_Internal        = 16

# Maps ErrorId from the module's error classification to CLI exit codes.
# Structured module errors are preferred. The application adapter normalizes
# the additional errors raised by its profile-deletion and configuration paths.
$script:ErrorIdToExitCode = @{
  'NetworkLantern.Throughput.InputValidation' = $EC_InputValidation
  'NetworkLantern.Throughput.Prerequisite'    = $EC_Prerequisite
  'NetworkLantern.Throughput.Connectivity'    = $EC_Connectivity
  'NetworkLantern.Throughput.Internal'        = $EC_Internal
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$privateDirectory = Join-Path $PSScriptRoot 'Private'
$modulePath = Join-Path $repoRoot 'src/powershell/throughput/NetworkLantern.Throughput.psd1'

try {
  Import-Module $modulePath -Force
  . (Join-Path $privateDirectory 'ThroughputModuleAdapter.ps1')
  . (Join-Path $privateDirectory 'PathOpening.ps1')
}
catch {
  Write-Error -Message "Failed to initialize throughput CLI prerequisites: $($_.Exception.Message)" -ErrorAction Continue
  exit $EC_Prerequisite
}

if ($DeleteProfile -and ($SaveProfile -or $ListProfiles)) {
  Write-Error -Message 'DeleteProfile cannot be combined with SaveProfile or ListProfiles.' -ErrorAction Continue
  exit $EC_InputValidation
}

$defaultParams = Get-NetworkThroughputDefaultParameterSet
$forwardParams = @{}

if ($ConfigurationPath) {
  try {
    $configBasePath = (Get-Location).Path
    $resolvedConfigPath = Resolve-ThroughputConfigurationPath -Path $ConfigurationPath -BasePath $configBasePath -RequireExistingFile
    $configRaw = Read-ThroughputConfigurationFile -Path $resolvedConfigPath -BasePath $configBasePath
    $configHash = ConvertFrom-Json -InputObject $configRaw -AsHashtable -Depth 32 -ErrorAction Stop
    Write-Verbose "Loaded $($configHash.Count) key(s) from configuration file: $resolvedConfigPath"
    foreach ($key in $configHash.Keys) {
      if ($defaultParams.ContainsKey($key)) {
        $forwardParams[$key] = $configHash[$key]
      }
      elseif ($StrictConfiguration) {
        throw "Unknown configuration key '$key'."
      }
      else {
        Write-Warning "Unknown configuration key '$key' ignored."
      }
    }
  }
  catch {
    $record = Get-ThroughputApplicationErrorRecord -Message "Failed to load configuration from '$ConfigurationPath': $($_.Exception.Message)" -ErrorId 'NetworkLantern.Throughput.InputValidation' -TargetObject $ConfigurationPath
    Write-Error -Message $record.Exception.Message -ErrorAction Continue
    exit (Resolve-ThroughputExitCode -ErrorRecord $record -ErrorIdToExitCode $script:ErrorIdToExitCode -InternalExitCode $EC_Internal)
  }
}

foreach ($key in $PSBoundParameters.Keys) {
  if ($key -ne 'ConfigurationPath' -and $defaultParams.ContainsKey($key)) {
    $forwardParams[$key] = $PSBoundParameters[$key]
  }
}

if ($PSBoundParameters.ContainsKey('DeleteProfile') -and [string]::IsNullOrWhiteSpace($DeleteProfile)) {
  Write-Error -Message "Profile name cannot be empty." -ErrorAction Continue
  exit $EC_InputValidation
}
if ($PSBoundParameters.ContainsKey('DeleteProfile')) {
  if ($DeleteProfile.Length -gt 128) {
    Write-Error -Message "DeleteProfile name exceeds maximum length (128 characters)." -ErrorAction Continue
    exit $EC_InputValidation
  }
  if ($DeleteProfile -match '[/\\:\*\?"<>\|\x00]') {
    Write-Error -Message "DeleteProfile name contains invalid characters: '$DeleteProfile'." -ErrorAction Continue
    exit $EC_InputValidation
  }
}

if ($DeleteProfile) {
  try {
    $profilesFileSupplied = $forwardParams.ContainsKey('ProfilesFile')
    $profilesFile = if ($profilesFileSupplied) { $forwardParams['ProfilesFile'] } else { $null }
    $strictConfiguration = if ($forwardParams.ContainsKey('StrictConfiguration')) { [bool]$forwardParams['StrictConfiguration'] } else { [bool]$defaultParams['StrictConfiguration'] }
    $quietMode = if ($forwardParams.ContainsKey('Quiet')) { [bool]$forwardParams['Quiet'] } else { [bool]$defaultParams['Quiet'] }

    $removeParams = @{ ProfileName = $DeleteProfile; StrictConfiguration = $strictConfiguration }
    if ($profilesFileSupplied) { $removeParams['ProfilesFile'] = $profilesFile }
    $removed = Remove-Iperf3Profile @removeParams
    $profilesFileDisplay = if ($profilesFileSupplied) { $profilesFile } else { $defaultParams['ProfilesFile'] }
    if (-not $removed) {
      Write-Error -Message "Profile '$DeleteProfile' not found in '$profilesFileDisplay'." -ErrorAction Continue
      exit $EC_InputValidation
    }
    if (-not $quietMode) {
      Write-Information -InformationAction Continue "Deleted profile '$DeleteProfile' from '$profilesFileDisplay'."
    }
    if ($PassThru) {
      [pscustomobject]@{
        Mode        = 'DeleteProfile'
        ProfileName = $DeleteProfile
        ProfilesFile = $profilesFileDisplay
        Removed     = $true
      }
    }
    exit 0
  }
  catch {
    $exitCode = Resolve-ThroughputExitCode -ErrorRecord $_ -ErrorIdToExitCode $script:ErrorIdToExitCode -InternalExitCode $EC_Internal
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit $exitCode
  }
}

$invokeParams = @{}
foreach ($key in $forwardParams.Keys) {
  # Skip null values to avoid parameter binding failures on nullable parameters with ValidateRange.
  if ($null -ne $forwardParams[$key]) {
    $invokeParams[$key] = $forwardParams[$key]
  }
}
$invokeParams['PassThru'] = $true

try {
  $runSummary = Measure-NetworkThroughput @invokeParams
  $exitCode = 0
  if ($runSummary -and $runSummary.PSObject.Properties.Name -contains 'ExitCode') {
    $exitCode = [int]$runSummary.ExitCode
  }

  $quietMode = if ($forwardParams.ContainsKey('Quiet')) { [bool]$forwardParams['Quiet'] } else { [bool]$defaultParams['Quiet'] }
  if (-not $quietMode -and $runSummary) {
    $mode = if ($runSummary.PSObject.Properties.Name -contains 'Mode') { [string]$runSummary.Mode } else { 'Run' }
    if ($mode -eq 'Run' -or ($runSummary.PSObject.Properties.Name -contains 'Status')) {
      Write-Information -InformationAction Continue "Final status: $($runSummary.Status) (ExitCode=$exitCode)"
      if ($runSummary.Supplemental) {
        if ($runSummary.Supplemental.SummaryJsonPath) { Write-Information -InformationAction Continue "Summary JSON: $($runSummary.Supplemental.SummaryJsonPath)" }
        if ($runSummary.Supplemental.ReportMdPath) { Write-Information -InformationAction Continue "Report MD  : $($runSummary.Supplemental.ReportMdPath)" }
        if ($runSummary.Supplemental.RunIndexPath) { Write-Information -InformationAction Continue "Run index  : $($runSummary.Supplemental.RunIndexPath)" }
      }
    }
    elseif ($mode -eq 'WhatIf') {
      Write-Information -InformationAction Continue "WhatIf complete. Approx tests: $($runSummary.TotalApprox)"
      Write-Information -InformationAction Continue "CSV  : $($runSummary.CsvPath)"
      Write-Information -InformationAction Continue "JSON : $($runSummary.JsonPath)"
    }
  }

  if ($OpenOutputFolder) {
    $outDirToOpen = $null
    if ($runSummary -and $runSummary.PSObject.Properties.Name -contains 'OutDir') {
      $outDirToOpen = [string]$runSummary.OutDir
    }
    elseif ($runSummary -and $runSummary.PSObject.Properties.Name -contains 'EffectiveParameters' -and $runSummary.EffectiveParameters) {
      $outDirToOpen = [string]$runSummary.EffectiveParameters.OutDir
    }
    if ($outDirToOpen -and (Test-Path -LiteralPath $outDirToOpen -PathType Container)) {
      Open-ThroughputFolderOrFile -Path $outDirToOpen
    }
    else {
      Write-Warning "Output directory not found: $outDirToOpen"
    }
  }

  if ($PassThru) {
    $runSummary
  }
  exit $exitCode
}
catch {
  $exitCode = Resolve-ThroughputExitCode -ErrorRecord $_ -ErrorIdToExitCode $script:ErrorIdToExitCode -InternalExitCode $EC_Internal
  Write-Error -Message $_.Exception.Message -ErrorAction Continue
  exit $exitCode
}
