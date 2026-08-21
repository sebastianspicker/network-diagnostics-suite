Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:RepoRoot = Split-Path -Parent $PSScriptRoot
  . (Join-Path $script:RepoRoot 'src/powershell/path/lib-ps/Test-HostNameSafe.ps1')
  . (Join-Path $script:RepoRoot 'src/powershell/path/lib-ps/Test-PathSafe.ps1')
  Import-Module (Join-Path $script:RepoRoot 'src/powershell/throughput/NetworkLantern.Throughput.psd1') -Force
  Import-Module (Join-Path $script:RepoRoot 'src/powershell/windows-tuning/NetworkLantern.WindowsTuning/NetworkLantern.WindowsTuning.psd1') -Force
}

Describe 'Network Lantern direct contracts' {
  It 'rejects command-shaped hosts and output paths' {
    Test-HostNameSafe 'example.local' | Should -BeTrue
    Test-HostNameSafe 'host;command' | Should -BeFalse
    Test-PathSafe '/tmp/network-lantern' | Should -BeTrue
    Test-PathSafe '../unsafe' | Should -BeFalse
  }

  It 'keeps the PowerShell path dry-run side-effect free' {
    $output = & pwsh -NoProfile -NonInteractive -File (Join-Path $script:RepoRoot 'apps/path/Test-NetworkPath.ps1') -DryRun -Quiet 2>&1
    $LASTEXITCODE | Should -Be 0
    ($output | Out-String) | Should -Match 'Planned runs: 7'
  }

  It 'stores a strict throughput profile atomically and rejects unknown input' {
    InModuleScope 'NetworkLantern.Throughput' {
      $profilesFile = Join-Path $TestDrive 'profiles.json'
      $null = Save-Iperf3Profile -ProfileName 'lab' -ProfilesFile $profilesFile -Parameters @{ Target = 'example.local'; Port = 5201 } -StrictConfiguration
      (Get-Iperf3ProfileParameters -ProfileName 'lab' -ProfilesFile $profilesFile -StrictConfiguration).Port | Should -Be 5201
      $null = Save-Iperf3Profile -ProfileName 'bad' -ProfilesFile $profilesFile -Parameters @{ Unknown = 'x' } -StrictConfiguration
      (Get-Iperf3ProfileParameters -ProfileName 'bad' -ProfilesFile $profilesFile -StrictConfiguration).PSObject.Properties.Name | Should -Not -Contain 'Unknown'
    }
  }

  It 'extracts embedded iperf JSON and preserves reports under WhatIf' {
    InModuleScope 'NetworkLantern.Throughput' {
      Get-JsonSubstringOrNull -Text 'prefix {not-json} {"end":{"sum_sent":{"bits_per_second":1000000}}}' | Should -Be '{"end":{"sum_sent":{"bits_per_second":1000000}}}'
      $reportPath = Join-Path $TestDrive 'summary.json'
      Set-Content -LiteralPath $reportPath -Value '{"existing":true}' -NoNewline
      Set-Iperf3JsonFileAtomic -Path $reportPath -InputObject @{ changed = $true } -WhatIf 6>$null
      (Get-Content -LiteralPath $reportPath -Raw) | Should -Be '{"existing":true}'
    }
  }

  It 'fails closed when a profile sidecar lock is held' {
    InModuleScope 'NetworkLantern.Throughput' {
      $profilesFile = Join-Path $TestDrive 'held.json'
      $lock = [IO.File]::Open("$profilesFile.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
      $oldTimeout = $script:ExclusiveFileLockTimeoutMs
      $oldDelay = $script:ExclusiveFileLockRetryDelayMs
      try {
        $script:ExclusiveFileLockTimeoutMs = 60
        $script:ExclusiveFileLockRetryDelayMs = 10
        { Save-Iperf3Profile -ProfileName 'blocked' -ProfilesFile $profilesFile -Parameters @{ Target = 'example.local' } } | Should -Throw '*lock deadline*'
      } finally {
        $script:ExclusiveFileLockTimeoutMs = $oldTimeout
        $script:ExclusiveFileLockRetryDelayMs = $oldDelay
        $lock.Dispose()
      }
    }
  }

  It 'writes only a nonce-bound cancellation signal' {
    $lifecycle = Join-Path $script:RepoRoot 'apps/throughput/Private/GuiRunLifecycle.ps1'
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($lifecycle, [ref]$tokens, [ref]$errors)
    @($errors).Count | Should -Be 0
    foreach ($name in 'New-RunCancellationContext', 'Set-RunCancellationSignal') {
      $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true) | Select-Object -First 1
      . ([scriptblock]::Create($definition.Extent.Text))
    }
    $context = New-RunCancellationContext
    try {
      Set-RunCancellationSignal -CancellationContext $context
      [IO.File]::ReadAllText($context.CancellationFile) | Should -Be $context.ExpectedSignalContent
    } finally { Remove-Item -LiteralPath $context.CancellationFile -Force -ErrorAction SilentlyContinue }
  }

  It 'refuses an invalid restore manifest before work begins' {
    InModuleScope 'NetworkLantern.WindowsTuning' {
      $backup = Join-Path $TestDrive 'backup'
      New-Item -ItemType Directory -Path $backup | Out-Null
      Set-Content -LiteralPath (Join-Path $backup 'backup_manifest.json') -Value '{' -NoNewline
      $result = Restore-UjState -BackupFolder $backup
      $result.Manifest | Should -Be 'Warn'
      $result.Registry | Should -Be 'Skipped'
    }
  }
}
