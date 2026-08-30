function Get-NetworkTuningRestoreComponentResult {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)]
    [ValidateSet('OK', 'Warn', 'Skipped')]
    [string]$Status,

    [Parameter()]
    [string]$Message = ''
  )

  return [pscustomobject]@{
    Status  = $Status
    Message = $Message
  }
}

function Resolve-NetworkTuningRestoreStatus {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter()]
    $Result,

    [Parameter()]
    [string]$DefaultIfNull = 'Skipped'
  )

  if ($null -eq $Result) {
    return $DefaultIfNull
  }

  if ($Result -is [bool]) {
    if ($Result) {
      return 'OK'
    }
    return 'Warn'
  }

  if ($Result -is [System.Collections.IDictionary] -and $Result.Contains('Status')) {
    $statusValue = [string]$Result['Status']
    if ($statusValue -in @('OK', 'Warn', 'Skipped')) {
      return $statusValue
    }
  }

  if ($Result.PSObject -and ($Result.PSObject.Properties.Name -contains 'Status')) {
    $statusValue = [string]$Result.Status
    if ($statusValue -in @('OK', 'Warn', 'Skipped')) {
      return $statusValue
    }
  }

  return $DefaultIfNull
}

function Get-NetworkTuningStagingBlockedRestoreStatus {
  [CmdletBinding()]
  [OutputType([System.Collections.Specialized.OrderedDictionary])]
  param(
    [Parameter(Mandatory)][System.Collections.IDictionary]$RestoreResults
  )

  $status = [ordered]@{ Manifest = 'Warn' }
  foreach ($componentName in @('Registry', 'Qos', 'NicAdvanced', 'Rsc', 'PowerPlan')) {
    $status[$componentName] = if ($RestoreResults.Contains($componentName)) {
      Resolve-NetworkTuningRestoreStatus -Result $RestoreResults[$componentName]
    } else {
      'Skipped'
    }
  }
  return $status
}

