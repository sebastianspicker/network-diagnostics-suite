[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Lifecycle helpers change only the locally owned job and its nonce-bound cancellation signal.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '', Justification = 'Start-Job receives values through its param block and -ArgumentList.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The plural name describes processing the complete deferred-job collection.')]
param()

function New-RunCancellationContext {
  $runId = [guid]::NewGuid().ToString('N')
  $nonce = [guid]::NewGuid().ToString('N')
  $path = Join-Path ([System.IO.Path]::GetTempPath()) "network-lantern-iperf3-cancel-$runId.signal"
  return [pscustomobject]@{
    RunId               = $runId
    Nonce               = $nonce
    CancellationFile    = $path
    ExpectedSignalContent = "NETWORK-LANTERN-IPERF3-CANCEL/1:${runId}:${nonce}"
  }
}

function Set-RunCancellationSignal {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$CancellationContext
  )
  $cancellationFile = [string]$CancellationContext.CancellationFile
  $expectedContent = [string]$CancellationContext.ExpectedSignalContent
  if ([string]::IsNullOrWhiteSpace($cancellationFile) -or [string]::IsNullOrWhiteSpace($expectedContent)) {
    throw 'Cancellation context is incomplete.'
  }
  $tempPath = "$CancellationFile.$([guid]::NewGuid().ToString('N')).tmp"
  try {
    [System.IO.File]::WriteAllText($tempPath, $expectedContent, [System.Text.UTF8Encoding]::new($false))
    try {
      [System.IO.File]::Move($tempPath, $CancellationFile, $false)
      $tempPath = $null
    }
    catch [System.IO.IOException] {
      if (-not (Test-Path -LiteralPath $CancellationFile -PathType Leaf)) { throw }
      $existingContent = [System.IO.File]::ReadAllText($CancellationFile)
      if (-not [string]::Equals($existingContent, $expectedContent, [StringComparison]::Ordinal)) {
        throw "Cancellation signal path already contains foreign content: $CancellationFile"
      }
    }
  }
  finally {
    if ($tempPath -and (Test-Path -LiteralPath $tempPath)) {
      Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
  }
}

function Clear-RunCancellationContext {
  if ($script:RunJobCancellationContext) {
    Remove-Item -LiteralPath $script:RunJobCancellationContext.CancellationFile -Force -ErrorAction SilentlyContinue
    $script:RunJobCancellationContext = $null
  }
}

function Receive-RunJobLifecycleOutput {
  param(
    [Parameter(Mandatory)]
    [System.Management.Automation.Job]$Job
  )
  $ordinaryOutput = [System.Collections.Generic.List[object]]::new()
  foreach ($item in @(Receive-Job -Job $Job -ErrorAction SilentlyContinue)) {
    $recordType = if ($item -and $item.PSObject.Properties.Name -contains 'RecordType') { [string]$item.RecordType } else { '' }
    if ($recordType -eq 'NetworkLantern.Iperf3.JobStarted') {
      if ($script:RunJobCancellationContext -and $item.RunId -eq $script:RunJobCancellationContext.RunId) {
        $script:RunJobStartedRecords = @($script:RunJobStartedRecords) + @($item)
      }
      continue
    }
    if ($recordType -eq 'NetworkLantern.Iperf3.JobTerminal') {
      $script:RunJobTerminalRecords = @($script:RunJobTerminalRecords) + @($item)
      continue
    }
    $ordinaryOutput.Add($item)
  }
  return $ordinaryOutput.ToArray()
}

function Get-ValidatedRunWorkerIdentity {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$CancellationContext,
    [AllowEmptyCollection()]
    [object[]]$StartedRecords = @()
  )
  if (@($StartedRecords).Count -ne 1) { return $null }
  $record = @($StartedRecords)[0]
  if ($record.RecordType -ne 'NetworkLantern.Iperf3.JobStarted' -or
      $record.RunId -ne $CancellationContext.RunId -or
      [string]::IsNullOrWhiteSpace([string]$record.WorkerStartTimeUtc)) {
    return $null
  }
  try {
    $version = [int]$record.Version
    $workerProcessId = [int]$record.WorkerProcessId
    $startTime = [datetime]::Parse(
      [string]$record.WorkerStartTimeUtc,
      [Globalization.CultureInfo]::InvariantCulture,
      [Globalization.DateTimeStyles]::RoundtripKind
    ).ToUniversalTime()
  }
  catch {
    return $null
  }
  if ($version -ne 1 -or $workerProcessId -le 0) { return $null }
  return [pscustomobject]@{
    ProcessId          = $workerProcessId
    WorkerStartTimeUtc = $startTime
  }
}

