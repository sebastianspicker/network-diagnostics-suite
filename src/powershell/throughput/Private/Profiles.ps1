# Profile storage helpers (private to NetworkLantern.Throughput)

function Get-DefaultProfilesFilePath {
  [CmdletBinding()]
  [OutputType([string])]
  param()
  return (Join-Path (Join-Path (Get-Location) '.iperf3') 'profiles.json')
}

function Resolve-ProfilesFilePath {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [string]$ProfilesFile
  )
  if ([string]::IsNullOrWhiteSpace($ProfilesFile)) {
    return (Get-DefaultProfilesFilePath)
  }
  if ($ProfilesFile -match '[\x00-\x1f]') {
    throw "ProfilesFile path contains control characters."
  }
  # Absolute paths intentionally bypass Test-PathUnderBase. When the user explicitly
  # provides a rooted path (CLI -ProfilesFile or GUI text box), they are choosing
  # a specific location outside the project directory, which is a supported use case.
  if ([System.IO.Path]::IsPathRooted($ProfilesFile)) {
    return [System.IO.Path]::GetFullPath($ProfilesFile)
  }
  $base = (Get-Location).Path
  $candidate = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($base, $ProfilesFile))
  if (-not (Test-PathUnderBase -BasePath $base -CandidatePath $candidate)) {
    throw "Profiles file path must be under the current directory. Resolved: $candidate"
  }
  return $candidate
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

function Read-Iperf3ProfilesStore {
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)]
    [string]$ProfilesFile,
    [switch]$StrictConfiguration
  )
  if (-not (Test-Path -LiteralPath $ProfilesFile -PathType Leaf)) {
    return @{
      version    = 1
      updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
      profiles   = @{}
    }
  }
  $fileInfo = Get-Item -LiteralPath $ProfilesFile
  if ($fileInfo.Length -gt 1MB) {
    throw "Profiles file exceeds maximum size (1 MB): $ProfilesFile"
  }
  $raw = Get-Content -LiteralPath $ProfilesFile -Raw -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return @{
      version    = 1
      updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
      profiles   = @{}
    }
  }
  try {
    $obj = ConvertFrom-Json -InputObject $raw -AsHashtable -ErrorAction Stop
  }
  catch {
    if ($StrictConfiguration) { throw "Profiles file is invalid JSON: $ProfilesFile" }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $backupPath = "$ProfilesFile.corrupt.$stamp.bak"
    try {
      Copy-Item -LiteralPath $ProfilesFile -Destination $backupPath -Force -ErrorAction Stop
      Write-Warning "Profiles file is invalid JSON: $ProfilesFile. Backed up to '$backupPath'. Starting with empty profile store."
    }
    catch {
      Write-Verbose "Failed to back up corrupt profiles file: $($_.Exception.Message)"
      Write-Warning "Profiles file is invalid JSON: $ProfilesFile. Starting with empty profile store."
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
    [Parameter(Mandatory)]
    [string]$ProfilesFile,
    [Parameter(Mandatory)]
    [scriptblock]$Operation,
    [switch]$StrictConfiguration
  )
  if (-not $ProfilesFile.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Profiles file must have a .json extension: $ProfilesFile"
  }
  $dir = Split-Path -Parent $ProfilesFile
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    $null = New-Item -ItemType Directory -Path $dir -Force
  }
  $lockPath = "$ProfilesFile.lock"
  $lockStream = $null
  $tempPath = $null
  try {
    # Lock a stable sidecar rather than the replace target itself. Readers see
    # either the old complete file or the new complete file after the rename.
    try {
      $lockStream = Open-ExclusiveSidecarLock -LockPath $lockPath
    }
    catch [System.IO.IOException] {
      throw "Failed to access profiles file after $($script:ExclusiveFileLockTimeoutMs)ms lock deadline (file locked): $ProfilesFile"
    }
    # Reuse the read path so mutation honors the 1 MiB limit and corrupt-store
    # backup behavior before applying any change.
    $store = Read-Iperf3ProfilesStore -ProfilesFile $ProfilesFile -StrictConfiguration:$StrictConfiguration
    $store = & $Operation $store
    $store['updatedUtc'] = (Get-Date).ToUniversalTime().ToString('o')
    $json = $store | ConvertTo-Json -Depth 10
    $serializedBytes = [System.Text.Encoding]::UTF8.GetByteCount([string]$json)
    if ($serializedBytes -gt 1MB) {
      throw "Profiles file would exceed maximum size (1 MB): $ProfilesFile"
    }
    $tempName = ".{0}.{1}.tmp" -f ([System.IO.Path]::GetFileName($ProfilesFile)), ([guid]::NewGuid().ToString('N'))
    $tempPath = Join-Path -Path (Split-Path -Parent $ProfilesFile) -ChildPath $tempName
    Set-Content -LiteralPath $tempPath -Value $json -Encoding UTF8 -NoNewline
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

function Get-Iperf3ProfileNames {
  <#
  .SYNOPSIS
  Returns the names of all saved profiles.
  .PARAMETER ProfilesFile
  Path to the profiles JSON file. Defaults to .iperf3/profiles.json.
  .OUTPUTS
  [string[]] Sorted array of profile names.
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [string]$ProfilesFile,
    [switch]$StrictConfiguration
  )
  $path = Resolve-ProfilesFilePath -ProfilesFile $ProfilesFile
  $store = Read-Iperf3ProfilesStore -ProfilesFile $path -StrictConfiguration:$StrictConfiguration
  return [string[]]@($store['profiles'].Keys | Sort-Object)
}

