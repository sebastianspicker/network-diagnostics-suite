Set-StrictMode -Version Latest

BeforeAll {
  $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  $script:ModuleManifest = Join-Path $script:RepoRoot 'src/powershell/throughput/NetworkLantern.Throughput.psd1'
  Import-Module $script:ModuleManifest -Force
}

Describe 'NetworkLantern.Throughput public boundaries' {
  It 'exports exactly the manifest contract' {
    $expected = @(
      'Compare-Iperf3Runs', 'Get-Iperf3ProfileNames', 'Get-Iperf3ProfileParameters',
      'Get-NetworkThroughputDefaultParameterSet', 'Measure-NetworkThroughput',
      'Remove-Iperf3Profile', 'Save-Iperf3Profile'
    )
    (Get-Module NetworkLantern.Throughput).ExportedCommands.Keys | Sort-Object | Should -Be $expected
  }

  It 'keeps WhatIf free of output-directory writes' {
    $outDir = Join-Path $TestDrive 'whatif-output'
    $result = Measure-NetworkThroughput -Target 'example.local' -OutDir $outDir -WhatIf -PassThru -Quiet
    $result.Mode | Should -Be 'WhatIf'
    Test-Path -LiteralPath $outDir | Should -BeFalse
  }

  It 'persists profiles atomically and fails closed while the sidecar is locked' {
    InModuleScope 'NetworkLantern.Throughput' {
      $profilesFile = Join-Path $TestDrive 'profiles.json'
      $null = Save-Iperf3Profile -ProfileName 'lab' -ProfilesFile $profilesFile -Parameters @{ Target = 'example.local'; Port = 5201 } -StrictConfiguration
      (Get-Content -LiteralPath $profilesFile -Raw | ConvertFrom-Json).profiles.lab.Port | Should -Be 5201

      $lock = [IO.File]::Open("$profilesFile.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
      $oldTimeout = $script:ExclusiveFileLockTimeoutMs
      $oldDelay = $script:ExclusiveFileLockRetryDelayMs
      try {
        $script:ExclusiveFileLockTimeoutMs = 60
        $script:ExclusiveFileLockRetryDelayMs = 10
        { Save-Iperf3Profile -ProfileName 'blocked' -ProfilesFile $profilesFile -Parameters @{ Target = 'example.local' } } | Should -Throw '*lock deadline*'
      }
      finally {
        $script:ExclusiveFileLockTimeoutMs = $oldTimeout
        $script:ExclusiveFileLockRetryDelayMs = $oldDelay
        $lock.Dispose()
      }
    }
  }
}

Describe 'Throughput application adapters' {
  It 'maps configuration-boundary errors to the documented input exit code' {
    $cli = Join-Path $script:RepoRoot 'apps/throughput/Measure-NetworkThroughput.ps1'
    Push-Location $TestDrive
    try {
      $null = & pwsh -NoProfile -NonInteractive -File $cli -ConfigurationPath '../outside.json' -Quiet 2>&1
      $LASTEXITCODE | Should -Be 11
    }
    finally { Pop-Location }
  }

  It 'rejects a relative configuration path that reaches outside cwd through a symbolic link' {
    $cli = Join-Path $script:RepoRoot 'apps/throughput/Measure-NetworkThroughput.ps1'
    $outside = Join-Path (Split-Path -Parent $TestDrive) ("throughput-config-outside-" + [guid]::NewGuid().ToString('N'))
    $link = Join-Path $TestDrive 'config-link'
    try {
      $null = New-Item -ItemType Directory -Path $outside -Force
      Set-Content -LiteralPath (Join-Path $outside 'config.json') -Value '{"Target":"example.local"}' -NoNewline
      try {
        $null = New-Item -ItemType SymbolicLink -Path $link -Target $outside -ErrorAction Stop
      }
      catch {
        Set-ItResult -Skipped -Because "Symbolic links are unavailable: $($_.Exception.Message)"
        return
      }
      Push-Location $TestDrive
      try {
        $null = & pwsh -NoProfile -NonInteractive -File $cli -ConfigurationPath 'config-link/config.json' -Quiet 2>&1
        $LASTEXITCODE | Should -Be 11
      }
      finally { Pop-Location }
    }
    finally {
      Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $outside -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'rejects relative profile writes through an ancestor or preplanted target symbolic link' {
    $outside = Join-Path (Split-Path -Parent $TestDrive) ("throughput-profile-outside-" + [guid]::NewGuid().ToString('N'))
    $ancestorLink = Join-Path $TestDrive 'profiles-link'
    $targetLink = Join-Path $TestDrive 'profiles-target-link.json'
    $outsideTarget = Join-Path $outside 'preplanted.json'
    try {
      $null = New-Item -ItemType Directory -Path $outside -Force
      try {
        $null = New-Item -ItemType SymbolicLink -Path $ancestorLink -Target $outside -ErrorAction Stop
        Set-Content -LiteralPath $outsideTarget -Value '{"version":1,"profiles":{}}' -NoNewline
        $null = New-Item -ItemType SymbolicLink -Path $targetLink -Target $outsideTarget -ErrorAction Stop
      }
      catch {
        Set-ItResult -Skipped -Because "Symbolic links are unavailable: $($_.Exception.Message)"
        return
      }
      Push-Location $TestDrive
      try {
        InModuleScope 'NetworkLantern.Throughput' {
          { Save-Iperf3Profile -ProfileName 'lab' -ProfilesFile 'profiles-link/profiles.json' -Parameters @{ Target = 'example.local' } -StrictConfiguration } | Should -Throw '*symbolic link or reparse point*'
          { Save-Iperf3Profile -ProfileName 'lab' -ProfilesFile 'profiles-target-link.json' -Parameters @{ Target = 'example.local' } -StrictConfiguration } | Should -Throw '*symbolic link or reparse point*'
        }
      }
      finally { Pop-Location }
      Test-Path -LiteralPath (Join-Path $outside 'profiles.json') | Should -BeFalse
      Get-Content -LiteralPath $outsideTarget -Raw | Should -Be '{"version":1,"profiles":{}}'
    }
    finally {
      Remove-Item -LiteralPath $ancestorLink -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $targetLink -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $outside -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'revalidates a parent created after relative profile resolution before writing a lock or profile outside cwd' {
    $outside = Join-Path (Split-Path -Parent $TestDrive) ("throughput-swap-outside-" + [guid]::NewGuid().ToString('N'))
    $lateParent = Join-Path $TestDrive 'late-parent'
    try {
      $null = New-Item -ItemType Directory -Path $outside -Force
      Push-Location $TestDrive
      try {
        InModuleScope -ModuleName 'NetworkLantern.Throughput' -Parameters @{ LateParent = $lateParent; Outside = $outside } -ScriptBlock {
          param($LateParent, $Outside)
          if (Test-Iperf3ProcessIsElevated) {
            { Resolve-ProfilesFilePath -ProfilesFile 'late-parent/profiles.json' } | Should -Throw '*refused when the process is elevated*'
            return
          }
          $resolved = Resolve-ProfilesFilePath -ProfilesFile 'late-parent/profiles.json'
          $null = New-Item -ItemType SymbolicLink -Path $LateParent -Target $Outside -ErrorAction Stop
          { Invoke-LockedProfileOperation -Resolution $resolved -Operation { param($store) $store } -StrictConfiguration } | Should -Throw '*symbolic link or reparse point*'
        }
      }
      catch {
        if ($_.Exception.Message -match 'Symbolic links are unavailable|A parameter cannot be found') {
          Set-ItResult -Skipped -Because "Symbolic links are unavailable: $($_.Exception.Message)"
        }
        else { throw }
      }
      finally { Pop-Location }
      Test-Path -LiteralPath (Join-Path $outside 'profiles.json') | Should -BeFalse
      Test-Path -LiteralPath (Join-Path $outside 'profiles.json.lock') | Should -BeFalse
    }
    finally {
      Remove-Item -LiteralPath $lateParent -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $outside -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'rejects an oversized configuration before JSON parsing' {
    $cli = Join-Path $script:RepoRoot 'apps/throughput/Measure-NetworkThroughput.ps1'
    $configPath = Join-Path $TestDrive 'oversized-config.json'
    Set-Content -LiteralPath $configPath -Value (' ' * (1MB + 1)) -NoNewline
    Push-Location $TestDrive
    try {
      $null = & pwsh -NoProfile -NonInteractive -File $cli -ConfigurationPath 'oversized-config.json' -Quiet 2>&1
      $LASTEXITCODE | Should -Be 11
    }
    finally { Pop-Location }
  }

  It 'maps profile deletion input and store failures to documented exit codes' {
    $cli = Join-Path $script:RepoRoot 'apps/throughput/Measure-NetworkThroughput.ps1'
    Push-Location $TestDrive
    try {
      $null = & pwsh -NoProfile -NonInteractive -File $cli -DeleteProfile 'lab' -ProfilesFile '../outside.json' -Quiet 2>&1
      $LASTEXITCODE | Should -Be 11

      $invalidStore = Join-Path $TestDrive 'invalid-profiles.json'
      Set-Content -LiteralPath $invalidStore -Value '{not json' -NoNewline
      $null = & pwsh -NoProfile -NonInteractive -File $cli -DeleteProfile 'lab' -ProfilesFile $invalidStore -StrictConfiguration -Quiet 2>&1
      $LASTEXITCODE | Should -Be 12
    }
    finally { Pop-Location }
  }

  It 'rejects an oversized profiles store from the opened bounded handle' {
    $profilesFile = Join-Path $TestDrive 'oversized-profiles.json'
    Set-Content -LiteralPath $profilesFile -Value (' ' * (1MB + 1)) -NoNewline
    { Save-Iperf3Profile -ProfileName 'lab' -ProfilesFile $profilesFile -Parameters @{ Target = 'example.local' } -StrictConfiguration } | Should -Throw '*exceeds maximum size*'
  }

  It 'accepts only its nonce-bound GUI cancellation signal and verified terminal cleanup record' {
    . (Join-Path $script:RepoRoot 'apps/throughput/Private/GuiRunLifecycle.ps1')
    $context = New-RunCancellationContext
    $job = $null
    try {
      $context.RunId | Should -Match '^[a-f0-9]{32}$'
      $context.Nonce | Should -Match '^[a-f0-9]{32}$'
      Set-RunCancellationSignal -CancellationContext $context
      [IO.File]::ReadAllText($context.CancellationFile) | Should -Be $context.ExpectedSignalContent
      [IO.File]::WriteAllText($context.CancellationFile, 'foreign')
      { Set-RunCancellationSignal -CancellationContext $context } | Should -Throw '*foreign content*'
      [IO.File]::WriteAllText($context.CancellationFile, ('x' * 513))
      { Set-RunCancellationSignal -CancellationContext $context } | Should -Throw '*exceeds maximum size*'

      $identity = Get-ValidatedRunWorkerIdentity -CancellationContext $context -StartedRecords @(
        [pscustomobject]@{
          RecordType = 'NetworkLantern.Iperf3.JobStarted'; Version = 1; RunId = $context.RunId
          WorkerProcessId = 42; WorkerStartTimeUtc = '2026-08-28T12:00:00.0000000Z'
        }
      )
      $identity.ProcessId | Should -Be 42
      $identity.WorkerStartTimeUtc.ToString('o') | Should -Be '2026-08-28T12:00:00.0000000Z'

      $job = Start-Job -ScriptBlock { throw 'fixture worker failure' }
      $null = Wait-Job -Job $job -Timeout 5
      $terminal = [pscustomobject]@{
        RecordType = 'NetworkLantern.Iperf3.JobTerminal'; Version = 1; RunId = $context.RunId
        Outcome = 'Cancelled'; CleanupStatus = 'Verified'; RootExited = $true
        TreeTerminationVerified = $true; StreamsCompleted = $true; TerminationScope = 'TrackedProcessTree'
      }
      (Get-VerifiedRunCleanupRecord -Job $job -CancellationContext $context -TerminalRecords @($terminal)).CleanupStatus | Should -Be 'Verified'
      $terminal.StreamsCompleted = $false
      Get-VerifiedRunCleanupRecord -Job $job -CancellationContext $context -TerminalRecords @($terminal) | Should -BeNullOrEmpty
    }
    finally {
      if ($job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
      Remove-Item -LiteralPath $context.CancellationFile -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe 'NetworkLantern.Throughput core behavior with controlled process and result fixtures' {
  It 'captures native process output, stderr, and nonzero exit status within its timeout' {
    InModuleScope 'NetworkLantern.Throughput' {
      $pwshPath = (Get-Process -Id $PID).Path
      $result = Invoke-Iperf3NativeProcess -FilePath $pwshPath -Arguments @('-NoProfile', '-NonInteractive', '-Command', '[Console]::Out.Write("fixture-out"); [Console]::Error.Write("fixture-err"); exit 7') -TimeoutMs 5000
      $result.ExitCode | Should -Be 7
      $result.StdOut | Should -Be 'fixture-out'
      $result.StdErr | Should -Be 'fixture-err'
      $result.TimedOut | Should -BeFalse
      $result.StreamsCompleted | Should -BeTrue
    }
  }

  It 'terminates a timed-out native process and verifies stream and process cleanup' {
    InModuleScope 'NetworkLantern.Throughput' {
      $pwshPath = (Get-Process -Id $PID).Path
      $result = Invoke-Iperf3NativeProcess -FilePath $pwshPath -Arguments @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 10') -TimeoutMs 100 -TerminationGracePeriodMs 2000 -StreamDrainTimeoutMs 2000
      $result.TimedOut | Should -BeTrue
      $result.Cancelled | Should -BeFalse
      $result.TerminationSucceeded | Should -BeTrue
      $result.RootExited | Should -BeTrue
      $result.TreeTerminationVerified | Should -BeTrue
      $result.StreamsCompleted | Should -BeTrue
      { Get-Process -Id $result.ProcessId -ErrorAction Stop } | Should -Throw
    }
  }

  It 'retries only a transient iperf3 failure and persists the successful retry result' {
    InModuleScope 'NetworkLantern.Throughput' {
      $oldRetryCount = $script:ActiveRetryCount
      $oldRetryDelay = $script:RetryDelayMs
      try {
        $script:ActiveRetryCount = 1
        $script:RetryDelayMs = 1
        $script:retryFixtureCalls = 0
        $successfulJson = ConvertFrom-Json -InputObject '{"end":{"sum_sent":{"bits_per_second":2000000,"retransmits":0},"sum_received":{"bits_per_second":1500000}}}'
        Mock Invoke-Iperf3 {
          $script:retryFixtureCalls++
          if ($script:retryFixtureCalls -eq 1) {
            return [pscustomobject]@{ ExitCode = 1; Json = $null; JsonParseError = $null; Args = @(); RawText = 'connection refused'; DurationMs = 1 }
          }
          return [pscustomobject]@{ ExitCode = 0; Json = $successfulJson; JsonParseError = $null; Args = @(); RawText = 'fixture json'; DurationMs = 1 }
        }
        $results = [System.Collections.Generic.List[object]]::new()
        $csvRows = [System.Collections.Generic.List[object]]::new()
        $null = Invoke-SingleIperf3TestAndAddResult -AllResultsList $results -CsvRowsList $csvRows -No 1 -Proto TCP -Dir TX -DSCP CS0 -Tos 0 -Stack IPv4 -Target example.local -Port 5201 -Duration 1 -Omit 0 -ConnectTimeoutMs 1000 -Caps ([pscustomobject]@{ BidirSupported = $true })
        Assert-MockCalled Invoke-Iperf3 -Times 2 -Exactly
        $results.Count | Should -Be 1
        $results[0].ExitCode | Should -Be 0
        $results[0].Metrics.TxMbps | Should -Be 2
      }
      finally {
        $script:ActiveRetryCount = $oldRetryCount
        $script:RetryDelayMs = $oldRetryDelay
      }
    }
  }

  It 'extracts an iperf3 JSON fixture and shapes TCP metrics' {
    InModuleScope 'NetworkLantern.Throughput' {
      $fixture = 'diagnostic prefix {"end":{"sum_sent":{"bits_per_second":2500000,"retransmits":3},"sum_received":{"bits_per_second":1750000}}} diagnostic suffix'
      $json = Get-JsonSubstringOrNull -Text $fixture
      $metrics = Get-Iperf3Metric -Json (ConvertFrom-Json -InputObject $json) -Proto TCP -Dir TX
      $metrics.TxMbps | Should -Be 2.5
      $metrics.RxMbps | Should -Be 1.75
      $metrics.Retr | Should -Be 3
    }
  }

  It 'accepts prefixed iperf3 JSON and reports malformed successful output as a parse failure' {
    InModuleScope 'NetworkLantern.Throughput' {
      $pwshPath = (Get-Process -Id $PID).Path
      $caps = [pscustomobject]@{ BidirSupported = $true; VersionText = 'fixture' }
      $prefixedCommand = '$payload = @{ end = @{ sum_sent = @{ bits_per_second = 2500000; retransmits = 3 }; sum_received = @{ bits_per_second = 1750000 } } } | ConvertTo-Json -Compress; [Console]::Out.Write("diagnostic prefix " + $payload + " diagnostic suffix")'
      $prefixed = Invoke-Iperf3 -Server example.local -Port 5201 -Stack IPv4 -Duration 1 -Omit 0 -Proto TCP -Dir TX -Caps $caps -Iperf3Path $pwshPath -NativeArgumentsOverride @('-NoProfile', '-NonInteractive', '-Command', $prefixedCommand)
      $prefixed.ExitCode | Should -Be 0
      $prefixed.Json.end.sum_sent.bits_per_second | Should -Be 2500000
      $prefixed.JsonParseError | Should -BeNullOrEmpty

      $malformed = Invoke-Iperf3 -Server example.local -Port 5201 -Stack IPv4 -Duration 1 -Omit 0 -Proto TCP -Dir TX -Caps $caps -Iperf3Path $pwshPath -NativeArgumentsOverride @('-NoProfile', '-NonInteractive', '-Command', '[Console]::Out.Write("diagnostic prefix {not json}")')
      $malformed.ExitCode | Should -Be 0
      $malformed.Json | Should -BeNullOrEmpty
      $malformed.JsonParseError | Should -Be 'iperf3 JSON output was not found.'
    }
  }

  It 'returns exact public WhatIf plan cardinality for a mixed matrix and a single UDP test' {
    InModuleScope 'NetworkLantern.Throughput' {
      Mock Get-Iperf3Capability { [pscustomobject]@{ VersionText = 'iperf 3.15'; Major = 3; Minor = 15; BidirSupported = $true } }
      $matrix = Measure-NetworkThroughput -Target example.local -Protocol Both -DscpClasses @('CS0', 'EF') -TcpStreams @(1, 4) -TcpWindows @('default', '128K') -UdpStart 1M -UdpMax 3M -UdpStep 1M -WhatIf -PassThru -Quiet
      $matrix.Mode | Should -Be WhatIf
      $matrix.TotalApprox | Should -Be 40

      $single = Measure-NetworkThroughput -Target example.local -Protocol UDP -SingleTest -WhatIf -PassThru -Quiet
      $single.Mode | Should -Be WhatIf
      $single.TotalApprox | Should -Be 1
    }
  }

  It 'shapes a complete result and protects formula-like CSV values' {
    InModuleScope 'NetworkLantern.Throughput' {
      $results = [System.Collections.Generic.List[object]]::new()
      $csvRows = [System.Collections.Generic.List[object]]::new()
      $run = [pscustomobject]@{ ExitCode = 0; Args = @('-c', 'example.local'); RawText = 'fixture'; DurationMs = 15; JsonParseError = $null }
      $metrics = [pscustomobject]@{ TxMbps = 12.5; RxMbps = 11.5; Retr = 0; LossPct = $null; JitterMs = $null }
      Add-Iperf3TestResult -AllResultsList $results -CsvRowsList $csvRows -No 1 -Proto TCP -Dir TX -DSCP '=unsafe' -Tos 0 -Stack IPv4 -Target 'example.local' -Port 5201 -Run $run -Metrics $metrics
      $results.Count | Should -Be 1
      $results[0].MetricError | Should -BeNullOrEmpty
      $csvRows[0].DSCP | Should -Be "'=unsafe"
      $csvRows[0].Duration_ms | Should -Be 15
    }
  }

  It 'upgrades an otherwise successful run to the documented partial-failure exit for threshold breaches' {
    InModuleScope 'NetworkLantern.Throughput' {
      $result = [pscustomobject]@{
        No = 1; Proto = 'UDP'; Dir = 'TX'; DSCP = 'CS0'; ExitCode = 0; JsonParseError = $null; MetricError = $null; RawText = 'fixture'
        Metrics = [pscustomobject]@{ TxMbps = 5.0; RxMbps = 5.0; LossPct = 2.5; JitterMs = 2.0 }
      }
      $summary = Build-RunSummary -Results @($result) -TestCount 1 -ParseErrorCount 0 -Target 'example.local' -Port 5201 -Stack IPv4 -Timestamp 'fixture' -OutDir $TestDrive -ThresholdMinThroughputMbps 10.0 -ThresholdMaxLossPct 1.0 -ThresholdMaxJitterMs 1.0
      $summary.Status | Should -Be 'PartialFailure'
      $summary.ExitCode | Should -Be 14
      $summary.ThresholdBreachCount | Should -Be 1
      @($summary.ThresholdBreaches[0].Reasons).Count | Should -Be 4
    }
  }

  It 'keeps passing threshold runs successful and does not downgrade total failures to threshold results' {
    InModuleScope 'NetworkLantern.Throughput' {
      $passing = [pscustomobject]@{
        No = 1; Proto = 'UDP'; Dir = 'TX'; DSCP = 'CS0'; ExitCode = 0; JsonParseError = $null; MetricError = $null; RawText = 'fixture'
        Metrics = [pscustomobject]@{ TxMbps = 20.0; RxMbps = 20.0; LossPct = 0.5; JitterMs = 0.5 }
      }
      $passingSummary = Build-RunSummary -Results @($passing) -TestCount 1 -ParseErrorCount 0 -Target example.local -Port 5201 -Stack IPv4 -Timestamp fixture -OutDir $TestDrive -ThresholdMinThroughputMbps 10 -ThresholdMaxLossPct 1 -ThresholdMaxJitterMs 1
      $passingSummary.Status | Should -Be Success
      $passingSummary.ExitCode | Should -Be 0
      $passingSummary.ThresholdBreachCount | Should -Be 0

      $failed = [pscustomobject]@{
        No = 1; Proto = 'UDP'; Dir = 'TX'; DSCP = 'CS0'; ExitCode = 1; JsonParseError = $null; MetricError = $null; RawText = 'fixture'
        Metrics = [pscustomobject]@{ TxMbps = 0.1; RxMbps = 0.1; LossPct = 99.0; JitterMs = 99.0 }
      }
      $failedSummary = Build-RunSummary -Results @($failed) -TestCount 1 -ParseErrorCount 0 -Target example.local -Port 5201 -Stack IPv4 -Timestamp fixture -OutDir $TestDrive -ThresholdMinThroughputMbps 10 -ThresholdMaxLossPct 1 -ThresholdMaxJitterMs 1
      $failedSummary.Status | Should -Be TotalFailure
      $failedSummary.ExitCode | Should -Be 15
      $failedSummary.ThresholdBreachCount | Should -Be 0
    }
  }
}

Describe 'NetworkLantern.Throughput artifact and profile behavior' {
  It 'preserves default, relative, and explicit-absolute profile provenance at elevation time' {
    Push-Location $TestDrive
    try {
      InModuleScope 'NetworkLantern.Throughput' {
        Mock Test-Iperf3ProcessIsElevated { $true }
        { Get-Iperf3ProfileNames } | Should -Throw '*Default profile paths are refused when the process is elevated*'
        { Get-Iperf3ProfileNames -ProfilesFile 'relative/profiles.json' } | Should -Throw '*Relative profile paths are refused when the process is elevated*'
        { Remove-Iperf3Profile -ProfileName 'missing' -Confirm:$false } | Should -Throw '*Default profile paths are refused when the process is elevated*'
        { Remove-Iperf3Profile -ProfileName 'missing' -ProfilesFile 'relative/profiles.json' -Confirm:$false } | Should -Throw '*Relative profile paths are refused when the process is elevated*'

        $defaultLocation = Get-DefaultProfilesFilePath
        { Resolve-ProfilesFilePath -ProfilesFile $defaultLocation -Provenance Default } | Should -Throw '*Default profile paths are refused when the process is elevated*'
        $defaultLocationSave = Save-Iperf3Profile -ProfileName 'explicit-default' -ProfilesFile $defaultLocation -Parameters @{ Target = 'example.local' }
        $defaultLocationSave.ProfilesFile | Should -Be $defaultLocation
        (Remove-Iperf3Profile -ProfileName 'explicit-default' -ProfilesFile $defaultLocation -Confirm:$false) | Should -BeTrue

        $explicit = Join-Path $TestDrive 'operator-selected-profiles.json'
        $saved = Save-Iperf3Profile -ProfileName 'operator' -ProfilesFile $explicit -Parameters @{ Target = 'example.local' }
        $saved.ProfilesFile | Should -Be $explicit
        @(Get-Iperf3ProfileNames -ProfilesFile $explicit) | Should -Be @('operator')
      }
    }
    finally { Pop-Location }
  }

  It 'rechecks captured default provenance at operation time through Measure-NetworkThroughput' {
    InModuleScope 'NetworkLantern.Throughput' {
      $script:elevationChecks = 0
      Mock Test-Iperf3ProcessIsElevated { $script:elevationChecks++; return ($script:elevationChecks -gt 1) }
      { Measure-NetworkThroughput -ListProfiles -PassThru -Quiet } | Should -Throw '*Default profile paths are refused when the process is elevated*'

      $script:elevationChecks = 0
      { Measure-NetworkThroughput -ProfileName 'missing' -WhatIf -PassThru -Quiet } | Should -Throw '*Default profile paths are refused when the process is elevated*'

      $script:elevationChecks = 0
      { Measure-NetworkThroughput -Target 'example.local' -ProfileName 'late' -SaveProfile -WhatIf -PassThru -Quiet } | Should -Throw '*Default profile paths are refused when the process is elevated*'
    }
  }

  It 'provides complete public profile CRUD without retaining removed values' {
    $profilesFile = Join-Path $TestDrive 'profiles.json'
    $saved = Save-Iperf3Profile -ProfileName lab -ProfilesFile $profilesFile -Parameters @{ Target = 'example.local'; Port = 5201; Protocol = 'TCP' } -StrictConfiguration
    $saved.ProfileName | Should -Be lab
    @(Get-Iperf3ProfileNames -ProfilesFile $profilesFile -StrictConfiguration) | Should -Be @('lab')
    $parameters = Get-Iperf3ProfileParameters -ProfileName lab -ProfilesFile $profilesFile -StrictConfiguration
    $parameters.Target | Should -Be example.local
    $parameters.Port | Should -Be 5201
    (Remove-Iperf3Profile -ProfileName lab -ProfilesFile $profilesFile -Confirm:$false -StrictConfiguration) | Should -BeTrue
    @(Get-Iperf3ProfileNames -ProfilesFile $profilesFile -StrictConfiguration).Count | Should -Be 0
    (Remove-Iperf3Profile -ProfileName lab -ProfilesFile $profilesFile -Confirm:$false -StrictConfiguration) | Should -BeFalse
  }

  It 'fails closed for corrupt profiles in strict mode and recovers them in non-strict mode' {
    $profilesFile = Join-Path $TestDrive 'corrupt-profiles.json'
    Set-Content -LiteralPath $profilesFile -Value '{not json' -NoNewline
    $errorRecord = $null
    try { Get-Iperf3ProfileNames -ProfilesFile $profilesFile -StrictConfiguration | Out-Null }
    catch { $errorRecord = $_ }
    (($errorRecord.FullyQualifiedErrorId -split ',')[0]) | Should -Be 'NetworkLantern.Throughput.Prerequisite'
    @(Get-Iperf3ProfileNames -ProfilesFile $profilesFile).Count | Should -Be 0
    $null = Save-Iperf3Profile -ProfileName recovered -ProfilesFile $profilesFile -Parameters @{ Target = 'example.local'; Port = 5201 }
    (Get-Iperf3ProfileParameters -ProfileName recovered -ProfilesFile $profilesFile).Port | Should -Be 5201
  }

  It 'compares public run summaries by status, elapsed time, and count deltas' {
    $baselinePath = Join-Path $TestDrive 'baseline.json'
    $currentPath = Join-Path $TestDrive 'current.json'
    [ordered]@{ Status = 'Success'; Counts = [ordered]@{ Failed = 0; Total = 2 }; Timestamp = '2026-08-28T10:00:00Z'; ElapsedSeconds = 2.5 } | ConvertTo-Json | Set-Content -LiteralPath $baselinePath -Encoding UTF8 -NoNewline
    [ordered]@{ Status = 'PartialFailure'; Counts = [ordered]@{ Failed = 2; Total = 4 }; Timestamp = '2026-08-28T10:05:00Z'; ElapsedSeconds = 4.5 } | ConvertTo-Json | Set-Content -LiteralPath $currentPath -Encoding UTF8 -NoNewline
    $comparison = Compare-Iperf3Runs -BaselinePath $baselinePath -CurrentPath $currentPath
    $comparison.StatusChanged | Should -BeTrue
    $comparison.FailedDelta | Should -Be 2
    $comparison.TotalDelta | Should -Be 2
    $comparison.BaselineElapsed | Should -Be 2.5
    $comparison.CurrentElapsed | Should -Be 4.5
  }

  It 'uses bounded same-handle reads for comparison summaries at the exact limit and limit plus one' {
    $baselinePath = Join-Path $TestDrive 'bounded-baseline.json'
    $currentPath = Join-Path $TestDrive 'bounded-current.json'
    $summary = '{"Status":"Success","Counts":{"Failed":0,"Total":1},"Timestamp":"2026-08-28T10:00:00Z","ElapsedSeconds":1}'
    $exact = $summary + (' ' * ((1MB) - [Text.Encoding]::UTF8.GetByteCount($summary)))
    Set-Content -LiteralPath $baselinePath -Value $exact -Encoding UTF8 -NoNewline
    Set-Content -LiteralPath $currentPath -Value $summary -Encoding UTF8 -NoNewline
    (Compare-Iperf3Runs -BaselinePath $baselinePath -CurrentPath $currentPath).TotalDelta | Should -Be 0
    Set-Content -LiteralPath $baselinePath -Value ($exact + 'x') -Encoding UTF8 -NoNewline
    { Compare-Iperf3Runs -BaselinePath $baselinePath -CurrentPath $currentPath } | Should -Throw '*exceeds maximum size*'
  }

  It 'opens comparison artifacts directly instead of trusting pre-open metadata during replacement races' {
    InModuleScope 'NetworkLantern.Throughput' {
      $baselinePath = Join-Path $TestDrive 'replacement-baseline.json'
      $currentPath = Join-Path $TestDrive 'replacement-current.json'
      $summary = '{"Status":"Success","Counts":{"Failed":0,"Total":1},"Timestamp":"2026-08-28T10:00:00Z","ElapsedSeconds":1}'
      Set-Content -LiteralPath $baselinePath -Value $summary -Encoding UTF8 -NoNewline
      Set-Content -LiteralPath $currentPath -Value $summary -Encoding UTF8 -NoNewline
      Mock Test-Path { throw 'comparison must not trust a pre-open path check' }
      (Compare-Iperf3Runs -BaselinePath $baselinePath -CurrentPath $currentPath).TotalDelta | Should -Be 0
      Should -Invoke -CommandName Test-Path -Exactly 0
    }
  }

  It 'fails closed or starts fresh from bounded malformed run-index handles' {
    InModuleScope 'NetworkLantern.Throughput' {
      $summary = [pscustomobject]@{ Timestamp = '2026-08-28T10:00:00Z'; Status = 'Success'; ExitCode = 0; Target = 'example.local'; Port = 5201; Stack = 'IPv4' }
      $indexPath = Join-Path $TestDrive 'iperf3_run_index.json'
      try {
        Set-Content -LiteralPath $indexPath -Value '{malformed' -Encoding UTF8 -NoNewline
        $written = Write-Iperf3RunIndex -OutDir $TestDrive -RunSummary $summary -CsvPath 'x.csv' -JsonPath 'x.json' -SummaryJsonPath 'x-summary.json' -ReportMdPath 'x.md'
        @((Get-Content -LiteralPath $written -Raw | ConvertFrom-Json).runs).Count | Should -Be 1

        $oversized = '{"runs":[]}' + (' ' * ((1MB) - [Text.Encoding]::UTF8.GetByteCount('{"runs":[]}') + 1))
        Set-Content -LiteralPath $indexPath -Value $oversized -Encoding UTF8 -NoNewline
        $written = Write-Iperf3RunIndex -OutDir $TestDrive -RunSummary $summary -CsvPath 'x.csv' -JsonPath 'x.json' -SummaryJsonPath 'x-summary.json' -ReportMdPath 'x.md'
        @((Get-Content -LiteralPath $written -Raw | ConvertFrom-Json).runs).Count | Should -Be 1
      }
      finally {
        Remove-Item -LiteralPath $indexPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$indexPath.lock" -Force -ErrorAction SilentlyContinue
      }
    }
  }

  It 'accepts only an exactly bounded nonce cancellation signal from its opened handle' {
    InModuleScope 'NetworkLantern.Throughput' {
      $signal = Join-Path $TestDrive 'bounded-cancel.signal'
      $runId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
      $nonce = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
      $expected = "NETWORK-LANTERN-IPERF3-CANCEL/1:${runId}:${nonce}"
      Set-Content -LiteralPath $signal -Value $expected -Encoding UTF8 -NoNewline
      $pwshPath = (Get-Process -Id $PID).Path
      $valid = Invoke-Iperf3NativeProcess -FilePath $pwshPath -Arguments @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 2') -TimeoutMs 1000 -CancellationFile $signal -CancellationRunId $runId -CancellationNonce $nonce
      $valid.Cancelled | Should -BeTrue

      Set-Content -LiteralPath $signal -Value ($expected + (' ' * ($script:Iperf3CancellationSignalMaxBytes - [Text.Encoding]::UTF8.GetByteCount($expected)))) -Encoding UTF8 -NoNewline
      $exact = Invoke-Iperf3NativeProcess -FilePath $pwshPath -Arguments @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 2') -TimeoutMs 1000 -CancellationFile $signal -CancellationRunId $runId -CancellationNonce $nonce
      $exact.Cancelled | Should -BeFalse

      Set-Content -LiteralPath $signal -Value ($expected + ('x' * ($script:Iperf3CancellationSignalMaxBytes - [Text.Encoding]::UTF8.GetByteCount($expected) + 1))) -Encoding UTF8 -NoNewline
      $oversized = Invoke-Iperf3NativeProcess -FilePath $pwshPath -Arguments @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 2') -TimeoutMs 100 -CancellationFile $signal -CancellationRunId $runId -CancellationNonce $nonce
      $oversized.Cancelled | Should -BeFalse
    }
  }

  It 'replaces a report JSON with one complete artifact and leaves it parseable' {
    InModuleScope 'NetworkLantern.Throughput' {
      $path = Join-Path $TestDrive 'report.json'
      Set-Content -LiteralPath $path -Value '{"state":"old"}' -NoNewline
      Set-Iperf3JsonFileAtomic -Path $path -InputObject ([pscustomobject]@{ State = 'new'; Count = 2 })
      $persisted = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
      $persisted.State | Should -Be new
      $persisted.Count | Should -Be 2
    }
  }

  It 'writes complete report artifacts and appends a valid run index through the public command' {
    InModuleScope 'NetworkLantern.Throughput' {
      Mock Test-NetworkThroughputPrerequisites {}
      Mock Get-Iperf3Capability { [pscustomobject]@{ VersionText = 'iperf 3.15'; Major = 3; Minor = 15; BidirSupported = $true } }
      Mock Get-TestSuiteConnectivity {
        [pscustomobject]@{
          Stack = 'IPv4'; MtuFails = @()
          Net = [pscustomobject]@{
            Tcp = [pscustomobject]@{ TcpTestSucceeded = $true; RemoteAddress = '127.0.0.1'; PingSucceeded = $true }
            Trace = $null
          }
        }
      }
      Mock Invoke-SingleIperf3TestAndAddResult {
        param($AllResultsList, $CsvRowsList, $No, $Proto, $Dir, $DSCP, $Tos, $Streams, $Window, $UdpBw, $Stack, $Target, $Port)
        $run = [pscustomobject]@{ ExitCode = 0; Args = @(); RawText = 'fixture'; DurationMs = 1; JsonParseError = $null }
        $metrics = [pscustomobject]@{ TxMbps = 10.0; RxMbps = 10.0; Retr = 0; LossPct = $null; JitterMs = $null }
        Add-Iperf3TestResult -AllResultsList $AllResultsList -CsvRowsList $CsvRowsList -No $No -Proto $Proto -Dir $Dir -DSCP $DSCP -Tos $Tos -Streams $Streams -Window $Window -UdpBw $UdpBw -Stack $Stack -Target $Target -Port $Port -Run $run -Metrics $metrics
        return [pscustomobject]@{ Run = $run; Metrics = $metrics }
      }
      $first = Measure-NetworkThroughput -Target example.local -Protocol TCP -SingleTest -SkipReachabilityCheck -DisableMtuProbe -OutDir $TestDrive -PassThru -Quiet
      Start-Sleep -Milliseconds 10
      $second = Measure-NetworkThroughput -Target example.local -Protocol TCP -SingleTest -SkipReachabilityCheck -DisableMtuProbe -OutDir $TestDrive -PassThru -Quiet
      foreach ($run in @($first, $second)) {
        $run.Status | Should -Be Success
        $run.ExitCode | Should -Be 0
        $run.ArtifactStatus.Complete | Should -BeTrue
        $run.Supplemental.SummaryJsonPath | Should -Exist
        $run.Supplemental.ReportMdPath | Should -Exist
        $run.Supplemental.RunIndexPath | Should -Exist
        (Get-Content -LiteralPath $run.Supplemental.SummaryJsonPath -Raw | ConvertFrom-Json).ArtifactStatus.Complete | Should -BeTrue
      }
      $index = Get-Content -LiteralPath $second.Supplemental.RunIndexPath -Raw | ConvertFrom-Json
      @($index.runs).Count | Should -Be 2
      $index.lastRun.status | Should -Be Success
    }
  }
}

Describe 'NetworkLantern.Throughput stable error identities' {
  It 'labels input validation without deriving the category from its message' {
    InModuleScope 'NetworkLantern.Throughput' {
      $errorRecord = $null
      try { Measure-NetworkThroughput -Target 'not a valid hostname!' -WhatIf -Quiet }
      catch { $errorRecord = $_ }
      (($errorRecord.FullyQualifiedErrorId -split ',')[0]) | Should -Be 'NetworkLantern.Throughput.InputValidation'
    }
  }

  It 'labels prerequisite failures at the prerequisite boundary' {
    InModuleScope 'NetworkLantern.Throughput' {
      Mock Test-NetworkThroughputPrerequisites { throw 'fixture wording is not a classifier input' }
      $errorRecord = $null
      try { Measure-NetworkThroughput -Target 'example.local' -SkipReachabilityCheck -DisableMtuProbe -Quiet }
      catch { $errorRecord = $_ }
      (($errorRecord.FullyQualifiedErrorId -split ',')[0]) | Should -Be 'NetworkLantern.Throughput.Prerequisite'
    }
  }

  It 'labels connectivity failures at the connectivity boundary' {
    InModuleScope 'NetworkLantern.Throughput' {
      Mock Test-NetworkThroughputPrerequisites {}
      Mock Get-Iperf3Capability { [pscustomobject]@{ VersionText = 'iperf 3.15'; Major = 3; Minor = 15; BidirSupported = $true } }
      Mock Get-TestSuiteConnectivity { throw 'fixture wording is not a classifier input' }
      $errorRecord = $null
      try { Measure-NetworkThroughput -Target 'example.local' -SkipReachabilityCheck -DisableMtuProbe -OutDir $TestDrive -Force -Quiet }
      catch { $errorRecord = $_ }
      (($errorRecord.FullyQualifiedErrorId -split ',')[0]) | Should -Be 'NetworkLantern.Throughput.Connectivity'
    }
  }

  It 'labels uncategorized implementation failures as internal' {
    InModuleScope 'NetworkLantern.Throughput' {
      Mock Test-NetworkThroughputPrerequisites {}
      Mock Get-Iperf3Capability { [pscustomobject]@{ VersionText = 'iperf 3.15'; Major = 3; Minor = 15; BidirSupported = $true } }
      Mock Build-TestPlan { throw 'fixture wording is not a classifier input' }
      $errorRecord = $null
      try { Measure-NetworkThroughput -Target 'example.local' -SkipReachabilityCheck -DisableMtuProbe -Quiet }
      catch { $errorRecord = $_ }
      (($errorRecord.FullyQualifiedErrorId -split ',')[0]) | Should -Be 'NetworkLantern.Throughput.Internal'
    }
  }
}
