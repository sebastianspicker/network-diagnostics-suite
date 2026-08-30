[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Restore-NetworkTuningState delegates mutation decisions to component functions that implement ShouldProcess.')]
param()

function Restore-NetworkTuningState {
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
  [OutputType([System.Collections.Specialized.OrderedDictionary])]
  param(
    [Parameter(Mandatory)]
    [string]$BackupFolder,

    [Parameter()]
    [switch]$DryRun
  )

  Write-NetworkTuningInformation -Message 'Restoring previous state ...'

  $manifestCheck = Read-NetworkTuningBackupManifest -BackupFolder $BackupFolder
  if ($manifestCheck.Status -eq 'OK') {
    Write-NetworkTuningInformation -Message ("Validated backup manifest (Timestamp: {0})" -f $manifestCheck.Manifest.Timestamp)
  } else {
    Write-Warning -Message ("Restore blocked: {0}" -f $manifestCheck.Message)
    return [ordered]@{
      Manifest    = 'Warn'
      Registry    = 'Skipped'
      Qos         = 'Skipped'
      NicAdvanced = 'Skipped'
      Rsc         = 'Skipped'
      PowerPlan   = 'Skipped'
    }
  }

  if ($DryRun) {
    Write-NetworkTuningInformation -Message '[DryRun] Backup manifest verified; skip restore writes.'
    return [ordered]@{
      Manifest    = 'OK'
      Registry    = 'Skipped'
      Qos         = 'Skipped'
      NicAdvanced = 'Skipped'
      Rsc         = 'Skipped'
      PowerPlan   = 'Skipped'
    }
  }

  try {
    $stagingSession = Copy-NetworkTuningVerifiedBackupToStaging -BackupFolder $BackupFolder -Manifest $manifestCheck.Manifest
  } catch {
    Write-Warning -Message ("Restore blocked while staging verified artifacts: {0}" -f $_.Exception.Message)
    return [ordered]@{
      Manifest    = 'Warn'
      Registry    = 'Skipped'
      Qos         = 'Skipped'
      NicAdvanced = 'Skipped'
      Rsc         = 'Skipped'
      PowerPlan   = 'Skipped'
    }
  }

  try {
    $restoreFolder = [string]$stagingSession.Path
    $restoreResults = [ordered]@{}
    $restoreOperations = @(
      @{
        Name = 'Registry'
        Invoke = {
          Restore-NetworkTuningRegistryFromBackup `
            -BackupFolder $restoreFolder `
            -StagingSession $stagingSession `
            -Manifest $manifestCheck.Manifest
        }
      },
      @{ Name = 'Qos'; Invoke = { Restore-NetworkTuningQosFromBackup -BackupFolder $restoreFolder } },
      @{ Name = 'NicAdvanced'; Invoke = { Restore-NetworkTuningNicFromBackup -BackupFolder $restoreFolder } },
      @{ Name = 'Rsc'; Invoke = { Restore-NetworkTuningRscFromBackup -BackupFolder $restoreFolder } },
      @{ Name = 'PowerPlan'; Invoke = { Restore-NetworkTuningPowerPlanFromBackup -BackupFolder $restoreFolder } }
    )

    foreach ($operation in $restoreOperations) {
      try {
        Assert-NetworkTuningRestoreStagingConsumerInvariant -Session $stagingSession -Manifest $manifestCheck.Manifest
      } catch {
        Write-Warning -Message ("Restore blocked before consumer '{0}' because the verified staging session changed: {1}" -f $operation.Name, $_.Exception.Message)
        return Get-NetworkTuningStagingBlockedRestoreStatus -RestoreResults $restoreResults
      }

      try {
        $restoreResults[$operation.Name] = & $operation.Invoke
      } catch {
        if ($_.Exception.Data.Contains('NetworkLantern.RestoreStagingInvariant') -and
            [bool]$_.Exception.Data['NetworkLantern.RestoreStagingInvariant']) {
          Write-Warning -Message ("Restore blocked inside consumer '{0}' because the verified staging session changed: {1}" -f $operation.Name, $_.Exception.Message)
          $restoreResults[$operation.Name] = Get-NetworkTuningRestoreComponentResult -Status 'Warn' -Message 'Restore consumer stopped after staging verification failed.'
          return Get-NetworkTuningStagingBlockedRestoreStatus -RestoreResults $restoreResults
        }
        throw
      }
    }

    $registryResult = $restoreResults['Registry']
    $qosResult = $restoreResults['Qos']
    $nicResult = $restoreResults['NicAdvanced']
    $rscResult = $restoreResults['Rsc']
    $powerResult = $restoreResults['PowerPlan']

    $componentStatus = [ordered]@{
      Registry    = Resolve-NetworkTuningRestoreStatus -Result $registryResult
      Qos         = Resolve-NetworkTuningRestoreStatus -Result $qosResult
      NicAdvanced = Resolve-NetworkTuningRestoreStatus -Result $nicResult
      Rsc         = Resolve-NetworkTuningRestoreStatus -Result $rscResult
      PowerPlan   = Resolve-NetworkTuningRestoreStatus -Result $powerResult
    }

    Write-NetworkTuningInformation -Message (
      "Restore complete. Components: Registry={0}; QoS={1}; NicAdvanced={2}; RSC={3}; PowerPlan={4}. A reboot may be required for registry-based settings." -f
      $componentStatus.Registry,
      $componentStatus.Qos,
      $componentStatus.NicAdvanced,
      $componentStatus.Rsc,
      $componentStatus.PowerPlan
    )

    foreach ($entry in @(
        @{ Name = 'Registry'; Result = $registryResult },
        @{ Name = 'QoS'; Result = $qosResult },
        @{ Name = 'NIC'; Result = $nicResult },
        @{ Name = 'RSC'; Result = $rscResult },
        @{ Name = 'PowerPlan'; Result = $powerResult }
      )) {
      $entryResult = $entry['Result']
      if ($null -ne $entryResult -and
          $entryResult.PSObject -and
          ($entryResult.PSObject.Properties.Match('Message').Count -gt 0) -and
          -not [string]::IsNullOrWhiteSpace([string]$entryResult.Message)) {
        Write-Verbose -Message ("Restore detail [{0}]: {1}" -f $entry['Name'], $entryResult.Message)
      }
    }

    return $componentStatus
  } finally {
    Close-NetworkTuningRestoreStagingSession -Session $stagingSession
  }
}
