function Test-NetworkTuningManagedQosPolicyName {
  [CmdletBinding()]
  [OutputType([bool])]
  param([Parameter(Mandatory)][string]$Name)

  foreach ($prefix in $script:NetworkTuningManagedQosNamePrefixes) {
    if ($Name.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      return $true
    }
  }
  return $false
}

function Test-NetworkTuningLocalExecutablePath {
  [CmdletBinding()]
  [OutputType([bool])]
  param([Parameter(Mandatory)][string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^[A-Za-z]:\\') { return $false }
  if ($Path.StartsWith('\\', [System.StringComparison]::Ordinal) -or $Path.StartsWith('\\?\\', [System.StringComparison]::Ordinal)) { return $false }
  if ([System.IO.Path]::GetExtension($Path) -ine '.exe') { return $false }
  return $true
}

function Test-NetworkTuningStrictPropertySet {
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]$Item,
    [Parameter(Mandatory)][string[]]$Names
  )

  $actual = @($Item.PSObject.Properties.Name)
  if ($actual.Count -ne $Names.Count) { return $false }
  foreach ($name in $Names) {
    if ($actual -cnotcontains $name) { return $false }
  }
  return $true
}

function Test-NetworkTuningQosBackupSpec {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)]$Spec)

  try {
    $name = [string]$Spec.Name
    if ([string]::IsNullOrWhiteSpace($name) -or -not (Test-NetworkTuningManagedQosPolicyName -Name $name)) {
      return [pscustomobject]@{ IsValid = $false; Message = 'QoS backup policy name is outside the managed prefixes.' }
    }
    $dscpValue = [int]$Spec.Dscp
    if ($dscpValue -lt 0 -or $dscpValue -gt 63) {
      return [pscustomobject]@{ IsValid = $false; Message = 'QoS backup DSCP value must be between 0 and 63.' }
    }

    if ([string]$Spec.Type -eq 'Port') {
      if (-not (Test-NetworkTuningStrictPropertySet -Item $Spec -Names @('Name', 'Type', 'Protocol', 'Port', 'Dscp'))) {
        return [pscustomobject]@{ IsValid = $false; Message = 'QoS port backup has unknown or missing fields.' }
      }
      if ([string]$Spec.Protocol -cnotin @('TCP', 'UDP')) {
        return [pscustomobject]@{ IsValid = $false; Message = 'QoS backup protocol must be TCP or UDP.' }
      }
      $port = [int]$Spec.Port
      if ($port -lt 1 -or $port -gt 65535) {
        return [pscustomobject]@{ IsValid = $false; Message = 'QoS backup port must be between 1 and 65535.' }
      }
    } elseif ([string]$Spec.Type -eq 'App') {
      if (-not (Test-NetworkTuningStrictPropertySet -Item $Spec -Names @('Name', 'Type', 'AppPath', 'Dscp'))) {
        return [pscustomobject]@{ IsValid = $false; Message = 'QoS application backup has unknown or missing fields.' }
      }
      if (-not (Test-NetworkTuningLocalExecutablePath -Path ([string]$Spec.AppPath))) {
        return [pscustomobject]@{ IsValid = $false; Message = 'QoS application backup must use an absolute local .exe path.' }
      }
    } else {
      return [pscustomobject]@{ IsValid = $false; Message = 'QoS backup policy type must be Port or App.' }
    }
  } catch {
    return [pscustomobject]@{ IsValid = $false; Message = 'QoS backup contains an invalid value.' }
  }
  return [pscustomobject]@{ IsValid = $true; Message = '' }
}

