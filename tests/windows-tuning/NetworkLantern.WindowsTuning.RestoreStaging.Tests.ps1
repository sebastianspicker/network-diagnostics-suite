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
      It 'reads and restores a verified backup from a folder containing wildcard characters' {
        $backupFolder = Join-Path $TestDrive 'verified-[literal]-backup'
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
        $powerPlanPath = Join-Path $backupFolder $script:UjBackupFilePowerplan
        Set-Content -LiteralPath $powerPlanPath -Value $script:UjPowerPlanGuidBalanced -Encoding UTF8
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
          ArtifactDigests = @{
            $script:UjBackupFilePowerplan = (Get-FileHash -LiteralPath $powerPlanPath -Algorithm SHA256).Hash
          }
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Encoding UTF8

        Mock -CommandName Restore-UjRegistryFromBackup { Get-UjRestoreComponentResult -Status 'Skipped' }
        Mock -CommandName Restore-UjQosFromBackup { Get-UjRestoreComponentResult -Status 'Skipped' }
        Mock -CommandName Restore-UjNicFromBackup { Get-UjRestoreComponentResult -Status 'Skipped' }
        Mock -CommandName Restore-UjRscFromBackup { Get-UjRestoreComponentResult -Status 'Skipped' }
        Mock -CommandName Restore-UjPowerPlanFromBackup { Get-UjRestoreComponentResult -Status 'OK' }

        $result = Restore-UjState -BackupFolder $backupFolder

        $result['PowerPlan'] | Should -Be 'OK'
      }

      It 'restores only from a freshly staged copy of verified artifacts' {
        $backupFolder = Join-Path $TestDrive 'staging-source-backup'
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
        $powerPlanPath = Join-Path $backupFolder $script:UjBackupFilePowerplan
        Set-Content -LiteralPath $powerPlanPath -Value $script:UjPowerPlanGuidBalanced -Encoding UTF8
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
          ArtifactDigests = @{
            $script:UjBackupFilePowerplan = (Get-FileHash -LiteralPath $powerPlanPath -Algorithm SHA256).Hash
          }
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Encoding UTF8

        $script:observedRestoreFolder = $null
        Mock -CommandName Assert-UjRestoreStagingConsumerInvariant {
          param($Session, [hashtable]$Manifest)
          Assert-UjRestoreStagingInvariant -Session $Session -Manifest $Manifest
        }
        Mock -CommandName Restore-UjRegistryFromBackup { Get-UjRestoreComponentResult -Status 'Skipped' }
        Mock -CommandName Restore-UjQosFromBackup { Get-UjRestoreComponentResult -Status 'Skipped' }
        Mock -CommandName Restore-UjNicFromBackup { Get-UjRestoreComponentResult -Status 'Skipped' }
        Mock -CommandName Restore-UjRscFromBackup { Get-UjRestoreComponentResult -Status 'Skipped' }
        Mock -CommandName Restore-UjPowerPlanFromBackup {
          param([string]$BackupFolder)
          $script:observedRestoreFolder = $BackupFolder
          Get-UjRestoreComponentResult -Status 'OK'
        }

        $result = Restore-UjState -BackupFolder $backupFolder

        $result['PowerPlan'] | Should -Be 'OK'
        $script:observedRestoreFolder | Should -Not -Be $backupFolder
        $script:observedRestoreFolder | Should -Not -BeNullOrEmpty
        Assert-MockCalled -CommandName Assert-UjRestoreStagingConsumerInvariant -Times 5 -Exactly
      }

      It 'blocks restore consumers when a verified staging folder is renamed and replaced' {
        $backupFolder = Join-Path $TestDrive 'replacement-source-backup'
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
        $registryPath = Join-Path $backupFolder $script:UjBackupFileSystemProfile
        @'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile]
"SystemResponsiveness"=-
"NetworkThrottlingIndex"=-

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Audio]
"Priority"=-
"BackgroundOnly"=-
"Clock Rate"=-
"SchedulingCategory"=-
"SFIOPriority"=-
'@ | Set-Content -LiteralPath $registryPath -Encoding Unicode
        @{
          SchemaVersion = $script:UjBackupSchemaVersion
          ToolName = 'network-diagnostics-suite'
          Timestamp = '2026-01-01T00:00:00Z'
          Components = @{
            SystemProfile = $true
            AfdParameters = $false
            QosPolicies = $false
            NicAdvanced = $false
            NicRsc = $false
            PowerPlan = $false
          }
          ArtifactDigests = @{
            $script:UjBackupFileSystemProfile = (Get-FileHash -LiteralPath $registryPath -Algorithm SHA256).Hash
          }
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Encoding UTF8

        $script:movedStagingPath = $null
        Mock -CommandName Assert-UjRestoreStagingConsumerInvariant {
          param($Session, [hashtable]$Manifest)

          $script:movedStagingPath = "$($Session.Path)-moved"
          try {
            Move-Item -LiteralPath $Session.Path -Destination $script:movedStagingPath -ErrorAction Stop
            [System.IO.Directory]::CreateDirectory([string]$Session.Path) | Out-Null
          } catch {
            throw "Staging replacement attempt could not preserve the verified session: $($_.Exception.Message)"
          }

          $check = Test-UjRestoreStagingInvariant -Session $Session -Manifest $Manifest
          if (-not $check.IsValid) { throw $check.Message }
        }
        Mock -CommandName Import-UjRegistryFile { throw 'must not import after staging replacement' }
        Mock -CommandName Restore-UjRegistryFromBackup { throw 'must not reach restore consumers' }
        Mock -CommandName Restore-UjQosFromBackup { throw 'must not reach restore consumers' }
        Mock -CommandName Restore-UjNicFromBackup { throw 'must not reach restore consumers' }
        Mock -CommandName Restore-UjRscFromBackup { throw 'must not reach restore consumers' }
        Mock -CommandName Restore-UjPowerPlanFromBackup { throw 'must not reach restore consumers' }

        try {
          $result = Restore-UjState -BackupFolder $backupFolder

          $result['Manifest'] | Should -Be 'Warn'
          $result['Registry'] | Should -Be 'Skipped'
          Assert-MockCalled -CommandName Import-UjRegistryFile -Times 0 -Exactly
          Assert-MockCalled -CommandName Restore-UjRegistryFromBackup -Times 0 -Exactly
        } finally {
          if (-not [string]::IsNullOrWhiteSpace([string]$script:movedStagingPath)) {
            Remove-Item -LiteralPath $script:movedStagingPath -Recurse -Force -ErrorAction SilentlyContinue
          }
        }
      }

      It 'revalidates staging immediately before registry import and aborts all remaining consumers' {
        $backupFolder = Join-Path $TestDrive 'pre-import-replacement-source-backup'
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
        $registryPath = Join-Path $backupFolder $script:UjBackupFileSystemProfile
        @'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile]
"SystemResponsiveness"=-
"NetworkThrottlingIndex"=-

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Audio]
"Priority"=-
"BackgroundOnly"=-
"Clock Rate"=-
"SchedulingCategory"=-
"SFIOPriority"=-
'@ | Set-Content -LiteralPath $registryPath -Encoding Unicode
        @{
          SchemaVersion = $script:UjBackupSchemaVersion
          ToolName = 'network-diagnostics-suite'
          Timestamp = '2026-01-01T00:00:00Z'
          Components = @{
            SystemProfile = $true
            AfdParameters = $false
            QosPolicies = $false
            NicAdvanced = $false
            NicRsc = $false
            PowerPlan = $false
          }
          ArtifactDigests = @{
            $script:UjBackupFileSystemProfile = (Get-FileHash -LiteralPath $registryPath -Algorithm SHA256).Hash
          }
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Encoding UTF8

        $script:consumerGateCallCount = 0
        $script:movedPreImportStagingPath = $null
        Mock -CommandName Assert-UjRestoreStagingConsumerInvariant {
          param($Session, [hashtable]$Manifest)

          $script:consumerGateCallCount++
          if ($script:consumerGateCallCount -lt 3) {
            Assert-UjRestoreStagingInvariant -Session $Session -Manifest $Manifest
            return
          }

          $message = $null
          $script:movedPreImportStagingPath = "$($Session.Path)-moved"
          try {
            Move-Item -LiteralPath $Session.Path -Destination $script:movedPreImportStagingPath -ErrorAction Stop
            [System.IO.Directory]::CreateDirectory([string]$Session.Path) | Out-Null
            $check = Test-UjRestoreStagingInvariant -Session $Session -Manifest $Manifest
            if (-not $check.IsValid) { $message = $check.Message }
          } catch {
            $message = "Staging replacement attempt could not preserve the verified session: $($_.Exception.Message)"
          }

          $exception = [System.InvalidOperationException]::new($message)
          $exception.Data['NetworkLantern.RestoreStagingInvariant'] = $true
          throw $exception
        }
        Mock -CommandName Import-UjRegistryFile { throw 'must not import after pre-import replacement' }
        Mock -CommandName Restore-UjQosFromBackup { throw 'must abort remaining consumers' }
        Mock -CommandName Restore-UjNicFromBackup { throw 'must abort remaining consumers' }
        Mock -CommandName Restore-UjRscFromBackup { throw 'must abort remaining consumers' }
        Mock -CommandName Restore-UjPowerPlanFromBackup { throw 'must abort remaining consumers' }

        try {
          $result = Restore-UjState -BackupFolder $backupFolder -Confirm:$false

          $result['Manifest'] | Should -Be 'Warn'
          $result['Registry'] | Should -Be 'Warn'
          $result['Qos'] | Should -Be 'Skipped'
          Assert-MockCalled -CommandName Assert-UjRestoreStagingConsumerInvariant -Times 3 -Exactly
          Assert-MockCalled -CommandName Import-UjRegistryFile -Times 0 -Exactly
          Assert-MockCalled -CommandName Restore-UjQosFromBackup -Times 0 -Exactly
        } finally {
          if (-not [string]::IsNullOrWhiteSpace([string]$script:movedPreImportStagingPath)) {
            Remove-Item -LiteralPath $script:movedPreImportStagingPath -Recurse -Force -ErrorAction SilentlyContinue
          }
        }
      }

      It 'rejects a digested registry backup that writes an HKLM Run value' {
        $backupFolder = Join-Path $TestDrive 'crafted-registry-backup'
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
        $registryPath = Join-Path $backupFolder $script:UjBackupFileSystemProfile
        @'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile]
"SystemResponsiveness"=-
"NetworkThrottlingIndex"=-

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Audio]
"Priority"=-
"BackgroundOnly"=-
"Clock Rate"=-
"SchedulingCategory"=-
"SFIOPriority"=-
'@ | Set-Content -LiteralPath $registryPath -Encoding Unicode
        $craftedRegistryPath = Join-Path $backupFolder $script:UjBackupFileAfdParameters
        @'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Run]
