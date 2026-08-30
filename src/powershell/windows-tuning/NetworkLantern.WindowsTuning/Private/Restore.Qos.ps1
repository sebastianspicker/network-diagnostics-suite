function ConvertTo-NetworkTuningQosBackupSpec {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)]$Item
  )

  if ([string]::IsNullOrWhiteSpace([string]$Item.Name)) {
    throw 'QoS backup item is missing Name.'
  }
  if (-not (Test-NetworkTuningManagedQosPolicyName -Name ([string]$Item.Name))) {
    throw 'QoS backup item name is outside the managed prefixes.'
  }

  $dscp = [int]$script:NetworkTuningDefaultDscp
  if ($Item.PSObject.Properties.Name -contains 'DSCPAction' -and $null -ne $Item.DSCPAction) {
    $dscp = [int]$Item.DSCPAction
  } elseif ($Item.PSObject.Properties.Name -contains 'DSCPValue' -and $null -ne $Item.DSCPValue) {
    $dscp = [int]$Item.DSCPValue
  } elseif ($Item.PSObject.Properties.Name -contains 'Dscp' -and $null -ne $Item.Dscp) {
    $dscp = [int]$Item.Dscp
  }
  if ($dscp -lt 0 -or $dscp -gt 63) {
    throw 'QoS backup DSCP value must be between 0 and 63.'
  }

  if ($Item.PSObject.Properties.Name -contains 'Type') {
    if ([string]$Item.Type -eq 'Port') {
      if (-not (Test-NetworkTuningStrictPropertySet -Item $Item -Names @('Name', 'Type', 'Protocol', 'Port', 'Dscp'))) {
        throw 'QoS port backup has unknown or missing fields.'
      }
      $protocol = [string]$Item.Protocol
      $port = [int]$Item.Port
      $spec = [pscustomobject]@{ Name = [string]$Item.Name; Type = 'Port'; Protocol = $protocol; Port = $port; Dscp = $dscp }
      $specCheck = Test-NetworkTuningQosBackupSpec -Spec $spec
      if (-not $specCheck.IsValid) { throw $specCheck.Message }
      return $spec
    }
    if ([string]$Item.Type -eq 'App') {
      if (-not (Test-NetworkTuningStrictPropertySet -Item $Item -Names @('Name', 'Type', 'AppPath', 'Dscp'))) {
        throw 'QoS application backup has unknown or missing fields.'
      }
      $spec = [pscustomobject]@{ Name = [string]$Item.Name; Type = 'App'; AppPath = [string]$Item.AppPath; Dscp = $dscp }
      $specCheck = Test-NetworkTuningQosBackupSpec -Spec $spec
      if (-not $specCheck.IsValid) { throw $specCheck.Message }
      return $spec
    }
    throw 'QoS backup item type must be Port or App.'
  }

  if ($Item.PSObject.Properties.Name -contains 'IPPortMatchCondition' -and $Item.IPPortMatchCondition) {
    $protocol = if ($Item.PSObject.Properties.Name -contains 'IPProtocolMatchCondition' -and $Item.IPProtocolMatchCondition) { [string]$Item.IPProtocolMatchCondition } else { 'UDP' }
    $port = [int]$Item.IPPortMatchCondition
    $spec = [pscustomobject]@{
      Name = [string]$Item.Name
      Type = 'Port'
      Protocol = $protocol
      Port = $port
      Dscp = $dscp
    }
    $specCheck = Test-NetworkTuningQosBackupSpec -Spec $spec
    if (-not $specCheck.IsValid) { throw $specCheck.Message }
    return $spec
  }

  if ($Item.PSObject.Properties.Name -contains 'AppPathNameMatchCondition' -and $Item.AppPathNameMatchCondition) {
    $spec = [pscustomobject]@{
      Name = [string]$Item.Name
      Type = 'App'
      AppPath = [string]$Item.AppPathNameMatchCondition
      Dscp = $dscp
    }
    $specCheck = Test-NetworkTuningQosBackupSpec -Spec $spec
    if (-not $specCheck.IsValid) { throw $specCheck.Message }
    return $spec
  }

  throw "QoS backup item '$($Item.Name)' has no supported match condition."
}

function Test-NetworkTuningQosSpecMatchesPolicy {
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][object]$Spec,
    [Parameter(Mandatory)][object]$Policy
  )

  $policyDscp = if ($Policy.PSObject.Properties.Name -contains 'DSCPAction' -and $null -ne $Policy.DSCPAction) { [int]$Policy.DSCPAction } else { [int]$script:NetworkTuningDefaultDscp }
  if ($Spec.Type -eq 'Port') {
    return ([string]$Policy.Name -eq $Spec.Name -and [int]$Policy.IPPortMatchCondition -eq [int]$Spec.Port -and [string]$Policy.IPProtocolMatchCondition -eq $Spec.Protocol -and $policyDscp -eq [int]$Spec.Dscp)
  }

  return ([string]$Policy.Name -eq $Spec.Name -and [string]$Policy.AppPathNameMatchCondition -eq $Spec.AppPath -and $policyDscp -eq [int]$Spec.Dscp)
}