function Test-NetworkTuningQosBackupArtifact {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][string]$Path)

  try {
    $items = @(Read-NetworkTuningBoundedCliXml -Path $Path -MaximumBytes $script:NetworkTuningMaxQosBackupBytes)
  } catch {
    return [pscustomobject]@{ IsValid = $false; Message = 'QoS backup file could not be parsed.' }
  }
  if ($items.Count -gt 512) {
    return [pscustomobject]@{ IsValid = $false; Message = 'QoS backup contains too many policies.' }
  }
  $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($item in $items) {
    try { $spec = ConvertTo-NetworkTuningQosBackupSpec -Item $item } catch {
      return [pscustomobject]@{ IsValid = $false; Message = 'QoS backup contains an unsupported legacy policy shape.' }
    }
    $specCheck = Test-NetworkTuningQosBackupSpec -Spec $spec
    if (-not $specCheck.IsValid) { return $specCheck }
    if (-not $names.Add([string]$spec.Name)) {
      return [pscustomobject]@{ IsValid = $false; Message = 'QoS backup contains duplicate policy names.' }
    }
  }
  return [pscustomobject]@{ IsValid = $true; Message = '' }
}

function Get-NetworkTuningCurrentPhysicalAdapterName {
  [CmdletBinding()]
  [OutputType([string[]])]
  param()

  return @(Get-NetAdapter -Physical -ErrorAction Stop | ForEach-Object { [string]$_.Name })
}

function Test-NetworkTuningNicAdvancedBackupArtifact {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][string]$Path)

  try { $rows = @(Read-NetworkTuningBoundedTextFile -Path $Path -MaximumBytes $script:NetworkTuningMaxCsvBackupBytes | ConvertFrom-Csv -ErrorAction Stop) } catch {
    return [pscustomobject]@{ IsValid = $false; Message = 'NIC advanced backup CSV could not be parsed.' }
  }
  if ($rows.Count -lt 1 -or $rows.Count -gt $script:NetworkTuningMaxBackupRows) {
    return [pscustomobject]@{ IsValid = $false; Message = 'NIC advanced backup has an invalid row count.' }
  }
  try { $physicalAdapters = @(Get-NetworkTuningCurrentPhysicalAdapterName) } catch {
    return [pscustomobject]@{ IsValid = $false; Message = 'Could not enumerate current physical network adapters.' }
  }
  foreach ($row in $rows) {
    if (-not (Test-NetworkTuningStrictPropertySet -Item $row -Names @('Adapter', 'DisplayName', 'RegistryKeyword', 'DisplayValue', 'RegistryValue'))) {
      return [pscustomobject]@{ IsValid = $false; Message = 'NIC advanced backup has unknown or missing CSV fields.' }
    }
    $adapter = [string]$row.Adapter
    if ([string]::IsNullOrWhiteSpace($adapter) -or $adapter -notin $physicalAdapters) {
      return [pscustomobject]@{ IsValid = $false; Message = 'NIC advanced backup references a missing or non-physical adapter.' }
    }
    $hasKeyword = -not [string]::IsNullOrWhiteSpace([string]$row.RegistryKeyword)
    $hasDisplayName = -not [string]::IsNullOrWhiteSpace([string]$row.DisplayName)
    if ((-not $hasKeyword -and -not $hasDisplayName) -or
        ($hasKeyword -and [string]::IsNullOrWhiteSpace([string]$row.RegistryValue)) -or
        ($hasDisplayName -and [string]::IsNullOrWhiteSpace([string]$row.DisplayValue))) {
      return [pscustomobject]@{ IsValid = $false; Message = 'NIC advanced backup row must identify one known property and a value.' }
    }
    try { $currentProperties = @(Get-NetAdapterAdvancedProperty -Name $adapter -ErrorAction Stop) } catch {
      return [pscustomobject]@{ IsValid = $false; Message = 'Could not enumerate current NIC advanced properties.' }
    }
    $isKnown = if ($hasKeyword) {
      @($currentProperties | Where-Object { [string]$_.RegistryKeyword -ceq [string]$row.RegistryKeyword }).Count -gt 0
    } else {
      @($currentProperties | Where-Object { [string]$_.DisplayName -ceq [string]$row.DisplayName }).Count -gt 0
    }
    if (-not $isKnown) {
      return [pscustomobject]@{ IsValid = $false; Message = 'NIC advanced backup references a property not present on the current adapter.' }
    }
  }
  return [pscustomobject]@{ IsValid = $true; Message = '' }
}

