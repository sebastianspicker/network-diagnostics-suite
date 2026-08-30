# Profile storage helpers (private to NetworkLantern.Throughput)
$script:Iperf3ProfilesFileMaxBytes = 1MB

function Get-DefaultProfilesFilePath {
  [CmdletBinding()]
  [OutputType([string])]
  param()
  return (Join-Path (Join-Path (Get-Location) '.iperf3') 'profiles.json')
}

function Test-Iperf3ProcessIsElevated {
  [CmdletBinding()]
  [OutputType([bool])]
  param()

  if ($IsWindows) {
    try {
      $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
      $principal = [Security.Principal.WindowsPrincipal]::new($identity)
      return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
  }
  try { return ([int](& id -u) -eq 0) }
  catch { return ([Environment]::UserName -eq 'root') }
}

function Resolve-ProfilesFilePath {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [string]$ProfilesFile,
    [string]$Provenance
  )
  $base = [System.IO.Path]::GetFullPath((Get-Location).Path)
  $defaultPath = [System.IO.Path]::GetFullPath((Get-DefaultProfilesFilePath))
  $resolvedProvenance = 'ExplicitAbsolute'
  $containmentBase = $null
  if ($Provenance -eq 'Default' -or [string]::IsNullOrWhiteSpace([string]$ProfilesFile)) {
    $ProfilesFile = $defaultPath
    $resolvedProvenance = 'Default'
    $containmentBase = $base
  }
  if ($ProfilesFile -match '[\x00-\x1f]') {
    Write-Iperf3Error -Message 'ProfilesFile path contains control characters.' -ErrorId 'NetworkLantern.Throughput.InputValidation' -TargetObject $ProfilesFile
  }
  if ([System.IO.Path]::IsPathRooted($ProfilesFile)) {
    $candidate = [System.IO.Path]::GetFullPath($ProfilesFile)
  }
  else {
    $resolvedProvenance = 'Relative'
    $containmentBase = $base
    $candidate = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($base, [string]$ProfilesFile))
  }
  # Created once at the adapter boundary and carried unchanged through the
  # operation. Re-resolving Resolution.Path would erase the original trust.
  $resolution = [pscustomobject]@{ Path = $candidate; Provenance = $resolvedProvenance; ContainmentBase = $containmentBase }
  Assert-Iperf3ProfileOperationPathSafety -Resolution $resolution
  return $resolution
}

function Assert-Iperf3ProfileWritePathIsNotReparsePoint {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Path
  )

  try {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
  }
  catch [System.Management.Automation.ItemNotFoundException] {
    return
  }
  catch {
    Write-Iperf3Error -Message "Profiles file write target could not be validated '$Path': $($_.Exception.Message)" -ErrorId 'NetworkLantern.Throughput.InputValidation' -TargetObject $Path
  }
  if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    Write-Iperf3Error -Message "Profiles file write target must not be a symbolic link or reparse point: $Path" -ErrorId 'NetworkLantern.Throughput.InputValidation' -TargetObject $Path
  }
}

function Assert-Iperf3ProfileOperationPathSafety {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object]$Resolution
  )
  if ($Resolution.Provenance -in @('Default', 'Relative') -and (Test-Iperf3ProcessIsElevated)) {
    Write-Iperf3Error -Message "$($Resolution.Provenance) profile paths are refused when the process is elevated. Use an explicit absolute profiles path." -ErrorId 'NetworkLantern.Throughput.InputValidation' -TargetObject $Resolution.Path
  }
  if ($Resolution.ContainmentBase) {
    Assert-RelativePathHasNoReparsePoint -BasePath $Resolution.ContainmentBase -CandidatePath $Resolution.Path -PathDescription 'Profiles file path' | Out-Null
  }
  Assert-Iperf3ProfileWritePathIsNotReparsePoint -Path $Resolution.Path
}

