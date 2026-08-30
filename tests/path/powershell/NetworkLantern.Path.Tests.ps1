Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
  $script:EntryPoint = Join-Path $script:RepoRoot 'apps/path/Test-NetworkPath.ps1'
  $script:Manifest = Join-Path $script:RepoRoot 'src/powershell/path/NetworkLantern.Path/NetworkLantern.Path.psd1'
}

Describe 'Network Lantern Path module and CLI contracts' {
  It 'exports only the diagnostics orchestration command' {
    Remove-Module NetworkLantern.Path -Force -ErrorAction SilentlyContinue
    $module = Import-Module -Name $script:Manifest -Force -PassThru
    @($module.ExportedCommands.Keys) | Should -Be @('Invoke-NetworkPathDiagnostics')
  }

  It 'keeps version and list modes available through the existing CLI path' {
    $versionOutput = & pwsh -NoProfile -NonInteractive -File $script:EntryPoint -Version 2>&1
    $LASTEXITCODE | Should -Be 0
    ($versionOutput | Out-String).Trim() | Should -Be 'Test-NetworkPath.ps1 v1.1.0'

    $roundOutput = & pwsh -NoProfile -NonInteractive -File $script:EntryPoint -ListRounds 2>&1
    $LASTEXITCODE | Should -Be 0
    @($roundOutput | ForEach-Object ToString) | Should -Be @('Standard', 'MTU1400_DF', 'TTL64_Timeout5s')

    $protocolOutput = & pwsh -NoProfile -NonInteractive -File $script:EntryPoint -ListProtocols 2>&1
    $LASTEXITCODE | Should -Be 0
    @($protocolOutput | ForEach-Object ToString) | Should -Be @('IPv4', 'IPv6')
  }

  It 'honors explicit hosts over configured defaults and leaves dry-run output absent' {
    $logDirectory = Join-Path $TestDrive 'would-be-output'
    $output = & pwsh -NoProfile -NonInteractive -File $script:EntryPoint -DryRun -LogDirectory $logDirectory -Protocols IPv4 -Rounds Standard -HostsIPv4 'example.test' 2>&1
    $LASTEXITCODE | Should -Be 0
    $text = $output | Out-String
    $text | Should -Match 'Planned runs: 1'
    $text | Should -Match 'IPv4 hosts: example\.test'
    $text | Should -Match 'Would write JSON: .*net_results_.*\.json'
    $text | Should -Match 'Would write CSV : .*net_summary_.*\.csv'
    Test-Path -LiteralPath $logDirectory | Should -BeFalse
  }

  It 'rejects invalid hosts before creating a requested output directory' {
    $logDirectory = Join-Path $TestDrive 'invalid-host-output'
    $output = & pwsh -NoProfile -NonInteractive -File $script:EntryPoint -DryRun -LogDirectory $logDirectory -HostsIPv4 'host;command' 2>&1
    $LASTEXITCODE | Should -Be 1
    ($output | Out-String) | Should -Match 'Host names must not start'
    Test-Path -LiteralPath $logDirectory | Should -BeFalse
  }

  It 'rejects traversal output paths before creating files' {
    $output = & pwsh -NoProfile -NonInteractive -File $script:EntryPoint -DryRun -LogDirectory '../escape' -HostsIPv4 'example.test' 2>&1
    $LASTEXITCODE | Should -Be 1
    ($output | Out-String) | Should -Match 'LogDirectory must not be empty'
    Test-Path -LiteralPath (Join-Path (Split-Path -Parent $script:RepoRoot) 'escape') | Should -BeFalse
  }
}