function Test-NetworkTuningRscBackupArtifact {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][string]$Path)

  try { $rows = @(Read-NetworkTuningBoundedTextFile -Path $Path -MaximumBytes $script:NetworkTuningMaxCsvBackupBytes | ConvertFrom-Csv -ErrorAction Stop) } catch {
    return [pscustomobject]@{ IsValid = $false; Message = 'RSC backup CSV could not be parsed.' }
  }
  if ($rows.Count -lt 1 -or $rows.Count -gt 64) {
    return [pscustomobject]@{ IsValid = $false; Message = 'RSC backup has an invalid row count.' }
  }
  try { $physicalAdapters = @(Get-NetworkTuningCurrentPhysicalAdapterName) } catch {
    return [pscustomobject]@{ IsValid = $false; Message = 'Could not enumerate current physical network adapters.' }
  }
  foreach ($row in $rows) {
    if (-not (Test-NetworkTuningStrictPropertySet -Item $row -Names @('Name', 'IPv4Enabled', 'IPv6Enabled'))) {
      return [pscustomobject]@{ IsValid = $false; Message = 'RSC backup has unknown or missing CSV fields.' }
    }
    if ([string]::IsNullOrWhiteSpace([string]$row.Name) -or [string]$row.Name -notin $physicalAdapters) {
      return [pscustomobject]@{ IsValid = $false; Message = 'RSC backup references a missing or non-physical adapter.' }
    }
    if ([string]$row.IPv4Enabled -cnotin @('True', 'False') -or [string]$row.IPv6Enabled -cnotin @('True', 'False')) {
      return [pscustomobject]@{ IsValid = $false; Message = 'RSC backup booleans must be exactly True or False.' }
    }
  }
  return [pscustomobject]@{ IsValid = $true; Message = '' }
}

function Test-NetworkTuningPowerPlanBackupArtifact {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory)][string]$Path)

  try { $content = Read-NetworkTuningBoundedTextFile -Path $Path -MaximumBytes 64 } catch {
    return [pscustomobject]@{ IsValid = $false; Message = 'Power-plan backup could not be read.' }
  }
  if ($content.Length -gt 64 -or $content.Trim() -cnotmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
    return [pscustomobject]@{ IsValid = $false; Message = 'Power-plan backup must contain exactly one GUID.' }
  }
  return [pscustomobject]@{ IsValid = $true; Message = '' }
}

function Test-NetworkTuningRestoreArtifactAuthorization {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][string]$BackupFolder,
    [Parameter(Mandatory)][hashtable]$Manifest
  )

  $checks = @{
    SystemProfile = { param($path) Test-NetworkTuningRegistryBackupFile -InFile $path -ContractName 'SystemProfile' }
    AfdParameters = { param($path) Test-NetworkTuningRegistryBackupFile -InFile $path -ContractName 'AfdParameters' }
    QosPolicies = { param($path) Test-NetworkTuningQosBackupArtifact -Path $path }
    NicAdvanced = { param($path) Test-NetworkTuningNicAdvancedBackupArtifact -Path $path }
    NicRsc = { param($path) Test-NetworkTuningRscBackupArtifact -Path $path }
    PowerPlan = { param($path) Test-NetworkTuningPowerPlanBackupArtifact -Path $path }
  }
  $fileMap = Get-NetworkTuningBackupArtifactFileMap
  foreach ($componentName in $fileMap.Keys) {
    if (-not [bool]$Manifest.Components[$componentName]) { continue }
    $artifactNames = @($fileMap[$componentName])
    if ($artifactNames.Count -ne 1) {
      return [pscustomobject]@{ IsAuthorized = $false; Message = "Restore authorization does not support the $componentName artifact layout." }
    }
    $artifactPath = Join-Path -Path $BackupFolder -ChildPath $artifactNames[0]
    $result = & $checks[$componentName] $artifactPath
    $isValid = if ($result.PSObject.Properties.Name -contains 'IsApproved') { [bool]$result.IsApproved } else { [bool]$result.IsValid }
    if (-not $isValid) {
      return [pscustomobject]@{ IsAuthorized = $false; Message = "Restore authorization rejected ${componentName}: $($result.Message)" }
    }
  }
  return [pscustomobject]@{ IsAuthorized = $true; Message = '' }
}