function Get-VerifiedRunCleanupRecord {
  param(
    [Parameter(Mandatory)]
    [System.Management.Automation.Job]$Job,
    [Parameter(Mandatory)]
    [pscustomobject]$CancellationContext,
    [AllowEmptyCollection()]
    [object[]]$TerminalRecords = @()
  )
  if ([string]$Job.State -ne 'Failed') { return $null }
  $childJobs = @($Job.ChildJobs)
  if ($childJobs.Count -ne 1 -or -not $childJobs[0].JobStateInfo.Reason) { return $null }
  if (@($TerminalRecords).Count -ne 1) { return $null }
  $record = @($TerminalRecords)[0]
  try { $recordVersion = [int]$record.Version } catch { return $null }
  if ($record.RecordType -ne 'NetworkLantern.Iperf3.JobTerminal' -or
      $recordVersion -ne 1 -or
      $record.RunId -ne $CancellationContext.RunId -or
      $record.Outcome -ne 'Cancelled' -or
      $record.CleanupStatus -ne 'Verified' -or
      $record.RootExited -isnot [bool] -or -not $record.RootExited -or
      $record.TreeTerminationVerified -isnot [bool] -or -not $record.TreeTerminationVerified -or
      $record.StreamsCompleted -isnot [bool] -or -not $record.StreamsCompleted -or
      $record.TerminationScope -ne 'TrackedProcessTree') {
    return $null
  }
  return $record
}

function Stop-RunWorkerProcessBounded {
  param(
    [Parameter(Mandatory)]
    [int]$ProcessId,
    [Parameter(Mandatory)]
    [datetime]$ExpectedStartTimeUtc,
    [ValidateRange(1, 5000)]
    [int]$GracePeriodMs = 1000
  )
  $worker = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  if (-not $worker) { return $true }
  try {
    if ($worker.StartTime.ToUniversalTime().Ticks -ne $ExpectedStartTimeUtc.ToUniversalTime().Ticks) {
      Write-Warning "Worker PID $ProcessId was reused; refusing to terminate the unrelated process."
      return $false
    }
    $worker.Kill($true)
    return [bool]$worker.WaitForExit($GracePeriodMs)
  }
  catch {
    if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $true }
    Write-Warning "Failed to terminate worker process $ProcessId within the cancellation fallback: $($_.Exception.Message)"
    return $false
  }
  finally {
    $worker.Dispose()
  }
}

function Update-DeferredRunJobs {
  $pending = [System.Collections.Generic.List[object]]::new()
  foreach ($deferredJob in @($script:DeferredRunJobs)) {
    if (@('Completed', 'Failed', 'Stopped') -contains [string]$deferredJob.State) {
      $null = Receive-Job -Job $deferredJob -ErrorAction SilentlyContinue
      Remove-Job -Job $deferredJob -Force -ErrorAction SilentlyContinue
    }
    else {
      $pending.Add($deferredJob)
    }
  }
  $script:DeferredRunJobs = $pending.ToArray()
}