function Read-Iperf3ProfilesFileBounded {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][object]$Resolution
  )

  $stream = $null
  try {
    # This is the operation-time check for relative paths. The subsequent
    # opened handle is bounded to limit+1 bytes; non-elevated Unix callers get
    # best-effort revalidation, not a claim of adversarial no-follow safety.
    Assert-Iperf3ProfileOperationPathSafety -Resolution $Resolution
    return (Read-Iperf3BoundedTextFile -Path $Resolution.Path -MaxBytes $script:Iperf3ProfilesFileMaxBytes -ArtifactDescription 'Profiles file')
  }
  catch [System.IO.FileNotFoundException] { return $null }
  catch [System.IO.DirectoryNotFoundException] { return $null }
  catch [System.Management.Automation.RuntimeException] {
    if ($_.Exception.InnerException -is [System.IO.FileNotFoundException] -or
        $_.Exception.InnerException -is [System.IO.DirectoryNotFoundException]) { return $null }
    throw
  }
  catch {
    if ($_.Exception.InnerException -is [System.IO.FileNotFoundException] -or
        $_.Exception.InnerException -is [System.IO.DirectoryNotFoundException]) { return $null }
    Write-Iperf3Error -Message "Profiles file could not be read: $($Resolution.Path). $($_.Exception.Message)" -ErrorId 'NetworkLantern.Throughput.Prerequisite' -TargetObject $Resolution.Path
  }
  finally {
    if ($stream) { $stream.Dispose() }
  }
}

function Get-Iperf3ProfileStorableKeys {
  [CmdletBinding()]
  [OutputType([string[]])]
  param()
  return [string[]]@(
    'Target', 'Port', 'Duration', 'Omit', 'OutDir', 'Quiet', 'Progress', 'Summary',
    'DisableMtuProbe', 'SkipReachabilityCheck', 'Force', 'Protocol', 'SingleTest', 'MtuSizes',
    'ConnectTimeoutMs', 'UdpStart', 'UdpMax', 'UdpStep', 'UdpLossThreshold',
    'TcpStreams', 'TcpWindows', 'DscpClasses', 'IpVersion', 'RetryCount',
    'ThresholdMinThroughputMbps', 'ThresholdMaxLossPct', 'ThresholdMaxJitterMs'
  )
}

function Assert-Iperf3ProfileName {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$ProfileName)
  if ([string]::IsNullOrWhiteSpace($ProfileName)) {
    Write-Iperf3Error -Message 'ProfileName is required when using -SaveProfile.' -ErrorId 'NetworkLantern.Throughput.InputValidation' -TargetObject $ProfileName
  }
  if ($ProfileName.Length -gt 128) {
    Write-Iperf3Error -Message "ProfileName exceeds maximum length (128 characters): '$($ProfileName.Substring(0, 32))...'." -ErrorId 'NetworkLantern.Throughput.InputValidation' -TargetObject $ProfileName
  }
  if ($ProfileName -match '[/\\:\*\?"<>\|\x00]') {
    Write-Iperf3Error -Message "ProfileName contains invalid characters: '$ProfileName'." -ErrorId 'NetworkLantern.Throughput.InputValidation' -TargetObject $ProfileName
  }
}

function Read-Iperf3ProfilesStore {
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][object]$Resolution,
    [switch]$StrictConfiguration
  )
  $raw = Read-Iperf3ProfilesFileBounded -Resolution $Resolution
  if ($null -eq $raw) {
    return @{
      version    = 1
      updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
      profiles   = @{}
    }
  }
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return @{
      version    = 1
      updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
      profiles   = @{}
    }
  }
  try {
    $obj = ConvertFrom-Json -InputObject $raw -AsHashtable -Depth 32 -ErrorAction Stop
  }
  catch {
    if ($StrictConfiguration) { Write-Iperf3Error -Message "Profiles file is invalid JSON: $($Resolution.Path)" -ErrorId 'NetworkLantern.Throughput.Prerequisite' -TargetObject $Resolution.Path }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $backupPath = "$($Resolution.Path).corrupt.$stamp.bak"
    # This is a mutation boundary.  Do not downgrade a failed provenance or
    # containment revalidation into the ordinary best-effort backup warning.
    Assert-Iperf3ProfileOperationPathSafety -Resolution $Resolution
    Assert-Iperf3ProfileWritePathIsNotReparsePoint -Path $backupPath
    try {
      Copy-Item -LiteralPath $Resolution.Path -Destination $backupPath -Force -ErrorAction Stop
      Write-Warning "Profiles file is invalid JSON: $($Resolution.Path). Backed up to '$backupPath'. Starting with empty profile store."
    }
    catch {
      Write-Verbose "Failed to back up corrupt profiles file: $($_.Exception.Message)"
      Write-Warning "Profiles file is invalid JSON: $($Resolution.Path). Starting with empty profile store."
    }
    return @{
      version    = 1
      updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
      profiles   = @{}
    }
  }
  $store = ConvertTo-Iperf3HashtableFromObject -InputObject $obj
  if (-not $store.ContainsKey('profiles')) { $store['profiles'] = @{} }
  $store['profiles'] = ConvertTo-Iperf3HashtableFromObject -InputObject $store['profiles']
  if (-not $store.ContainsKey('version')) { $store['version'] = 1 }
  if (-not $store.ContainsKey('updatedUtc')) { $store['updatedUtc'] = (Get-Date).ToUniversalTime().ToString('o') }
  return $store
}

