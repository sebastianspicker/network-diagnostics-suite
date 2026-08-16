# Report and summary helpers (private to NetworkLantern.Throughput)

function Set-Iperf3JsonFileAtomic {
  [CmdletBinding(SupportsShouldProcess = $true)]
  [OutputType([void])]
  param(
    [Parameter(Mandatory)]
    [string]$Path,
    [Parameter(Mandatory)]
    [object]$InputObject
  )
  $directory = Split-Path -Parent $Path
  $tempName = ".{0}.{1}.tmp" -f ([System.IO.Path]::GetFileName($Path)), ([guid]::NewGuid().ToString('N'))
  $tempPath = Join-Path -Path $directory -ChildPath $tempName
  if (-not $PSCmdlet.ShouldProcess($Path, 'Write JSON file atomically')) {
    return
  }
  try {
    $InputObject | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tempPath -Encoding UTF8 -NoNewline
    [System.IO.File]::Move($tempPath, $Path, $true)
    $tempPath = $null
  }
  finally {
    if ($tempPath -and (Test-Path -LiteralPath $tempPath)) {
      Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
  }
}

function Build-RunSummary {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [object[]]$Results,
    [Parameter(Mandatory)]
    [int]$TestCount,
    [Parameter(Mandatory)]
    [int]$ParseErrorCount,
    [Parameter(Mandatory)]
    [string]$Target,
    [Parameter(Mandatory)]
    [int]$Port,
    [Parameter(Mandatory)]
    [string]$Stack,
    [Parameter(Mandatory)]
    [string]$Timestamp,
    [Parameter(Mandatory)]
    [string]$OutDir,
    [string]$StartedUtc,
    [string]$CompletedUtc,
    [double]$ElapsedSeconds = 0,
    [string]$Iperf3Version,
    [nullable[double]]$ThresholdMinThroughputMbps,
    [nullable[double]]$ThresholdMaxLossPct,
    [nullable[double]]$ThresholdMaxJitterMs
  )
  $failed = @($Results | Where-Object {
      $_.ExitCode -ne 0 -or
      $_.JsonParseError -or
      ($_.PSObject.Properties.Name -contains 'MetricError' -and $_.MetricError)
    })
  $succeededCount = $TestCount - $failed.Count
  if ($succeededCount -lt 0) { $succeededCount = 0 }
  $status = if ($TestCount -eq 0 -or $failed.Count -eq $TestCount) { 'TotalFailure' } elseif ($failed.Count -gt 0) { 'PartialFailure' } else { 'Success' }
  $statusCode = switch ($status) {
    'Success' { 0 }
    'PartialFailure' { $script:ExitCodes.PartialFailure }
    default { $script:ExitCodes.TotalFailure }
  }
  $topFailures = @(
    $failed |
      Select-Object -First $script:MaxTopFailures |
      ForEach-Object {
        [pscustomobject]@{
          No             = $_.No
          Proto          = $_.Proto
          Dir            = $_.Dir
          DSCP           = $_.DSCP
          ExitCode       = $_.ExitCode
          JsonParseError = $_.JsonParseError
          MetricError    = if ($_.PSObject.Properties.Name -contains 'MetricError') { $_.MetricError } else { $null }
        }
      }
  )
  # Threshold evaluation: check each succeeded test's metrics against thresholds.
  $thresholdBreaches = @()
  $hasThresholds = ($null -ne $ThresholdMinThroughputMbps) -or ($null -ne $ThresholdMaxLossPct) -or ($null -ne $ThresholdMaxJitterMs)
  if ($hasThresholds) {
    foreach ($r in $Results) {
      if ($r.ExitCode -ne 0 -or
          $r.JsonParseError -or
          ($r.PSObject.Properties.Name -contains 'MetricError' -and $r.MetricError)) { continue }  # only evaluate succeeded tests
      $m = $r.Metrics
      if (-not $m) { continue }
      $reasons = @()
      if ($null -ne $ThresholdMinThroughputMbps) {
        if ($null -ne $m.TxMbps -and $m.TxMbps -lt $ThresholdMinThroughputMbps) { $reasons += "TX throughput $($m.TxMbps) < $ThresholdMinThroughputMbps Mbps" }
        if ($null -ne $m.RxMbps -and $m.RxMbps -lt $ThresholdMinThroughputMbps) { $reasons += "RX throughput $($m.RxMbps) < $ThresholdMinThroughputMbps Mbps" }
      }
      if ($null -ne $ThresholdMaxLossPct -and $null -ne $m.LossPct -and $m.LossPct -gt $ThresholdMaxLossPct) {
        $reasons += "Loss $($m.LossPct)% > $ThresholdMaxLossPct%"
      }
      if ($null -ne $ThresholdMaxJitterMs -and $null -ne $m.JitterMs -and $m.JitterMs -gt $ThresholdMaxJitterMs) {
        $reasons += "Jitter $($m.JitterMs)ms > ${ThresholdMaxJitterMs}ms"
      }
      if ($reasons.Count -gt 0) {
        $thresholdBreaches += [pscustomobject]@{ No = $r.No; Proto = $r.Proto; Dir = $r.Dir; DSCP = $r.DSCP; Reasons = $reasons }
      }
    }
    # Upgrade status if thresholds breached on otherwise-successful tests
    if ($thresholdBreaches.Count -gt 0 -and $status -eq 'Success') {
      $status = 'PartialFailure'
      $statusCode = $script:ExitCodes.PartialFailure
    }
  }
  return [pscustomobject]@{
    SummaryVersion  = 2
    Timestamp       = $Timestamp
    StartedUtc      = $StartedUtc
    CompletedUtc    = $CompletedUtc
    ElapsedSeconds  = $ElapsedSeconds
    OutDir          = $OutDir
    Target          = $Target
    Port            = $Port
    Stack           = $Stack
    Status          = $status
    ExitCode        = $statusCode
    Counts          = [pscustomobject]@{
      Total       = $TestCount
      Succeeded   = $succeededCount
      Failed      = $failed.Count
      ParseErrors = $ParseErrorCount
    }
    Environment     = [pscustomobject]@{
      Iperf3Version     = $Iperf3Version
      PowerShellVersion = [string]$PSVersionTable.PSVersion
      OS                = [string]$PSVersionTable.OS
    }
    FailureBreakdown = if ($failed.Count -gt 0) {
      $groups = @{}
      foreach ($f in $failed) {
        $reason = if ($f.JsonParseError) { 'JSON parse error' }
                  elseif ($f.PSObject.Properties.Name -contains 'MetricError' -and $f.MetricError) { $f.MetricError }
                  elseif ($f.RawText -match 'unable to connect|connection refused') { 'connection refused' }
                  elseif ($f.RawText -match 'timed out|timeout') { 'timeout' }
                  elseif ($f.ExitCode -ne 0) { "iperf3 exit $($f.ExitCode)" }
                  else { 'unknown' }
        $groups[$reason] = ($groups[$reason] ?? 0) + 1
      }
      $groups.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
        [pscustomobject]@{ Reason = $_.Key; Count = $_.Value }
      }
    } else { @() }
    ThresholdBreaches   = $thresholdBreaches
    ThresholdBreachCount = $thresholdBreaches.Count
    TopFailures     = $topFailures
    ArtifactStatus  = [pscustomobject]@{
      Csv         = 'Pending'
      Json        = 'Pending'
      SummaryJson = 'Pending'
      ReportMd    = 'Pending'
      RunIndex    = 'Pending'
      Complete    = $false
    }
    Supplemental    = [pscustomobject]@{
      SummaryJsonPath = $null
      ReportMdPath    = $null
      RunIndexPath    = $null
    }
  }
}

