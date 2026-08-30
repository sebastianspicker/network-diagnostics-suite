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
$script:Iperf3SummaryFileMaxBytes         = 1MB
$script:Iperf3RunIndexFileMaxBytes        = 1MB
$script:Iperf3CancellationSignalMaxBytes  = 512

function Read-Iperf3BoundedTextFile {
  <#
  .SYNOPSIS
  Reads a small throughput artifact from one stable handle.
  .DESCRIPTION
  Reads at most MaxBytes plus one byte from the opened handle.  Do not add a
  preceding metadata check: it would race replacement or growth and would not
  describe the bytes subsequently parsed.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][ValidateRange(1, 10485760)][int]$MaxBytes,
    [Parameter(Mandatory)][string]$ArtifactDescription
  )
  $stream = $null
  try {
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $buffer = [byte[]]::new($MaxBytes + 1)
    $total = 0
    while ($total -lt $buffer.Length) {
      $read = $stream.Read($buffer, $total, $buffer.Length - $total)
      if ($read -eq 0) { break }
      $total += $read
    }
    if ($total -gt $MaxBytes) {
      throw [System.IO.InvalidDataException]::new("$ArtifactDescription exceeds maximum size ($MaxBytes bytes): $Path")
    }
    $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $total)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    return $text
  }
  finally {
    if ($stream) { $stream.Dispose() }
  }
}

function Open-ExclusiveSidecarLock {
  <#
  .SYNOPSIS
  Opens a sidecar file with exclusive access before a bounded deadline.
  .DESCRIPTION
  This is deliberately limited to lock acquisition. Callers retain their own
  policies for failures after the lock is held: profiles fail immediately,
  whereas run-index persistence retries its complete read-modify-write body.
  #>
  [CmdletBinding()]
  [OutputType([System.IO.FileStream])]
  param(
    [Parameter(Mandatory)]
    [string]$LockPath,
    [int]$TimeoutMs = $script:ExclusiveFileLockTimeoutMs,
    [int]$RetryDelayMs = $script:ExclusiveFileLockRetryDelayMs
  )
  $lockWait = [System.Diagnostics.Stopwatch]::StartNew()
  while ($true) {
    try {
      return [System.IO.File]::Open(
        $LockPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
      )
    }
    catch [System.IO.IOException] {
      $remainingMs = $TimeoutMs - [int]$lockWait.ElapsedMilliseconds
      if ($remainingMs -le 0) { throw }
      Start-Sleep -Milliseconds ([Math]::Min($RetryDelayMs, $remainingMs))
    }
  }
}

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
