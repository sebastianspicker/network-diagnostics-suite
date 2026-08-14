$ErrorActionPreference = 'Stop'

BeforeAll {
  . (Join-Path (Get-Item $PSScriptRoot).Parent.Parent.FullName 'scripts/Get-RepoRoot.ps1')
  $repoRoot = Get-RepoRoot
  $modulePath = Join-Path $repoRoot 'src/powershell/throughput/NetworkLantern.Throughput.psd1'
  Import-Module $modulePath -Force
}

Describe 'Network Lantern throughput locking' {

  It 'throws the established deadline message when the profile sidecar is held' {
    InModuleScope 'NetworkLantern.Throughput' {
      $profilesFile = Join-Path $TestDrive 'profiles-held-lock.json'
      $lockStream = [System.IO.File]::Open(
        "$profilesFile.lock",
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
      )
      $originalTimeoutMs = $script:ExclusiveFileLockTimeoutMs
      $originalRetryDelayMs = $script:ExclusiveFileLockRetryDelayMs
      try {
        $script:ExclusiveFileLockTimeoutMs = 60
        $script:ExclusiveFileLockRetryDelayMs = 10

        { Save-Iperf3Profile -ProfileName 'blocked' -ProfilesFile $profilesFile -Parameters @{ Target = 'example.local' } } |
          Should -Throw '*Failed to access profiles file after 60ms lock deadline (file locked):*'
      }
      finally {
        $script:ExclusiveFileLockTimeoutMs = $originalTimeoutMs
        $script:ExclusiveFileLockRetryDelayMs = $originalRetryDelayMs
        $lockStream.Dispose()
      }
    }
  }

  It 'warns and returns null when the run-index sidecar remains locked through its deadline' {
    InModuleScope 'NetworkLantern.Throughput' {
      $historyDir = Join-Path $TestDrive 'history-held-lock'
      $null = New-Item -ItemType Directory -Path $historyDir -Force
      $indexPath = Join-Path $historyDir 'iperf3_run_index.json'
      $lockStream = [System.IO.File]::Open(
        "$indexPath.lock",
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
      )
      $originalTimeoutMs = $script:ExclusiveFileLockTimeoutMs
      $originalRetryDelayMs = $script:ExclusiveFileLockRetryDelayMs
      try {
        $script:ExclusiveFileLockTimeoutMs = 60
        $script:ExclusiveFileLockRetryDelayMs = 10
        $summary = [pscustomobject]@{
          Timestamp = 'held-lock'; Status = 'Success'; ExitCode = 0
          Target = 'x'; Port = 5201; Stack = 'IPv4'
        }
        $warnings = @()
        $result = Write-Iperf3RunIndex -OutDir $historyDir -RunSummary $summary `
          -CsvPath '/held.csv' -JsonPath '/held.json' -SummaryJsonPath $null -ReportMdPath $null `
          -WarningVariable +warnings

        $result | Should -BeNullOrEmpty
        ($warnings -join "`n") | Should -Match 'Failed to write run index after 60ms lock deadline:'
      }
      finally {
        $script:ExclusiveFileLockTimeoutMs = $originalTimeoutMs
        $script:ExclusiveFileLockRetryDelayMs = $originalRetryDelayMs
        $lockStream.Dispose()
      }
    }
  }
}