"NetworkDiagnosticsSuiteTest"="cmd.exe /c exit"
'@ | Set-Content -LiteralPath $craftedRegistryPath -Encoding Unicode
        @{
          SchemaVersion = $script:UjBackupSchemaVersion
          ToolName = 'network-diagnostics-suite'
          Timestamp = '2026-01-01T00:00:00Z'
          Components = @{
            SystemProfile = $true
            AfdParameters = $true
            QosPolicies = $false
            NicAdvanced = $false
            NicRsc = $false
            PowerPlan = $false
          }
          ArtifactDigests = @{
            $script:UjBackupFileSystemProfile = (Get-FileHash -LiteralPath $registryPath -Algorithm SHA256).Hash
            $script:UjBackupFileAfdParameters = (Get-FileHash -LiteralPath $craftedRegistryPath -Algorithm SHA256).Hash
          }
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Encoding UTF8

        Mock -CommandName Import-UjRegistryFile { throw 'unapproved registry file reached import' }
        Mock -CommandName Restore-UjQosFromBackup { Get-UjRestoreComponentResult -Status 'Skipped' }
        Mock -CommandName Restore-UjNicFromBackup { Get-UjRestoreComponentResult -Status 'Skipped' }
        Mock -CommandName Restore-UjRscFromBackup { Get-UjRestoreComponentResult -Status 'Skipped' }
        Mock -CommandName Restore-UjPowerPlanFromBackup { Get-UjRestoreComponentResult -Status 'Skipped' }

        $result = Restore-UjState -BackupFolder $backupFolder

        $result['Registry'] | Should -Be 'Warn'
        Assert-MockCalled -CommandName Import-UjRegistryFile -Times 0 -Exactly
      }

      It 'restores a digested registry backup that contains only approved value state' {
        $backupFolder = Join-Path $TestDrive 'approved-registry-backup'
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
        $registryPath = Join-Path $backupFolder $script:UjBackupFileSystemProfile
        @'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile]
"SystemResponsiveness"=-
"NetworkThrottlingIndex"=dword:ffffffff

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Audio]
"Priority"=-
"BackgroundOnly"=-
"Clock Rate"=-
"SchedulingCategory"="High"
"SFIOPriority"=-
'@ | Set-Content -LiteralPath $registryPath -Encoding Unicode
        @{
          SchemaVersion = $script:UjBackupSchemaVersion
          ToolName = 'network-diagnostics-suite'
          Timestamp = '2026-01-01T00:00:00Z'
          Components = @{
            SystemProfile = $true
            AfdParameters = $false
            QosPolicies = $false
            NicAdvanced = $false
            NicRsc = $false
            PowerPlan = $false
          }
          ArtifactDigests = @{
            $script:UjBackupFileSystemProfile = (Get-FileHash -LiteralPath $registryPath -Algorithm SHA256).Hash
          }
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Encoding UTF8

        Mock -CommandName Import-UjRegistryFile { $true }
        Mock -CommandName Restore-UjQosFromBackup { Get-UjRestoreComponentResult -Status 'Skipped' }
        Mock -CommandName Restore-UjNicFromBackup { Get-UjRestoreComponentResult -Status 'Skipped' }
        Mock -CommandName Restore-UjRscFromBackup { Get-UjRestoreComponentResult -Status 'Skipped' }
        Mock -CommandName Restore-UjPowerPlanFromBackup { Get-UjRestoreComponentResult -Status 'Skipped' }

        $result = Restore-UjState -BackupFolder $backupFolder -Confirm:$false

        $result['Registry'] | Should -Be 'OK'
        Assert-MockCalled -CommandName Import-UjRegistryFile -Times 1 -Exactly
      }

      It 'rejects untrusted restore paths before artifact digests or restore work' {
        $backupFolder = Join-Path $TestDrive 'untrusted-path-backup'
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
        $powerPlanPath = Join-Path $backupFolder $script:UjBackupFilePowerplan
        Set-Content -LiteralPath $powerPlanPath -Value $script:UjPowerPlanGuidBalanced -Encoding UTF8
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
          ArtifactDigests = @{
            $script:UjBackupFilePowerplan = (Get-FileHash -LiteralPath $powerPlanPath -Algorithm SHA256).Hash
          }
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupFolder 'backup_manifest.json') -Encoding UTF8

        Mock -CommandName Test-UjBackupPathTrust {
          [pscustomobject]@{ IsTrusted = $false; Message = 'Backup path owner is not trusted: test' }
        }
        Mock -CommandName Test-UjBackupArtifactDigests { throw 'should not run' }
        Mock -CommandName Restore-UjRegistryFromBackup { throw 'should not run' }
        Mock -CommandName Restore-UjQosFromBackup { throw 'should not run' }
        Mock -CommandName Restore-UjNicFromBackup { throw 'should not run' }
        Mock -CommandName Restore-UjRscFromBackup { throw 'should not run' }
        Mock -CommandName Restore-UjPowerPlanFromBackup { throw 'should not run' }

        $result = Restore-UjState -BackupFolder $backupFolder

        $result['Manifest'] | Should -Be 'Warn'
        Assert-MockCalled -CommandName Test-UjBackupArtifactDigests -Times 0 -Exactly
      }

      It 'rejects a restore folder that is a symbolic link or reparse point' {
        $realFolder = Join-Path $TestDrive 'real-backup-folder'
        $linkedFolder = Join-Path $TestDrive 'linked-backup-folder'
        New-Item -ItemType Directory -Path $realFolder -Force | Out-Null
        $powerPlanPath = Join-Path $realFolder $script:UjBackupFilePowerplan
        Set-Content -LiteralPath $powerPlanPath -Value $script:UjPowerPlanGuidBalanced -Encoding UTF8
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
          ArtifactDigests = @{
            $script:UjBackupFilePowerplan = (Get-FileHash -LiteralPath $powerPlanPath -Algorithm SHA256).Hash
          }
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $realFolder 'backup_manifest.json') -Encoding UTF8

        try {
          New-Item -ItemType SymbolicLink -Path $linkedFolder -Target $realFolder -ErrorAction Stop | Out-Null
        } catch {
          Set-ItResult -Skipped -Because 'symbolic-link creation is unavailable on this test host'
          return
        }

        $result = Read-UjBackupManifest -BackupFolder $linkedFolder

        $result.Status | Should -Be 'Invalid'
        $result.Message | Should -Match 'symbolic link|reparse point'
      }

      It 'rejects tampered restore artifacts before restore work starts' {
        $backupFolder = Join-Path $TestDrive 'tampered-backup'
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
        $powerPlanPath = Join-Path $backupFolder $script:UjBackupFilePowerplan
        Set-Content -LiteralPath $powerPlanPath -Value $script:UjPowerPlanGuidBalanced -Encoding UTF8
        $digests = @{
          $script:UjBackupFilePowerplan = (Get-FileHash -LiteralPath $powerPlanPath -Algorithm SHA256).Hash
        }
        Set-Content -LiteralPath $powerPlanPath -Value $script:UjPowerPlanGuidHighPerformance -Encoding UTF8
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

        Mock -CommandName Restore-UjRegistryFromBackup { throw 'should not run' }
        Mock -CommandName Restore-UjQosFromBackup { throw 'should not run' }
        Mock -CommandName Restore-UjNicFromBackup { throw 'should not run' }
        Mock -CommandName Restore-UjRscFromBackup { throw 'should not run' }
        Mock -CommandName Restore-UjPowerPlanFromBackup { throw 'should not run' }

        $result = Restore-UjState -BackupFolder $backupFolder

        $result['Manifest'] | Should -Be 'Warn'
        $result['PowerPlan'] | Should -Be 'Skipped'
      }

      It 'reset removes only owned MMCSS audio values' {
        function Get-NetTCPSetting {}
        $script:UjNetshInvocations = [System.Collections.Generic.List[string]]::new()
        function netsh {
          $script:UjNetshInvocations.Add(($args -join ' ')) | Out-Null
          $global:LASTEXITCODE = 0
        }
        $script:UjRegistryPathSystemProfile = '/tmp/SystemProfile'
        $script:UjRegistryPathAfdParameters = '/tmp/AfdParameters'
        $script:UjRegistryPathQos = '/tmp/Qos'
        Mock -CommandName Set-UjPowerPlan {}
        Mock -CommandName Set-UjGameDvrState {}
        Mock -CommandName Remove-UjManagedQosPolicy {}
        Mock -CommandName Get-NetTCPSetting { $null }
        Mock -CommandName Test-Path { $true }
        Mock -CommandName Remove-ItemProperty {}
        Mock -CommandName Remove-Item {}

        Reset-UjBaseline -Confirm:$false

        Assert-MockCalled -CommandName Remove-Item -Times 0 -Exactly
        Assert-MockCalled -CommandName Remove-ItemProperty -Times 6
        $script:UjNetshInvocations.Count | Should -Be 11
        $script:UjNetshInvocations | Should -Contain 'int tcp set global autotuninglevel=normal'
      }
    }
  }
}