Describe 'Network Lantern Path diagnostic result behavior' {
  It 'persists successful diagnostics with the retained empty port schema' {
    InModuleScope 'NetworkLantern.Path' {
      Mock Invoke-PingRaw { [pscustomobject]@{ Raw = @('ping'); ExitCode = 0 } }
      Mock Invoke-TracertRaw { [pscustomobject]@{ Raw = @('tracert'); ExitCode = 0 } }
      Mock Invoke-PathpingRaw { [pscustomobject]@{ Raw = @('pathping'); ExitCode = 0 } }
      Mock Test-TcpPort { [pscustomobject]@{ TcpTestSucceeded = $true } }

      $round = [pscustomobject]@{ Name = 'Standard'; PingArgs4 = {}; PingArgs6 = {}; TracertArgs = {}; PathpingArgs = {} }
      $plan = [System.Collections.Generic.List[object]]::new()
      [void]$plan.Add([pscustomobject]@{ RoundName = 'Standard'; RoundDef = $round; Protocol = 'IPv4'; Host = 'example.test' })
      $results = [System.Collections.Generic.List[object]]::new()
      Invoke-DiagnosticsMatrix -Plan $plan -Results $results -Settings ([pscustomobject]@{ PingCount = 1; SkipPathping = $false })
      $jsonPath = Join-Path $TestDrive 'successful.json'
      $csvPath = Join-Path $TestDrive 'successful.csv'
      Save-DiagnosticResults -Results @($results) -JsonPath $jsonPath -CsvPath $csvPath

      $results.Count | Should -Be 1
      $results[0].OverallStatus | Should -Be 'OK'
      $results[0].FailedStages | Should -BeNullOrEmpty
      $jsonRecord = @(Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json)[0]
      @($jsonRecord.Ports).Count | Should -Be 0
      $jsonRecord.PortsStatus | Should -Be 'Skipped'
      (Import-Csv -LiteralPath $csvPath)[0].PortsStatus | Should -Be 'Skipped'
    }
  }

  It 'persists failed diagnostics with the retained empty port schema' {
    InModuleScope 'NetworkLantern.Path' {
      Mock Invoke-PingRaw { [pscustomobject]@{ Raw = @('ping failed'); ExitCode = 1 } }
      Mock Invoke-TracertRaw { [pscustomobject]@{ Raw = @('tracert'); ExitCode = 0 } }
      Mock Invoke-PathpingRaw { [pscustomobject]@{ Raw = @('pathping'); ExitCode = 0 } }
      Mock Test-TcpPort { [pscustomobject]@{ TcpTestSucceeded = $true } }

      $round = [pscustomobject]@{ Name = 'Standard'; PingArgs4 = {}; PingArgs6 = {}; TracertArgs = {}; PathpingArgs = {} }
      $plan = [System.Collections.Generic.List[object]]::new()
      [void]$plan.Add([pscustomobject]@{ RoundName = 'Standard'; RoundDef = $round; Protocol = 'IPv4'; Host = 'example.test' })
      $results = [System.Collections.Generic.List[object]]::new()
      Invoke-DiagnosticsMatrix -Plan $plan -Results $results -Settings ([pscustomobject]@{ PingCount = 1; SkipPathping = $false })
      $jsonPath = Join-Path $TestDrive 'failed.json'
      $csvPath = Join-Path $TestDrive 'failed.csv'
      Save-DiagnosticResults -Results @($results) -JsonPath $jsonPath -CsvPath $csvPath

      $results[0].OverallStatus | Should -Be 'Fail'
      $results[0].FailedStages | Should -Be @('Ping')
      $jsonRecord = @(Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json)[0]
      $jsonRecord.OverallStatus | Should -Be 'Fail'
      $jsonRecord.PortsStatus | Should -Be 'Skipped'
      (Import-Csv -LiteralPath $csvPath)[0].PortsStatus | Should -Be 'Skipped'
    }
  }

  It 'keeps an explicitly skipped pathping stage out of failed aggregation' {
    InModuleScope 'NetworkLantern.Path' {
      Mock Invoke-PingRaw { [pscustomobject]@{ Raw = @('ping'); ExitCode = 0 } }
      Mock Invoke-TracertRaw { [pscustomobject]@{ Raw = @('tracert'); ExitCode = 0 } }
      Mock Invoke-PathpingRaw { throw 'Pathping must not run when explicitly skipped.' }
      Mock Test-TcpPort { [pscustomobject]@{ TcpTestSucceeded = $true } }

      $round = [pscustomobject]@{ Name = 'Standard'; PingArgs4 = {}; PingArgs6 = {}; TracertArgs = {}; PathpingArgs = {} }
      $plan = [System.Collections.Generic.List[object]]::new()
      [void]$plan.Add([pscustomobject]@{ RoundName = 'Standard'; RoundDef = $round; Protocol = 'IPv4'; Host = 'example.test' })
      $results = [System.Collections.Generic.List[object]]::new()
      Invoke-DiagnosticsMatrix -Plan $plan -Results $results -Settings ([pscustomobject]@{ PingCount = 1; SkipPathping = $true })
      $jsonPath = Join-Path $TestDrive 'skipped.json'
      $csvPath = Join-Path $TestDrive 'skipped.csv'
      Save-DiagnosticResults -Results @($results) -JsonPath $jsonPath -CsvPath $csvPath

      Assert-MockCalled Invoke-PathpingRaw -Times 0 -Exactly
      $results[0].PathpingStatus | Should -Be 'Skipped'
      $results[0].OverallStatus | Should -Be 'OK'
      $jsonRecord = @(Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json)[0]
      $jsonRecord.PathpingStatus | Should -Be 'Skipped'
      $jsonRecord.PortsStatus | Should -Be 'Skipped'
      (Import-Csv -LiteralPath $csvPath)[0].PortsStatus | Should -Be 'Skipped'
    }
  }
}
