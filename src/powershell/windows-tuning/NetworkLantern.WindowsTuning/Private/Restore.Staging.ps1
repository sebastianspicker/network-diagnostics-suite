function New-NetworkTuningRestoreStagingSession {
  [CmdletBinding(SupportsShouldProcess = $true)]
  [OutputType([pscustomobject])]
  param()

  $isWindowsRuntime = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
  $parentPath = if ($isWindowsRuntime) { Get-NetworkTuningWindowsRestoreStagingRoot } else { [System.IO.Path]::GetTempPath() }
  $stagingPath = Join-Path -Path $parentPath -ChildPath ("NetworkLantern-Restore-{0}" -f [guid]::NewGuid().ToString('N'))
  if (-not $PSCmdlet.ShouldProcess($stagingPath, 'Create restricted restore staging session')) {
    throw 'Restore staging session creation was declined.'
  }

  $sentinelStream = $null
  try {
    if ($isWindowsRuntime) {
      $stagingPath = Initialize-NetworkTuningAdminOnlyDirectory -Path $stagingPath -Confirm:$false
    } else {
      [System.IO.Directory]::CreateDirectory($stagingPath) | Out-Null
      $stagingItem = Get-Item -LiteralPath $stagingPath -Force -ErrorAction Stop
      if (($stagingItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Restore staging session unexpectedly resolved to a reparse point.'
      }
    }

    $nonce = [guid]::NewGuid().ToString('N')
    $sentinelPath = Join-Path -Path $stagingPath -ChildPath '.restore-session'
    $sentinelStream = [System.IO.File]::Open(
      $sentinelPath,
      [System.IO.FileMode]::CreateNew,
      [System.IO.FileAccess]::ReadWrite,
      [System.IO.FileShare]::Read
    )
    $nonceBytes = [System.Text.Encoding]::UTF8.GetBytes($nonce)
    $sentinelStream.Write($nonceBytes, 0, $nonceBytes.Length)
    $sentinelStream.Flush($true)
    $sentinelStream.Position = 0
    if ($isWindowsRuntime) {
      Protect-NetworkTuningAdminOnlyFile -Path $sentinelPath -Confirm:$false
    }

    return [pscustomobject]@{
      Path = $stagingPath
      ParentPath = $parentPath
      SentinelPath = $sentinelPath
      Nonce = $nonce
      SentinelStream = $sentinelStream
      IsWindows = $isWindowsRuntime
    }
  } catch {
    if ($null -ne $sentinelStream) { $sentinelStream.Dispose() }
    Remove-Item -LiteralPath $stagingPath -Recurse -Force -ErrorAction SilentlyContinue
    throw "Could not create a trusted restore staging session: $($_.Exception.Message)"
  }
}

function Close-NetworkTuningRestoreStagingSession {
  [CmdletBinding()]
  [OutputType([void])]
  param(
    [Parameter(Mandatory)]$Session
  )

  if ($null -ne $Session.SentinelStream) {
    $Session.SentinelStream.Dispose()
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$Session.Path)) {
    Remove-Item -LiteralPath $Session.Path -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Test-NetworkTuningRestoreStagingInvariant {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)]$Session,
    [Parameter(Mandatory)][hashtable]$Manifest
  )

  try {
    $fullPath = [System.IO.Path]::GetFullPath([string]$Session.Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $fullParent = [System.IO.Path]::GetFullPath([string]$Session.ParentPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $actualParent = [System.IO.Path]::GetDirectoryName($fullPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $comparison = if ([bool]$Session.IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    if (-not $actualParent.Equals($fullParent, $comparison)) {
      return [pscustomobject]@{ IsValid = $false; Message = 'Restore staging session moved outside its trusted parent.' }
    }

    $expectedSentinelPath = Join-Path -Path $fullPath -ChildPath '.restore-session'
    if (-not ([string]$Session.SentinelPath).Equals($expectedSentinelPath, $comparison)) {
      return [pscustomobject]@{ IsValid = $false; Message = 'Restore staging sentinel path changed.' }
    }

    $pathsToInspect = @($fullPath, $expectedSentinelPath)
    foreach ($artifactName in (Get-NetworkTuningExpectedBackupArtifactNames -Manifest $Manifest)) {
      $pathsToInspect += Join-Path -Path $fullPath -ChildPath $artifactName
    }
    foreach ($path in $pathsToInspect) {
      $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
      if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        return [pscustomobject]@{ IsValid = $false; Message = "Restore staging path became a reparse point: $path" }
      }
      if ([bool]$Session.IsWindows) {
        $pathCheck = Test-NetworkTuningWindowsAdminOnlyPath -Path $path
        if (-not $pathCheck.IsTrusted) {
          return [pscustomobject]@{ IsValid = $false; Message = $pathCheck.Message }
        }
      }
    }

    if ($null -eq $Session.SentinelStream -or $Session.SentinelStream.SafeFileHandle.IsClosed) {
      return [pscustomobject]@{ IsValid = $false; Message = 'Restore staging sentinel handle is not open.' }
    }
    $sentinelText = Read-NetworkTuningBoundedTextFile -Path $expectedSentinelPath -MaximumBytes 128
    if ($sentinelText -cne [string]$Session.Nonce) {
      return [pscustomobject]@{ IsValid = $false; Message = 'Restore staging sentinel does not match the verified session.' }
    }

    $digestCheck = Test-NetworkTuningBackupArtifactDigests -BackupFolder $fullPath -Manifest $Manifest
    if (-not $digestCheck.IsValid) {
      return [pscustomobject]@{ IsValid = $false; Message = "Staged backup verification failed: $($digestCheck.Message)" }
    }
    $authorizationCheck = Test-NetworkTuningRestoreArtifactAuthorization -BackupFolder $fullPath -Manifest $Manifest
    if (-not $authorizationCheck.IsAuthorized) {
      return [pscustomobject]@{ IsValid = $false; Message = "Staged backup authorization failed: $($authorizationCheck.Message)" }
    }
  } catch {
    return [pscustomobject]@{ IsValid = $false; Message = "Restore staging invariant failed: $($_.Exception.Message)" }
  }

  return [pscustomobject]@{ IsValid = $true; Message = '' }
}

function Assert-NetworkTuningRestoreStagingInvariant {
  [CmdletBinding()]
  [OutputType([void])]
  param(
    [Parameter(Mandatory)]$Session,
    [Parameter(Mandatory)][hashtable]$Manifest
  )

  $check = Test-NetworkTuningRestoreStagingInvariant -Session $Session -Manifest $Manifest
  if (-not $check.IsValid) {
    $exception = [System.InvalidOperationException]::new($check.Message)
    $exception.Data['NetworkLantern.RestoreStagingInvariant'] = $true
    throw $exception
  }
}

function Assert-NetworkTuningRestoreStagingConsumerInvariant {
  [CmdletBinding()]
  [OutputType([void])]
  param(
    [Parameter(Mandatory)]$Session,
    [Parameter(Mandatory)][hashtable]$Manifest
  )

  Assert-NetworkTuningRestoreStagingInvariant -Session $Session -Manifest $Manifest
}

function Copy-NetworkTuningBoundedArtifactToStaging {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$DestinationPath,
    [Parameter(Mandatory)][long]$MaximumBytes,
    [Parameter(Mandatory)][string]$ExpectedSha256,
    [Parameter(Mandatory)][bool]$WindowsRuntime
  )

  $sourceCheck = Test-NetworkTuningBackupPathEntryIsRegular -Path $SourcePath
  if (-not $sourceCheck.IsTrusted) { throw $sourceCheck.Message }
  $destinationStream = $null
  $hasher = $null
  try {
    # The source is opened once, with sharing that denies replacement and
    # writes. Hashing and copying consume the same bounded byte stream.
    $destinationStream = [System.IO.File]::Open($DestinationPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $hasher = [System.Security.Cryptography.IncrementalHash]::CreateHash([System.Security.Cryptography.HashAlgorithmName]::SHA256)
    Invoke-NetworkTuningBoundedFileStream -Path $SourcePath -MaximumBytes $MaximumBytes -OnChunk {
      param($buffer, $read)
      $hasher.AppendData($buffer, 0, $read)
      $destinationStream.Write($buffer, 0, $read)
    } | Out-Null
    $destinationStream.Flush($true)
    $hash = [System.Convert]::ToHexString($hasher.GetHashAndReset())
  } finally {
    if ($null -ne $hasher) { $hasher.Dispose() }
    if ($null -ne $destinationStream) { $destinationStream.Dispose() }
  }

  if ($hash -cne $ExpectedSha256) { throw "Backup artifact digest mismatch while staging: $([System.IO.Path]::GetFileName($SourcePath))" }
  $destinationCheck = Test-NetworkTuningBackupPathEntryIsRegular -Path $DestinationPath
  if (-not $destinationCheck.IsTrusted) { throw $destinationCheck.Message }
  if ($WindowsRuntime) {
    Protect-NetworkTuningAdminOnlyFile -Path $DestinationPath -Confirm:$false
    $destinationAclCheck = Test-NetworkTuningWindowsAdminOnlyPath -Path $DestinationPath
    if (-not $destinationAclCheck.IsTrusted) { throw $destinationAclCheck.Message }
  }
  return $hash
}

function Copy-NetworkTuningVerifiedBackupToStaging {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][string]$BackupFolder,
    [Parameter(Mandatory)][hashtable]$Manifest
  )

  $session = New-NetworkTuningRestoreStagingSession -Confirm:$false
  try {
    foreach ($artifactName in (Get-NetworkTuningExpectedBackupArtifactNames -Manifest $Manifest)) {
      $sourcePath = Join-Path -Path $BackupFolder -ChildPath $artifactName
      $destinationPath = Join-Path -Path $session.Path -ChildPath $artifactName
      $expectedDigest = [string]$Manifest.ArtifactDigests[$artifactName]
      Copy-NetworkTuningBoundedArtifactToStaging -SourcePath $sourcePath -DestinationPath $destinationPath -MaximumBytes (Get-NetworkTuningBackupArtifactMaximumBytes -FileName $artifactName) -ExpectedSha256 $expectedDigest -WindowsRuntime ([bool]$session.IsWindows) | Out-Null
    }

    Assert-NetworkTuningRestoreStagingInvariant -Session $session -Manifest $Manifest
    return $session
  } catch {
    Close-NetworkTuningRestoreStagingSession -Session $session
    throw
  }
}