function Get-Iperf3ProfileParameters {
  <#
  .SYNOPSIS
  Loads and validates the parameters stored in a named profile.
  .PARAMETER ProfileName
  Name of the profile to load.
  .PARAMETER ProfilesFile
  Path to the profiles JSON file.
  .OUTPUTS
  [hashtable] Normalized parameter set from the profile.
  .EXAMPLE
  $params = Get-Iperf3ProfileParameters -ProfileName 'lab'
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)]
    [string]$ProfileName,
    [string]$ProfilesFile,
    [switch]$StrictConfiguration
  )
  $path = Resolve-ProfilesFilePath -ProfilesFile $ProfilesFile
  $store = Read-Iperf3ProfilesStore -ProfilesFile $path -StrictConfiguration:$StrictConfiguration
  if (-not $store['profiles'].ContainsKey($ProfileName)) {
    throw "Profile '$ProfileName' not found in '$path'. Use -ListProfiles to see available profile names."
  }
  $rawParams = ConvertTo-Iperf3HashtableFromObject -InputObject $store['profiles'][$ProfileName]
  $allowed = Get-Iperf3ProfileStorableKeys
  $normalized = ConvertTo-Iperf3NormalizedParameterSet -InputParameters $rawParams -AllowedKeys $allowed -StrictConfiguration:$StrictConfiguration
  return $normalized.Parameters
}

function Save-Iperf3Profile {
  <#
  .SYNOPSIS
  Saves a named parameter profile to the profiles JSON store.
  .DESCRIPTION
  Persists the given parameters under ProfileName in the profiles file.
  Only keys from Get-Iperf3ProfileStorableKeys are stored; others are silently dropped
  (or throw in StrictConfiguration mode). ProfileName must be <= 128 chars and free of
  filesystem-unsafe characters.
  .PARAMETER ProfileName
  Name for the profile (max 128 characters, no /\:*?"<>| or null bytes).
  .PARAMETER Parameters
  Hashtable of parameter key-value pairs to store.
  .PARAMETER ProfilesFile
  Path to the profiles JSON file. Defaults to .iperf3/profiles.json under the current directory.
  .PARAMETER StrictConfiguration
  When set, unknown keys or invalid values throw instead of being silently dropped.
  .EXAMPLE
  Save-Iperf3Profile -ProfileName 'lab' -Parameters @{ Target = '10.0.0.1'; Port = 5201 }
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)]
    [string]$ProfileName,
    [Parameter(Mandatory)]
    [hashtable]$Parameters,
    [string]$ProfilesFile,
    [switch]$StrictConfiguration
  )
  if ([string]::IsNullOrWhiteSpace($ProfileName)) {
    throw "ProfileName is required when using -SaveProfile."
  }
  if ($ProfileName.Length -gt 128) {
    throw "ProfileName exceeds maximum length (128 characters): '$($ProfileName.Substring(0, 32))...'."
  }
  if ($ProfileName -match '[/\\:\*\?"<>\|\x00]') {
    throw "ProfileName contains invalid characters: '$ProfileName'."
  }
  $path = Resolve-ProfilesFilePath -ProfilesFile $ProfilesFile
  $allowed = Get-Iperf3ProfileStorableKeys
  $toStore = @{}
  foreach ($k in $allowed) {
    if ($Parameters.ContainsKey($k)) { $toStore[$k] = $Parameters[$k] }
  }
  $normalized = ConvertTo-Iperf3NormalizedParameterSet -InputParameters $toStore -AllowedKeys $allowed -StrictConfiguration:$StrictConfiguration
  foreach ($w in $normalized.Warnings) { Write-Warning $w }
  $capturedParams = $normalized.Parameters
  $capturedName = $ProfileName
  $null = Invoke-LockedProfileOperation -ProfilesFile $path -StrictConfiguration:$StrictConfiguration -Operation {
    param($store)
    $store['profiles'][$capturedName] = $capturedParams
    return $store
  }
  return [pscustomobject]@{
    ProfileName = $ProfileName
    ProfilesFile = $path
  }
}

function Remove-Iperf3Profile {
  <#
  .SYNOPSIS
  Removes a named profile from the profiles JSON store.
  .PARAMETER ProfileName
  Name of the profile to remove.
  .PARAMETER ProfilesFile
  Path to the profiles JSON file.
  .OUTPUTS
  [bool] True if the profile was found and removed, false if it did not exist.
  .EXAMPLE
  Remove-Iperf3Profile -ProfileName 'lab'
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [string]$ProfileName,
    [string]$ProfilesFile,
    [switch]$StrictConfiguration
  )
  $path = Resolve-ProfilesFilePath -ProfilesFile $ProfilesFile
  $capturedName = $ProfileName
  [ref]$removedRef = $false
  $null = Invoke-LockedProfileOperation -ProfilesFile $path -StrictConfiguration:$StrictConfiguration -Operation {
    param($store)
    if ($store['profiles'].ContainsKey($capturedName)) {
      $store['profiles'].Remove($capturedName) | Out-Null
      $removedRef.Value = $true
    }
    return $store
  }
  return $removedRef.Value
}