function Write-Iperf3SupplementalReports {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$RunSummary,
    [Parameter(Mandatory)]
    [string]$OutDir,
    [Parameter(Mandatory)]
    [string]$Timestamp,
    [switch]$DeferSummaryJson
  )
  $plannedSummaryPath = Join-Path -Path $OutDir -ChildPath "iperf3_summary_$Timestamp.json"
  $summaryPath = $null
  $reportPath = Join-Path -Path $OutDir -ChildPath "iperf3_report_$Timestamp.md"
  $summaryStatus = 'Pending'

  if (-not $DeferSummaryJson) {
    try {
      Set-Iperf3JsonFileAtomic -Path $plannedSummaryPath -InputObject $RunSummary
      $summaryPath = $plannedSummaryPath
      $summaryStatus = 'OK'
    } catch {
      Write-Warning "Failed to write summary JSON: $_"
      $summaryPath = $null
      $summaryStatus = 'Warn'
    }
  }

  $lines = New-Object System.Collections.Generic.List[string]
  [void]$lines.Add('# iperf3 Test Run Report')
  [void]$lines.Add('')
  [void]$lines.Add("Timestamp: $($RunSummary.Timestamp)")
  [void]$lines.Add("Target: ``$($RunSummary.Target)``:``$($RunSummary.Port)``")
  [void]$lines.Add("Stack: $($RunSummary.Stack)")
  [void]$lines.Add("Status: $($RunSummary.Status)")
  if ($RunSummary.ElapsedSeconds) { [void]$lines.Add("Elapsed: $($RunSummary.ElapsedSeconds)s") }
  if ($RunSummary.Environment) { [void]$lines.Add("iperf3: $($RunSummary.Environment.Iperf3Version)") }
  [void]$lines.Add('')
  [void]$lines.Add('## Counts')
  [void]$lines.Add("- Total: $($RunSummary.Counts.Total)")
  [void]$lines.Add("- Succeeded: $($RunSummary.Counts.Succeeded)")
  [void]$lines.Add("- Failed: $($RunSummary.Counts.Failed)")
  [void]$lines.Add("- JSON parse errors: $($RunSummary.Counts.ParseErrors)")
  [void]$lines.Add('')
  [void]$lines.Add('## Top failures')
  if (-not $RunSummary.TopFailures -or $RunSummary.TopFailures.Count -eq 0) {
    [void]$lines.Add('No failed tests.')
  }
  else {
    foreach ($f in $RunSummary.TopFailures) {
      [void]$lines.Add("- #$($f.No) $($f.Proto)/$($f.Dir) DSCP=$($f.DSCP) ExitCode=$($f.ExitCode) ParseError=$($f.JsonParseError)")
    }
  }
  if ($RunSummary.ThresholdBreachCount -gt 0) {
    [void]$lines.Add('')
    [void]$lines.Add('## Threshold breaches')
    foreach ($b in $RunSummary.ThresholdBreaches) {
      $escapedReasons = ($b.Reasons | ForEach-Object { "``$_``" }) -join '; '
      [void]$lines.Add("- #$($b.No) $($b.Proto)/$($b.Dir) DSCP=$($b.DSCP): $escapedReasons")
    }
  }
  [void]$lines.Add('')
  [void]$lines.Add('## Files')
  $summaryDisplay = if ($summaryPath) { $summaryPath } else { 'not available' }
  [void]$lines.Add("- Summary JSON: $summaryDisplay")
  [void]$lines.Add("- This report: $reportPath")
  try {
    Set-Content -LiteralPath $reportPath -Encoding UTF8 -Value ($lines -join [Environment]::NewLine)
  } catch {
    Write-Warning "Failed to write report markdown: $_"
    $reportPath = $null
  }

  return [pscustomobject]@{
    SummaryJsonPath   = $summaryPath
    ReportMdPath      = $reportPath
    SummaryJsonStatus = $summaryStatus
    ReportMdStatus    = if ($reportPath) { 'OK' } else { 'Warn' }
  }
}

