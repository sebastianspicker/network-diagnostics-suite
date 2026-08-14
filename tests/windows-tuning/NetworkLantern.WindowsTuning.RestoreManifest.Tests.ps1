Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ManifestPath = Join-Path -Path $PSScriptRoot -ChildPath '../../src/powershell/windows-tuning/NetworkLantern.WindowsTuning/NetworkLantern.WindowsTuning.psd1'
Import-Module -Name $ManifestPath -Force

Describe 'Windows network tuning module' {
  Context 'Restore safety and reset scope' {
    InModuleScope 'NetworkLantern.WindowsTuning' {
      BeforeEach {
        $runningOnWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
          [System.Runtime.InteropServices.OSPlatform]::Windows
        )
        if ($runningOnWindows) {
          # Pester's Windows TestDrive inherits the host TEMP ACL, which can be
          # writable by unrelated identities. Give source fixtures a trusted
          # DACL and redirect privileged staging to the disposable test root.
          $testDriveAcl = [System.Security.AccessControl.DirectorySecurity]::new()
          $testDriveAcl.SetAccessRuleProtection($true, $false)
          $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
            [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
          $trustedFixtureSids = @(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value,
            'S-1-5-18',
            'S-1-5-32-544'
          )
          foreach ($sidValue in $trustedFixtureSids) {
            $sid = [System.Security.Principal.SecurityIdentifier]::new($sidValue)
            $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
              $sid,
              [System.Security.AccessControl.FileSystemRights]::FullControl,
              $inheritance,
              [System.Security.AccessControl.PropagationFlags]::None,
              [System.Security.AccessControl.AccessControlType]::Allow
            )
            $testDriveAcl.AddAccessRule($rule) | Out-Null
          }
          [System.IO.FileSystemAclExtensions]::SetAccessControl(
            [System.IO.DirectoryInfo]::new($TestDrive),
            $testDriveAcl
          )

          $script:UjRestoreFixtureRoot = $TestDrive
          Mock -CommandName Get-UjWindowsRestoreStagingRoot { $script:UjRestoreFixtureRoot }
          Mock -CommandName Initialize-UjAdminOnlyDirectory {
            param([string]$Path)
            return [System.IO.Directory]::CreateDirectory($Path).FullName
          }
          Mock -CommandName Protect-UjAdminOnlyFile
          Mock -CommandName Test-UjWindowsAdminOnlyPath {
            [pscustomobject]@{ IsTrusted = $true; Message = '' }
          }
        }
      }
      It 'uses a fixed administrative SID allow-list for privileged restore staging' {
        $trustedSids = @(Get-UjTrustedStagingSidValue)

        $trustedSids.Count | Should -Be 3
        $trustedSids | Should -Contain 'S-1-5-18'
        $trustedSids | Should -Contain 'S-1-5-32-544'
        $trustedSids | Should -Contain 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
        $trustedSids | Should -Not -Contain 'S-1-1-0'
        $trustedSids | Should -Not -Contain 'S-1-5-11'
        $trustedSids | Should -Not -Contain 'S-1-5-32-545'
      }

      It 'rejects missing backup manifests before restore work starts' {
        $backupFolder = Join-Path $TestDrive 'missing-manifest-backup'
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null

        Mock -CommandName Restore-UjRegistryFromBackup { throw 'should not run' }
        Mock -CommandName Restore-UjQosFromBackup { throw 'should not run' }
        Mock -CommandName Restore-UjNicFromBackup { throw 'should not run' }
        Mock -CommandName Restore-UjRscFromBackup { throw 'should not run' }
        Mock -CommandName Restore-UjPowerPlanFromBackup { throw 'should not run' }

        $result = Restore-UjState -BackupFolder $backupFolder

        $result['Manifest'] | Should -Be 'Warn'
        $result['Registry'] | Should -Be 'Skipped'
      }

      It 'rejects invalid backup manifests before restore work starts' {
        $backupFolder = Join-Path $TestDrive 'invalid-manifest-backup'
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Value '{' -Encoding UTF8

        Mock -CommandName Restore-UjRegistryFromBackup { throw 'should not run' }
        Mock -CommandName Restore-UjQosFromBackup { throw 'should not run' }
        Mock -CommandName Restore-UjNicFromBackup { throw 'should not run' }
        Mock -CommandName Restore-UjRscFromBackup { throw 'should not run' }
        Mock -CommandName Restore-UjPowerPlanFromBackup { throw 'should not run' }

        $result = Restore-UjState -BackupFolder $backupFolder

        $result['Manifest'] | Should -Be 'Warn'
        $result['Registry'] | Should -Be 'Skipped'
      }

      It 'rejects a backup manifest without a Components map' {
        $backupFolder = Join-Path $TestDrive 'missing-components-backup'
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
        @{
          SchemaVersion = $script:UjBackupSchemaVersion
          ToolName = 'network-diagnostics-suite'
          Timestamp = '2026-01-01T00:00:00Z'
          ArtifactDigests = @{}
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Encoding UTF8

        $result = Read-UjBackupManifest -BackupFolder $backupFolder

        $result.Status | Should -Be 'Invalid'
        $result.Message | Should -Match 'Components'
      }

      It 'rejects a backup manifest whose Components value is not a map' {
        $backupFolder = Join-Path $TestDrive 'nondictionary-components-backup'
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
        @{
          SchemaVersion = $script:UjBackupSchemaVersion
          ToolName = 'network-diagnostics-suite'
          Timestamp = '2026-01-01T00:00:00Z'
          Components = @('PowerPlan')
          ArtifactDigests = @{}
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Encoding UTF8

        $result = Read-UjBackupManifest -BackupFolder $backupFolder

        $result.Status | Should -Be 'Invalid'
        $result.Message | Should -Match 'dictionary'
      }

      It 'rejects a backup manifest with an empty Components map' {
        $backupFolder = Join-Path $TestDrive 'literal-empty-components-backup'
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
        @{
          SchemaVersion = $script:UjBackupSchemaVersion
          ToolName = 'network-diagnostics-suite'
          Timestamp = '2026-01-01T00:00:00Z'
          Components = @{}
          ArtifactDigests = @{}
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Encoding UTF8

        $result = Read-UjBackupManifest -BackupFolder $backupFolder

        $result.Status | Should -Be 'Invalid'
        $result.Message | Should -Match 'missing component state'
      }

      It 'rejects a backup manifest with no enabled component' {
        $backupFolder = Join-Path $TestDrive 'empty-components-backup'
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
        @{
          SchemaVersion = $script:UjBackupSchemaVersion
          ToolName = 'network-diagnostics-suite'
          Timestamp = '2026-01-01T00:00:00Z'
          Components = @{
            SystemProfile = $false
            AfdParameters = $false
            QosPolicies = $false
            NicAdvanced = $false
            NicRsc = $false
            PowerPlan = $false
          }
          ArtifactDigests = @{}
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Encoding UTF8

        $result = Read-UjBackupManifest -BackupFolder $backupFolder

        $result.Status | Should -Be 'Invalid'
        $result.Message | Should -Match 'at least one'
      }

      It 'rejects a backup manifest with an unknown component' {
        $backupFolder = Join-Path $TestDrive 'unknown-component-backup'
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
        @{
          SchemaVersion = $script:UjBackupSchemaVersion
          ToolName = 'network-diagnostics-suite'
          Timestamp = '2026-01-01T00:00:00Z'
          Components = @{
            SystemProfile = $false
            AfdParameters = $false
            QosPolicies = $false
            NicAdvanced = $false
            NicRsc = $false
            PowerPlan = $true
            ArbitraryCommand = $true
          }
          ArtifactDigests = @{}
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Encoding UTF8

        $result = Read-UjBackupManifest -BackupFolder $backupFolder

        $result.Status | Should -Be 'Invalid'
        $result.Message | Should -Match 'unknown component'
      }

      It 'rejects a backup manifest whose component key casing is not exact' {
        $backupFolder = Join-Path $TestDrive 'wrong-case-component-backup'
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
        @{
          SchemaVersion = $script:UjBackupSchemaVersion
          ToolName = 'network-diagnostics-suite'
          Timestamp = '2026-01-01T00:00:00Z'
          Components = @{
            SystemProfile = $false
            AfdParameters = $false
            QosPolicies = $false
            NicAdvanced = $false
            NicRsc = $false
            powerplan = $true
          }
          ArtifactDigests = @{}
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Encoding UTF8

        $result = Read-UjBackupManifest -BackupFolder $backupFolder

        $result.Status | Should -Be 'Invalid'
        $result.Message | Should -Match 'unknown component'
      }

      It 'rejects a backup manifest whose top-level Components casing is not exact' {
        $backupFolder = Join-Path $TestDrive 'wrong-case-components-property-backup'
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
        @'
{
  "SchemaVersion": 1,
  "ToolName": "network-diagnostics-suite",
  "Timestamp": "2026-01-01T00:00:00Z",
  "components": {
    "SystemProfile": false,
    "AfdParameters": false,
    "QosPolicies": false,
    "NicAdvanced": false,
    "NicRsc": false,
    "PowerPlan": true
  },
  "ArtifactDigests": {}
}
'@ | Set-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Encoding UTF8

        $result = Read-UjBackupManifest -BackupFolder $backupFolder

        $result.Status | Should -Be 'Invalid'
        $result.Message | Should -Match 'casing.*Components'
      }

      It 'rejects duplicate component keys before JSON hashtable conversion' {
        $backupFolder = Join-Path $TestDrive 'duplicate-component-backup'
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
        @'
{
  "SchemaVersion": 1,
  "ToolName": "network-diagnostics-suite",
  "Timestamp": "2026-01-01T00:00:00Z",
  "Components": {
    "SystemProfile": false,
    "AfdParameters": false,
    "QosPolicies": false,
    "NicAdvanced": false,
    "NicRsc": false,
    "PowerPlan": true,
    "PowerPlan": false
  },
  "ArtifactDigests": {}
}
'@ | Set-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Encoding UTF8

        $result = Read-UjBackupManifest -BackupFolder $backupFolder

        $result.Status | Should -Be 'Invalid'
        $result.Message | Should -Match 'duplicate component.*PowerPlan'
      }

      It 'rejects case-variant component pairs before JSON hashtable conversion' {
        $backupFolder = Join-Path $TestDrive 'case-variant-component-pair-backup'
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
        @'
{
  "SchemaVersion": 1,
  "ToolName": "network-diagnostics-suite",
  "Timestamp": "2026-01-01T00:00:00Z",
  "Components": {
    "SystemProfile": false,
    "AfdParameters": false,
    "QosPolicies": false,
    "NicAdvanced": false,
    "NicRsc": false,
    "PowerPlan": true,
    "powerplan": false
  },
  "ArtifactDigests": {}
}
'@ | Set-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Encoding UTF8

        $result = Read-UjBackupManifest -BackupFolder $backupFolder

        $result.Status | Should -Be 'Invalid'
        $result.Message | Should -Match 'duplicate component or case variant'
      }

      It 'rejects a backup manifest with a nonboolean component state' {
        $backupFolder = Join-Path $TestDrive 'nonboolean-component-backup'
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
        @{
          SchemaVersion = $script:UjBackupSchemaVersion
          ToolName = 'network-diagnostics-suite'
          Timestamp = '2026-01-01T00:00:00Z'
          Components = @{
            SystemProfile = $false
            AfdParameters = $false
            QosPolicies = $false
            NicAdvanced = $false
            NicRsc = $false
            PowerPlan = 'true'
          }
          ArtifactDigests = @{}
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Encoding UTF8

        $result = Read-UjBackupManifest -BackupFolder $backupFolder

        $result.Status | Should -Be 'Invalid'
        $result.Message | Should -Match 'boolean'
      }

      It 'rejects incompatible backup manifests before restore work starts' {
        $backupFolder = Join-Path $TestDrive 'incompatible-backup'
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
        @{
          SchemaVersion = 999
          ToolName = 'network-diagnostics-suite'
          Timestamp = '2026-01-01T00:00:00Z'
          Components = @{
            SystemProfile = $false
            AfdParameters = $false
            QosPolicies = $false
            NicAdvanced = $false
            NicRsc = $false
            PowerPlan = $true
          }
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Encoding UTF8

        Mock -CommandName Restore-UjRegistryFromBackup { throw 'should not run' }
        Mock -CommandName Restore-UjQosFromBackup { throw 'should not run' }
        Mock -CommandName Restore-UjNicFromBackup { throw 'should not run' }
        Mock -CommandName Restore-UjRscFromBackup { throw 'should not run' }
        Mock -CommandName Restore-UjPowerPlanFromBackup { throw 'should not run' }

        $result = Restore-UjState -BackupFolder $backupFolder

        $result['Manifest'] | Should -Be 'Warn'
        $result['Registry'] | Should -Be 'Skipped'
      }

      It 'rejects restore manifests without artifact digests before restore work starts' {
        $backupFolder = Join-Path $TestDrive 'unsigned-manifest-backup'
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $backupFolder $script:UjBackupFilePowerplan) -Value $script:UjPowerPlanGuidBalanced -Encoding UTF8
        @{
          SchemaVersion = $script:UjBackupSchemaVersion
          ToolName = 'network-diagnostics-suite'
          Timestamp = '2026-01-01T00:00:00Z'
          Components = @{
            SystemProfile = $false
            AfdParameters = $false
            QosPolicies = $false
            NicAdvanced = $false
            NicRsc = $false
            PowerPlan = $true
          }
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Encoding UTF8

        Mock -CommandName Restore-UjRegistryFromBackup { throw 'should not run' }
        Mock -CommandName Restore-UjQosFromBackup { throw 'should not run' }
        Mock -CommandName Restore-UjNicFromBackup { throw 'should not run' }
        Mock -CommandName Restore-UjRscFromBackup { throw 'should not run' }
        Mock -CommandName Restore-UjPowerPlanFromBackup { throw 'should not run' }

        $result = Restore-UjState -BackupFolder $backupFolder

        $result['Manifest'] | Should -Be 'Warn'
        $result['Registry'] | Should -Be 'Skipped'
      }

      It 'accepts restore manifests when listed artifact digests match' {
        $backupFolder = Join-Path $TestDrive 'digested-manifest-backup'
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
        $powerPlanPath = Join-Path $backupFolder $script:UjBackupFilePowerplan
        Set-Content -LiteralPath $powerPlanPath -Value $script:UjPowerPlanGuidBalanced -Encoding UTF8
        $digests = @{
          $script:UjBackupFilePowerplan = (Get-FileHash -LiteralPath $powerPlanPath -Algorithm SHA256).Hash
        }
        @{
          SchemaVersion = $script:UjBackupSchemaVersion
          ToolName = 'network-diagnostics-suite'
          Timestamp = '2026-01-01T00:00:00Z'
          Components = @{
            SystemProfile = $false
            AfdParameters = $false
            QosPolicies = $false
            NicAdvanced = $false
            NicRsc = $false
            PowerPlan = $true
          }
          ArtifactDigests = $digests
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Encoding UTF8

        Mock -CommandName Restore-UjRegistryFromBackup { Get-UjRestoreComponentResult -Status 'Skipped' }
        Mock -CommandName Restore-UjQosFromBackup { Get-UjRestoreComponentResult -Status 'Skipped' }
        Mock -CommandName Restore-UjNicFromBackup { Get-UjRestoreComponentResult -Status 'Skipped' }
        Mock -CommandName Restore-UjRscFromBackup { Get-UjRestoreComponentResult -Status 'Skipped' }
        Mock -CommandName Restore-UjPowerPlanFromBackup { Get-UjRestoreComponentResult -Status 'OK' }

        $result = Restore-UjState -BackupFolder $backupFolder

        $result['PowerPlan'] | Should -Be 'OK'
        Assert-MockCalled -CommandName Restore-UjPowerPlanFromBackup -Times 1 -Exactly
      }

      It 'rejects an enabled component when its expected artifact and digest are missing' {
        $backupFolder = Join-Path $TestDrive 'missing-enabled-artifact'
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
        @{
          SchemaVersion = $script:UjBackupSchemaVersion
          ToolName = 'network-diagnostics-suite'
          Timestamp = '2026-01-01T00:00:00Z'
          Components = @{
            SystemProfile = $false
            AfdParameters = $false
            QosPolicies = $false
            NicAdvanced = $false
            NicRsc = $false
            PowerPlan = $true
          }
          ArtifactDigests = @{}
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Encoding UTF8

        $result = Read-UjBackupManifest -BackupFolder $backupFolder

        $result.Status | Should -Be 'Invalid'
        $result.Message | Should -Match 'powerplan\.txt'
      }

      It 'rejects an enabled component artifact when its digest is missing' {
        $backupFolder = Join-Path $TestDrive 'missing-enabled-digest'
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $backupFolder $script:UjBackupFilePowerplan) -Value $script:UjPowerPlanGuidBalanced -Encoding UTF8
        @{
          SchemaVersion = $script:UjBackupSchemaVersion
          ToolName = 'network-diagnostics-suite'
          Timestamp = '2026-01-01T00:00:00Z'
          Components = @{
            SystemProfile = $false
            AfdParameters = $false
            QosPolicies = $false
            NicAdvanced = $false
            NicRsc = $false
            PowerPlan = $true
          }
          ArtifactDigests = @{}
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Encoding UTF8

        $result = Read-UjBackupManifest -BackupFolder $backupFolder

        $result.Status | Should -Be 'Invalid'
        $result.Message | Should -Match 'digest.*powerplan\.txt|powerplan\.txt.*digest'
      }

    }
  }
}
