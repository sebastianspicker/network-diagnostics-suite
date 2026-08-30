Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$manifestPath = Join-Path $repoRoot 'src/powershell/windows-tuning/NetworkLantern.WindowsTuning/NetworkLantern.WindowsTuning.psd1'

Import-Module -Name $manifestPath -Force

Describe 'Windows tuning verified restore staging' {
  InModuleScope NetworkLantern.WindowsTuning {
    BeforeAll {
      function Get-NetworkLanternStagingFixture {
        param([Parameter(Mandatory)][string]$Folder)

        New-Item -ItemType Directory -Path $Folder -Force | Out-Null
        $artifactPath = Join-Path $Folder $script:NetworkTuningBackupFilePowerplan
        Set-Content -LiteralPath $artifactPath -Value $script:NetworkTuningPowerPlanGuidBalanced -Encoding utf8 -NoNewline
        $manifest = @{
          SchemaVersion = $script:NetworkTuningBackupSchemaVersion
          ToolName = 'network-lantern'
          Timestamp = '2026-01-01T00:00:00Z'
          Components = @{ SystemProfile = $false; AfdParameters = $false; QosPolicies = $false; NicAdvanced = $false; NicRsc = $false; PowerPlan = $true }
          ArtifactDigests = @{ $script:NetworkTuningBackupFilePowerplan = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash }
        }
        $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Folder $script:NetworkTuningBackupFileManifest) -Encoding utf8
        return $manifest
      }
    }

    It 'restores a valid manifest in DryRun as a structured no-write result' {
      $folder = Join-Path $TestDrive 'dry-run-restore'
      $null = Get-NetworkLanternStagingFixture -Folder $folder
      $before = Get-Content -LiteralPath (Join-Path $folder $script:NetworkTuningBackupFilePowerplan) -Raw

      $result = Invoke-NetworkPathTuning -Action Restore -BackupFolder $folder -DryRun -PassThru

      $result.Success | Should -BeTrue
      $result.DryRun | Should -BeTrue
      $result.Components['Manifest'] | Should -Be 'OK'
      $result.Components['Registry'] | Should -Be 'Skipped'
      (Get-Content -LiteralPath (Join-Path $folder $script:NetworkTuningBackupFilePowerplan) -Raw) | Should -Be $before
    }

    It 'uses a fresh staging copy that satisfies the recorded artifact digest' {
      $sourceFolder = Join-Path $TestDrive 'source-backup'
      $manifest = Get-NetworkLanternStagingFixture -Folder $sourceFolder
      $session = $null
      try {
        $session = Copy-NetworkTuningVerifiedBackupToStaging -BackupFolder $sourceFolder -Manifest $manifest

        $session.Path | Should -Not -Be $sourceFolder
        Test-Path -LiteralPath $session.SentinelPath -PathType Leaf | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $session.Path $script:NetworkTuningBackupFilePowerplan) -Raw) |
          Should -Be (Get-Content -LiteralPath (Join-Path $sourceFolder $script:NetworkTuningBackupFilePowerplan) -Raw)
        (Test-NetworkTuningRestoreStagingInvariant -Session $session -Manifest $manifest).IsValid | Should -BeTrue
      } finally {
        if ($null -ne $session) { Close-NetworkTuningRestoreStagingSession -Session $session }
      }
    }

    It 'rejects a source artifact that is swapped after the manifest digest was recorded' {
      $sourceFolder = Join-Path $TestDrive 'source-swap-before-stage'
      $manifest = Get-NetworkLanternStagingFixture -Folder $sourceFolder
      Set-Content -LiteralPath (Join-Path $sourceFolder $script:NetworkTuningBackupFilePowerplan) -Value $script:NetworkTuningPowerPlanGuidHighPerformance -Encoding utf8 -NoNewline

      { Copy-NetworkTuningVerifiedBackupToStaging -BackupFolder $sourceFolder -Manifest $manifest } |
        Should -Throw '*digest mismatch while staging*'
    }

    It 'authorizes the staged bytes rather than accepting a source-only digest check' {
      $sourceFolder = Join-Path $TestDrive 'staged-authorization'
      $manifest = Get-NetworkLanternStagingFixture -Folder $sourceFolder
      $artifactPath = Join-Path $sourceFolder $script:NetworkTuningBackupFilePowerplan
      Set-Content -LiteralPath $artifactPath -Value 'not-a-power-plan-guid' -Encoding utf8 -NoNewline
      $manifest.ArtifactDigests[$script:NetworkTuningBackupFilePowerplan] = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash

      { Copy-NetworkTuningVerifiedBackupToStaging -BackupFolder $sourceFolder -Manifest $manifest } |
        Should -Throw '*Staged backup authorization failed*'
    }

    It 'blocks a staged artifact that changes after verification' {
      $sourceFolder = Join-Path $TestDrive 'staging-tamper-source'
      $manifest = Get-NetworkLanternStagingFixture -Folder $sourceFolder
      $session = $null
      try {
        $session = Copy-NetworkTuningVerifiedBackupToStaging -BackupFolder $sourceFolder -Manifest $manifest
        Set-Content -LiteralPath (Join-Path $session.Path $script:NetworkTuningBackupFilePowerplan) -Value $script:NetworkTuningPowerPlanGuidHighPerformance -Encoding utf8 -NoNewline

        $check = Test-NetworkTuningRestoreStagingInvariant -Session $session -Manifest $manifest

        $check.IsValid | Should -BeFalse
        $check.Message | Should -Match 'verification failed|digest mismatch'
      } finally {
        if ($null -ne $session) { Close-NetworkTuningRestoreStagingSession -Session $session }
      }
    }

    It 'blocks consumers when the verified staging directory is moved or replaced' {
      $sourceFolder = Join-Path $TestDrive 'staging-replacement-source'
      $manifest = Get-NetworkLanternStagingFixture -Folder $sourceFolder
      $session = $null
      $movedPath = $null
      try {
        $session = Copy-NetworkTuningVerifiedBackupToStaging -BackupFolder $sourceFolder -Manifest $manifest
        $movedPath = "$($session.Path)-moved"
        Move-Item -LiteralPath $session.Path -Destination $movedPath
        New-Item -ItemType Directory -Path $session.Path -Force | Out-Null

        $check = Test-NetworkTuningRestoreStagingInvariant -Session $session -Manifest $manifest

        $check.IsValid | Should -BeFalse
        $check.Message | Should -Match 'invariant failed|sentinel|verification'
      } finally {
        if ($null -ne $session) { Close-NetworkTuningRestoreStagingSession -Session $session }
        if ($null -ne $movedPath -and (Test-Path -LiteralPath $movedPath)) {
          Remove-Item -LiteralPath $movedPath -Recurse -Force
        }
      }
    }
  }
}