function Write-Iperf3RunIndex {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$OutDir,
    [Parameter(Mandatory)]
    [pscustomobject]$RunSummary,
    [Parameter(Mandatory)]
    [AllowNull()][AllowEmptyString()]
    [string]$CsvPath,
    [Parameter(Mandatory)]
    [AllowNull()][AllowEmptyString()]
    [string]$JsonPath,
    [Parameter(Mandatory)]
    [AllowNull()][AllowEmptyString()][string]$SummaryJsonPath,
    [Parameter(Mandatory)]
    [AllowNull()][AllowEmptyString()][string]$ReportMdPath
  )
  if ([string]::IsNullOrEmpty($SummaryJsonPath)) { $SummaryJsonPath = $null }
  if ([string]::IsNullOrEmpty($ReportMdPath)) { $ReportMdPath = $null }
  $indexPath = Join-Path -Path $OutDir -ChildPath 'iperf3_run_index.json'
  $runEntry = [ordered]@{
    timestamp       = $RunSummary.Timestamp
    status          = $RunSummary.Status
    exitCode        = $RunSummary.ExitCode
    target          = $RunSummary.Target
    port            = $RunSummary.Port
    stack           = $RunSummary.Stack
    csvPath         = $CsvPath
    jsonPath        = $JsonPath
    summaryJsonPath = $SummaryJsonPath
    reportMdPath    = $ReportMdPath
  }
  $lockPath = "$indexPath.lock"
  $lockWait = [System.Diagnostics.Stopwatch]::StartNew()
  while ($true) {
    $lockStream = $null
    try {
      $remainingMs = $script:ExclusiveFileLockTimeoutMs - [int]$lockWait.ElapsedMilliseconds
      if ($remainingMs -le 0) {
        throw [System.IO.IOException]::new('Run-index lock deadline expired.')
      }
      $lockStream = Open-ExclusiveSidecarLock -LockPath $lockPath -TimeoutMs $remainingMs

      # Read, validate, append, and atomically replace while holding one stable
      # sidecar lock so concurrent writers cannot overwrite each other's entry.
      $existingRuns = @()
      if (Test-Path -LiteralPath $indexPath -PathType Leaf) {
        $indexFileInfo = Get-Item -LiteralPath $indexPath
        if ($indexFileInfo.Length -gt 1MB) {
          Write-Warning "Run index file exceeds 1 MB ($($indexFileInfo.Length) bytes); starting fresh."
        }
        else {
          try {
            $existing = Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            if ($existing.ContainsKey('runs') -and $existing['runs'] -is [array]) {
              $requiredEntryProps = @('timestamp', 'status')
              $existingRuns = @($existing['runs'] | Where-Object {
                $entry = $_
                $valid = $true
                foreach ($p in $requiredEntryProps) {
                  if (-not ($entry -is [hashtable] -and $entry.ContainsKey($p)) -and
                      -not ($entry.PSObject -and $entry.PSObject.Properties.Name -contains $p)) {
                    $valid = $false
                    break
                  }
                }
                $valid
              })
            }
          }
          catch { Write-Verbose "Could not read existing run index; starting fresh." }
        }
      }

      $allRuns = @($existingRuns) + @($runEntry)
      if ($allRuns.Count -gt 50) { $allRuns = $allRuns[($allRuns.Count - 50)..($allRuns.Count - 1)] }
      $index = [ordered]@{
        schemaVersion = 2
        updatedUtc    = (Get-Date).ToUniversalTime().ToString('o')
        lastRun       = $runEntry
        runs          = $allRuns
      }
      Set-Iperf3JsonFileAtomic -Path $indexPath -InputObject $index
      return $indexPath
    }
    catch [System.IO.IOException] {
      $remainingMs = $script:ExclusiveFileLockTimeoutMs - [int]$lockWait.ElapsedMilliseconds
      if ($remainingMs -le 0) {
        Write-Warning "Failed to write run index after $($script:ExclusiveFileLockTimeoutMs)ms lock deadline: $($_.Exception.Message)"
        return $null
      }
      Start-Sleep -Milliseconds ([Math]::Min($script:ExclusiveFileLockRetryDelayMs, $remainingMs))
    }
    catch {
      Write-Warning "Failed to write run index: $_"
      return $null
    }
    finally {
      if ($lockStream) { $lockStream.Dispose() }
    }
  }
  return $null
}
