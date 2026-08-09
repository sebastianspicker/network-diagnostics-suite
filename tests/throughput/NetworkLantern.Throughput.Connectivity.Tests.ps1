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

  Context 'Get-PingArgumentsForStack' {
    It 'returns IPv4 args with -4' {
      InModuleScope 'NetworkLantern.Throughput' {
        $testHost = 'example'
        $args4 = Get-PingArgumentsForStack -Stack 'IPv4' -ComputerName $testHost
        $args4 | Should -Contain '-4'
        $args4 | Should -Contain 'example'
      }
    }

    It 'returns IPv6 args with -6' {
      InModuleScope 'NetworkLantern.Throughput' {
        $testHost = 'example'
        $args6 = Get-PingArgumentsForStack -Stack 'IPv6' -ComputerName $testHost
        $args6 | Should -Contain '-6'
      }
    }

    It 'includes MTU payload size when specified' {
      InModuleScope 'NetworkLantern.Throughput' {
        $testHost = 'example'
        $args4 = Get-PingArgumentsForStack -Stack 'IPv4' -ComputerName $testHost -MtuPayloadSize 1400
        $args4 | Should -Contain '-f'
        $args4 | Should -Contain '1400'
      }
    }
  }

  Context 'Test-NetworkThroughputPrerequisites cross-platform' {
    It 'does not throw on non-Windows when both checks are skipped' -Skip:$IsWindows {
      InModuleScope 'NetworkLantern.Throughput' {
        Mock Get-Command { [pscustomobject]@{ Name = $Name } }
        { Test-NetworkThroughputPrerequisites -SkipReachabilityCheck -DisableMtuProbe } | Should -Not -Throw
      }
    }
  }

  Context 'Test-TcpPortAndTrace timeout parameter' {
    It 'accepts TimeoutMs parameter' {
      InModuleScope 'NetworkLantern.Throughput' {
        $cmd = Get-Command Test-TcpPortAndTrace
        $cmd.Parameters.Keys | Should -Contain 'TimeoutMs'
      }
    }

    It 'forwards TimeoutMs to the bounded TCP connector' {
      InModuleScope 'NetworkLantern.Throughput' {
        $testComputer = 'example.local'
        Mock Test-Iperf3TcpConnection {
          [pscustomobject]@{
            TcpTestSucceeded = $false
            RemoteAddress = $ComputerName
            RemoteAddressFamily = $null
            PingSucceeded = $null
          }
        }

        $result = Test-TcpPortAndTrace -ComputerName $testComputer -Port 5201 -TimeoutMs 1234

        $result.Tcp.TcpTestSucceeded | Should -BeFalse
        Should -Invoke Test-Iperf3TcpConnection -Times 1 -Exactly -ParameterFilter { $TimeoutMs -eq 1234 }
      }
    }

    It 'returns from an incomplete TCP connect task at the deadline' {
      InModuleScope 'NetworkLantern.Throughput' {
        $testComputer = 'example.local'
        $pending = [System.Threading.Tasks.TaskCompletionSource[bool]]::new()
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        $result = Test-Iperf3TcpConnection -ComputerName $testComputer -Port 5201 -TimeoutMs 100 -ConnectAsync {
          param($client, $computerName, $port)
          $null = $client, $computerName, $port
          return $pending.Task
        }

        $stopwatch.Stop()
        $result.TcpTestSucceeded | Should -BeFalse
        $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 2
      }
    }

    It 'bounds traceroute independently from the TCP deadline' {
      InModuleScope 'NetworkLantern.Throughput' {
        $testComputer = 'example.local'
        $pidFile = Join-Path $TestDrive 'noncooperative-trace.pid'
        $escapedPidFile = $pidFile.Replace("'", "''")
        $traceScript = [scriptblock]::Create(@"
param(`$computerName, `$hops)
`$null = `$computerName, `$hops
[IO.File]::WriteAllText('$escapedPidFile', [string]`$PID)
while (`$true) { [Threading.Thread]::Sleep(1000) }
"@)
        $traceTimeoutMs = 1000
        $terminationGracePeriodMs = 500
        $streamDrainTimeoutMs = 250
        $workerStartupAllowanceMs = 1000
        $maximumExpectedSeconds = ($traceTimeoutMs + $terminationGracePeriodMs + $streamDrainTimeoutMs + $workerStartupAllowanceMs) / 1000
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        $trace = Invoke-Iperf3TraceRoute -ComputerName $testComputer -Hops 1 -TimeoutMs $traceTimeoutMs -TraceScript $traceScript

        $stopwatch.Stop()
        $trace | Should -BeNullOrEmpty
        $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan $maximumExpectedSeconds
        Test-Path -LiteralPath $pidFile -PathType Leaf | Should -BeTrue
        $traceProcessId = [int](Get-Content -LiteralPath $pidFile -Raw)
        (Get-Process -Id $traceProcessId -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
      }
    }

    It 'does not hang when a traceroute descendant retains redirected pipes' {
      InModuleScope 'NetworkLantern.Throughput' {
        $pidFile = Join-Path $TestDrive 'trace-pipe-holder.pid'
        $pidFileBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pidFile))
        $traceScript = [scriptblock]::Create(@"
param(`$computerName, `$hops)
`$null = `$computerName, `$hops
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
[pscustomobject]@{ TraceRoute = @('hop') }
"@)
        $childProcess = $null
        try {
          $traceTimeoutMs = 2000
          $streamDrainTimeoutMs = 250
          # Invocation timing begins before worker startup, which is outside the
          # native execution deadline. Retain a fixed, finite startup allowance.
          $workerStartupAllowanceMs = 1000
          $maximumExpectedSeconds = ($traceTimeoutMs + $streamDrainTimeoutMs + $workerStartupAllowanceMs) / 1000
          $stopwatch = [Diagnostics.Stopwatch]::StartNew()
          $testComputer = 'example.local'
          $trace = Invoke-Iperf3TraceRoute -ComputerName $testComputer -Hops 1 -TimeoutMs $traceTimeoutMs -TraceScript $traceScript
          $stopwatch.Stop()

          $trace | Should -BeNullOrEmpty
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
  }

  Context 'Get-TestSuiteConnectivity accepts ConnectTimeoutMs' {
    It 'has ConnectTimeoutMs parameter' {
      InModuleScope 'NetworkLantern.Throughput' {
        $cmd = Get-Command Get-TestSuiteConnectivity
        $cmd.Parameters.Keys | Should -Contain 'ConnectTimeoutMs'
      }
    }
  }

  Context 'Get-Iperf3StackFromTcpResult' {
    It 'uses the remote endpoint address family before hostname text' {
      InModuleScope 'NetworkLantern.Throughput' {
        $tcp = [pscustomobject]@{
          RemoteAddress = 'dualstack.example'
          RemoteAddressFamily = 'InterNetworkV6'
        }

        Get-Iperf3StackFromTcpResult -Tcp $tcp | Should -Be 'IPv6'
      }
    }
  }
}
