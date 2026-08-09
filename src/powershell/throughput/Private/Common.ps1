# Common utility helpers (private to NetworkLantern.Throughput)

# --- Named constants ---
# Exit codes map to structured ErrorIds (see ErrorClassification.ps1).
# The CLI script (Measure-NetworkThroughput.ps1) mirrors these values for process exit codes.
$script:ExitCodes = @{
  Success          = 0
  InputValidation  = 11
  Prerequisite     = 12
  Connectivity     = 13
  PartialFailure   = 14
  TotalFailure     = 15
  Internal         = 16
}
$script:MaxUdpSaturationIterations = 1000
$script:MaxJsonTextLength          = 1MB   # 1048576 chars
$script:MaxTopFailures             = 10
$script:DefaultTraceHops           = 5
$script:InvariantCulture           = [System.Globalization.CultureInfo]::InvariantCulture
$script:Iperf3ProcessTimeoutBufferSec = 30  # extra seconds beyond Duration+Omit before killing iperf3
$script:DefaultRetryCount            = 0   # retries per test on transient failure (ExitCode != 0, no JSON)
$script:RetryDelayMs                 = 2000
# Profile and run-index writers share sidecar-lock behavior. Fifteen seconds leaves
# enough time for the supported eight-writer burst while keeping contention bounded.
$script:ExclusiveFileLockTimeoutMs   = 15000
$script:ExclusiveFileLockRetryDelayMs = 100
# Threshold defaults: $null means "no threshold check" (disabled).
$script:DefaultThresholdMinThroughputMbps = $null
$script:DefaultThresholdMaxLossPct        = $null
$script:DefaultThresholdMaxJitterMs       = $null

function ConvertTo-Iperf3HashtableFromObject {
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [AllowNull()]
    [object]$InputObject
  )
  if ($InputObject -is [hashtable]) { return $InputObject }
  if ($InputObject -is [System.Collections.IDictionary]) {
    $h = @{}
    foreach ($k in $InputObject.Keys) { $h[[string]$k] = $InputObject[$k] }
    return $h
  }
  $h = @{}
  if ($null -eq $InputObject) { return $h }
  foreach ($p in $InputObject.PSObject.Properties) {
    $h[$p.Name] = $p.Value
  }
  return $h
}