function Invoke-LockedProfileOperation {
  <#
  .SYNOPSIS
  Executes a read-modify-write operation on the profiles file under an exclusive file lock.
  .DESCRIPTION
  Holds a stable sidecar lock while using the guarded store reader, passes the store to
  the provided scriptblock, then atomically replaces the profiles file from a same-directory
  temporary file. This prevents lost updates and partial reads across GUI and CLI processes.
  .PARAMETER ProfilesFile
  Path to the profiles JSON file.
  .PARAMETER Operation
  Scriptblock that receives the parsed store hashtable and returns the (possibly modified) store.
  .PARAMETER StrictConfiguration
  When set, invalid JSON throws instead of being recovered.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][object]$Resolution,
    [Parameter(Mandatory)]
    [scriptblock]$Operation,
    [switch]$StrictConfiguration
  )
  $ProfilesFile = $Resolution.Path
  if (-not $ProfilesFile.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase)) {
    Write-Iperf3Error -Message "Profiles file must have a .json extension: $ProfilesFile" -ErrorId 'NetworkLantern.Throughput.InputValidation' -TargetObject $ProfilesFile
  }
  $dir = Split-Path -Parent $ProfilesFile
  Assert-Iperf3ProfileOperationPathSafety -Resolution $Resolution
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    Assert-Iperf3ProfileOperationPathSafety -Resolution $Resolution
    $null = New-Item -ItemType Directory -Path $dir -Force
  }
  $lockPath = "$ProfilesFile.lock"
  $lockStream = $null
  $tempPath = $null
  try {
    # Lock a stable sidecar rather than the replace target itself. Readers see
    # either the old complete file or the new complete file after the rename.
    try {
      Assert-Iperf3ProfileOperationPathSafety -Resolution $Resolution
      Assert-Iperf3ProfileWritePathIsNotReparsePoint -Path $ProfilesFile
      Assert-Iperf3ProfileWritePathIsNotReparsePoint -Path $lockPath
      $lockStream = Open-ExclusiveSidecarLock -LockPath $lockPath
    }
    catch [System.IO.IOException] {
      throw "Failed to access profiles file after $($script:ExclusiveFileLockTimeoutMs)ms lock deadline (file locked): $ProfilesFile"
    }
    # Reuse the read path so mutation honors the 1 MiB limit and corrupt-store
    # backup behavior before applying any change.
    Assert-Iperf3ProfileOperationPathSafety -Resolution $Resolution
    Assert-Iperf3ProfileWritePathIsNotReparsePoint -Path $ProfilesFile
    $store = Read-Iperf3ProfilesStore -Resolution $Resolution -StrictConfiguration:$StrictConfiguration
    $store = & $Operation $store
    $store['updatedUtc'] = (Get-Date).ToUniversalTime().ToString('o')
    $json = $store | ConvertTo-Json -Depth 10
    $serializedBytes = [System.Text.Encoding]::UTF8.GetByteCount([string]$json)
    if ($serializedBytes -gt 1MB) {
      throw "Profiles file would exceed maximum size (1 MB): $ProfilesFile"
    }
    $tempName = ".{0}.{1}.tmp" -f ([System.IO.Path]::GetFileName($ProfilesFile)), ([guid]::NewGuid().ToString('N'))
    $tempPath = Join-Path -Path (Split-Path -Parent $ProfilesFile) -ChildPath $tempName
    Assert-Iperf3ProfileOperationPathSafety -Resolution $Resolution
    Assert-Iperf3ProfileWritePathIsNotReparsePoint -Path $tempPath
    Set-Content -LiteralPath $tempPath -Value $json -Encoding UTF8 -NoNewline
    Assert-Iperf3ProfileOperationPathSafety -Resolution $Resolution
    Assert-Iperf3ProfileWritePathIsNotReparsePoint -Path $ProfilesFile
    Assert-Iperf3ProfileWritePathIsNotReparsePoint -Path $tempPath
    [System.IO.File]::Move($tempPath, $ProfilesFile, $true)
    $tempPath = $null
    return $store
  }
  finally {
    if ($lockStream) { $lockStream.Dispose() }
    if ($tempPath -and (Test-Path -LiteralPath $tempPath)) {
      Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
  }
}

