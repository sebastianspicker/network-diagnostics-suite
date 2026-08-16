function ConvertTo-UjQosBackupSpec {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)]$Item
  )

  if ([string]::IsNullOrWhiteSpace([string]$Item.Name)) {
    throw 'QoS backup item is missing Name.'
  }

  $dscp = [sbyte]$script:UjDefaultDscp
  if ($Item.PSObject.Properties.Name -contains 'DSCPAction' -and $null -ne $Item.DSCPAction) {
    $dscp = [sbyte][int]$Item.DSCPAction
  } elseif ($Item.PSObject.Properties.Name -contains 'DSCPValue' -and $null -ne $Item.DSCPValue) {
    $dscp = [sbyte][int]$Item.DSCPValue
  }

  if ($Item.PSObject.Properties.Name -contains 'IPPortMatchCondition' -and $Item.IPPortMatchCondition) {
    return [pscustomobject]@{
      Name = [string]$Item.Name
      Type = 'Port'
      Protocol = if ($Item.PSObject.Properties.Name -contains 'IPProtocolMatchCondition' -and $Item.IPProtocolMatchCondition) { [string]$Item.IPProtocolMatchCondition } else { 'UDP' }
      Port = [uint16][int]$Item.IPPortMatchCondition
      Dscp = $dscp
    }
  }

  if ($Item.PSObject.Properties.Name -contains 'AppPathNameMatchCondition' -and $Item.AppPathNameMatchCondition) {
    return [pscustomobject]@{
      Name = [string]$Item.Name
      Type = 'App'
      AppPath = [string]$Item.AppPathNameMatchCondition
      Dscp = $dscp
    }
  }

  throw "QoS backup item '$($Item.Name)' has no supported match condition."
}

function Test-UjQosSpecMatchesPolicy {
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][object]$Spec,
    [Parameter(Mandatory)][object]$Policy
  )

  $policyDscp = if ($Policy.PSObject.Properties.Name -contains 'DSCPAction' -and $null -ne $Policy.DSCPAction) { [int]$Policy.DSCPAction } else { [int]$script:UjDefaultDscp }
  if ($Spec.Type -eq 'Port') {
    return ([string]$Policy.Name -eq $Spec.Name -and [int]$Policy.IPPortMatchCondition -eq [int]$Spec.Port -and [string]$Policy.IPProtocolMatchCondition -eq $Spec.Protocol -and $policyDscp -eq [int]$Spec.Dscp)
  }

  return ([string]$Policy.Name -eq $Spec.Name -and [string]$Policy.AppPathNameMatchCondition -eq $Spec.AppPath -and $policyDscp -eq [int]$Spec.Dscp)
}

function New-UjQosPolicyFromSpec {
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

function Restore-UjQosFromBackup {
  [CmdletBinding(SupportsShouldProcess = $true)]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][string]$BackupFolder)

  $qosInventory = Join-Path -Path $BackupFolder -ChildPath $script:UjBackupFileQosOurs
  if (-not (Test-Path -LiteralPath $qosInventory -PathType Leaf)) {
    Write-Verbose -Message 'No QoS backup file found; skipping QoS restore.'
    return Get-UjRestoreComponentResult -Status 'Skipped' -Message 'QoS backup file not found.'
  }

  try {
    $qosItems = Import-CliXml -LiteralPath $qosInventory
  } catch {
    Write-Warning -Message ("Could not read the QoS backup file. It may be corrupted. File: {0} ({1})" -f $qosInventory, $_.Exception.Message)
    return Get-UjRestoreComponentResult -Status 'Warn' -Message 'QoS backup file could not be parsed.'
  }

  $hadFailure = $false
  $didWork = $false
  $desiredSpecs = @()
  try {
    $desiredSpecs = @($qosItems | ForEach-Object { ConvertTo-UjQosBackupSpec -Item $_ })
  } catch {
    Write-Warning -Message ("QoS backup validation failed before any policies were removed. {0}" -f $_.Exception.Message)
    return Get-UjRestoreComponentResult -Status 'Warn' -Message 'QoS backup validation failed.'
  }

  $existingPolicies = @()
  try {
    $existingPolicies = @(Get-UjManagedQosPolicy)
  } catch {
    Write-Verbose -Message 'Could not snapshot existing QoS policies before restore.'
  }

  $existingByName = @{}
  foreach ($policy in $existingPolicies) {
    $existingByName[[string]$policy.Name] = $policy
  }

  foreach ($spec in $desiredSpecs) {
    $existing = $existingByName[$spec.Name]
    if ($null -ne $existing -and (Test-UjQosSpecMatchesPolicy -Spec $spec -Policy $existing)) {
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
      New-UjQosPolicyFromSpec -Spec $spec -Confirm:$false
    } catch {
      $hadFailure = $true
      Write-Warning -Message ("Could not restore network priority rule '{0}': {1}" -f $spec.Name, $_.Exception.Message)
      if ($removedExisting) {
        try {
          New-UjQosPolicyFromSpec -Spec (ConvertTo-UjQosBackupSpec -Item $existing) -Confirm:$false
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
    return Get-UjRestoreComponentResult -Status 'Skipped' -Message 'QoS restore skipped by ShouldProcess.'
  }

  if ($hadFailure) {
    return Get-UjRestoreComponentResult -Status 'Warn' -Message 'One or more QoS policies failed to restore.'
  }

  return Get-UjRestoreComponentResult -Status 'OK' -Message 'QoS policies restored.'
}