function Start-SuiteJob {
  [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess', '', Justification = 'WhatIf is passed through to the module, not implemented here')]
  param(
    [hashtable]$ParamHash,
    [switch]$WhatIf,
    [string]$ModulePath,
    [Parameter(Mandatory)]
    [pscustomobject]$CancellationContext
  )
  $hash = $ParamHash.Clone()
  if ($WhatIf) { $hash['WhatIf'] = $true }
  $hash['PassThru'] = $true
  return (Start-Job -ScriptBlock {
      param($modPath, $params, $cancelFile, $runId, $cancelNonce)
      $previousCancelFile = [Environment]::GetEnvironmentVariable('NETWORK_LANTERN_IPERF3_CANCEL_FILE', 'Process')
      $previousCancelRunId = [Environment]::GetEnvironmentVariable('NETWORK_LANTERN_IPERF3_CANCEL_RUN_ID', 'Process')
      $previousCancelNonce = [Environment]::GetEnvironmentVariable('NETWORK_LANTERN_IPERF3_CANCEL_NONCE', 'Process')
      try {
        [Environment]::SetEnvironmentVariable('NETWORK_LANTERN_IPERF3_CANCEL_FILE', $cancelFile, 'Process')
        [Environment]::SetEnvironmentVariable('NETWORK_LANTERN_IPERF3_CANCEL_RUN_ID', $runId, 'Process')
        [Environment]::SetEnvironmentVariable('NETWORK_LANTERN_IPERF3_CANCEL_NONCE', $cancelNonce, 'Process')
        $workerStartTimeUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
        [pscustomobject]@{
          RecordType      = 'NetworkLantern.Iperf3.JobStarted'
          Version         = 1
          RunId           = $runId
          WorkerProcessId = $PID
          WorkerStartTimeUtc = $workerStartTimeUtc
        }
        Import-Module $modPath -Force
        Measure-NetworkThroughput @params *>&1
        [pscustomobject]@{
          RecordType              = 'NetworkLantern.Iperf3.JobTerminal'
          Version                 = 1
          RunId                   = $runId
          Outcome                 = 'Completed'
          CleanupStatus           = 'NotApplicable'
          ReasonCode              = 'RunCompleted'
          NativeProcessId         = $null
          RootExited              = $null
          TreeTerminationVerified = $null
          StreamsCompleted        = $null
          TerminationScope        = $null
          TerminationError        = $null
        }
      }
      catch {
        $exceptionData = $_.Exception.Data
        $isLifecycleRecord = $exceptionData -and $exceptionData['NetworkLantern.CleanupRecordVersion'] -eq 1
        $cancellationObserved = $isLifecycleRecord -and [bool]$exceptionData['NetworkLantern.CancellationObserved']
        $cleanupVerified = $isLifecycleRecord -and
          $exceptionData['NetworkLantern.RunId'] -eq $runId -and
          [bool]$exceptionData['NetworkLantern.CleanupVerified']
        [pscustomobject]@{
          RecordType              = 'NetworkLantern.Iperf3.JobTerminal'
          Version                 = 1
          RunId                   = $runId
          Outcome                 = if ($cancellationObserved) { 'Cancelled' } else { 'Failed' }
          CleanupStatus           = if ($cleanupVerified) { 'Verified' } else { 'Unverified' }
          ReasonCode              = if ($cleanupVerified) { 'TrackedTreeAndStreamsClosed' } elseif ($cancellationObserved) { 'NativeCleanupUnverified' } else { 'UnhandledFailure' }
          NativeProcessId         = if ($isLifecycleRecord) { $exceptionData['NetworkLantern.ProcessId'] } else { $null }
          RootExited              = if ($isLifecycleRecord) { [bool]$exceptionData['NetworkLantern.RootExited'] } else { $false }
          TreeTerminationVerified = if ($isLifecycleRecord) { [bool]$exceptionData['NetworkLantern.TreeTerminationVerified'] } else { $false }
          StreamsCompleted        = if ($isLifecycleRecord) { [bool]$exceptionData['NetworkLantern.StreamsCompleted'] } else { $false }
          TerminationScope        = if ($isLifecycleRecord) { [string]$exceptionData['NetworkLantern.TerminationScope'] } else { $null }
          TerminationError        = if ($isLifecycleRecord) { [string]$exceptionData['NetworkLantern.Error'] } else { $_.Exception.Message }
        }
        throw
      }
      finally {
        [Environment]::SetEnvironmentVariable('NETWORK_LANTERN_IPERF3_CANCEL_FILE', $previousCancelFile, 'Process')
        [Environment]::SetEnvironmentVariable('NETWORK_LANTERN_IPERF3_CANCEL_RUN_ID', $previousCancelRunId, 'Process')
        [Environment]::SetEnvironmentVariable('NETWORK_LANTERN_IPERF3_CANCEL_NONCE', $previousCancelNonce, 'Process')
      }
    } -ArgumentList $ModulePath, $hash, $CancellationContext.CancellationFile, $CancellationContext.RunId, $CancellationContext.Nonce)
}

function Update-LogAndStateFromJob {
  param(
    [System.Windows.Forms.Form]$Form,
    [System.Management.Automation.Job]$Job,
    [System.Windows.Forms.TextBox]$LogBox,
    [System.Windows.Forms.ProgressBar]$ProgressBar,
    [System.Windows.Forms.Label]$StatusLabel,
    [System.Windows.Forms.Timer]$Timer
  )
  if (-not $Job) { return $false }

  $output = Receive-RunJobLifecycleOutput -Job $Job
  if ($output) {
    foreach ($item in @($output)) {
      if ($item -and $item.PSObject -and $item.PSObject.Properties.Name -contains 'ExitCode' -and $item.PSObject.Properties.Name -contains 'Status') {
        $script:LastRunSummary = $item
        $summaryPathBox = $Form.Controls.Find('txtLastSummary', $true) | Select-Object -First 1
        $reportPathBox = $Form.Controls.Find('txtLastReport', $true) | Select-Object -First 1
        if ($summaryPathBox -and $item.Supplemental.SummaryJsonPath) { $summaryPathBox.Text = [string]$item.Supplemental.SummaryJsonPath }
        if ($reportPathBox -and $item.Supplemental.ReportMdPath) { $reportPathBox.Text = [string]$item.Supplemental.ReportMdPath }
        continue
      }
      $line = [string]$item
      if ($line) {
        $LogBox.AppendText($line + "`r`n")
        if ($line -match 'Running test\s+(\d+)/(\d+)') {
          $current = [int]$matches[1]
          $total = [math]::Max([int]$matches[2], 1)
          $pct = [math]::Min(100, [int](100 * $current / $total))
          $ProgressBar.Value = $pct
          $elapsed = if ($script:RunStartTime) { [int]([datetime]::UtcNow - $script:RunStartTime).TotalSeconds } else { 0 }
          $StatusLabel.Text = "Running $current/$total ($pct%) ${elapsed}s"
        }
      }
    }
    $LogBox.ScrollToCaret()
  }

  if ($Job.State -eq 'Completed' -or $Job.State -eq 'Failed') {
    if (@($script:DeferredRunJobs).Count -eq 0) { $Timer.Stop() }
    Update-UiBusyState -Form $Form -Busy $false
    $ProgressBar.Value = 100
    $elapsed = if ($script:RunStartTime) { [int]([datetime]::UtcNow - $script:RunStartTime).TotalSeconds } else { 0 }
    if ($script:RunCancellationRequested) {
      $verifiedCleanup = if ($script:RunJobCancellationContext) {
        Get-VerifiedRunCleanupRecord -Job $Job `
          -CancellationContext $script:RunJobCancellationContext `
          -TerminalRecords $script:RunJobTerminalRecords
      } else { $null }
      $StatusLabel.Text = if ($verifiedCleanup) { 'Cancelled' } else { 'Cancelled; iperf3 cleanup unverified' }
    }
    elseif ($script:LastRunSummary) {
      $StatusLabel.Text = "Done: $($script:LastRunSummary.Status) (${elapsed}s)"
    }
    else {
      $StatusLabel.Text = "Done: $($Job.State) (${elapsed}s)"
    }
    Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
    if ($script:RunJob -eq $Job) {
      $script:RunJob = $null
      Clear-RunCancellationContext
      $script:RunJobStartedRecords = @()
      $script:RunJobTerminalRecords = @()
      $script:RunCancellationRequested = $false
    }
    return $true
  }

  if ($Job.State -eq 'Stopped') {
    if (@($script:DeferredRunJobs).Count -eq 0) { $Timer.Stop() }
    Update-UiBusyState -Form $Form -Busy $false
    $StatusLabel.Text = 'Cancelled; iperf3 cleanup unverified'
    Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
    if ($script:RunJob -eq $Job) {
      $script:RunJob = $null
      Clear-RunCancellationContext
      $script:RunJobStartedRecords = @()
      $script:RunJobTerminalRecords = @()
      $script:RunCancellationRequested = $false
    }
    return $true
  }
  return $false
}

function Stop-CurrentRunJob {
  param(
    [object]$Timer,
    [object]$StatusLabel
  )
  if (-not $script:RunJob) {
    Clear-RunCancellationContext
    return $true
  }
  $childCleanupVerified = $false
  $releaseJob = $false
  $fallbackUsed = $false
  try {
    $script:RunCancellationRequested = $true
    if (-not $script:RunJobCancellationContext) {
      Write-Warning 'No cancellation context is associated with the current run.'
    }
    else {
      try {
        Set-RunCancellationSignal -CancellationContext $script:RunJobCancellationContext
      }
      catch {
        Write-Warning "Failed to signal the running job for cancellation: $($_.Exception.Message)"
      }
    }

    # Give the worker time to observe the nonce-bound signal, terminate its
    # tracked native tree, close redirected streams, and emit a terminal record.
    $null = Wait-Job -Job $script:RunJob -Timeout 7
    $null = Receive-RunJobLifecycleOutput -Job $script:RunJob
    $terminalStates = @('Completed', 'Failed', 'Stopped')
    if ($terminalStates -contains [string]$script:RunJob.State) {
      $releaseJob = $true
      $childCleanupVerified = $script:RunJobCancellationContext -and
        $null -ne (Get-VerifiedRunCleanupRecord -Job $script:RunJob `
            -CancellationContext $script:RunJobCancellationContext `
            -TerminalRecords $script:RunJobTerminalRecords)
    }
    else {
      # Forced worker termination is a bounded fallback and can never count as
      # cooperative native cleanup proof. If the started record is unavailable,
      # leave the registered job and signal in place for timer-based observation.
      $workerIdentity = if ($script:RunJobCancellationContext) {
        Get-ValidatedRunWorkerIdentity -CancellationContext $script:RunJobCancellationContext `
          -StartedRecords $script:RunJobStartedRecords
      } else { $null }
      if ($workerIdentity) {
        $fallbackUsed = $true
        $workerStopped = Stop-RunWorkerProcessBounded -ProcessId $workerIdentity.ProcessId `
          -ExpectedStartTimeUtc $workerIdentity.WorkerStartTimeUtc -GracePeriodMs 1000
        if ($workerStopped) {
          $null = Wait-Job -Job $script:RunJob -Timeout 1
          $null = Receive-RunJobLifecycleOutput -Job $script:RunJob
          $releaseJob = $true
          if ($terminalStates -notcontains [string]$script:RunJob.State) {
            $script:DeferredRunJobs = @($script:DeferredRunJobs) + @($script:RunJob)
          }
        }
      }
    }
    if ($fallbackUsed) { $childCleanupVerified = $false }
    if ($releaseJob -and $terminalStates -contains [string]$script:RunJob.State) {
      Remove-Job -Job $script:RunJob -Force -ErrorAction SilentlyContinue
    }
  }
  finally {
    if ($releaseJob) {
      $script:RunJob = $null
      Clear-RunCancellationContext
      $script:RunJobStartedRecords = @()
      $script:RunJobTerminalRecords = @()
      $script:RunCancellationRequested = $false
      if ($Timer) {
        $Timer.Tag = $null
        if (@($script:DeferredRunJobs).Count -gt 0) { $Timer.Start() } else { $Timer.Stop() }
      }
    }
    elseif ($Timer) {
      $Timer.Tag = $script:RunJob
      $Timer.Start()
    }
    if ($StatusLabel) {
      $StatusLabel.Text = if ($childCleanupVerified) {
        'Cancelled'
      }
      elseif ($releaseJob) {
        'Cancelled; iperf3 cleanup unverified'
      }
      else {
        'Cancellation pending; iperf3 cleanup unverified'
      }
    }
  }
  return $releaseJob
}

function Start-RunFromUi {
  [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess', '', Justification = 'WhatIf is passed through to the background suite job')]
  param(
    [Parameter(Mandatory)]
    [System.Windows.Forms.Form]$Form,
    [Parameter(Mandatory)]
    [System.Windows.Forms.ErrorProvider]$ErrorProvider,
    [Parameter(Mandatory)]
    [System.Windows.Forms.ProgressBar]$ProgressBar,
    [Parameter(Mandatory)]
    [System.Windows.Forms.Label]$StatusLabel,
    [Parameter(Mandatory)]
    [System.Windows.Forms.TextBox]$LogBox,
    [Parameter(Mandatory)]
    [System.Windows.Forms.Timer]$Timer,
    [switch]$WhatIf
  )
  if (-not (Test-RunFormValid -Form $Form -ErrorProvider $ErrorProvider)) { return }

  Update-UiBusyState -Form $Form -Busy $true
  $ProgressBar.Value = 0
  $StatusLabel.Text = if ($WhatIf) { 'WhatIf preview...' } else { 'Starting run...' }
  $LogBox.Clear()
  $script:LastRunSummary = $null
  $script:RunStartTime = [datetime]::UtcNow
  $script:RunJobStartedRecords = @()
  $script:RunJobTerminalRecords = @()
  $script:RunCancellationRequested = $false
  $params = Get-ParamHashFromRunTab -Form $Form
  $script:RunJobCancellationContext = New-RunCancellationContext

  try {
    if ($WhatIf) {
      $script:RunJob = Start-SuiteJob -ParamHash $params -WhatIf -ModulePath $script:ModulePath -CancellationContext $script:RunJobCancellationContext
    }
    else {
      $script:RunJob = Start-SuiteJob -ParamHash $params -ModulePath $script:ModulePath -CancellationContext $script:RunJobCancellationContext
    }
  }
  catch {
    Clear-RunCancellationContext
    Update-UiBusyState -Form $Form -Busy $false
    $StatusLabel.Text = if ($WhatIf) { 'Failed to start preview' } else { 'Failed to start run' }
    $errorTitle = if ($WhatIf) { 'Preview failed to start' } else { 'Run failed to start' }
    Show-GuiError -Message $_.Exception.Message -Title $errorTitle
    return
  }
  $Timer.Tag = $script:RunJob
  $Timer.Start()
}
