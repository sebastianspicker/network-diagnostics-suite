Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$discoveryRepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$manifestPath = Join-Path $discoveryRepoRoot 'src/powershell/windows-tuning/NetworkLantern.WindowsTuning/NetworkLantern.WindowsTuning.psd1'
Import-Module -Name $manifestPath -Force

BeforeAll {
  $script:RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

Describe 'Windows tuning public contracts' {
  It 'exports only the supported tuning commands and no legacy entrypoints' {
    $exports = @(Get-Command -Module NetworkLantern.WindowsTuning -CommandType Function |
        Select-Object -ExpandProperty Name | Sort-Object)

    $exports | Should -Be @(
      'Get-NetworkLanternDefaultBackupFolder',
      'Invoke-NetworkPathTuning',
      'Test-NetworkTuningAdministrator'
    )
    { Get-Command -Name Invoke-UdpJitterOptimization -ErrorAction Stop } | Should -Throw
    { Get-Command -Name Get-UjDefaultBackupFolder -ErrorAction Stop } | Should -Throw
    (Get-Command Invoke-NetworkPathTuning).Parameters.Keys | Should -Not -Contain 'SkipAdminCheck'
  }

  It 'keeps NetworkLantern and NetworkDiagnosticsSuite backup names compatible' {
    Get-NetworkLanternDefaultBackupFolder | Should -Match 'NetworkLantern$'

    InModuleScope NetworkLantern.WindowsTuning {
      $script:NetworkTuningLegacyDefaultBackupFolder | Should -Match 'NetworkDiagnosticsSuite$'
      $script:NetworkTuningCompatibleToolNames | Should -Contain 'network-lantern'
      $script:NetworkTuningCompatibleToolNames | Should -Contain 'network-diagnostics-suite'
    }
  }

  It 'keeps the adapter thin and leaves implicit restore-folder selection to the module' {
    $adapterPath = Join-Path $script:RepoRoot 'apps/windows-tuning/Invoke-NetworkPathTuning.ps1'
    $adapterSource = Get-Content -LiteralPath $adapterPath -Raw

    $adapterSource | Should -Not -Match 'NetworkDiagnosticsSuite|Get-NetworkLanternDefaultBackupFolder'
  }

  InModuleScope NetworkLantern.WindowsTuning {
    It 'does not load retired reset or historical mutation paths' {
      $moduleRoot = Split-Path -Parent $ExecutionContext.SessionState.Module.Path
      Test-Path -LiteralPath (Join-Path $moduleRoot 'Private/Actions.Reset.ps1') | Should -BeFalse
      (Get-Command -Name Reset-NetworkTuningBaseline -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
    }
    It 'selects the legacy folder only when Restore omits BackupFolder' {
      $originalDefault = $script:NetworkTuningDefaultBackupFolder
      $originalLegacy = $script:NetworkTuningLegacyDefaultBackupFolder
      try {
        $script:NetworkTuningDefaultBackupFolder = Join-Path $TestDrive 'current-default'
        $script:NetworkTuningLegacyDefaultBackupFolder = Join-Path $TestDrive 'legacy-default'
        New-Item -ItemType Directory -Path $script:NetworkTuningLegacyDefaultBackupFolder -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:NetworkTuningLegacyDefaultBackupFolder $script:NetworkTuningBackupFileManifest) -Value '{}' -Encoding utf8
        Mock Restore-NetworkTuningState {
          [ordered]@{ Manifest = 'OK'; Registry = 'Skipped'; Qos = 'Skipped'; NicAdvanced = 'Skipped'; Rsc = 'Skipped'; PowerPlan = 'Skipped' }
        }

        $result = Invoke-NetworkPathTuning -Action Restore -DryRun -PassThru

        $result.BackupFolder | Should -Be $script:NetworkTuningLegacyDefaultBackupFolder
        Assert-MockCalled Restore-NetworkTuningState -Times 1 -Exactly -ParameterFilter {
          $BackupFolder -eq $script:NetworkTuningLegacyDefaultBackupFolder
        }
      } finally {
        $script:NetworkTuningDefaultBackupFolder = $originalDefault
        $script:NetworkTuningLegacyDefaultBackupFolder = $originalLegacy
      }
    }
  }

  Context 'non-Windows mutation guard' {
    It 'rejects live tuning before it can create a backup directory' {
      if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
        Set-ItResult -Skipped -Because 'this guard is specific to non-Windows hosts'
        return
      }

      $backupFolder = Join-Path $TestDrive 'must-not-be-created'
      { Invoke-NetworkPathTuning -Action Apply -BackupFolder $backupFolder } | Should -Throw '*require Windows*'
      Test-Path -LiteralPath $backupFolder | Should -BeFalse
    }
  }

  Context 'dry-run result contract' {
    InModuleScope NetworkLantern.WindowsTuning {
      It 'returns a structured Safe preview without writing the requested backup folder' {
        $backupFolder = Join-Path $TestDrive 'safe-preview'
        Mock Backup-NetworkTuningState { [pscustomobject]@{ Status = 'Skipped' } }
        Mock Resolve-NetworkTuningRestoreStatus { 'OK' }
        Mock Enable-NetworkTuningLocalQosMarking {}
        Mock New-NetworkTuningDscpPolicyByPort { $true }

        $result = Invoke-NetworkPathTuning -Action Apply -TuningProfile Safe -UdpPorts @(5202, 5201, 5201) -BackupFolder $backupFolder -DryRun -PassThru

        $result.Action | Should -Be 'Apply'
        $result.TuningProfile | Should -Be 'Safe'
        $result.DryRun | Should -BeTrue
        $result.Success | Should -BeTrue
        $result.UdpPorts | Should -Be @(5201, 5202)
        $result.Components['Backup'] | Should -Be 'OK'
        $result.Components['NicPowerSaving'] | Should -Be 'Skipped'
        Test-Path -LiteralPath $backupFolder | Should -BeFalse
      }

      It 'reports Measured preview-only NIC and power-plan components as skipped' {
        Mock Backup-NetworkTuningState { [pscustomobject]@{ Status = 'Skipped' } }
        Mock Resolve-NetworkTuningRestoreStatus { 'OK' }
        Mock Enable-NetworkTuningLocalQosMarking {}
        Mock Set-NetworkTuningNicConfiguration { $true }
        Mock Set-NetworkTuningPowerPlan { $true }

        $result = Invoke-NetworkPathTuning -Action Apply -TuningProfile Measured -BackupFolder (Join-Path $TestDrive 'measured-preview') -DryRun -PassThru

        $result.Success | Should -BeTrue
        $result.Components['NicPowerSaving'] | Should -Be 'Skipped'
        $result.Components['PowerPlan'] | Should -Be 'Skipped'
      }

      It 'rejects a sensitive backup location even for a dry-run' {
        { Invoke-NetworkPathTuning -Action Backup -BackupFolder 'C:\Windows\System32\NetworkLantern' -DryRun } |
          Should -Throw '*unsafe*'
      }
    }
  }

  Context 'CLI behavior' {
    It 'keeps structured output opt-in through PassThru' {
      $cliPath = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'apps/windows-tuning/Invoke-NetworkPathTuning.ps1'
      $withoutPassThru = @(& $cliPath -Action Backup -DryRun)
      $withPassThru = @(& $cliPath -Action Backup -DryRun -PassThru)

      $withoutPassThru.Count | Should -Be 0
      $withPassThru.Count | Should -Be 1
      $withPassThru[0].Action | Should -Be 'Backup'
      $withPassThru[0].DryRun | Should -BeTrue
      $withPassThru[0].Success | Should -BeTrue
    }

    It 'returns a nonzero process exit for an invalid restore manifest without emitting a result' {
      $cliPath = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'apps/windows-tuning/Invoke-NetworkPathTuning.ps1'
      $backupFolder = Join-Path $TestDrive 'invalid-cli-restore'
      New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
      Set-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Value '{"SchemaVersion":"not-an-int","Components":{}}' -Encoding utf8

      $output = & pwsh -NoLogo -NoProfile -NonInteractive -File $cliPath -Action Restore -BackupFolder $backupFolder -DryRun 2>&1

      $LASTEXITCODE | Should -Be 1
      ($output | Out-String) | Should -Not -Match '^\s*Success\s*:'
    }
  }

  Context 'apply backup verification' {
    InModuleScope NetworkLantern.WindowsTuning {
      It 'refuses to apply when backup verification is not OK' {
        if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
          Set-ItResult -Skipped -Because 'live Apply is intentionally blocked before backup verification on non-Windows'
          return
        }

        Mock Assert-NetworkTuningAdministrator {}
        Mock Backup-NetworkTuningState { [pscustomobject]@{ Status = 'Warn' } }
        Mock Resolve-NetworkTuningRestoreStatus { 'Warn' }
        Mock Read-NetworkTuningBackupManifest { [pscustomobject]@{ Status = 'Invalid'; Message = 'digest mismatch' } }
        Mock Enable-NetworkTuningLocalQosMarking { throw 'must not mutate' }

        { Invoke-NetworkPathTuning -Action Apply -BackupFolder (Join-Path $TestDrive 'incomplete-backup') } |
          Should -Throw '*backup was not verified*'
      }
    }
  }
}
