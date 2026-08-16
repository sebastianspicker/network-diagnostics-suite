$ErrorActionPreference = 'Stop'

BeforeAll {
  . (Join-Path (Get-Item $PSScriptRoot).Parent.Parent.FullName 'scripts/Get-RepoRoot.ps1')
  $repoRoot = Get-RepoRoot
  $script:RepoRoot = $repoRoot
  $modulePath = Join-Path $repoRoot 'src/powershell/throughput/NetworkLantern.Throughput.psd1'
  Import-Module $modulePath -Force
  $script:TestCapability = [pscustomobject]@{ VersionText = 'iperf3 3.9'; Major = 3; Minor = 9; BidirSupported = $true }
  $global:NetworkThroughput_TestCapability = $script:TestCapability
  try {
    $global:IsWindows = $true
  } catch {
    Write-Verbose 'On some hosts (e.g. macOS) $IsWindows is read-only; Windows-only tests may fail or be skipped.'
  }
}

Describe 'Network Lantern throughput helpers' {

  Context 'Invoke-Iperf3 args' {
    It 'adds -R for TCP RX' {
      $captured = InModuleScope 'NetworkLantern.Throughput' {
        $script:captured = $null
        $caps = $global:NetworkThroughput_TestCapability
        $runner = { param([string[]]$IperfArgs); $script:captured = $IperfArgs; $global:LASTEXITCODE = 0; return '{"end":{}}' }
        $null = Invoke-Iperf3 -Server 'example' -Port 5201 -Stack 'IPv4' -Duration 1 -Omit 0 -Proto 'TCP' -Dir 'RX' -Caps $caps -Runner $runner
        return $script:captured
      }
      $captured | Should -Contain '-R'
    }

    It 'adds --bidir for TCP BD when supported' {
      $captured = InModuleScope 'NetworkLantern.Throughput' {
        $script:captured = $null
        $caps = $global:NetworkThroughput_TestCapability
        $runner = { param([string[]]$IperfArgs); $script:captured = $IperfArgs; $global:LASTEXITCODE = 0; return '{"end":{}}' }
        $null = Invoke-Iperf3 -Server 'example' -Port 5201 -Stack 'IPv4' -Duration 1 -Omit 0 -Proto 'TCP' -Dir 'BD' -Caps $caps -Runner $runner
        return $script:captured
      }
      $captured | Should -Contain '--bidir'
    }

    It 'adds -u and -b for UDP' {
      $captured = InModuleScope 'NetworkLantern.Throughput' {
        $script:captured = $null
        $caps = $global:NetworkThroughput_TestCapability
        $runner = { param([string[]]$IperfArgs); $script:captured = $IperfArgs; $global:LASTEXITCODE = 0; return '{"end":{}}' }
        $null = Invoke-Iperf3 -Server 'example' -Port 5201 -Stack 'IPv4' -Duration 1 -Omit 0 -Proto 'UDP' -Dir 'TX' -UdpBw '5M' -Caps $caps -Runner $runner
        return $script:captured
      }
      $captured | Should -Contain '-u'
      $captured | Should -Contain '-b'
      $captured | Should -Contain '5M'
    }

    It 'marks a zero-exit run without JSON as a parse failure' {
      InModuleScope 'NetworkLantern.Throughput' {
        $caps = $global:NetworkThroughput_TestCapability
        $runner = {
          param([string[]]$IperfArgs)
          $null = $IperfArgs
          $global:LASTEXITCODE = 0
          return 'iperf3 completed without JSON output'
        }

        $result = Invoke-Iperf3 -Server 'example' -Port 5201 -Stack 'IPv4' -Duration 1 -Omit 0 -Proto 'TCP' -Dir 'TX' -Caps $caps -Runner $runner

        $result.ExitCode | Should -Be 0
        $result.Json | Should -Be $null
        $result.JsonParseError | Should -Match 'JSON output was not found'
      }
    }
  }

  Context 'Invoke-Iperf3 adds -6 for IPv6' {
    It 'adds -6 flag when Stack is IPv6' {
      $captured = InModuleScope 'NetworkLantern.Throughput' {
        $script:captured = $null
        $caps = $global:NetworkThroughput_TestCapability
        $runner = { param([string[]]$IperfArgs); $script:captured = $IperfArgs; $global:LASTEXITCODE = 0; return '{"end":{}}' }
        $null = Invoke-Iperf3 -Server 'example' -Port 5201 -Stack 'IPv6' -Duration 1 -Omit 0 -Proto 'TCP' -Dir 'TX' -Caps $caps -Runner $runner
        return $script:captured
      }
      $captured | Should -Contain '-6'
    }
  }

  Context 'Invoke-Iperf3 returns DurationMs' {
    It 'includes DurationMs in result' {
      InModuleScope 'NetworkLantern.Throughput' {
        $caps = $global:NetworkThroughput_TestCapability
        $runner = { param([string[]]$IperfArgs); $null = $IperfArgs; $global:LASTEXITCODE = 0; return '{"end":{}}' }
        $result = Invoke-Iperf3 -Server 'example' -Port 5201 -Stack 'IPv4' -Duration 1 -Omit 0 -Proto 'TCP' -Dir 'TX' -Caps $caps -Runner $runner
        $result.PSObject.Properties.Name | Should -Contain 'DurationMs'
        $result.DurationMs | Should -BeGreaterOrEqual 0
      }
    }
  }

  Context 'Invoke-Iperf3 native process collection' {
    It 'drains large stdout and stderr streams without deadlocking' {
      InModuleScope 'NetworkLantern.Throughput' {
        $pwshPath = (Get-Process -Id $PID).Path
        $command = "[Console]::Out.Write(('o' * 200000)); [Console]::Error.Write(('e' * 200000))"

        $result = Invoke-Iperf3NativeProcess -FilePath $pwshPath `
          -Arguments @('-NoLogo', '-NoProfile', '-Command', $command) -TimeoutMs 5000

        $result.ExitCode | Should -Be 0
        $result.StreamsCompleted | Should -BeTrue
        $result.StdOut.Length | Should -Be 200000
        $result.StdErr.Length | Should -Be 200000
      }
    }

    It 'terminates a native process that exceeds its deadline' {
      InModuleScope 'NetworkLantern.Throughput' {
        $pwshPath = (Get-Process -Id $PID).Path
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        $result = Invoke-Iperf3NativeProcess -FilePath $pwshPath `
          -Arguments @('-NoLogo', '-NoProfile', '-Command', 'Start-Sleep -Seconds 5') `
          -TimeoutMs 150

        $stopwatch.Stop()
        $result.TimedOut | Should -BeTrue
        $result.TerminationSucceeded | Should -BeTrue
        $result.RootExited | Should -BeTrue
        $result.TreeTerminationVerified | Should -BeTrue
        $result.StreamsCompleted | Should -BeTrue
        $result.ExitCode | Should -Not -Be 0
        $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 3
      }
    }

    It 'reports a timeout termination failure distinctly' {
      InModuleScope 'NetworkLantern.Throughput' {
        $process = [pscustomobject]@{ Id = 4242; HasExited = $false }
        $process | Add-Member -MemberType ScriptMethod -Name Kill -Value {
          param([bool]$entireProcessTree)
          $null = $entireProcessTree
          throw 'access denied'
        }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
          param([int]$milliseconds)
          $null = $milliseconds
          return $false
        }

        $result = Stop-Iperf3ProcessAfterTimeout -Process $process -GracePeriodMs 10

        $result.TerminationSucceeded | Should -BeFalse
        $result.ProcessId | Should -Be 4242
        $result.Error | Should -Match 'access denied'
      }
    }

    It 'does not kill a timed-out process under WhatIf' {
      InModuleScope 'NetworkLantern.Throughput' {
        $script:killCalls = 0
        $process = [pscustomobject]@{ Id = 4243; HasExited = $false }
        $process | Add-Member -MemberType ScriptMethod -Name Kill -Value {
          param([bool]$entireProcessTree)
          $null = $entireProcessTree
          $script:killCalls++
        }
        Mock -CommandName Get-Iperf3DescendantProcessSnapshot {
          [pscustomobject]@{
            Succeeded = $true
            Processes = @()
            ProcessIds = [int[]]@()
            Error = $null
          }
        }

        $result = Stop-Iperf3ProcessAfterTimeout -Process $process -GracePeriodMs 10 -WhatIf 6>$null

        $script:killCalls | Should -Be 0
        $result.TerminationSucceeded | Should -BeFalse
        $result.ProcessId | Should -Be 4243
        $result.UnterminatedProcessIds | Should -Contain 4243
        $result.Error | Should -Be 'Termination skipped by ShouldProcess.'
      }
    }

    It 'does not claim tree cleanup when the root already exited before ownership was established' {
      InModuleScope 'NetworkLantern.Throughput' {
        $process = [pscustomobject]@{ Id = 424242; HasExited = $true }

        $result = Stop-Iperf3ProcessAfterTimeout -Process $process -GracePeriodMs 10

        $result.RootExited | Should -BeTrue
        $result.TerminationSucceeded | Should -BeFalse
        $result.TreeTerminationVerified | Should -BeFalse
        $result.TerminationScope | Should -Be 'RootOnly'
        $result.Error | Should -Match 'cannot be ruled out'
      }
    }

    It 'returns within the drain deadline when an exited root leaves a descendant holding its pipes' {
      InModuleScope 'NetworkLantern.Throughput' {
        $pidFile = Join-Path $TestDrive 'pipe-holder.pid'
        $pidFileBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pidFile))
        $command = @"
`$pidFile = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$pidFileBase64'))
`$psi = [Diagnostics.ProcessStartInfo]::new()
`$psi.FileName = (Get-Process -Id `$PID).Path
`$psi.UseShellExecute = `$false
`$psi.ArgumentList.Add('-NoLogo')
`$psi.ArgumentList.Add('-NoProfile')
`$psi.ArgumentList.Add('-Command')
`$psi.ArgumentList.Add('Start-Sleep -Seconds 30')
`$child = [Diagnostics.Process]::Start(`$psi)
[IO.File]::WriteAllText(`$pidFile, [string]`$child.Id)
"@
        $pwshPath = (Get-Process -Id $PID).Path
        $childProcess = $null
        $processTimeoutMs = 3000
        $streamDrainTimeoutMs = 150
        $maximumExpectedSeconds = ($processTimeoutMs + $streamDrainTimeoutMs + 1000) / 1000
        try {
          $stopwatch = [Diagnostics.Stopwatch]::StartNew()
          $result = Invoke-Iperf3NativeProcess -FilePath $pwshPath `
            -Arguments @('-NoLogo', '-NoProfile', '-Command', $command) `
            -TimeoutMs $processTimeoutMs -StreamDrainTimeoutMs $streamDrainTimeoutMs
          $stopwatch.Stop()

          $result.TimedOut | Should -BeFalse
          $result.RootExited | Should -BeTrue
          $result.StreamsCompleted | Should -BeFalse
          $result.StreamReadError | Should -Match 'descendant may still hold'
          $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan $maximumExpectedSeconds
          $childProcess = Get-Process -Id ([int](Get-Content -LiteralPath $pidFile -Raw)) -ErrorAction Stop
        }
        finally {
          if (-not $childProcess -and (Test-Path -LiteralPath $pidFile -PathType Leaf)) {
            $childProcess = Get-Process -Id ([int](Get-Content -LiteralPath $pidFile -Raw)) -ErrorAction SilentlyContinue
          }
          if ($childProcess -and -not $childProcess.HasExited) {
            $childProcess.Kill($true)
            $null = $childProcess.WaitForExit(2000)
          }
          if ($childProcess) { $childProcess.Dispose() }
        }
      }
    }

    It 'tracks and terminates a live descendant on timeout' {
      InModuleScope 'NetworkLantern.Throughput' {
        $pidFile = Join-Path $TestDrive 'timeout-descendant.pid'
        $pidFileBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pidFile))
        $command = @"
`$pidFile = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$pidFileBase64'))
`$psi = [Diagnostics.ProcessStartInfo]::new()
`$psi.FileName = (Get-Process -Id `$PID).Path
`$psi.UseShellExecute = `$false
`$psi.ArgumentList.Add('-NoLogo')
`$psi.ArgumentList.Add('-NoProfile')
`$psi.ArgumentList.Add('-Command')
`$psi.ArgumentList.Add('Start-Sleep -Seconds 30')
`$child = [Diagnostics.Process]::Start(`$psi)
[IO.File]::WriteAllText(`$pidFile, [string]`$child.Id)
Start-Sleep -Seconds 30
"@
        $pwshPath = (Get-Process -Id $PID).Path
        $result = $null
        $childId = $null
        try {
          $result = Invoke-Iperf3NativeProcess -FilePath $pwshPath `
            -Arguments @('-NoLogo', '-NoProfile', '-Command', $command) `
            -TimeoutMs 5000 -TerminationGracePeriodMs 1500 -StreamDrainTimeoutMs 500

          (Test-Path -LiteralPath $pidFile -PathType Leaf) | Should -BeTrue
          $childId = [int](Get-Content -LiteralPath $pidFile -Raw)
          $result.TerminationSucceeded | Should -BeTrue
          $result.TreeTerminationVerified | Should -BeTrue
          $result.DescendantProcessIds | Should -Contain $childId
          $result.StreamsCompleted | Should -BeTrue
          (Get-Process -Id $childId -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
        }
        finally {
          $cleanupIds = @($childId, $(if ($result) { $result.ProcessId } else { $null })) | Where-Object { $_ }
          foreach ($cleanupId in $cleanupIds) {
            $cleanupProcess = Get-Process -Id $cleanupId -ErrorAction SilentlyContinue
            if ($cleanupProcess) {
              try { $cleanupProcess.Kill($true); $null = $cleanupProcess.WaitForExit(2000) }
              catch { Write-Verbose "Test cleanup could not terminate process $cleanupId." }
              $cleanupProcess.Dispose()
            }
          }
        }
      }
    }

    It 'cancels and terminates the owned native process when signalled' {
      InModuleScope 'NetworkLantern.Throughput' {
        $cancellationFile = Join-Path $TestDrive "iperf3-cancel-$([guid]::NewGuid().ToString('N')).signal"
        $runId = [guid]::NewGuid().ToString('N')
        $nonce = [guid]::NewGuid().ToString('N')
        $cancellationToken = "NETWORK-LANTERN-IPERF3-CANCEL/1:${runId}:${nonce}"
        $previousCancellationFile = [Environment]::GetEnvironmentVariable('NETWORK_LANTERN_IPERF3_CANCEL_FILE', 'Process')
        $previousCancellationRunId = [Environment]::GetEnvironmentVariable('NETWORK_LANTERN_IPERF3_CANCEL_RUN_ID', 'Process')
        $previousCancellationNonce = [Environment]::GetEnvironmentVariable('NETWORK_LANTERN_IPERF3_CANCEL_NONCE', 'Process')
        $cancelJob = $null
        try {
          [Environment]::SetEnvironmentVariable('NETWORK_LANTERN_IPERF3_CANCEL_FILE', $cancellationFile, 'Process')
          [Environment]::SetEnvironmentVariable('NETWORK_LANTERN_IPERF3_CANCEL_RUN_ID', $runId, 'Process')
          [Environment]::SetEnvironmentVariable('NETWORK_LANTERN_IPERF3_CANCEL_NONCE', $nonce, 'Process')
          $cancelJob = Start-Job -ScriptBlock {
            Start-Sleep -Milliseconds 300
            [IO.File]::WriteAllText($args[0], $args[1])
          } -ArgumentList $cancellationFile, $cancellationToken
          $caps = $global:NetworkThroughput_TestCapability
          $pwshPath = (Get-Process -Id $PID).Path
          $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
          $caught = $null

          try {
            $null = Invoke-Iperf3 -Server 'example.local' -Port 5201 -Stack 'IPv4' -Duration 1 -Omit 0 `
              -Proto 'TCP' -Dir 'TX' -Caps $caps -Iperf3Path $pwshPath `
              -NativeArgumentsOverride @('-NoLogo', '-NoProfile', '-Command', 'Start-Sleep -Seconds 30')
          }
          catch {
            $caught = $_
          }
          $stopwatch.Stop()

          $caught | Should -Not -BeNullOrEmpty
          $caught.Exception | Should -BeOfType ([System.OperationCanceledException])
          $caught.Exception.Data['NetworkLantern.RunId'] | Should -Be $runId
          $caught.Exception.Data['NetworkLantern.CleanupVerified'] | Should -BeTrue
          $caught.Exception.Data['NetworkLantern.StreamsCompleted'] | Should -BeTrue
          $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 5
        }
        finally {
          if ($cancelJob) {
            $null = $cancelJob | Wait-Job -Timeout 5
            $null = Receive-Job -Job $cancelJob -ErrorAction SilentlyContinue
            Remove-Job -Job $cancelJob -Force -ErrorAction SilentlyContinue
          }
          [Environment]::SetEnvironmentVariable('NETWORK_LANTERN_IPERF3_CANCEL_FILE', $previousCancellationFile, 'Process')
          [Environment]::SetEnvironmentVariable('NETWORK_LANTERN_IPERF3_CANCEL_RUN_ID', $previousCancellationRunId, 'Process')
          [Environment]::SetEnvironmentVariable('NETWORK_LANTERN_IPERF3_CANCEL_NONCE', $previousCancellationNonce, 'Process')
          Remove-Item -LiteralPath $cancellationFile -Force -ErrorAction SilentlyContinue
        }
      }
    }

    It 'ignores the correct nonce when it belongs to another run identity' {
      InModuleScope 'NetworkLantern.Throughput' {
        $cancellationFile = Join-Path $TestDrive 'foreign-cancel.signal'
        $runId = [guid]::NewGuid().ToString('N')
        $nonce = [guid]::NewGuid().ToString('N')
        $foreignRunId = [guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText($cancellationFile, "NETWORK-LANTERN-IPERF3-CANCEL/1:${foreignRunId}:${nonce}")
        $pwshPath = (Get-Process -Id $PID).Path

        $result = Invoke-Iperf3NativeProcess -FilePath $pwshPath `
          -Arguments @('-NoLogo', '-NoProfile', '-Command', 'Start-Sleep -Milliseconds 250') `
          -TimeoutMs 2000 -CancellationFile $cancellationFile `
          -CancellationRunId $runId -CancellationNonce $nonce

        $result.Cancelled | Should -BeFalse
        $result.TimedOut | Should -BeFalse
        $result.ExitCode | Should -Be 0
      }
    }

    It 'ignores a foreign nonce for the current run identity' {
      InModuleScope 'NetworkLantern.Throughput' {
        $cancellationFile = Join-Path $TestDrive 'foreign-nonce.signal'
        $runId = [guid]::NewGuid().ToString('N')
        $nonce = [guid]::NewGuid().ToString('N')
        $foreignNonce = [guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText($cancellationFile, "NETWORK-LANTERN-IPERF3-CANCEL/1:${runId}:${foreignNonce}")
        $pwshPath = (Get-Process -Id $PID).Path

        $result = Invoke-Iperf3NativeProcess -FilePath $pwshPath `
          -Arguments @('-NoLogo', '-NoProfile', '-Command', 'Start-Sleep -Milliseconds 250') `
          -TimeoutMs 2000 -CancellationFile $cancellationFile `
          -CancellationRunId $runId -CancellationNonce $nonce

        $result.Cancelled | Should -BeFalse
        $result.TimedOut | Should -BeFalse
        $result.ExitCode | Should -Be 0
      }
    }

    It 'marks cancellation cleanup unverified when redirected streams did not close' {
      InModuleScope 'NetworkLantern.Throughput' {
        $native = [pscustomobject]@{
          TerminationSucceeded = $true; RootExited = $true; TreeTerminationVerified = $true
          StreamsCompleted = $false; ProcessId = 42; TerminationScope = 'TrackedProcessTree'
          UnterminatedProcessIds = @(); TerminationError = $null; StreamReadError = 'pipe still open'
        }

        $exception = New-Iperf3CancellationException -NativeProcess $native -RunId 'run-42'

        $exception | Should -BeOfType ([System.InvalidOperationException])
        $exception.Data['NetworkLantern.CleanupVerified'] | Should -BeFalse
        $exception.Data['NetworkLantern.Error'] | Should -Match 'pipe still open'
      }
    }
  }

  Context 'Get-Iperf3Capability version parsing' {
    It 'correctly identifies bidir support for 3.9' {
      InModuleScope 'NetworkLantern.Throughput' {
        Mock Invoke-Iperf3NativeProcess {
          [pscustomobject]@{
            ExitCode = 0
            StdOut = "iperf 3.9 (cJSON 1.7.15)`n"
            StdErr = ''
            TimedOut = $false
          }
        }

        $caps = Get-Iperf3Capability -TimeoutMs 250 -Iperf3Path 'iperf3-test-double'

        $caps.Major | Should -Be 3
        $caps.Minor | Should -Be 9
        $caps.BidirSupported | Should -BeTrue
        Should -Invoke Invoke-Iperf3NativeProcess -Times 1 -Exactly -ParameterFilter {
          $FilePath -eq 'iperf3-test-double' -and $TimeoutMs -eq 250 -and
          $Arguments.Count -eq 1 -and $Arguments[0] -eq '--version'
        }
      }
    }

    It 'fails the capability probe when version collection times out' {
      InModuleScope 'NetworkLantern.Throughput' {
        Mock Invoke-Iperf3NativeProcess {
          [pscustomobject]@{
            ExitCode = 137; StdOut = ''; StdErr = ''; TimedOut = $true
            TerminationSucceeded = $true; ProcessId = 41
          }
        }

        { Get-Iperf3Capability -TimeoutMs 100 -Iperf3Path 'iperf3-test-double' } | Should -Throw '*--version timed out*'
      }
    }
  }
}
