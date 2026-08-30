function Backup-NetworkTuningState {
  [CmdletBinding(SupportsShouldProcess = $true)]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)]
    [string]$BackupFolder,

    [Parameter()]
    [switch]$DryRun
  )

  Write-NetworkTuningInformation -Message 'Backing up current state ...'
  if ($DryRun) {
    Write-NetworkTuningInformation -Message '[DryRun] Skip backup (no writes).'
    return Get-NetworkTuningRestoreComponentResult -Status 'Skipped' -Message 'Backup skipped (DryRun).'
  }

  $backupPathTrust = Test-NetworkTuningBackupWritePathTrust -BackupFolder $BackupFolder
  if (-not $backupPathTrust.IsTrusted) {
    return Get-NetworkTuningRestoreComponentResult -Status 'Warn' -Message ("Backup blocked because the destination is not trusted: {0}" -f $backupPathTrust.Message)
  }

  if (-not $PSCmdlet.ShouldProcess($BackupFolder, 'Write backup artifacts')) {
    return Get-NetworkTuningRestoreComponentResult -Status 'Skipped' -Message 'Backup skipped by ShouldProcess.'
  }

  New-NetworkTuningDirectory -Path $BackupFolder | Out-Null
  $backupPathTrust = Test-NetworkTuningBackupWritePathTrust -BackupFolder $BackupFolder
  if (-not $backupPathTrust.IsTrusted) {
    return Get-NetworkTuningRestoreComponentResult -Status 'Warn' -Message ("Backup blocked because the destination changed after creation: {0}" -f $backupPathTrust.Message)
  }
  Assert-NetworkTuningBackupWriteNamespace -BackupFolder $BackupFolder
  $backupHadFailure = $false
  $manifest = @{
    Timestamp  = (Get-Date -Format 'o')
    Components = @{}
  }
  $metadata = Get-NetworkTuningBackupManifestMetadata
  foreach ($key in $metadata.Keys) {
    $manifest[$key] = $metadata[$key]
  }

  Assert-NetworkTuningBackupWriteNamespace -BackupFolder $BackupFolder
  $compReg = Invoke-NetworkTuningBackupArtifactPublication -BackupFolder $BackupFolder -FileName $script:NetworkTuningBackupFileSystemProfile -WriteTemporary {
    param($temporaryPath)
    Export-NetworkTuningRegistryKey -RegistryPath $script:NetworkTuningRegistryPathSystemProfile -OutFile $temporaryPath
  }
  $manifest.Components['SystemProfile'] = $compReg
  if (-not $compReg) { $backupHadFailure = $true }

  Assert-NetworkTuningBackupWriteNamespace -BackupFolder $BackupFolder
  $compAfd = Invoke-NetworkTuningBackupArtifactPublication -BackupFolder $BackupFolder -FileName $script:NetworkTuningBackupFileAfdParameters -WriteTemporary {
    param($temporaryPath)
    Export-NetworkTuningRegistryKey -RegistryPath $script:NetworkTuningRegistryPathAfdParameters -OutFile $temporaryPath
  }
  $manifest.Components['AfdParameters'] = $compAfd
  if (-not $compAfd) { $backupHadFailure = $true }

  Assert-NetworkTuningBackupWriteNamespace -BackupFolder $BackupFolder
  try {
    $policies = @(Get-NetworkTuningManagedQosPolicy -ErrorOnFailure)
    if ($policies.Count -eq 0) {
      Write-Verbose -Message 'No QoS policies found to backup.'
      $qosPublished = Invoke-NetworkTuningBackupArtifactPublication -BackupFolder $BackupFolder -FileName $script:NetworkTuningBackupFileQosOurs -WriteTemporary {
        param($temporaryPath)
        Export-CliXml -LiteralPath $temporaryPath -InputObject ([System.Collections.ArrayList]::new())
      }
    } else {
      $qosSpecs = @($policies | ForEach-Object { ConvertTo-NetworkTuningQosBackupSpec -Item $_ })
      $qosPublished = Invoke-NetworkTuningBackupArtifactPublication -BackupFolder $BackupFolder -FileName $script:NetworkTuningBackupFileQosOurs -WriteTemporary {
        param($temporaryPath)
        Export-CliXml -LiteralPath $temporaryPath -InputObject $qosSpecs
      }
    }
    $manifest.Components['QosPolicies'] = [bool]$qosPublished
    if (-not $qosPublished) { $backupHadFailure = $true }
  } catch {
    Write-Warning -Message 'Could not back up your current QoS (network priority) settings. This is non-critical if you have not set up custom QoS rules before.'
    $manifest.Components['QosPolicies'] = $false
    $backupHadFailure = $true
  }

  Assert-NetworkTuningBackupWriteNamespace -BackupFolder $BackupFolder
  try {
    $rows = @(
      foreach ($n in (Get-NetworkTuningPhysicalUpAdapter)) {
        Get-NetAdapterAdvancedProperty -Name $n.Name |
          Select-Object @{ Name = 'Adapter'; Expression = { $n.Name } }, DisplayName, RegistryKeyword, DisplayValue, RegistryValue
      }
    )
    if ($rows.Count -gt 0) {
      $nicPublished = Invoke-NetworkTuningBackupArtifactPublication -BackupFolder $BackupFolder -FileName $script:NetworkTuningBackupFileNicAdvanced -WriteTemporary {
        param($temporaryPath)
        $rows | Export-Csv -NoTypeInformation -LiteralPath $temporaryPath
      }
      $manifest.Components['NicAdvanced'] = [bool]$nicPublished
      if (-not $nicPublished) { $backupHadFailure = $true }
    } else {
      $manifest.Components['NicAdvanced'] = $false
      $backupHadFailure = $true
    }
  } catch {
    Write-Warning -Message 'Could not back up your network adapter settings. NIC tuning will still be applied but cannot be automatically undone via Restore.'
    $manifest.Components['NicAdvanced'] = $false
    $backupHadFailure = $true
  }

  Assert-NetworkTuningBackupWriteNamespace -BackupFolder $BackupFolder
  try {
    $rscRows = @(Get-NetAdapterRsc | Select-Object Name, IPv4Enabled, IPv6Enabled)
    if ($rscRows.Count -gt 0) {
      $rscPublished = Invoke-NetworkTuningBackupArtifactPublication -BackupFolder $BackupFolder -FileName $script:NetworkTuningBackupFileRsc -WriteTemporary {
        param($temporaryPath)
        $rscRows | Export-Csv -NoTypeInformation -LiteralPath $temporaryPath
      }
      $manifest.Components['NicRsc'] = [bool]$rscPublished
      if (-not $rscPublished) { $backupHadFailure = $true }
    } else {
      $manifest.Components['NicRsc'] = $false
      $backupHadFailure = $true
    }
  } catch {
    Write-Verbose -Message 'RSC snapshot failed.'
    $manifest.Components['NicRsc'] = $false
    $backupHadFailure = $true
  }

  Assert-NetworkTuningBackupWriteNamespace -BackupFolder $BackupFolder
  try {
    $powerPlanOutput = & powercfg /GetActiveScheme 2>&1
    if ($LASTEXITCODE -eq 0 -and $powerPlanOutput) {
      $text = $powerPlanOutput -join "`n"
      $guid = Get-NetworkTuningGuidFromText -Text $text

      if ($guid) {
        $powerPlanPublished = Write-NetworkTuningBackupTextArtifact -BackupFolder $BackupFolder -FileName $script:NetworkTuningBackupFilePowerplan -Content $guid
        $manifest.Components['PowerPlan'] = [bool]$powerPlanPublished
        if (-not $powerPlanPublished) { $backupHadFailure = $true }
      } else {
        $manifest.Components['PowerPlan'] = $false
        $backupHadFailure = $true
      }
    } else {
      $manifest.Components['PowerPlan'] = $false
      $backupHadFailure = $true
    }
  } catch {
    Write-Verbose -Message ("Power plan snapshot failed: {0}" -f $_.Exception.Message)
    $manifest.Components['PowerPlan'] = $false
    $backupHadFailure = $true
  }

  Assert-NetworkTuningBackupWriteNamespace -BackupFolder $BackupFolder
  $manifest.ArtifactDigests = Get-NetworkTuningBackupArtifactDigests -BackupFolder $BackupFolder -Manifest $manifest
  $manifestPublished = Write-NetworkTuningBackupTextArtifact -BackupFolder $BackupFolder -FileName $script:NetworkTuningBackupFileManifest -Content ($manifest | ConvertTo-Json -Depth 5)
  if (-not $manifestPublished) {
    return Get-NetworkTuningRestoreComponentResult -Status 'Warn' -Message 'Backup summary could not be published securely.'
  }

  $backupVerification = Read-NetworkTuningBackupManifest -BackupFolder $BackupFolder
  if ($backupVerification.Status -ne 'OK') {
    $backupHadFailure = $true
    Write-Warning -Message ("Backup verification failed: {0}" -f $backupVerification.Message)
  }

  if ($backupHadFailure) {
    return Get-NetworkTuningRestoreComponentResult -Status 'Warn' -Message 'One or more backup components failed.'
  }

  return Get-NetworkTuningRestoreComponentResult -Status 'OK' -Message 'Backup completed successfully.'
}
