# Throughput application policies shared by the CLI and GUI adapters.
$script:ThroughputConfigurationMaxBytes = 1MB

function Get-ThroughputApplicationErrorRecord {
  [CmdletBinding()]
  [OutputType([System.Management.Automation.ErrorRecord])]
  param(
    [Parameter(Mandatory)][string]$Message,
    [Parameter(Mandatory)][string]$ErrorId,
    [System.Management.Automation.ErrorCategory]$Category = [System.Management.Automation.ErrorCategory]::InvalidArgument,
    [object]$TargetObject
  )
  return [System.Management.Automation.ErrorRecord]::new([System.Exception]::new($Message), $ErrorId, $Category, $TargetObject)
}

function Write-ThroughputApplicationInputError {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Message, [object]$TargetObject)
  throw (Get-ThroughputApplicationErrorRecord -Message $Message -ErrorId 'NetworkLantern.Throughput.InputValidation' -TargetObject $TargetObject)
}

function Test-ThroughputPathUnderBase {
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][string]$BasePath,
    [Parameter(Mandatory)][string]$CandidatePath
  )

  $baseFull = [System.IO.Path]::GetFullPath($BasePath)
  $candidateFull = [System.IO.Path]::GetFullPath($CandidatePath)
  $separators = @([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  $baseWithSeparator = $baseFull.TrimEnd($separators) + [System.IO.Path]::DirectorySeparatorChar
  $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
  return $candidateFull.Equals($baseFull, $comparison) -or $candidateFull.StartsWith($baseWithSeparator, $comparison)
}

function Test-ThroughputProcessIsElevated {
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

function Assert-ThroughputRelativePathHasNoReparsePoint {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$BasePath,
    [Parameter(Mandatory)][string]$CandidatePath,
    [Parameter(Mandatory)][string]$PathDescription
  )

  $baseFull = [System.IO.Path]::GetFullPath($BasePath)
  $candidateFull = [System.IO.Path]::GetFullPath($CandidatePath)
  if (-not (Test-ThroughputPathUnderBase -BasePath $baseFull -CandidatePath $candidateFull)) {
    Write-ThroughputApplicationInputError -Message "$PathDescription must be under the current directory. Resolved: $candidateFull" -TargetObject $candidateFull
  }

  # GetFullPath is lexical only. Inspect every existing component below the
  # operator's working directory so a relative path cannot escape through a
  # symlink or Windows reparse point. Once a component is absent, descendants
  # cannot exist, so the remaining destination is safe to create normally.
  $relativePath = [System.IO.Path]::GetRelativePath($baseFull, $candidateFull)
  $currentPath = $baseFull
  foreach ($component in @($relativePath -split '[\\/]' | Where-Object { $_ -and $_ -ne '.' })) {
    $currentPath = Join-Path -Path $currentPath -ChildPath $component
    try {
      $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
    }
    catch [System.Management.Automation.ItemNotFoundException] {
      break
    }
    catch {
      Write-ThroughputApplicationInputError -Message "$PathDescription could not validate path component '$currentPath': $($_.Exception.Message)" -TargetObject $currentPath
    }
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      Write-ThroughputApplicationInputError -Message "$PathDescription must not traverse a symbolic link or reparse point: $currentPath" -TargetObject $currentPath
    }
  }
  return $candidateFull
}

function Resolve-ThroughputConfigurationPath {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$Path,
    [string]$BasePath = (Get-Location).Path,
    [switch]$RequireExistingFile
  )
  if ($Path -match '[\x00-\x1f]') {
    Write-ThroughputApplicationInputError -Message 'Configuration path contains control characters.' -TargetObject $Path
  }
  $isRelative = -not [System.IO.Path]::IsPathRooted($Path)
  if ($isRelative -and (Test-ThroughputProcessIsElevated)) {
    Write-ThroughputApplicationInputError -Message 'Relative configuration paths are refused when the process is elevated. Use an explicit absolute configuration path.' -TargetObject $Path
  }
  $base = [System.IO.Path]::GetFullPath($BasePath)
  $resolved = if ([System.IO.Path]::IsPathRooted($Path)) {
    $candidate = [System.IO.Path]::GetFullPath($Path)
    if (Test-ThroughputPathUnderBase -BasePath $base -CandidatePath $candidate) {
      Assert-ThroughputRelativePathHasNoReparsePoint -BasePath $base -CandidatePath $candidate -PathDescription 'Configuration path'
    }
    else { $candidate }
  } else {
    $candidate = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($base, $Path))
    Assert-ThroughputRelativePathHasNoReparsePoint -BasePath $base -CandidatePath $candidate -PathDescription 'Configuration path'
  }
  if ($RequireExistingFile -and -not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    Write-ThroughputApplicationInputError -Message "Configuration path is not a file: $resolved" -TargetObject $resolved
  }
  return $resolved
}

function Read-ThroughputConfigurationFile {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$Path,
    [Parameter(Mandatory)]
    [string]$BasePath
  )

  if (Test-ThroughputPathUnderBase -BasePath $BasePath -CandidatePath $Path) {
    Assert-ThroughputRelativePathHasNoReparsePoint -BasePath $BasePath -CandidatePath $Path -PathDescription 'Configuration path'
  }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Write-ThroughputApplicationInputError -Message "Configuration path is not a file: $Path" -TargetObject $Path
  }

  $stream = $null
  try {
    # Revalidate immediately before opening. FileShare.Read holds an opened
    # handle stable on platforms that support sharing semantics; on Unix this
    # remains a non-elevated best-effort policy, not adversarial containment.
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $buffer = [byte[]]::new($script:ThroughputConfigurationMaxBytes + 1)
    $total = 0
    while ($total -lt $buffer.Length) {
      $read = $stream.Read($buffer, $total, $buffer.Length - $total)
      if ($read -eq 0) { break }
      $total += $read
    }
    if ($total -gt $script:ThroughputConfigurationMaxBytes) {
      Write-ThroughputApplicationInputError -Message "Configuration file exceeds maximum size (1 MB): $Path" -TargetObject $Path
    }
    $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $total)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    return $text
  }
  catch [System.Management.Automation.RuntimeException] { throw }
  catch {
    Write-ThroughputApplicationInputError -Message "Configuration file could not be read: $Path. $($_.Exception.Message)" -TargetObject $Path
  }
  finally {
    if ($stream) { $stream.Dispose() }
  }
}

function Resolve-ThroughputExitCode {
  [CmdletBinding()]
  [OutputType([int])]
  param(
    [Parameter(Mandatory)]
    [System.Management.Automation.ErrorRecord]$ErrorRecord,
    [Parameter(Mandatory)]
    [hashtable]$ErrorIdToExitCode,
    [Parameter(Mandatory)]
    [int]$InternalExitCode
  )
  $errorId = ([string]$ErrorRecord.FullyQualifiedErrorId -split ',')[0]
  $code = $ErrorIdToExitCode[$errorId]
  if ($null -ne $code) { return [int]$code }

  return $InternalExitCode
}
