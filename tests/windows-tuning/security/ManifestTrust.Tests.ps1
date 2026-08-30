Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$manifestPath = Join-Path $repoRoot 'src/powershell/windows-tuning/NetworkLantern.WindowsTuning/NetworkLantern.WindowsTuning.psd1'

Import-Module -Name $manifestPath -Force

Describe 'Windows tuning restore manifest trust' {
  InModuleScope NetworkLantern.WindowsTuning {
    BeforeAll {
      function Get-NetworkLanternPowerPlanFixture {
        param(
          [Parameter(Mandatory)][string]$Folder,
          [switch]$Tamper,
          [string]$ToolName = 'network-diagnostics-suite'
        )

        New-Item -ItemType Directory -Path $Folder -Force | Out-Null
        $artifactPath = Join-Path $Folder $script:NetworkTuningBackupFilePowerplan
        Set-Content -LiteralPath $artifactPath -Value $script:NetworkTuningPowerPlanGuidBalanced -Encoding utf8 -NoNewline
        $digest = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash
        $manifest = [ordered]@{
          SchemaVersion = $script:NetworkTuningBackupSchemaVersion
          ToolName = $ToolName
          Components = [ordered]@{
            SystemProfile = $false
            AfdParameters = $false
            QosPolicies = $false
            NicAdvanced = $false
            NicRsc = $false
            PowerPlan = $true
          }
          ArtifactDigests = @{ $script:NetworkTuningBackupFilePowerplan = $digest }
        }
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Folder $script:NetworkTuningBackupFileManifest) -Encoding utf8
        if ($Tamper) {
          Set-Content -LiteralPath $artifactPath -Value $script:NetworkTuningPowerPlanGuidHighPerformance -Encoding utf8 -NoNewline
        }
      }
    }

    It 'rejects missing, empty, wrong-case, and unknown component declarations' {
      $payloads = [ordered]@{
        Missing = '{"SchemaVersion":1,"ArtifactDigests":{}}'
        Empty = '{"SchemaVersion":1,"Components":{},"ArtifactDigests":{}}'
        WrongCase = '{"SchemaVersion":1,"components":{},"ArtifactDigests":{}}'
        Unknown = '{"SchemaVersion":1,"Components":{"ArbitraryCommand":true},"ArtifactDigests":{}}'
      }

      foreach ($caseName in $payloads.Keys) {
        $folder = Join-Path $TestDrive "components-$caseName"
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $folder $script:NetworkTuningBackupFileManifest) -Value $payloads[$caseName] -Encoding utf8

        $result = Read-NetworkTuningBackupManifest -BackupFolder $folder

        $result.Status | Should -Be 'Invalid' -Because "$caseName must fail closed"
      }
    }

    It 'rejects malformed, nonpositive, and future manifest schema versions' {
      $payloads = @(
        '{"SchemaVersion":"three","Components":{}}',
        '{"SchemaVersion":0,"Components":{}}',
        '{"SchemaVersion":999,"Components":{}}'
      )

      foreach ($payload in $payloads) {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $folder $script:NetworkTuningBackupFileManifest) -Value $payload -Encoding utf8

        $result = Read-NetworkTuningBackupManifest -BackupFolder $folder

        $result.Status | Should -BeIn @('Invalid', 'Incompatible')
      }
    }

    It 'accepts the legacy backup tool name when artifact content matches its digest' {
      $folder = Join-Path $TestDrive 'legacy-compatible'
      Get-NetworkLanternPowerPlanFixture -Folder $folder -ToolName 'network-diagnostics-suite'

      $result = Read-NetworkTuningBackupManifest -BackupFolder $folder

      $result.Status | Should -Be 'OK'
      $result.Manifest.ToolName | Should -Be 'network-diagnostics-suite'
    }

    It 'rejects unknown manifest fields even when the authorized artifact digest matches' {
      $folder = Join-Path $TestDrive 'unknown-manifest-field'
      Get-NetworkLanternPowerPlanFixture -Folder $folder
      $manifestPath = Join-Path $folder $script:NetworkTuningBackupFileManifest
      $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
      $manifest['UnexpectedCommand'] = 'not-authorized'
      $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding utf8

      $result = Read-NetworkTuningBackupManifest -BackupFolder $folder

      $result.Status | Should -Be 'Invalid'
      $result.Message | Should -Match 'unknown property'
    }

    It 'rejects an enabled component with a missing artifact or digest' {
      $missingArtifact = Join-Path $TestDrive 'missing-artifact'
      New-Item -ItemType Directory -Path $missingArtifact -Force | Out-Null
      @{
        SchemaVersion = $script:NetworkTuningBackupSchemaVersion
        ToolName = 'network-lantern'
        Components = @{ SystemProfile = $false; AfdParameters = $false; QosPolicies = $false; NicAdvanced = $false; NicRsc = $false; PowerPlan = $true }
        ArtifactDigests = @{}
      } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $missingArtifact $script:NetworkTuningBackupFileManifest) -Encoding utf8

      $result = Read-NetworkTuningBackupManifest -BackupFolder $missingArtifact

      $result.Status | Should -Be 'Invalid'
      $result.Message | Should -Match 'artifact|digest'
    }

    It 'detects tampered artifacts before restore consumers can receive them' {
      $folder = Join-Path $TestDrive 'tampered-artifact'
      Get-NetworkLanternPowerPlanFixture -Folder $folder -Tamper

      $result = Read-NetworkTuningBackupManifest -BackupFolder $folder

      $result.Status | Should -Be 'Invalid'
      $result.Message | Should -Match 'digest mismatch'
    }

    It 'rejects a backup folder that resolves through a symbolic link on hosts that support it' {
      if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
        Set-ItResult -Skipped -Because 'the portable symbolic-link fixture is exercised on macOS/Linux; Windows ACL/reparse coverage needs an elevated Windows runner'
        return
      }

      $target = Join-Path $TestDrive 'trusted-target'
      $link = Join-Path $TestDrive 'untrusted-link'
      Get-NetworkLanternPowerPlanFixture -Folder $target
      try {
        New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop | Out-Null
      } catch {
        Set-ItResult -Skipped -Because "symbolic links are unavailable: $($_.Exception.Message)"
        return
      }

      $result = Read-NetworkTuningBackupManifest -BackupFolder $link

      $result.Status | Should -Be 'Invalid'
      $result.Message | Should -Match 'symbolic link|reparse point'
    }

    It 'rejects a preplanted backup directory, ancestor, or artifact link before elevated backup writes' {
      if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
        Set-ItResult -Skipped -Because 'portable symbolic-link fixtures are exercised on macOS/Linux; Windows reparse coverage needs an elevated Windows runner'
        return
      }

      $target = Join-Path $TestDrive 'write-trust-target'
      New-Item -ItemType Directory -Path $target -Force | Out-Null
      $linkedFolder = Join-Path $TestDrive 'write-trust-folder-link'
      $linkedAncestor = Join-Path $TestDrive 'write-trust-ancestor-link'
      try {
        New-Item -ItemType SymbolicLink -Path $linkedFolder -Target $target -ErrorAction Stop | Out-Null
        New-Item -ItemType SymbolicLink -Path $linkedAncestor -Target $target -ErrorAction Stop | Out-Null
      } catch {
        Set-ItResult -Skipped -Because "symbolic links are unavailable: $($_.Exception.Message)"
        return
      }

      (Test-NetworkTuningBackupWritePathTrust -BackupFolder $linkedFolder).IsTrusted | Should -BeFalse
      (Test-NetworkTuningBackupWritePathTrust -BackupFolder (Join-Path $linkedAncestor 'child')).IsTrusted | Should -BeFalse

      $artifactFolder = Join-Path $TestDrive 'write-trust-artifact'
      New-Item -ItemType Directory -Path $artifactFolder -Force | Out-Null
      New-Item -ItemType SymbolicLink -Path (Join-Path $artifactFolder $script:NetworkTuningBackupFilePowerplan) -Target (Join-Path $target 'outside.txt') -ErrorAction Stop | Out-Null
      (Test-NetworkTuningBackupWritePathTrust -BackupFolder $artifactFolder).IsTrusted | Should -BeFalse
    }

    It 'rejects a self-consistent manifest carrying an unrelated QoS policy' {
      $folder = Join-Path $TestDrive 'forged-qos-bundle'
      New-Item -ItemType Directory -Path $folder -Force | Out-Null
      $qosPath = Join-Path $folder $script:NetworkTuningBackupFileQosOurs
      [pscustomobject]@{ Name = 'UNRELATED_POLICY'; Type = 'Port'; Protocol = 'UDP'; Port = 443; Dscp = 46 } |
        Export-CliXml -LiteralPath $qosPath
      $manifest = [ordered]@{
        SchemaVersion = $script:NetworkTuningBackupSchemaVersion
        ToolName = 'network-lantern'
        Components = [ordered]@{ SystemProfile = $false; AfdParameters = $false; QosPolicies = $true; NicAdvanced = $false; NicRsc = $false; PowerPlan = $false }
        ArtifactDigests = @{ $script:NetworkTuningBackupFileQosOurs = (Get-FileHash -LiteralPath $qosPath -Algorithm SHA256).Hash }
      }
      $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $folder $script:NetworkTuningBackupFileManifest) -Encoding utf8

      $result = Read-NetworkTuningBackupManifest -BackupFolder $folder

      $result.Status | Should -Be 'Invalid'
      $result.Message | Should -Match 'authorization|managed prefixes'
    }

    It 'rejects a NIC payload for an adapter that is not currently physical' {
      $folder = Join-Path $TestDrive 'forged-nic-bundle'
      New-Item -ItemType Directory -Path $folder -Force | Out-Null
      $nicPath = Join-Path $folder $script:NetworkTuningBackupFileNicAdvanced
      [pscustomobject]@{ Adapter = 'Virtual Adapter'; DisplayName = ''; RegistryKeyword = '*EEE'; DisplayValue = ''; RegistryValue = '0' } |
        Export-Csv -NoTypeInformation -LiteralPath $nicPath
      Mock Get-NetworkTuningCurrentPhysicalAdapterName { @('Ethernet') }

      $result = Test-NetworkTuningNicAdvancedBackupArtifact -Path $nicPath

      $result.IsValid | Should -BeFalse
      $result.Message | Should -Match 'missing or non-physical adapter'
    }

    It 'requires an Administrators or SYSTEM-only namespace for elevated backup writes' {
      $existingFolder = Join-Path $TestDrive 'untrusted-existing-namespace'
      New-Item -ItemType Directory -Path $existingFolder -Force | Out-Null
      Mock Test-NetworkTuningWindowsAdminOnlyPath { [pscustomobject]@{ IsTrusted = $false; Message = 'namespace is not Administrators or SYSTEM-only' } }

      $result = Test-NetworkTuningBackupWritePathTrust -BackupFolder $existingFolder -ForceWindowsNamespace

      $result.IsTrusted | Should -BeFalse
      $result.Message | Should -Match 'Administrators or SYSTEM-only'
    }

    It 'refuses a new elevated backup directory when its existing parent is not trusted' {
      $parent = Join-Path $TestDrive 'untrusted-parent'
      $candidate = Join-Path $parent 'new-backup'
      New-Item -ItemType Directory -Path $parent -Force | Out-Null
      Mock Test-NetworkTuningWindowsAdminOnlyPath { [pscustomobject]@{ IsTrusted = $false; Message = 'parent is not Administrators or SYSTEM-only' } }

      $result = Test-NetworkTuningBackupWritePathTrust -BackupFolder $candidate -ForceWindowsNamespace

      $result.IsTrusted | Should -BeFalse
      $result.Message | Should -Match 'parent is not Administrators or SYSTEM-only'
    }

    It 'rejects an existing backup artifact without an exact Administrators or SYSTEM-only ACL' {
      $folder = Join-Path $TestDrive 'artifact-acl-policy'
      New-Item -ItemType Directory -Path $folder -Force | Out-Null
      Set-Content -LiteralPath (Join-Path $folder $script:NetworkTuningBackupFilePowerplan) -Value $script:NetworkTuningPowerPlanGuidBalanced -NoNewline
      Mock Test-NetworkTuningWindowsAdminOnlyPath {
        param($Path)
        if ($Path -eq (Join-Path $folder $script:NetworkTuningBackupFilePowerplan)) {
          return [pscustomobject]@{ IsTrusted = $false; Message = 'artifact does not have the exact Administrators or SYSTEM-only ACL' }
        }
        return [pscustomobject]@{ IsTrusted = $true; Message = '' }
      }

      $result = Test-NetworkTuningBackupWritePathTrust -BackupFolder $folder -ForceWindowsNamespace

      $result.IsTrusted | Should -BeFalse
      $result.Message | Should -Match 'exact Administrators or SYSTEM-only ACL'
    }

    It 'publishes a backup artifact only through a create-new sibling and final artifact' {
      $folder = Join-Path $TestDrive 'atomic-artifact-publication'
      New-Item -ItemType Directory -Path $folder -Force | Out-Null

      $published = Invoke-NetworkTuningBackupArtifactPublication -BackupFolder $folder -FileName $script:NetworkTuningBackupFilePowerplan -WriteTemporary {
        param($temporaryPath)
        [System.IO.File]::WriteAllText($temporaryPath, $script:NetworkTuningPowerPlanGuidBalanced, [System.Text.UTF8Encoding]::new($false))
      }

      $published | Should -BeTrue
      (Get-Content -LiteralPath (Join-Path $folder $script:NetworkTuningBackupFilePowerplan) -Raw) | Should -Be $script:NetworkTuningPowerPlanGuidBalanced
      @(Get-ChildItem -LiteralPath $folder -Filter '.*.tmp' -Force).Count | Should -Be 0
    }

    It 'protects and validates the temporary artifact before publishing its final name' {
      $folder = Join-Path $TestDrive 'publication-order'
      New-Item -ItemType Directory -Path $folder -Force | Out-Null
      $events = [System.Collections.Generic.List[string]]::new()
      Mock Assert-NetworkTuningBackupWriteNamespace { $events.Add('namespace') | Out-Null }
      Mock Protect-NetworkTuningAdminOnlyFile { $events.Add('protect') | Out-Null }
      Mock Test-NetworkTuningWindowsAdminOnlyPath {
        param($Path)
        $kind = if ([System.IO.Path]::GetFileName($Path) -like '*.tmp') { 'temporary' } else { 'final' }
        $events.Add("validate-$kind") | Out-Null
        return [pscustomobject]@{ IsTrusted = $true; Message = '' }
      }

      $published = Invoke-NetworkTuningBackupArtifactPublication -BackupFolder $folder -FileName $script:NetworkTuningBackupFilePowerplan -ForceWindowsAcl -WriteTemporary {
        param($temporaryPath)
        [System.IO.File]::WriteAllText($temporaryPath, $script:NetworkTuningPowerPlanGuidBalanced, [System.Text.UTF8Encoding]::new($false))
      }

      $published | Should -BeTrue
      $events | Should -Be @('namespace', 'protect', 'validate-temporary', 'namespace', 'validate-final')
    }

    It 'does not publish a final artifact when temporary protection fails' {
      $folder = Join-Path $TestDrive 'temporary-protection-failure'
      $finalPath = Join-Path $folder $script:NetworkTuningBackupFilePowerplan
      New-Item -ItemType Directory -Path $folder -Force | Out-Null
      Mock Assert-NetworkTuningBackupWriteNamespace {}
      Mock Protect-NetworkTuningAdminOnlyFile { throw 'temporary ACL protection failed' }

      {
        Invoke-NetworkTuningBackupArtifactPublication -BackupFolder $folder -FileName $script:NetworkTuningBackupFilePowerplan -ForceWindowsAcl -WriteTemporary {
          param($temporaryPath)
          [System.IO.File]::WriteAllText($temporaryPath, $script:NetworkTuningPowerPlanGuidBalanced, [System.Text.UTF8Encoding]::new($false))
        }
      } | Should -Throw '*temporary ACL protection failed*'

      Test-Path -LiteralPath $finalPath | Should -BeFalse
      @(Get-ChildItem -LiteralPath $folder -Filter '.*.tmp' -Force).Count | Should -Be 0
    }

    It 'does not publish a final artifact when temporary ACL validation fails' {
      $folder = Join-Path $TestDrive 'temporary-validation-failure'
      $finalPath = Join-Path $folder $script:NetworkTuningBackupFilePowerplan
      New-Item -ItemType Directory -Path $folder -Force | Out-Null
      Mock Assert-NetworkTuningBackupWriteNamespace {}
      Mock Protect-NetworkTuningAdminOnlyFile {}
      Mock Test-NetworkTuningWindowsAdminOnlyPath { [pscustomobject]@{ IsTrusted = $false; Message = 'temporary ACL is not exact' } }

      {
        Invoke-NetworkTuningBackupArtifactPublication -BackupFolder $folder -FileName $script:NetworkTuningBackupFilePowerplan -ForceWindowsAcl -WriteTemporary {
          param($temporaryPath)
          [System.IO.File]::WriteAllText($temporaryPath, $script:NetworkTuningPowerPlanGuidBalanced, [System.Text.UTF8Encoding]::new($false))
        }
      } | Should -Throw '*temporary ACL is not exact*'

      Test-Path -LiteralPath $finalPath | Should -BeFalse
      @(Get-ChildItem -LiteralPath $folder -Filter '.*.tmp' -Force).Count | Should -Be 0
    }

    It 'removes a newly published final artifact when its post-rename ACL validation fails' {
      $folder = Join-Path $TestDrive 'final-validation-failure-absent'
      $finalPath = Join-Path $folder $script:NetworkTuningBackupFilePowerplan
      New-Item -ItemType Directory -Path $folder -Force | Out-Null
      Mock Assert-NetworkTuningBackupWriteNamespace {}
      Mock Protect-NetworkTuningAdminOnlyFile {}
      Mock Test-NetworkTuningWindowsAdminOnlyPath {
        param($Path)
        if ([System.IO.Path]::GetFileName($Path) -like '*.tmp' -or [System.IO.Path]::GetFileName($Path) -like '*.rollback') {
          return [pscustomobject]@{ IsTrusted = $true; Message = '' }
        }
        return [pscustomobject]@{ IsTrusted = $false; Message = 'final ACL validation failed' }
      }

      {
        Invoke-NetworkTuningBackupArtifactPublication -BackupFolder $folder -FileName $script:NetworkTuningBackupFilePowerplan -ForceWindowsAcl -WriteTemporary {
          param($temporaryPath)
          [System.IO.File]::WriteAllText($temporaryPath, $script:NetworkTuningPowerPlanGuidBalanced, [System.Text.UTF8Encoding]::new($false))
        }
      } | Should -Throw '*final ACL validation failed*'

      Test-Path -LiteralPath $finalPath | Should -BeFalse
      @(Get-ChildItem -LiteralPath $folder -Force).Count | Should -Be 0
    }

    It 'restores the prior trusted artifact when replacement final validation fails' {
      $folder = Join-Path $TestDrive 'final-validation-failure-existing'
      $finalPath = Join-Path $folder $script:NetworkTuningBackupFilePowerplan
      $originalContent = $script:NetworkTuningPowerPlanGuidBalanced
      New-Item -ItemType Directory -Path $folder -Force | Out-Null
      [System.IO.File]::WriteAllText($finalPath, $originalContent, [System.Text.UTF8Encoding]::new($false))
      $script:networkTuningFinalValidationCalls = 0
      Mock Assert-NetworkTuningBackupWriteNamespace {}
      Mock Protect-NetworkTuningAdminOnlyFile {}
      Mock Test-NetworkTuningWindowsAdminOnlyPath {
        param($Path)
        if ([System.IO.Path]::GetFileName($Path) -like '*.tmp' -or [System.IO.Path]::GetFileName($Path) -like '*.rollback') {
          return [pscustomobject]@{ IsTrusted = $true; Message = '' }
        }
        $script:networkTuningFinalValidationCalls++
        return [pscustomobject]@{
          IsTrusted = ($script:networkTuningFinalValidationCalls -lt 3)
          Message = 'replacement final ACL validation failed'
        }
      }

      {
        Invoke-NetworkTuningBackupArtifactPublication -BackupFolder $folder -FileName $script:NetworkTuningBackupFilePowerplan -ForceWindowsAcl -WriteTemporary {
          param($temporaryPath)
          [System.IO.File]::WriteAllText($temporaryPath, $script:NetworkTuningPowerPlanGuidHighPerformance, [System.Text.UTF8Encoding]::new($false))
        }
      } | Should -Throw '*replacement final ACL validation failed*'

      (Get-Content -LiteralPath $finalPath -Raw) | Should -Be $originalContent
      @(Get-ChildItem -LiteralPath $folder -Force).Name | Should -Be @($script:NetworkTuningBackupFilePowerplan)
    }

    It 'quarantines an originally absent final when direct cleanup fails without claiming a rollback' {
      $folder = Join-Path $TestDrive 'quarantine-absent'
      $finalPath = Join-Path $folder $script:NetworkTuningBackupFilePowerplan
      New-Item -ItemType Directory -Path $folder -Force | Out-Null
      Mock Assert-NetworkTuningBackupWriteNamespace {}
      Mock Protect-NetworkTuningAdminOnlyFile {}
      Mock Test-NetworkTuningWindowsAdminOnlyPath { param($Path) if ([IO.Path]::GetFileName($Path) -like '*.tmp') { [pscustomobject]@{ IsTrusted = $true; Message = '' } } else { [pscustomobject]@{ IsTrusted = $false; Message = 'final validation failed' } } }
      Mock Remove-NetworkTuningPublicationPath { throw 'direct cleanup blocked' }
      $message = $null
      try { Invoke-NetworkTuningBackupArtifactPublication -BackupFolder $folder -FileName $script:NetworkTuningBackupFilePowerplan -ForceWindowsAcl -WriteTemporary { param($p) [IO.File]::WriteAllText($p, 'new') } } catch { $message = $_.Exception.Message }
      $message | Should -Match 'quarantined.*no prior destination existed'
      $message | Should -Not -Match 'rollback artifact was retained'
      Test-Path -LiteralPath $finalPath | Should -BeFalse
      @(Get-ChildItem -LiteralPath $folder -Filter '*.quarantine' -Force).Count | Should -Be 1
    }

    It 'reports an existing destination as unrecoverable when its rollback is missing' {
      $folder = Join-Path $TestDrive 'missing-rollback'
      $finalPath = Join-Path $folder $script:NetworkTuningBackupFilePowerplan
      New-Item -ItemType Directory -Path $folder -Force | Out-Null; [IO.File]::WriteAllText($finalPath, 'old')
      $script:finalChecks = 0
      Mock Assert-NetworkTuningBackupWriteNamespace {}; Mock Protect-NetworkTuningAdminOnlyFile {}
      Mock Test-NetworkTuningWindowsAdminOnlyPath { param($Path) if ([IO.Path]::GetFileName($Path) -like '*.tmp') { [pscustomobject]@{ IsTrusted = $true; Message = '' } } else { $script:finalChecks++; [pscustomobject]@{ IsTrusted = ($script:finalChecks -lt 3); Message = 'final validation failed' } } }
      Mock Test-NetworkTuningRollbackArtifactTrust { [pscustomobject]@{ IsTrusted = $false; Message = 'rollback artifact is missing' } }
      $message = $null
      try { Invoke-NetworkTuningBackupArtifactPublication -BackupFolder $folder -FileName $script:NetworkTuningBackupFilePowerplan -ForceWindowsAcl -WriteTemporary { param($p) [IO.File]::WriteAllText($p, 'new') } } catch { $message = $_.Exception.Message }
      $message | Should -Match 'prior destination could not be recovered'
      $message | Should -Not -Match 'trusted rollback artifact was retained'
      Test-Path -LiteralPath $finalPath | Should -BeFalse
    }

    It 'retains a verified rollback when restore replacement fails and quarantine succeeds' {
      $folder = Join-Path $TestDrive 'retained-rollback'
      $finalPath = Join-Path $folder $script:NetworkTuningBackupFilePowerplan
      New-Item -ItemType Directory -Path $folder -Force | Out-Null; [IO.File]::WriteAllText($finalPath, 'old')
      $script:finalChecks = 0; $script:replaceCalls = 0
      Mock Assert-NetworkTuningBackupWriteNamespace {}; Mock Protect-NetworkTuningAdminOnlyFile {}
      Mock Test-NetworkTuningWindowsAdminOnlyPath { param($Path) if ([IO.Path]::GetFileName($Path) -like '*.tmp' -or [IO.Path]::GetFileName($Path) -like '*.rollback') { [pscustomobject]@{ IsTrusted = $true; Message = '' } } else { $script:finalChecks++; [pscustomobject]@{ IsTrusted = ($script:finalChecks -lt 3); Message = 'final validation failed' } } }
      Mock Invoke-NetworkTuningAtomicFileReplace { param($SourcePath, $DestinationPath, $BackupPath) $script:replaceCalls++; if ($script:replaceCalls -eq 1) { [IO.File]::Replace($SourcePath, $DestinationPath, $BackupPath, $true) } else { throw 'restore replace blocked' } }
      $message = $null
      try { Invoke-NetworkTuningBackupArtifactPublication -BackupFolder $folder -FileName $script:NetworkTuningBackupFilePowerplan -ForceWindowsAcl -WriteTemporary { param($p) [IO.File]::WriteAllText($p, 'new') } } catch { $message = $_.Exception.Message }
      $message | Should -Match 'trusted rollback artifact was retained'
      Test-Path -LiteralPath $finalPath | Should -BeFalse
      @(Get-ChildItem -LiteralPath $folder -Filter '*.rollback' -Force).Count | Should -Be 1
    }

    It 'states when quarantine fails that the well-known path may be unvalidated' {
      $folder = Join-Path $TestDrive 'quarantine-failure'
      $finalPath = Join-Path $folder $script:NetworkTuningBackupFilePowerplan
      New-Item -ItemType Directory -Path $folder -Force | Out-Null
      Mock Assert-NetworkTuningBackupWriteNamespace {}; Mock Protect-NetworkTuningAdminOnlyFile {}
      Mock Test-NetworkTuningWindowsAdminOnlyPath { param($Path) if ([IO.Path]::GetFileName($Path) -like '*.tmp') { [pscustomobject]@{ IsTrusted = $true; Message = '' } } else { [pscustomobject]@{ IsTrusted = $false; Message = 'final validation failed' } } }
      Mock Remove-NetworkTuningPublicationPath { throw 'direct cleanup blocked' }
      Mock Move-NetworkTuningPublicationPathToQuarantine { throw 'quarantine blocked' }
      $message = $null
      try { Invoke-NetworkTuningBackupArtifactPublication -BackupFolder $folder -FileName $script:NetworkTuningBackupFilePowerplan -ForceWindowsAcl -WriteTemporary { param($p) [IO.File]::WriteAllText($p, 'new') } } catch { $message = $_.Exception.Message }
      $message | Should -Match 'well-known path may contain an unvalidated artifact'
      Test-Path -LiteralPath $finalPath | Should -BeTrue
    }

    It 'keeps a natively published Windows artifact Administrators and SYSTEM-only' {
      if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
        Set-ItResult -Skipped -Because 'Native NTFS ACL assertions require Windows.'
        return
      }
      if (-not (Test-NetworkTuningAdministrator)) {
        Set-ItResult -Skipped -Because 'Native NTFS ACL assertion requires an elevated Windows test runner.'
        return
      }

      $folder = $null
      try {
        $folder = Initialize-NetworkTuningAdminOnlyDirectory -Path (Join-Path (Get-NetworkTuningWindowsRestoreStagingRoot) ("backup-publication-{0}" -f [guid]::NewGuid().ToString('N'))) -Confirm:$false
        $published = Invoke-NetworkTuningBackupArtifactPublication -BackupFolder $folder -FileName $script:NetworkTuningBackupFilePowerplan -WriteTemporary {
          param($temporaryPath)
          [System.IO.File]::WriteAllText($temporaryPath, $script:NetworkTuningPowerPlanGuidBalanced, [System.Text.UTF8Encoding]::new($false))
        }

        $published | Should -BeTrue
        (Test-NetworkTuningWindowsAdminOnlyPath -Path (Join-Path $folder $script:NetworkTuningBackupFilePowerplan)).IsTrusted | Should -BeTrue
      } finally {
        if ($null -ne $folder -and (Test-Path -LiteralPath $folder)) {
          Remove-Item -LiteralPath $folder -Recurse -Force
        }
      }
    }

    It 'stops backup before artifact publication when the namespace changes after creation' {
      $folder = Join-Path $TestDrive 'race-policy'
      $script:networkTuningTrustChecks = 0
      Mock Test-NetworkTuningBackupWritePathTrust {
        $script:networkTuningTrustChecks++
        [pscustomobject]@{ IsTrusted = ($script:networkTuningTrustChecks -eq 1); Message = 'namespace changed' }
      }
      Mock New-NetworkTuningDirectory {}
      Mock Export-NetworkTuningRegistryKey { throw 'artifact write must not run' }

      $result = Backup-NetworkTuningState -BackupFolder $folder -Confirm:$false

      $result.Status | Should -Be 'Warn'
      Assert-MockCalled Export-NetworkTuningRegistryKey -Times 0 -Exactly
    }

    It 'rejects oversized manifest content before parsing' {
      $folder = Join-Path $TestDrive 'oversized-manifest'
      New-Item -ItemType Directory -Path $folder -Force | Out-Null
      $originalLimit = $script:NetworkTuningMaxManifestBytes
      try {
        $script:NetworkTuningMaxManifestBytes = 16
        Set-Content -LiteralPath (Join-Path $folder $script:NetworkTuningBackupFileManifest) -Value ('x' * 128) -NoNewline

        $result = Read-NetworkTuningBackupManifest -BackupFolder $folder

        $result.Status | Should -Be 'Invalid'
        $result.Message | Should -Match 'Could not read'
      } finally {
        $script:NetworkTuningMaxManifestBytes = $originalLimit
      }
    }

    It 'accepts exact limits and rejects limit plus one for stable text and hashing reads' {
      $path = Join-Path $TestDrive 'stream-limit.txt'
      [System.IO.File]::WriteAllText($path, ('a' * 16), [System.Text.UTF8Encoding]::new($false))
      (Read-NetworkTuningBoundedTextFile -Path $path -MaximumBytes 16) | Should -Be ('a' * 16)
      (Get-NetworkTuningBoundedFileSha256 -Path $path -MaximumBytes 16) | Should -Match '^[0-9A-F]{64}$'
      [System.IO.File]::WriteAllText($path, ('a' * 17), [System.Text.UTF8Encoding]::new($false))
      { Read-NetworkTuningBoundedTextFile -Path $path -MaximumBytes 16 } | Should -Throw '*exceeds*'
      { Get-NetworkTuningBoundedFileSha256 -Path $path -MaximumBytes 16 } | Should -Throw '*exceeds*'
    }

    It 'detects growth after opening a bounded stream where the host permits concurrent writes' {
      if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
        Set-ItResult -Skipped -Because 'Windows FileShare.Read intentionally blocks the concurrent writer used by this portable fixture.'
        return
      }
      $path = Join-Path $TestDrive 'stream-growth.txt'
      [System.IO.File]::WriteAllText($path, 'abcd', [System.Text.UTF8Encoding]::new($false))
      $grew = $false
      {
        Invoke-NetworkTuningBoundedFileStream -Path $path -MaximumBytes 4 -OnChunk {
          if (-not $grew) { [System.IO.File]::AppendAllText($path, 'e', [System.Text.UTF8Encoding]::new($false)); $grew = $true }
        } | Out-Null
      } | Should -Throw '*exceeds*'
    }
  }
}