function New-NetworkTuningQosPolicyFromSpec {
  [CmdletBinding(SupportsShouldProcess = $true)]
  [OutputType([void])]
  param(
    [Parameter(Mandatory)][object]$Spec
  )

  if (-not $PSCmdlet.ShouldProcess([string]$Spec.Name, 'Create NetQosPolicy from backup')) {
    return
  }

  if ($Spec.Type -eq 'Port') {
    New-NetQosPolicy -Name $Spec.Name -IPPortMatchCondition $Spec.Port -IPProtocolMatchCondition $Spec.Protocol -DSCPAction $Spec.Dscp -NetworkProfile All -ErrorAction Stop | Out-Null
    return
  }

  New-NetQosPolicy -Name $Spec.Name -AppPathNameMatchCondition $Spec.AppPath -DSCPAction $Spec.Dscp -NetworkProfile All -ErrorAction Stop | Out-Null
}

function Restore-NetworkTuningQosFromBackup {
  [CmdletBinding(SupportsShouldProcess = $true)]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][string]$BackupFolder)

  $qosInventory = Join-Path -Path $BackupFolder -ChildPath $script:NetworkTuningBackupFileQosOurs
  if (-not (Test-Path -LiteralPath $qosInventory -PathType Leaf)) {
    Write-Verbose -Message 'No QoS backup file found; skipping QoS restore.'
    return Get-NetworkTuningRestoreComponentResult -Status 'Skipped' -Message 'QoS backup file not found.'
  }

  try {
    $qosItems = Read-NetworkTuningBoundedCliXml -Path $qosInventory -MaximumBytes $script:NetworkTuningMaxQosBackupBytes
  } catch {
    Write-Warning -Message ("Could not read the QoS backup file. It may be corrupted. File: {0} ({1})" -f $qosInventory, $_.Exception.Message)
    return Get-NetworkTuningRestoreComponentResult -Status 'Warn' -Message 'QoS backup file could not be parsed.'
  }

  $hadFailure = $false
  $didWork = $false
  $desiredSpecs = @()
  try {
    $desiredSpecs = @($qosItems | ForEach-Object { ConvertTo-NetworkTuningQosBackupSpec -Item $_ })
  } catch {
    Write-Warning -Message ("QoS backup validation failed before any policies were removed. {0}" -f $_.Exception.Message)
    return Get-NetworkTuningRestoreComponentResult -Status 'Warn' -Message 'QoS backup validation failed.'
  }

  $existingPolicies = @()
  try {
    $existingPolicies = @(Get-NetworkTuningManagedQosPolicy)
  } catch {
    Write-Verbose -Message 'Could not snapshot existing QoS policies before restore.'
  }

  $existingByName = @{}
  foreach ($policy in $existingPolicies) {
    $existingByName[[string]$policy.Name] = $policy
  }

  foreach ($spec in $desiredSpecs) {
    $existing = $existingByName[$spec.Name]
    if ($null -ne $existing -and (Test-NetworkTuningQosSpecMatchesPolicy -Spec $spec -Policy $existing)) {
      continue
    }

    if (-not $PSCmdlet.ShouldProcess($spec.Name, 'Restore NetQosPolicy from backup')) {
      continue
    }

    $didWork = $true
    $removedExisting = $false
    try {
      if ($null -ne $existing) {
        Remove-NetQosPolicy -Name $spec.Name -Confirm:$false -ErrorAction Stop | Out-Null
        $removedExisting = $true
      }
      New-NetworkTuningQosPolicyFromSpec -Spec $spec -Confirm:$false
    } catch {
      $hadFailure = $true
      Write-Warning -Message ("Could not restore network priority rule '{0}': {1}" -f $spec.Name, $_.Exception.Message)
      if ($removedExisting) {
        try {
          New-NetworkTuningQosPolicyFromSpec -Spec (ConvertTo-NetworkTuningQosBackupSpec -Item $existing) -Confirm:$false
        } catch {
          Write-Warning -Message ("Could not recover original network priority rule '{0}': {1}" -f $spec.Name, $_.Exception.Message)
        }
      }
    }
  }

  if (-not $hadFailure) {
    $desiredNames = @($desiredSpecs | ForEach-Object { $_.Name })
    foreach ($policy in $existingPolicies) {
      if ($policy.Name -in $desiredNames) {
        continue
      }
      if ($PSCmdlet.ShouldProcess($policy.Name, 'Remove stale managed NetQosPolicy')) {
        $didWork = $true
        try {
          Remove-NetQosPolicy -Name $policy.Name -Confirm:$false -ErrorAction Stop | Out-Null
        } catch {
          $hadFailure = $true
          Write-Warning -Message ("Could not remove stale network priority rule '{0}': {1}" -f $policy.Name, $_.Exception.Message)
        }
      }
    }
  }

  if (-not $didWork) {
    return Get-NetworkTuningRestoreComponentResult -Status 'Skipped' -Message 'QoS restore skipped by ShouldProcess.'
  }

  if ($hadFailure) {
    return Get-NetworkTuningRestoreComponentResult -Status 'Warn' -Message 'One or more QoS policies failed to restore.'
  }

  return Get-NetworkTuningRestoreComponentResult -Status 'OK' -Message 'QoS policies restored.'
}
