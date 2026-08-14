Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ManifestPath = Join-Path -Path $PSScriptRoot -ChildPath '../../src/powershell/windows-tuning/NetworkLantern.WindowsTuning/NetworkLantern.WindowsTuning.psd1'
Import-Module -Name $ManifestPath -Force

Describe 'Windows network tuning module' {
  It 'exports Invoke-NetworkPathTuning' {
    (Get-Command -Name Invoke-NetworkPathTuning -ErrorAction Stop).CommandType | Should -Be 'Function'
  }

  It 'does not expose an administrator-check bypass' {
    (Get-Command -Name Invoke-NetworkPathTuning -ErrorAction Stop).Parameters.Keys |
      Should -Not -Contain 'SkipAdminCheck'
  }

  It 'exports Get-NetworkLanternDefaultBackupFolder' {
    (Get-Command -Name Get-NetworkLanternDefaultBackupFolder -ErrorAction Stop).CommandType | Should -Be 'Function'
  }

  It 'does not export legacy tuning entrypoints' {
    { Get-Command -Name Invoke-UdpJitterOptimization -ErrorAction Stop } | Should -Throw
    { Get-Command -Name Get-UjDefaultBackupFolder -ErrorAction Stop } | Should -Throw
  }

  It 'Get-NetworkLanternDefaultBackupFolder returns a suite-named folder' {
    $path = Get-NetworkLanternDefaultBackupFolder
    $path | Should -Not -BeNullOrEmpty
    $path | Should -Match 'NetworkLantern$'
  }

  Context 'DryRun safety' {
    InModuleScope 'NetworkLantern.WindowsTuning' {
      It 'Apply DryRun returns a structured result for Safe profile' {
        Mock -CommandName Assert-UjAdministrator { throw 'administrator check must not run during DryRun' }
        Mock -CommandName Backup-UjState
        Mock -CommandName Resolve-UjRestoreStatus { 'OK' }
        Mock -CommandName Enable-UjLocalQosMarking
        Mock -CommandName New-UjDscpPolicyByPort

        $result = Invoke-NetworkPathTuning -Action Apply -TuningProfile Safe -UdpPorts @(5201, 5202) -DryRun -PassThru

        $result | Should -Not -BeNullOrEmpty
        $result.Action | Should -Be 'Apply'
        $result.TuningProfile | Should -Be 'Safe'
        $result.DryRun | Should -BeTrue
        $result.Success | Should -BeTrue
        $result.UdpPorts.Count | Should -Be 2
        Should -Invoke -CommandName New-UjDscpPolicyByPort -Times 1 -Exactly -ParameterFilter {
          $Name -eq 'NETWORK_LANTERN_QOS_PORT_5201'
        }
        Should -Invoke -CommandName New-UjDscpPolicyByPort -Times 1 -Exactly -ParameterFilter {
          $Name -eq 'NETWORK_LANTERN_QOS_PORT_5202'
        }
        Should -Invoke -CommandName Assert-UjAdministrator -Times 0 -Exactly
      }

      It 'Measured profile applies tier-1 NIC tuning and power plan in DryRun' {
        Mock -CommandName Backup-UjState
        Mock -CommandName Resolve-UjRestoreStatus { 'OK' }
        Mock -CommandName Enable-UjLocalQosMarking
        Mock -CommandName Set-UjNicConfiguration
        Mock -CommandName Set-UjPowerPlan

        $result = Invoke-NetworkPathTuning -Action Apply -TuningProfile Measured -DryRun -PassThru

        $result.Components['NicPowerSaving'] | Should -Be 'Skipped'
        $result.Components['PowerPlan'] | Should -Be 'Skipped'
        Assert-MockCalled -CommandName Set-UjNicConfiguration -Times 1 -Exactly
        Assert-MockCalled -CommandName Set-UjPowerPlan -Times 1 -Exactly
      }

      It 'blocks unsafe backup folder by default' {
        {
          Invoke-NetworkPathTuning -Action Backup -BackupFolder 'C:\Windows\System32\NetworkDiagnosticsSuite' -DryRun
        } | Should -Throw '*unsafe*'
      }
    }
  }

  Context 'Verify mode' {
    InModuleScope 'NetworkLantern.WindowsTuning' {
      It 'reports missing QoS policies' {
        Mock -CommandName Get-UjManagedQosPolicy { @([pscustomobject]@{ Name = 'NDS_QOS_PORT_5201' }) }
        Mock -CommandName Get-ItemProperty { [pscustomobject]@{ 'Do not use NLA' = '1' } }

        $result = Invoke-NetworkPathTuning -Action Verify -UdpPorts @(5201, 5202) -DryRun -PassThru

        $result.Success | Should -BeFalse
        $result.MissingPorts | Should -Contain 5202
      }

      It 'does not report success when QoS verification is unavailable' {
        Mock -CommandName Get-Command {
          param([string]$Name)
          if ($Name -eq 'Get-NetQosPolicy') { return $null }
        }
        Mock -CommandName Get-ItemProperty { [pscustomobject]@{ 'Do not use NLA' = '1' } }

        $result = Invoke-NetworkPathTuning -Action Verify -UdpPorts @(5201) -DryRun -PassThru

        $result.Success | Should -BeFalse
        $result.Components['QosPolicies'] | Should -Be 'Unknown'
        @($result.Warnings).Count | Should -BeGreaterThan 0
      }
    }
  }

  Context 'Apply helper failure status' {
    InModuleScope 'NetworkLantern.WindowsTuning' {
      It 'New-UjDscpPolicyByPort returns false when policy creation fails' {
        function New-NetQosPolicy { throw 'policy limit' }
        Mock -CommandName Get-UjManagedQosPolicy { @() }
        Mock -CommandName New-NetQosPolicy { throw 'policy limit' }

        $result = New-UjDscpPolicyByPort -Name 'NETWORK_LANTERN_QOS_PORT_5201' -PortStart 5201 -PortEnd 5201 -Confirm:$false

        $result | Should -BeOfType [bool]
        $result | Should -BeFalse
      }

      It 'New-UjDscpPolicyByApp returns false when policy creation fails' {
        function New-NetQosPolicy { throw 'policy limit' }
        Mock -CommandName Get-UjManagedQosPolicy { @() }
        Mock -CommandName New-NetQosPolicy { throw 'policy limit' }

        $result = New-UjDscpPolicyByApp -Name 'NETWORK_LANTERN_QOS_APP_1' -ExePath 'C:\app\test.exe' -Confirm:$false

        $result | Should -BeOfType [bool]
        $result | Should -BeFalse
      }

      It 'Set-UjPowerPlan returns false when powercfg cannot switch plans' {
        function powercfg {
          $global:LASTEXITCODE = 1
          'failed'
        }

        $result = Set-UjPowerPlan -PowerPlan HighPerformance -Confirm:$false

        $result | Should -BeOfType [bool]
        $result | Should -BeFalse
      }

      It 'Set-UjNicConfiguration returns false when adapters cannot be detected' {
        $result = Set-UjNicConfiguration -Preset 1 -Confirm:$false

        $result | Should -BeOfType [bool]
        $result | Should -BeFalse
      }

      It 'Set-UjNicConfiguration returns false when no active physical adapter exists' {
        try {
          [Microsoft.PowerShell.Cmdletization.GeneratedTypes.NetAdapter.NetAdapter] | Out-Null
        } catch {
          Add-Type -TypeDefinition @'
namespace Microsoft.PowerShell.Cmdletization.GeneratedTypes.NetAdapter {
  public class NetAdapter {}
}
'@
        }
        Mock -CommandName Get-UjPhysicalUpAdapter { @() }

        $result = Set-UjNicConfiguration -Preset 1 -Confirm:$false

        $result | Should -BeOfType [bool]
        $result | Should -BeFalse
      }
    }
  }

  Context 'Apply backup verification' {
    InModuleScope 'NetworkLantern.WindowsTuning' {
      It 'refuses mutation when the backup status is incomplete' {
        if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
          Set-ItResult -Skipped -Because 'the public Apply path refuses non-Windows mutation before backup verification'
          return
        }

        Mock -CommandName Backup-UjState { [pscustomobject]@{ Status = 'Warn'; Message = 'QoS backup failed.' } }
        Mock -CommandName Resolve-UjRestoreStatus { 'Warn' }
        Mock -CommandName Read-UjBackupManifest { [pscustomobject]@{ Status = 'Invalid'; Message = 'Backup artifact digest mismatch.' } }
        Mock -CommandName Enable-UjLocalQosMarking { throw 'must not mutate' }
        Mock -CommandName Assert-UjAdministrator

        { Invoke-NetworkPathTuning -Action Apply -BackupFolder $TestDrive } |
          Should -Throw '*backup was not verified*'

        Assert-MockCalled -CommandName Read-UjBackupManifest -Times 1 -Exactly
        Assert-MockCalled -CommandName Enable-UjLocalQosMarking -Times 0 -Exactly
      }
    }
  }

  It 'CLI wrapper resolves default backup folder via module function' {
    $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath '../../apps/windows-tuning/Invoke-NetworkPathTuning.ps1'
    $result = & $scriptPath -Action Backup -DryRun -PassThru

    $result | Should -Not -BeNullOrEmpty
    $result.BackupFolder | Should -Be (Get-NetworkLanternDefaultBackupFolder)
  }

  It 'CLI wrapper emits no structured result unless PassThru was requested' {
    $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath '../../apps/windows-tuning/Invoke-NetworkPathTuning.ps1'

    $result = @(& $scriptPath -Action Backup -DryRun)

    $result.Count | Should -Be 0
  }

  It 'CLI wrapper exits nonzero for an unsuccessful result without PassThru' {
    $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath '../../apps/windows-tuning/Invoke-NetworkPathTuning.ps1'

    $output = & pwsh -NoLogo -NoProfile -NonInteractive -File $scriptPath -Action Verify -UdpPorts 5201 -DryRun 2>&1

    $LASTEXITCODE | Should -Be 1
    ($output | Out-String) | Should -Not -Match '^\s*Success\s*:'
  }

  It 'CLI wrapper exits nonzero when a restore manifest has no components' {
    $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath '../../apps/windows-tuning/Invoke-NetworkPathTuning.ps1'
    $backupFolder = Join-Path $TestDrive 'cli-empty-components-backup'
    New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
    @{
      SchemaVersion = 1
      ToolName = 'network-diagnostics-suite'
      Timestamp = '2026-01-01T00:00:00Z'
      Components = @{}
      ArtifactDigests = @{}
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Encoding UTF8

    $output = & pwsh -NoLogo -NoProfile -NonInteractive -File $scriptPath -Action Restore -BackupFolder $backupFolder -DryRun 2>&1

    $LASTEXITCODE | Should -Be 1
    ($output | Out-String) | Should -Not -Match '^\s*Success\s*:'
  }

  It 'CLI wrapper exits nonzero for every invalid restore-manifest JSON shape' {
    $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath '../../apps/windows-tuning/Invoke-NetworkPathTuning.ps1'
    $invalidPayloads = [ordered]@{
      NullRoot = 'null'
      ArrayRoot = '[]'
      ScalarRoot = '"manifest"'
      NonnumericSchema = '{"SchemaVersion":"one","Components":{}}'
    }

    foreach ($caseName in $invalidPayloads.Keys) {
      $backupFolder = Join-Path $TestDrive "cli-invalid-shape-$caseName"
      New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
      Set-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Value $invalidPayloads[$caseName] -Encoding UTF8

      $output = & pwsh -NoLogo -NoProfile -NonInteractive -File $scriptPath -Action Restore -BackupFolder $backupFolder -DryRun 2>&1

      $LASTEXITCODE | Should -Be 1 -Because "$caseName must fail closed"
      ($output | Out-String) | Should -Not -Match '^\s*Success\s*:'
    }
  }

  It 'GUI entrypoint is informational instead of failing' {
    $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath '../../apps/windows-tuning/Invoke-NetworkPathTuning-GUI.ps1'
    $output = & pwsh -NoLogo -NoProfile -File $scriptPath 2>&1

    $LASTEXITCODE | Should -Be 0
    $message = $output | Out-String
    $message | Should -Match 'CLI-first'
    $message | Should -Match 'compatibility entrypoint'
    $message | Should -Match 'does not launch a GUI'
  }

  Context 'Backup action' {
    InModuleScope 'NetworkLantern.WindowsTuning' {
      It 'Backup action with PassThru returns a structured result' {
        Mock -CommandName Backup-UjState {
          [pscustomobject]@{ Status = 'OK'; Message = 'Backup complete.' }
        }
        Mock -CommandName Resolve-UjRestoreStatus { 'OK' }

        $result = Invoke-NetworkPathTuning -Action Backup -DryRun -PassThru

        $result | Should -Not -BeNullOrEmpty
        $result.Action | Should -Be 'Backup'
        $result.DryRun | Should -BeTrue
        $result.Success | Should -BeTrue
        $result.Components['Backup'] | Should -Be 'OK'
      }

      It 'marks backup incomplete when QoS policies cannot be read' {
        $backupFolder = Join-Path $TestDrive 'qos-read-failure-backup'
        try {
          [Microsoft.PowerShell.Cmdletization.GeneratedTypes.NetAdapter.NetAdapter] | Out-Null
        } catch {
          Add-Type -TypeDefinition @'
namespace Microsoft.PowerShell.Cmdletization.GeneratedTypes.NetAdapter {
  public class NetAdapter {}
}
'@
        }
        function Get-NetAdapterRsc {}
        function powercfg {
          $global:LASTEXITCODE = 1
          @()
        }

        Mock -CommandName Export-UjRegistryKey { $true }
        Mock -CommandName Get-UjManagedQosPolicy {
          param([switch]$ErrorOnFailure)
          if ($ErrorOnFailure) {
            throw 'qos read failed'
          }
          @()
        }
        Mock -CommandName Get-UjPhysicalUpAdapter { @() }
        Mock -CommandName Get-NetAdapterRsc { @() }

        $result = Backup-UjState -BackupFolder $backupFolder -Confirm:$false
        $manifest = Get-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Raw |
          ConvertFrom-Json

        $result.Status | Should -Be 'Warn'
        $manifest.Components.QosPolicies | Should -BeFalse
      }

      It 'writes an explicit restorable artifact when no managed QoS policies exist' {
        $backupFolder = Join-Path $TestDrive 'empty-qos-backup'
        try {
          [Microsoft.PowerShell.Cmdletization.GeneratedTypes.NetAdapter.NetAdapter] | Out-Null
        } catch {
          Add-Type -TypeDefinition @'
namespace Microsoft.PowerShell.Cmdletization.GeneratedTypes.NetAdapter {
  public class NetAdapter {}
}
'@
        }
        function Get-NetAdapterRsc {}
        function powercfg {
          $global:LASTEXITCODE = 1
          @()
        }

        Mock -CommandName Export-UjRegistryKey { $false }
        Mock -CommandName Get-UjManagedQosPolicy { @() }
        Mock -CommandName Get-UjPhysicalUpAdapter { @() }
        Mock -CommandName Get-NetAdapterRsc { @() }

        $null = Backup-UjState -BackupFolder $backupFolder -Confirm:$false
        $qosPath = Join-Path $backupFolder $script:UjBackupFileQosOurs
        $manifest = Get-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Raw | ConvertFrom-Json

        Test-Path -LiteralPath $qosPath -PathType Leaf | Should -BeTrue
        $restoredQos = Import-Clixml -LiteralPath $qosPath
        @($restoredQos).Count | Should -Be 0
        $manifest.Components.QosPolicies | Should -BeTrue
      }

      It 'does not mark missing NIC RSC or power-plan artifacts complete' {
        $backupFolder = Join-Path $TestDrive 'missing-optional-artifacts-backup'
        try {
          [Microsoft.PowerShell.Cmdletization.GeneratedTypes.NetAdapter.NetAdapter] | Out-Null
        } catch {
          Add-Type -TypeDefinition @'
namespace Microsoft.PowerShell.Cmdletization.GeneratedTypes.NetAdapter {
  public class NetAdapter {}
}
'@
        }
        function Get-NetAdapterRsc {}
        function powercfg {
          $global:LASTEXITCODE = 1
          @()
        }

        Mock -CommandName Export-UjRegistryKey { $false }
        Mock -CommandName Get-UjManagedQosPolicy { @() }
        Mock -CommandName Get-UjPhysicalUpAdapter { @() }
        Mock -CommandName Get-NetAdapterRsc { @() }

        $result = Backup-UjState -BackupFolder $backupFolder -Confirm:$false
        $manifest = Get-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Raw | ConvertFrom-Json

        $result.Status | Should -Be 'Warn'
        $manifest.Components.NicAdvanced | Should -BeFalse
        $manifest.Components.NicRsc | Should -BeFalse
        $manifest.Components.PowerPlan | Should -BeFalse
      }
    }
  }

  Context 'Restore action' {
    InModuleScope 'NetworkLantern.WindowsTuning' {
    It 'Restore action with a valid manifest succeeds when all components report OK' {
        Mock -CommandName Restore-UjState {
          @{ Registry = 'OK'; QosPolicies = 'OK'; Manifest = 'OK' }
        }

        $result = Invoke-NetworkPathTuning -Action Restore -DryRun -PassThru

        $result | Should -Not -BeNullOrEmpty
        $result.Action | Should -Be 'Restore'
        $result.Success | Should -BeTrue
        $result.Components['Registry'] | Should -Be 'OK'
        $result.Components['QosPolicies'] | Should -Be 'OK'
      }

      It 'Restore action reports failure when a dry-run manifest has no components' {
        $backupFolder = Join-Path $TestDrive 'public-empty-components-backup'
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
        @{
          SchemaVersion = $script:UjBackupSchemaVersion
          ToolName = 'network-diagnostics-suite'
          Timestamp = '2026-01-01T00:00:00Z'
          Components = @{}
          ArtifactDigests = @{}
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Encoding UTF8

        $result = Invoke-NetworkPathTuning -Action Restore -BackupFolder $backupFolder -DryRun -PassThru

        $result.Success | Should -BeFalse
        $result.Components['Manifest'] | Should -Be 'Warn'
      }

      It 'Restore action reports failure for every invalid manifest JSON shape' {
        $invalidPayloads = [ordered]@{
          NullRoot = 'null'
          ArrayRoot = '[]'
          ScalarRoot = '"manifest"'
          NonnumericSchema = '{"SchemaVersion":"one","Components":{}}'
        }

        foreach ($caseName in $invalidPayloads.Keys) {
          $backupFolder = Join-Path $TestDrive "public-invalid-shape-$caseName"
          New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
          Set-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Value $invalidPayloads[$caseName] -Encoding UTF8

          $result = Invoke-NetworkPathTuning -Action Restore -BackupFolder $backupFolder -DryRun -PassThru

          $result.Success | Should -BeFalse -Because "$caseName must fail closed"
          $result.Components['Manifest'] | Should -Be 'Warn'
        }
      }
    }

    InModuleScope 'NetworkLantern.WindowsTuning' {
      It 'falls back to the legacy default backup when the new default has no manifest' {
        $previousDefault = $script:UjDefaultBackupFolder
        $previousLegacyDefault = $script:UjLegacyDefaultBackupFolder
        try {
          $script:UjDefaultBackupFolder = Join-Path $TestDrive 'NetworkLantern'
          $script:UjLegacyDefaultBackupFolder = Join-Path $TestDrive 'NetworkDiagnosticsSuite'
          New-Item -ItemType Directory -Path $script:UjLegacyDefaultBackupFolder -Force | Out-Null
          Set-Content -LiteralPath (Join-Path $script:UjLegacyDefaultBackupFolder 'backup_manifest.json') -Value '{}' -Encoding UTF8
          Mock -CommandName Restore-UjState { [ordered]@{ Manifest = 'OK' } }

          $result = Invoke-NetworkPathTuning -Action Restore -DryRun -PassThru

          $result.Success | Should -BeTrue
          $result.BackupFolder | Should -Be $script:UjLegacyDefaultBackupFolder
          Should -Invoke -CommandName Restore-UjState -Times 1 -Exactly -ParameterFilter {
            $BackupFolder -eq $script:UjLegacyDefaultBackupFolder
          }
        } finally {
          $script:UjDefaultBackupFolder = $previousDefault
          $script:UjLegacyDefaultBackupFolder = $previousLegacyDefault
        }
      }
    }
  }

  Context 'IncludeAppPolicies flag' {
    InModuleScope 'NetworkLantern.WindowsTuning' {
      It 'IncludeAppPolicies with AppPaths reaches New-UjDscpPolicyByApp' {
        Mock -CommandName Backup-UjState
        Mock -CommandName Resolve-UjRestoreStatus { 'OK' }
        Mock -CommandName Enable-UjLocalQosMarking
        Mock -CommandName New-UjDscpPolicyByPort
        Mock -CommandName New-UjDscpPolicyByApp

        $result = Invoke-NetworkPathTuning `
          -Action Apply `
          -IncludeAppPolicies `
          -AppPaths @('C:\app\test.exe') `
          -DryRun `
          -PassThru

        Assert-MockCalled -CommandName New-UjDscpPolicyByApp -Times 1 -Exactly
        $result.IncludeAppPolicies | Should -BeTrue
        $result.AppPaths | Should -Contain 'C:\app\test.exe'
      }
    }
  }

  Context 'Non-Windows safety guard' {
    It 'throws on non-Windows without -DryRun' {
      $runningOnWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::Windows
      )
      if ($runningOnWindows) {
        Set-ItResult -Skipped -Because 'running on Windows; non-Windows guard cannot be exercised'
        return
      }

      { Invoke-NetworkPathTuning -Action Apply } | Should -Throw '*Windows*'
    }
  }

  Context 'Backup manifest metadata' {
    InModuleScope 'NetworkLantern.WindowsTuning' {
      It 'Get-UjBackupManifestMetadata returns required enrichment fields' {
        $metadata = Get-UjBackupManifestMetadata

        $metadata | Should -Not -BeNullOrEmpty
        $metadata['SchemaVersion'] | Should -BeGreaterThan 0
        $metadata['ToolName'] | Should -Be 'network-lantern'
        $metadata['MachineName'] | Should -Not -BeNullOrEmpty
        $metadata['Platform'] | Should -Not -BeNullOrEmpty
        $metadata['OsVersion'] | Should -Not -BeNullOrEmpty
      }
    }
  }
}
