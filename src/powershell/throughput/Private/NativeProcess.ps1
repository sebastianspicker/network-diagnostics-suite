# Native process lifecycle and cancellation helpers (private to NetworkLantern.Throughput)

function Get-Iperf3DescendantProcessSnapshot {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)]
    [int]$RootProcessId,
    [ValidateRange(1, 30000)]
    [int]$TimeoutMs = 1000
  )
  $descendants = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
  $snapshotDeadline = [System.Diagnostics.Stopwatch]::StartNew()
  $snapshotComplete = $true
  $snapshotErrors = [System.Collections.Generic.List[string]]::new()
  try {
    $childrenByParent = @{}
    $parentRows = @()
    if ($IsWindows) {
      # CIM only accepts whole-second operation timeouts. Do not begin an
      # operation that cannot fit into the remaining discovery budget.
      $remainingMs = $TimeoutMs - [int]$snapshotDeadline.ElapsedMilliseconds
      if ($remainingMs -lt 1000) {
        $snapshotComplete = $false
        $snapshotErrors.Add("Descendant discovery has less than one second remaining from its ${TimeoutMs}ms budget; skipping the CIM process listing.")
      }
      else {
        $cimTimeoutSeconds = [math]::Max(1, [math]::Floor($remainingMs / 1000))
        try {
          $parentRows = @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId `
              -OperationTimeoutSec $cimTimeoutSeconds -ErrorAction Stop)
        }
        catch {
          $snapshotComplete = $false
          $snapshotErrors.Add("Descendant process listing failed within its ${cimTimeoutSeconds}s CIM operation budget: $($_.Exception.Message)")
        }
      }
    }
    else {
      $psCommand = (Get-Command -Name ps -CommandType Application -ErrorAction Stop).Source
      $psInfo = [System.Diagnostics.ProcessStartInfo]::new()
      $psInfo.FileName = $psCommand
      $psInfo.ArgumentList.Add('-eo')
      $psInfo.ArgumentList.Add('pid=,ppid=')
      $psInfo.RedirectStandardOutput = $true
      $psInfo.RedirectStandardError = $true
      $psInfo.UseShellExecute = $false
      $psInfo.CreateNoWindow = $true
      $psProcess = $null
      try {
        $psProcess = [System.Diagnostics.Process]::Start($psInfo)
        $stdOutTask = $psProcess.StandardOutput.ReadToEndAsync()
        $stdErrTask = $psProcess.StandardError.ReadToEndAsync()
        $remainingMs = $TimeoutMs - [int]$snapshotDeadline.ElapsedMilliseconds
        if ($remainingMs -lt 1 -or -not $psProcess.WaitForExit($remainingMs)) {
          try { if (-not $psProcess.HasExited) { $psProcess.Kill($true) } } catch { Write-Verbose 'Could not stop the descendant-discovery process listing.' }
          $snapshotComplete = $false
          $snapshotErrors.Add("Descendant discovery exceeded its ${TimeoutMs}ms budget while listing processes.")
        }
        else {
          $remainingMs = $TimeoutMs - [int]$snapshotDeadline.ElapsedMilliseconds
          if ($remainingMs -lt 1 -or -not $stdOutTask.Wait($remainingMs)) {
            $snapshotComplete = $false
            $snapshotErrors.Add("Descendant discovery exceeded its ${TimeoutMs}ms budget while reading the process listing.")
          }
          elseif ($psProcess.ExitCode -ne 0) {
            $snapshotComplete = $false
            $snapshotErrors.Add("Descendant process listing failed: $($stdErrTask.Result)")
          }
          else {
            foreach ($line in ([string]$stdOutTask.Result -split "`r?`n")) {
              if ($snapshotDeadline.ElapsedMilliseconds -ge $TimeoutMs) {
                $snapshotComplete = $false
                $snapshotErrors.Add("Descendant discovery exceeded its ${TimeoutMs}ms budget while parsing the process listing.")
                break
              }
              if ($line -match '^\s*(\d+)\s+(\d+)\s*$') {
                $parentRows += [pscustomobject]@{ ProcessId = [int]$matches[1]; ParentProcessId = [int]$matches[2] }
              }
            }
          }
        }
      }
      finally {
        if ($psProcess) { $psProcess.Dispose() }
      }
    }

    foreach ($row in $parentRows) {
      if ($snapshotDeadline.ElapsedMilliseconds -ge $TimeoutMs) {
        $snapshotComplete = $false
        $snapshotErrors.Add("Descendant discovery exceeded its ${TimeoutMs}ms budget while indexing process relationships.")
        break
      }
      $parentId = [int]$row.ParentProcessId
      if (-not $childrenByParent.ContainsKey($parentId)) {
        $childrenByParent[$parentId] = [System.Collections.Generic.List[int]]::new()
      }
      $childrenByParent[$parentId].Add([int]$row.ProcessId)
    }

    $descendantIds = [System.Collections.Generic.List[int]]::new()
    $pending = [System.Collections.Generic.Queue[int]]::new()
    $pending.Enqueue($RootProcessId)
    while ($snapshotComplete -and $pending.Count -gt 0) {
      if ($snapshotDeadline.ElapsedMilliseconds -ge $TimeoutMs) {
        $snapshotComplete = $false
        $snapshotErrors.Add("Descendant discovery exceeded its ${TimeoutMs}ms budget while resolving the process tree.")
        break
      }
      $parentId = $pending.Dequeue()
      if (-not $childrenByParent.ContainsKey($parentId)) { continue }
      foreach ($childId in $childrenByParent[$parentId]) {
        if ($descendantIds.Contains($childId)) { continue }
        $descendantIds.Add($childId)
        $pending.Enqueue($childId)
      }
    }

    foreach ($descendantId in $descendantIds) {
      if ($snapshotDeadline.ElapsedMilliseconds -ge $TimeoutMs) {
        $snapshotComplete = $false
        $snapshotErrors.Add("Descendant discovery exceeded its ${TimeoutMs}ms budget while opening tracked processes.")
        break
      }
      try {
        $descendants.Add((Get-Process -Id $descendantId -ErrorAction Stop))
      }
      catch {
        $snapshotComplete = $false
        $snapshotErrors.Add("Tracked descendant process $descendantId became unavailable: $($_.Exception.Message)")
      }
    }
    return [pscustomobject]@{
      Succeeded   = $snapshotComplete
      Processes  = @($descendants)
      ProcessIds = [int[]]@($descendantIds)
      Error      = if ($snapshotComplete) { $null } else { $snapshotErrors -join ' ' }
    }
  }
  catch {
    foreach ($candidate in $descendants) {
      try { $candidate.Dispose() } catch { Write-Verbose "Could not dispose process snapshot $($candidate.Id)." }
    }
    return [pscustomobject]@{
      Succeeded   = $false
      Processes  = @()
      ProcessIds = [int[]]@()
      Error      = $_.Exception.Message
    }
  }
}

function Stop-Iperf3ProcessAfterTimeout {
  [CmdletBinding(SupportsShouldProcess = $true)]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)]
    [object]$Process,
    [ValidateRange(1, 30000)]
    [int]$GracePeriodMs = 5000
  )
  $processId = [int]$Process.Id
  # This budget covers pre-kill discovery and post-kill verification together;
  # no unbounded process-tree work may extend a native operation's deadline.
  $terminationDeadline = [System.Diagnostics.Stopwatch]::StartNew()
  $snapshot = Get-Iperf3DescendantProcessSnapshot -RootProcessId $processId -TimeoutMs $GracePeriodMs
  $trackedProcesses = @($Process) + @($snapshot.Processes)
  if ($Process.HasExited) {
    foreach ($descendant in $snapshot.Processes) { $descendant.Dispose() }
    return [pscustomobject]@{
      TerminationSucceeded     = $false
      RootExited               = $true
      TreeTerminationVerified  = $false
      TerminationScope         = 'RootOnly'
      ProcessId                = $processId
      DescendantProcessIds     = [int[]]@($snapshot.ProcessIds)
      UnterminatedProcessIds   = [int[]]@()
      Error                    = 'Root exited before termination ownership could be established; orphaned or reparented descendants cannot be ruled out.'
    }
  }
  if (-not $PSCmdlet.ShouldProcess("process $processId", 'Terminate process tree')) {
    foreach ($descendant in $snapshot.Processes) { $descendant.Dispose() }
    return [pscustomobject]@{
      TerminationSucceeded     = $false
      RootExited               = [bool]$Process.HasExited
      TreeTerminationVerified  = $false
      TerminationScope         = if ($snapshot.Succeeded) { 'TrackedProcessTree' } else { 'RootOnly' }
      ProcessId                = $processId
      DescendantProcessIds     = [int[]]@($snapshot.ProcessIds)
      UnterminatedProcessIds   = [int[]]@($trackedProcesses | ForEach-Object { [int]$_.Id })
      Error                    = 'Termination skipped by ShouldProcess.'
    }
  }
  try {
    $Process.Kill($true)
  }
  catch {
    foreach ($descendant in $snapshot.Processes) { $descendant.Dispose() }
    return [pscustomobject]@{
      TerminationSucceeded     = $false
      RootExited               = $false
      TreeTerminationVerified  = $false
      TerminationScope         = if ($snapshot.Succeeded) { 'TrackedProcessTree' } else { 'RootOnly' }
      ProcessId                = $processId
      DescendantProcessIds     = [int[]]@($snapshot.ProcessIds)
      UnterminatedProcessIds   = [int[]]@($trackedProcesses | ForEach-Object { [int]$_.Id })
      Error                    = "Kill failed: $($_.Exception.Message)"
    }
  }

  $unterminated = @($trackedProcesses)
  while ($unterminated.Count -gt 0 -and $terminationDeadline.ElapsedMilliseconds -lt $GracePeriodMs) {
    $unterminated = @($unterminated | Where-Object {
        try { -not $_.HasExited } catch { $true }
      })
    if ($unterminated.Count -gt 0) {
      $remainingMs = $GracePeriodMs - [int]$terminationDeadline.ElapsedMilliseconds
      Start-Sleep -Milliseconds ([math]::Min(25, [math]::Max($remainingMs, 1)))
    }
  }
  $terminationDeadline.Stop()
  $unterminated = @($trackedProcesses | Where-Object {
      try { -not $_.HasExited } catch { $true }
    })
  $rootExited = -not ($unterminated | Where-Object { [int]$_.Id -eq $processId })
  $treeVerified = [bool]$snapshot.Succeeded -and $unterminated.Count -eq 0
  $unterminatedIds = [int[]]@($unterminated | ForEach-Object { [int]$_.Id })
  foreach ($descendant in $snapshot.Processes) { $descendant.Dispose() }

  $errorText = $null
  if (-not $snapshot.Succeeded) {
    $errorText = "Root termination was attempted, but descendants could not be enumerated: $($snapshot.Error)"
  }
  elseif ($unterminatedIds.Count -gt 0) {
    $errorText = "Tracked process IDs remained alive after the ${GracePeriodMs}ms termination grace period: $($unterminatedIds -join ', ')."
  }
  return [pscustomobject]@{
    TerminationSucceeded     = ($rootExited -and $treeVerified)
    RootExited               = $rootExited
    TreeTerminationVerified  = $treeVerified
    TerminationScope         = if ($snapshot.Succeeded) { 'TrackedProcessTree' } else { 'RootOnly' }
    ProcessId                = $processId
    DescendantProcessIds     = [int[]]@($snapshot.ProcessIds)
    UnterminatedProcessIds   = $unterminatedIds
    Error                    = $errorText
  }
}

function New-Iperf3CancellationException {
  [CmdletBinding()]
  [OutputType([System.Exception])]
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$NativeProcess,
    [string]$RunId
  )
  $cleanupVerified = [bool]$NativeProcess.TerminationSucceeded -and
    [bool]$NativeProcess.RootExited -and
    [bool]$NativeProcess.TreeTerminationVerified -and
    [bool]$NativeProcess.StreamsCompleted
  $message = if ($cleanupVerified) {
    "NETWORK_LANTERN_IPERF3_CANCELLED run=$RunId process=$($NativeProcess.ProcessId) tracked process tree terminated."
  }
  else {
    $cleanupErrors = @($NativeProcess.TerminationError, $NativeProcess.StreamReadError) | Where-Object { $_ }
    "NETWORK_LANTERN_IPERF3_CLEANUP_FAILED run=$RunId process=$($NativeProcess.ProcessId): $($cleanupErrors -join ' ')"
  }
  $exception = if ($cleanupVerified) {
    [System.OperationCanceledException]::new($message)
  }
  else {
    [System.InvalidOperationException]::new($message)
  }
  $exception.Data['NetworkLantern.CleanupRecordVersion'] = 1
  $exception.Data['NetworkLantern.RunId'] = $RunId
  $exception.Data['NetworkLantern.CancellationObserved'] = $true
  $exception.Data['NetworkLantern.CleanupVerified'] = $cleanupVerified
  $exception.Data['NetworkLantern.RootExited'] = [bool]$NativeProcess.RootExited
  $exception.Data['NetworkLantern.TreeTerminationVerified'] = [bool]$NativeProcess.TreeTerminationVerified
  $exception.Data['NetworkLantern.StreamsCompleted'] = [bool]$NativeProcess.StreamsCompleted
  $exception.Data['NetworkLantern.TerminationScope'] = [string]$NativeProcess.TerminationScope
  $exception.Data['NetworkLantern.ProcessId'] = [int]$NativeProcess.ProcessId
  $exception.Data['NetworkLantern.UnterminatedProcessIds'] = [int[]]@($NativeProcess.UnterminatedProcessIds)
  $exception.Data['NetworkLantern.Error'] = [string](@($NativeProcess.TerminationError, $NativeProcess.StreamReadError) | Where-Object { $_ } | Join-String -Separator ' ')
  return $exception
}

function Get-Iperf3CompletedStreamText {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)]
    [System.Threading.Tasks.Task]$StdOutTask,
    [Parameter(Mandatory)]
    [System.Threading.Tasks.Task]$StdErrTask,
    [ValidateRange(1, 30000)]
    [int]$TimeoutMs = 1000
  )
  $combinedTask = [System.Threading.Tasks.Task]::WhenAll([System.Threading.Tasks.Task[]]@($StdOutTask, $StdErrTask))
  $completed = $false
  $streamError = $null
  try {
    $null = $combinedTask.Wait($TimeoutMs)
    $completed = $StdOutTask.IsCompletedSuccessfully -and $StdErrTask.IsCompletedSuccessfully
  }
  catch {
    $completed = $false
    $streamError = $_.Exception.Message
  }
  $stdout = ''
  $stderr = ''
  if ($completed) {
    try { $stdout = [string]$StdOutTask.Result } catch { $streamError = $_.Exception.Message }
    try { $stderr = [string]$StdErrTask.Result } catch { $streamError = $_.Exception.Message }
  }
  elseif (-not $streamError) {
    $streamError = "Redirected streams did not close within ${TimeoutMs}ms. A descendant may still hold a pipe handle."
  }
  return [pscustomobject]@{
    Completed = $completed
    StdOut    = $stdout
    StdErr    = $stderr
    Error     = $streamError
  }
}

function Invoke-Iperf3NativeProcess {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)]
    [string]$FilePath,
    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [string[]]$Arguments,
    [Parameter(Mandatory)]
    [ValidateRange(1, 3660000)]
    [int]$TimeoutMs,
    [ValidateRange(1, 30000)]
    [int]$TerminationGracePeriodMs = 5000,
    [ValidateRange(1, 30000)]
    [int]$StreamDrainTimeoutMs = 1000,
    [string]$CancellationFile = $env:NETWORK_LANTERN_IPERF3_CANCEL_FILE,
    [string]$CancellationRunId = $env:NETWORK_LANTERN_IPERF3_CANCEL_RUN_ID,
    [string]$CancellationNonce = $env:NETWORK_LANTERN_IPERF3_CANCEL_NONCE,
    [ValidateRange(10, 1000)]
    [int]$CancellationPollIntervalMs = 100
  )
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FilePath
  $Arguments | ForEach-Object { $psi.ArgumentList.Add([string]$_) }
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $proc = $null
  try {
    $proc = [System.Diagnostics.Process]::Start($psi)
    if (-not $proc) { throw "Failed to start native process: $FilePath" }
    $processId = $proc.Id
    # Start both readers before waiting so neither redirected pipe can fill.
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $cancelled = $false
    $hasCancellationContract = -not [string]::IsNullOrWhiteSpace($CancellationFile) -and
      $CancellationRunId -match '^[a-fA-F0-9]{32}$' -and
      $CancellationNonce -match '^[a-fA-F0-9]{32}$'
    $expectedCancellationContent = if ($hasCancellationContract) {
      "NETWORK-LANTERN-IPERF3-CANCEL/1:${CancellationRunId}:${CancellationNonce}"
    } else { $null }
    if (-not $hasCancellationContract) {
      $completed = $proc.WaitForExit($timeoutMs)
    }
    else {
      $completed = $false
      $waitStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
      while (-not $completed -and $waitStopwatch.ElapsedMilliseconds -lt $TimeoutMs) {
        try {
          try {
            $signalContent = Read-Iperf3BoundedTextFile -Path $CancellationFile -MaxBytes $script:Iperf3CancellationSignalMaxBytes -ArtifactDescription 'iperf3 cancellation signal'
            if ([string]::Equals($signalContent, $expectedCancellationContent, [StringComparison]::Ordinal)) {
              $cancelled = $true
              break
            }
            Write-Verbose "Ignoring foreign or stale iperf3 cancellation signal for run '$CancellationRunId'."
          }
          catch [System.IO.FileNotFoundException] { $null = $null } # Absence is the normal no-cancellation state.
          catch [System.IO.DirectoryNotFoundException] { $null = $null } # The temporary directory may disappear between polls.
          catch [System.IO.InvalidDataException] {
            Write-Verbose "Ignoring oversized iperf3 cancellation signal for run '$CancellationRunId'."
          }
        }
        catch {
          Write-Verbose "Could not inspect iperf3 cancellation signal '$CancellationFile': $($_.Exception.Message)"
        }
        $remainingMs = $TimeoutMs - [int]$waitStopwatch.ElapsedMilliseconds
        $waitSliceMs = [math]::Min($CancellationPollIntervalMs, [math]::Max($remainingMs, 1))
        $completed = $proc.WaitForExit($waitSliceMs)
      }
      $waitStopwatch.Stop()
    }
    $timedOut = (-not $completed -and -not $cancelled)
    $terminationSucceeded = $null
    $terminationError = $null
    $rootExited = [bool]$proc.HasExited
    $treeTerminationVerified = $false
    $terminationScope = 'NotRequested'
    $descendantProcessIds = [int[]]@()
    $unterminatedProcessIds = [int[]]@()
    if ($timedOut -or $cancelled) {
      $termination = Stop-Iperf3ProcessAfterTimeout -Process $proc -GracePeriodMs $TerminationGracePeriodMs
      $terminationSucceeded = [bool]$termination.TerminationSucceeded
      $terminationError = $termination.Error
      $rootExited = [bool]$termination.RootExited
      $treeTerminationVerified = [bool]$termination.TreeTerminationVerified
      $terminationScope = [string]$termination.TerminationScope
      $descendantProcessIds = [int[]]@($termination.DescendantProcessIds)
      $unterminatedProcessIds = [int[]]@($termination.UnterminatedProcessIds)
    }
    $rootExited = [bool]$proc.HasExited
    $exitCode = if ($rootExited) { $proc.ExitCode } else { -1 }
    # A normally exited root can still have a descendant holding inherited pipe
    # handles. Drain only within a fixed budget and never await these tasks later.
    $streamResult = Get-Iperf3CompletedStreamText -StdOutTask $stdoutTask -StdErrTask $stderrTask -TimeoutMs $StreamDrainTimeoutMs
    return [pscustomobject]@{
      ExitCode             = $exitCode
      StdOut               = $streamResult.StdOut
      StdErr               = $streamResult.StdErr
      StreamsCompleted     = [bool]$streamResult.Completed
      StreamReadError      = $streamResult.Error
      TimedOut             = $timedOut
      Cancelled            = $cancelled
      TerminationSucceeded = $terminationSucceeded
      TerminationError     = $terminationError
      RootExited           = $rootExited
      TreeTerminationVerified = $treeTerminationVerified
      TerminationScope     = $terminationScope
      DescendantProcessIds = $descendantProcessIds
      UnterminatedProcessIds = $unterminatedProcessIds
      ProcessId            = $processId
      CancellationRunId    = $CancellationRunId
    }
  }
  finally {
    if ($proc) { $proc.Dispose() }
  }
}
