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

  Context 'GUI native-process cancellation wiring' {
    BeforeAll {
      $lifecyclePath = Join-Path $PSScriptRoot '../../apps/throughput/Private/GuiRunLifecycle.ps1'
      $guiFunctions = @(
        'New-RunCancellationContext', 'Set-RunCancellationSignal',
        'Get-VerifiedRunCleanupRecord', 'Get-ValidatedRunWorkerIdentity',
        'Receive-RunJobLifecycleOutput', 'Stop-RunWorkerProcessBounded', 'Start-SuiteJob'
      )
      $guiTokens = $null
      $guiParseErrors = $null
      $guiAst = [System.Management.Automation.Language.Parser]::ParseFile($lifecyclePath, [ref]$guiTokens, [ref]$guiParseErrors)
      if (@($guiParseErrors).Count -gt 0) { throw "GUI lifecycle helper did not parse: $($guiParseErrors[0].Message)" }
      foreach ($functionName in $guiFunctions) {
        $definition = $guiAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
          }, $true) | Select-Object -First 1
        if (-not $definition) { throw "GUI function was not found: $functionName" }
        . ([scriptblock]::Create($definition.Extent.Text))
      }
    }

    It 'writes the exact nonce-bound signal and rejects a foreign collision' {
      $context = New-RunCancellationContext
      try {
        Set-RunCancellationSignal -CancellationContext $context
        [IO.File]::ReadAllText($context.CancellationFile) | Should -Be $context.ExpectedSignalContent
        $context.ExpectedSignalContent | Should -Match "^NETWORK-LANTERN-IPERF3-CANCEL/1:$($context.RunId):$($context.Nonce)$"

        Set-RunCancellationSignal -CancellationContext $context

        $foreignContext = New-RunCancellationContext
        [IO.File]::WriteAllText($foreignContext.CancellationFile, 'foreign')
        { Set-RunCancellationSignal -CancellationContext $foreignContext } | Should -Throw '*foreign content*'
      }
      finally {
        Remove-Item -LiteralPath $context.CancellationFile -Force -ErrorAction SilentlyContinue
        if ($foreignContext) {
          Remove-Item -LiteralPath $foreignContext.CancellationFile -Force -ErrorAction SilentlyContinue
        }
      }
    }

    It 'passes run identity to the worker environment and emits lifecycle records' {
      $context = New-RunCancellationContext
      $modulePath = Join-Path $TestDrive 'GuiLifecycleProbe.psm1'
      Set-Content -LiteralPath $modulePath -Encoding UTF8 -Value @'
function Measure-NetworkThroughput {
  [CmdletBinding()]
  param([switch]$PassThru)
  $null = $PassThru
  [pscustomobject]@{
    File = $env:NETWORK_LANTERN_IPERF3_CANCEL_FILE
    RunId = $env:NETWORK_LANTERN_IPERF3_CANCEL_RUN_ID
    Nonce = $env:NETWORK_LANTERN_IPERF3_CANCEL_NONCE
  }
}
Export-ModuleMember -Function Measure-NetworkThroughput
'@
      $job = $null
      try {
        $job = Start-SuiteJob -ParamHash @{} -ModulePath $modulePath -CancellationContext $context
        $null = Wait-Job -Job $job -Timeout 5
        $output = @(Receive-Job -Job $job -ErrorAction Stop)

        $startedRecord = $output | Where-Object {
            $_.PSObject.Properties.Name -contains 'RecordType' -and $_.RecordType -eq 'NetworkLantern.Iperf3.JobStarted'
          }
        $startedRecord.RunId | Should -Be $context.RunId
        $startedRecord.WorkerStartTimeUtc | Should -Not -BeNullOrEmpty
        ($output | Where-Object {
            $_.PSObject.Properties.Name -contains 'RecordType' -and $_.RecordType -eq 'NetworkLantern.Iperf3.JobTerminal'
          }).Outcome | Should -Be 'Completed'
        $probe = $output | Where-Object { $_.PSObject.Properties.Name -contains 'Nonce' }
        $probe.File | Should -Be $context.CancellationFile
        $probe.RunId | Should -Be $context.RunId
        $probe.Nonce | Should -Be $context.Nonce
      }
      finally {
        if ($job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
      }
    }

    It 'invalidates duplicate worker identities and refuses a reused PID' {
      $context = New-RunCancellationContext
      $startTime = (Get-Process -Id $PID).StartTime.ToUniversalTime()
      $startedRecord = [pscustomobject]@{
        RecordType = 'NetworkLantern.Iperf3.JobStarted'; Version = 1; RunId = $context.RunId
        WorkerProcessId = $PID; WorkerStartTimeUtc = $startTime.ToString('o')
      }

      $job = $null
      try {
        $script:RunJobCancellationContext = $context
        $script:RunJobStartedRecords = @()
        $script:RunJobTerminalRecords = @()
        $job = Start-Job -ScriptBlock { $args[0]; $args[0] } -ArgumentList $startedRecord
        $null = Wait-Job -Job $job -Timeout 5
        $null = Receive-RunJobLifecycleOutput -Job $job

        $script:RunJobStartedRecords.Count | Should -Be 2
        Get-ValidatedRunWorkerIdentity -CancellationContext $context -StartedRecords $script:RunJobStartedRecords |
          Should -BeNullOrEmpty
        $pidReuseResult = Stop-RunWorkerProcessBounded -ProcessId $PID `
          -ExpectedStartTimeUtc $startTime.AddSeconds(-1) -GracePeriodMs 10 3>$null
        $pidReuseResult | Should -BeFalse
        (Get-Process -Id $PID -ErrorAction Stop).Id | Should -Be $PID
      }
      finally {
        if ($job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
        $script:RunJobCancellationContext = $null
        $script:RunJobStartedRecords = @()
        $script:RunJobTerminalRecords = @()
      }
    }

    It 'converts verified native cancellation evidence into one verifiable terminal record' {
      $context = New-RunCancellationContext
      $modulePath = Join-Path $TestDrive 'GuiCancellationProbe.psm1'
      Set-Content -LiteralPath $modulePath -Encoding UTF8 -Value @'
function Measure-NetworkThroughput {
  [CmdletBinding()]
  param([switch]$PassThru)
  $null = $PassThru
  $exception = [OperationCanceledException]::new('probe cancellation')
  $exception.Data['NetworkLantern.CleanupRecordVersion'] = 1
  $exception.Data['NetworkLantern.RunId'] = $env:NETWORK_LANTERN_IPERF3_CANCEL_RUN_ID
  $exception.Data['NetworkLantern.CancellationObserved'] = $true
  $exception.Data['NetworkLantern.CleanupVerified'] = $true
  $exception.Data['NetworkLantern.RootExited'] = $true
  $exception.Data['NetworkLantern.TreeTerminationVerified'] = $true
  $exception.Data['NetworkLantern.StreamsCompleted'] = $true
  $exception.Data['NetworkLantern.TerminationScope'] = 'TrackedProcessTree'
  $exception.Data['NetworkLantern.ProcessId'] = 42
  $exception.Data['NetworkLantern.Error'] = ''
  throw $exception
}
Export-ModuleMember -Function Measure-NetworkThroughput
'@
      $job = $null
      try {
        $job = Start-SuiteJob -ParamHash @{} -ModulePath $modulePath -CancellationContext $context
        $null = Wait-Job -Job $job -Timeout 5
        $output = @(Receive-Job -Job $job -ErrorAction SilentlyContinue)
        $records = @($output | Where-Object {
            $_.PSObject.Properties.Name -contains 'RecordType' -and $_.RecordType -eq 'NetworkLantern.Iperf3.JobTerminal'
          })

        $job.State | Should -Be 'Failed'
        $job.ChildJobs[0].JobStateInfo.Reason | Should -Not -BeNullOrEmpty
        $records.Count | Should -Be 1
        Get-VerifiedRunCleanupRecord -Job $job -CancellationContext $context -TerminalRecords $records |
          Should -Not -BeNullOrEmpty
      }
      finally {
        if ($job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
      }
    }

    It 'requires one matching terminal record and the child JobStateInfo reason' {
      $context = New-RunCancellationContext
      $terminalRecord = [pscustomobject]@{
        RecordType = 'NetworkLantern.Iperf3.JobTerminal'; Version = 1; RunId = $context.RunId
        Outcome = 'Cancelled'; CleanupStatus = 'Verified'; RootExited = $true
        TreeTerminationVerified = $true; StreamsCompleted = $true
        TerminationScope = 'TrackedProcessTree'
      }
      $failedJob = Start-Job -ScriptBlock {
        $args[0]
        throw 'cancelled after verified cleanup'
      } -ArgumentList $terminalRecord
      $completedJob = Start-Job -ScriptBlock { 'done' }
      try {
        $null = Wait-Job -Job $failedJob -Timeout 5
        $null = Wait-Job -Job $completedJob -Timeout 5
        $records = @(Receive-Job -Job $failedJob -ErrorAction SilentlyContinue | Where-Object {
            $_.PSObject.Properties.Name -contains 'RecordType' -and $_.RecordType -eq 'NetworkLantern.Iperf3.JobTerminal'
          })

        Get-VerifiedRunCleanupRecord -Job $failedJob -CancellationContext $context -TerminalRecords $records |
          Should -Not -BeNullOrEmpty
        Get-VerifiedRunCleanupRecord -Job $failedJob -CancellationContext $context -TerminalRecords @() |
          Should -BeNullOrEmpty
        Get-VerifiedRunCleanupRecord -Job $failedJob -CancellationContext $context -TerminalRecords @($records[0], $records[0]) |
          Should -BeNullOrEmpty
        Get-VerifiedRunCleanupRecord -Job $completedJob -CancellationContext $context -TerminalRecords $records |
          Should -BeNullOrEmpty
        $wrongContext = [pscustomobject]@{ RunId = 'another-run' }
        Get-VerifiedRunCleanupRecord -Job $failedJob -CancellationContext $wrongContext -TerminalRecords $records |
          Should -BeNullOrEmpty
      }
      finally {
        Remove-Job -Job $failedJob, $completedJob -Force -ErrorAction SilentlyContinue
      }
    }

    It 'keeps the form and cancellation context alive while cleanup remains pending' {
      $guiPath = Join-Path $PSScriptRoot '../../apps/throughput/Measure-NetworkThroughput-GUI.ps1'
      $lifecyclePath = Join-Path $PSScriptRoot '../../apps/throughput/Private/GuiRunLifecycle.ps1'
      $guiSource = Get-Content -LiteralPath $guiPath -Raw
      $lifecycleSource = Get-Content -LiteralPath $lifecyclePath -Raw
      $formClosingSource = $guiSource.Substring($guiSource.IndexOf('$form.Add_FormClosing'))

      $formClosingSource | Should -Match '\$released\s*=\s*Stop-CurrentRunJob'
      $formClosingSource | Should -Match 'if\s*\(-not\s+\$released\)\s*\{[\s\S]*?\$formEventArgs\.Cancel\s*=\s*\$true'
      $formClosingSource | Should -Match 'if\s*\(-not\s+\$script:RunJob\)\s*\{[\s\S]*?Clear-RunCancellationContext'
      $lifecycleSource | Should -Match '\$script:DeferredRunJobs\s*=\s*@\(\$script:DeferredRunJobs\)\s*\+\s*@\(\$script:RunJob\)'
      $lifecycleSource | Should -Match 'function\s+Start-RunFromUi'
      $guiSource | Should -Match '\$btnRun\.Add_Click\(\{[\s\S]*?Start-RunFromUi'
      $guiSource | Should -Match '\$btnWhatIf\.Add_Click\(\{[\s\S]*?Start-RunFromUi[\s\S]*?-WhatIf'
    }

  }
}