function Get-Iperf3ProfileNamesCore {
  [CmdletBinding()]
  [OutputType([string[]])]
  param([Parameter(Mandatory)][object]$Resolution, [switch]$StrictConfiguration)
  $store = Read-Iperf3ProfilesStore -Resolution $Resolution -StrictConfiguration:$StrictConfiguration
  return [string[]]@($store['profiles'].Keys | Sort-Object)
}

function Get-Iperf3ProfileParametersCore {
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)][string]$ProfileName,
    [Parameter(Mandatory)][object]$Resolution,
    [switch]$StrictConfiguration
  )
  $store = Read-Iperf3ProfilesStore -Resolution $Resolution -StrictConfiguration:$StrictConfiguration
  if (-not $store['profiles'].ContainsKey($ProfileName)) {
    Write-Iperf3Error -Message "Profile '$ProfileName' not found in '$($Resolution.Path)'. Use -ListProfiles to see available profile names." -ErrorId 'NetworkLantern.Throughput.InputValidation' -TargetObject $ProfileName
  }
  $rawParams = ConvertTo-Iperf3HashtableFromObject -InputObject $store['profiles'][$ProfileName]
  $allowed = Get-Iperf3ProfileStorableKeys
  return (ConvertTo-Iperf3NormalizedParameterSet -InputParameters $rawParams -AllowedKeys $allowed -StrictConfiguration:$StrictConfiguration).Parameters
}

function Save-Iperf3ProfileCore {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][string]$ProfileName,
    [Parameter(Mandatory)][hashtable]$Parameters,
    [Parameter(Mandatory)][object]$Resolution,
    [switch]$StrictConfiguration
  )
  Assert-Iperf3ProfileName -ProfileName $ProfileName
  $allowed = Get-Iperf3ProfileStorableKeys
  $toStore = @{}
  foreach ($key in $allowed) {
    if ($Parameters.ContainsKey($key)) { $toStore[$key] = $Parameters[$key] }
  }
  $normalized = ConvertTo-Iperf3NormalizedParameterSet -InputParameters $toStore -AllowedKeys $allowed -StrictConfiguration:$StrictConfiguration
  foreach ($warning in $normalized.Warnings) { Write-Warning $warning }
  $capturedParams = $normalized.Parameters
  $capturedName = $ProfileName
  $null = Invoke-LockedProfileOperation -Resolution $Resolution -StrictConfiguration:$StrictConfiguration -Operation {
    param($store)
    $store['profiles'][$capturedName] = $capturedParams
    return $store
  }
  return [pscustomobject]@{ ProfileName = $ProfileName; ProfilesFile = $Resolution.Path }
}

function Remove-Iperf3ProfileCore {
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][string]$ProfileName,
    [Parameter(Mandatory)][object]$Resolution,
    [switch]$StrictConfiguration
  )
  [ref]$removedRef = $false
  $capturedName = $ProfileName
  $null = Invoke-LockedProfileOperation -Resolution $Resolution -StrictConfiguration:$StrictConfiguration -Operation {
    param($store)
    if ($store['profiles'].ContainsKey($capturedName)) {
      $store['profiles'].Remove($capturedName) | Out-Null
      $removedRef.Value = $true
    }
    return $store
  }
  return $removedRef.Value
}
